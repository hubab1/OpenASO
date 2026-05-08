import Foundation
import SwiftData

final class OpenASOMCPService: Sendable {
  private enum ResponseLimits {
    static let overviewStorefrontMetadata = 8
    static let overviewRatings = 25
    static let overviewCompetitors = 5
    static let overviewCompetitorEvidence = 8
    static let overviewDescriptionCharacters = 1_200
    static let overviewReleaseNotesCharacters = 800
    static let defaultCompetitorEvidence = 20
    static let maximumCompetitorEvidence = 100
    static let defaultLandscapeKeywordLimit = 20
    static let maximumLandscapeKeywordLimit = 50
    static let defaultRankingAppLimit = 25
    static let maximumRankingAppLimit = 50
    static let defaultKeywordRefreshTrackLimit = 20
    static let maximumKeywordRefreshTrackLimit = 25
    static let keywordVerificationSearchBudget = 16
    static let rankingSearchTimeoutNanoseconds: UInt64 = 20_000_000_000
    static let bigAppRatingThreshold = 10_000
    static let maximumReviewsPerLandscapeApp = 500
    static let maximumScreenshotsPerLandscapeApp = 12
    static let defaultCompetitorReviewLimit = 100
    static let maximumCompetitorReviewLimit = 500
    static let defaultReviewRefreshLimit = 200
    static let maximumReviewRefreshLimit = 500
    static let defaultReviewDownloadBatchPageCount = 5
    static let maximumReviewDownloadBatchPageCount = 25
    static let defaultLocalizationCompetitorLimit = 10
    static let maximumLocalizationCompetitorLimit = 20
    static let localizationDescriptionCharacters = 1_200
    static let localizationReleaseNotesCharacters = 800
  }

  private static let localizationBaselineStorefront = "us"
  private static let defaultLocalizationStorefronts = [
    "us", "jp", "cn", "gb", "de", "fr", "ca", "au", "kr", "br",
    "mx", "es", "it", "nl", "se", "ch", "tr", "in", "id", "sa",
  ]

  private let backgroundModelStore: BackgroundModelStore
  private let appResolver: any AppResolver
  private let appCatalogService: AppCatalogService
  private let httpClient: any HTTPClient
  private let screenshotDownloadService: ScreenshotDownloadService
  private let rankingProvider: (any SearchRankingProvider)?
  private let rankingRefreshCoordinator: RankingRefreshCoordinator?
  private let reviewService: AppStorefrontReviewService?
  private let keywordMetricsService: KeywordMetricsService?
  private let popularityContextAppStoreIDProvider: @MainActor @Sendable () -> Int64?
  private let appleAdsWebSessionProvider: @MainActor @Sendable () -> AppleAdsWebSession?
  private let now: @Sendable () -> Date

  init(
    backgroundModelStore: BackgroundModelStore,
    appResolver: any AppResolver,
    appCatalogService: AppCatalogService,
    httpClient: any HTTPClient = URLSessionHTTPClient(),
    screenshotDownloadService: ScreenshotDownloadService = ScreenshotDownloadService(),
    rankingProvider: (any SearchRankingProvider)? = nil,
    rankingRefreshCoordinator: RankingRefreshCoordinator? = nil,
    reviewService: AppStorefrontReviewService? = nil,
    keywordMetricsService: KeywordMetricsService? = nil,
    popularityContextAppStoreIDProvider: @escaping @MainActor @Sendable () -> Int64? = { nil },
    appleAdsWebSessionProvider: @escaping @MainActor @Sendable () -> AppleAdsWebSession? = { nil },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.backgroundModelStore = backgroundModelStore
    self.appResolver = appResolver
    self.appCatalogService = appCatalogService
    self.httpClient = httpClient
    self.screenshotDownloadService = screenshotDownloadService
    self.rankingProvider = rankingProvider
    self.rankingRefreshCoordinator = rankingRefreshCoordinator
    self.reviewService = reviewService
    self.keywordMetricsService = keywordMetricsService
    self.popularityContextAppStoreIDProvider = popularityContextAppStoreIDProvider
    self.appleAdsWebSessionProvider = appleAdsWebSessionProvider
    self.now = now
  }

  func listApps(
    includeUntrackedCatalogApps: Bool = false,
    folder: String? = nil,
    page: OpenASOMCPPageRequest = OpenASOMCPPageRequest(limit: nil, cursor: nil)
  ) async throws -> OpenASOMCPPage<OpenASOMCPAppSummary> {
    try await backgroundModelStore.read { modelContext in
      let trackedApps = try modelContext.fetch(
        FetchDescriptor<TrackedApp>(
          sortBy: [
            SortDescriptor(\.sidebarSortOrder, order: .forward),
            SortDescriptor(\.createdAt, order: .forward),
          ]
        ))
      var summaries =
        trackedApps
        .filter { trackedApp in
          guard let folder else { return true }
          return trackedApp.folder?.name.localizedCaseInsensitiveCompare(folder) == .orderedSame
        }
        .map { Self.appSummary(trackedApp: $0) }

      if includeUntrackedCatalogApps {
        let trackedIDs = Set(trackedApps.map(\.appStoreID))
        let storeApps = try modelContext.fetch(
          FetchDescriptor<StoreApp>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
          ))
        summaries +=
          storeApps
          .filter { !trackedIDs.contains($0.appStoreID) }
          .map { Self.appSummary(storeApp: $0, trackedApp: nil) }
      }

      let total = summaries.count
      let items = Array(summaries.dropFirst(page.offset).prefix(page.limit))
      return OpenASOMCPPage(
        items: items,
        nextCursor: OpenASOMCPValidation.nextCursor(
          offset: page.offset,
          limit: page.limit,
          returnedCount: items.count,
          totalCount: total
        ),
        total: total
      )
    }
  }

  func searchAppStoreApps(query: String, storefront: String, limit: Int? = nil) async throws
    -> [OpenASOMCPResolvedApp]
  {
    let query = try OpenASOMCPValidation.keyword(query)
    let storefront = try OpenASOMCPValidation.storefront(storefront)
    let limit = OpenASOMCPValidation.cappedLimit(limit, default: 25, maximum: 50)
    return try await appResolver.searchApps(
      named: query,
      storefrontCode: storefront,
      limit: limit
    ).map(Self.resolvedApp)
  }

  func detectApp(query: String, storefront: String, limit: Int? = nil) async throws
    -> OpenASOMCPAppDetectionResult
  {
    let query = try OpenASOMCPValidation.keyword(query)
    let storefront = try OpenASOMCPValidation.storefront(storefront)
    let candidates: [OpenASOMCPResolvedApp]
    if let appStoreID = Int64(query.trimmingCharacters(in: CharacterSet(charactersIn: " /"))) {
      candidates = [
        Self.resolvedApp(
          try await appResolver.resolve(appStoreID: appStoreID, storefrontCode: storefront))
      ]
    } else if let appStoreID = Self.appStoreID(fromPossibleURL: query) {
      candidates = [
        Self.resolvedApp(
          try await appResolver.resolve(appStoreID: appStoreID, storefrontCode: storefront))
      ]
    } else {
      candidates = try await searchAppStoreApps(query: query, storefront: storefront, limit: limit)
    }

    let recommended = candidates.first
    let confirmationPrompt: String
    if let recommended {
      confirmationPrompt =
        "Is this the app to onboard: \(recommended.name) (\(recommended.appStoreID)) by \(recommended.sellerName ?? "unknown seller")?"
    } else {
      confirmationPrompt =
        "No App Store candidates were found. Ask the user for an App Store URL or app ID."
    }
    return OpenASOMCPAppDetectionResult(
      query: query,
      storefront: storefront,
      candidates: candidates,
      recommendedAppStoreID: recommended?.appStoreID,
      requiresConfirmation: recommended != nil,
      confirmationPrompt: confirmationPrompt
    )
  }

  func addTrackedApp(appStoreID: Int64, storefront: String) async throws
    -> OpenASOMCPAddTrackedAppResult
  {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefront = try OpenASOMCPValidation.storefront(storefront)
    let resolvedApp = try await appResolver.resolve(
      appStoreID: appStoreID, storefrontCode: storefront)

    return try await backgroundModelStore.write { modelContext in
      let storeApp = try appCatalogService.upsertStoreApp(
        from: resolvedApp,
        storefrontCode: storefront,
        in: modelContext
      )
      storeApp.defaultStorefront = storefront

      var descriptor = FetchDescriptor<TrackedApp>(
        predicate: #Predicate { trackedApp in
          trackedApp.appStoreID == appStoreID
        }
      )
      descriptor.fetchLimit = 1

      let trackedApp: TrackedApp
      var summary = OpenASOMCPMutationSummary.empty
      if let existing = try modelContext.fetch(descriptor).first {
        existing.storeApp = storeApp
        existing.bundleID = resolvedApp.bundleID
        existing.name = resolvedApp.name
        existing.subtitle = resolvedApp.subtitle
        existing.sellerName = resolvedApp.sellerName
        existing.defaultPlatform = resolvedApp.defaultPlatform
        trackedApp = existing
        summary.updated = 1
      } else {
        let sidebarSortOrder =
          try modelContext.fetch(FetchDescriptor<TrackedApp>())
          .filter { $0.folder == nil }
          .map(\.sidebarSortOrder)
          .max()
          .map { $0 + 1 } ?? 0
        let inserted = TrackedApp(
          appStoreID: resolvedApp.appStoreID,
          storeApp: storeApp,
          sidebarSortOrder: sidebarSortOrder
        )
        modelContext.insert(inserted)
        trackedApp = inserted
        summary.inserted = 1
      }

      return OpenASOMCPAddTrackedAppResult(
        app: Self.appSummary(trackedApp: trackedApp),
        summary: summary
      )
    }
  }

  func getAppOverview(appStoreID: Int64) async throws -> OpenASOMCPAppOverview {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    return try await backgroundModelStore.read { modelContext in
      guard let storeApp = try Self.fetchStoreApp(appStoreID: appStoreID, in: modelContext) else {
        throw OpenASOError.appNotFound
      }
      let trackedApp = try Self.fetchTrackedApp(appStoreID: appStoreID, in: modelContext)
      let app = Self.appSummary(storeApp: storeApp, trackedApp: trackedApp)
      let metadata = storeApp.storefrontMetadata
        .sorted { $0.storefront < $1.storefront }
        .prefix(ResponseLimits.overviewStorefrontMetadata)
        .map {
          Self.storefrontMetadata(
            $0,
            descriptionLimit: ResponseLimits.overviewDescriptionCharacters,
            releaseNotesLimit: ResponseLimits.overviewReleaseNotesCharacters
          )
        }
      let ratings = storeApp.storefrontLatest
        .sorted { $0.storefront < $1.storefront }
        .prefix(ResponseLimits.overviewRatings)
        .map(Self.ratingSummary)
      let reviews = Self.reviewSummary(reviews: storeApp.reviews)
      let keywords =
        trackedApp.map { Self.keywordOverviewSummary(tracks: $0.keywordTracks) }
        ?? OpenASOMCPKeywordOverviewSummary(totalCount: 0, storefronts: [], latestRefreshAt: nil)
      let screenshots = Self.screenshotSummary(
        screenshots: storeApp.storefrontMetadata.flatMap(\.screenshots))
      let competitors = try Self.deriveCompetitors(
        appStoreID: appStoreID,
        storefronts: [],
        platform: nil,
        lookbackDays: 180,
        limit: ResponseLimits.overviewCompetitors,
        evidenceLimit: ResponseLimits.overviewCompetitorEvidence,
        in: modelContext
      )

      return OpenASOMCPAppOverview(
        app: app,
        storefrontMetadata: metadata,
        ratings: ratings,
        reviewSummary: reviews,
        keywordSummary: keywords,
        screenshotSummary: screenshots,
        topCompetitors: competitors,
        freshnessWarnings: Self.freshnessWarnings(
          app: app,
          reviewSummary: reviews,
          keywordSummary: keywords,
          screenshotSummary: screenshots,
          now: now()
        )
      )
    }
  }

  func listReviews(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    ratingMin: Int? = nil,
    ratingMax: Int? = nil,
    version: String? = nil,
    dateFrom: Date? = nil,
    dateTo: Date? = nil,
    page: OpenASOMCPPageRequest = OpenASOMCPPageRequest(limit: nil, cursor: nil)
  ) async throws -> OpenASOMCPPage<OpenASOMCPReview> {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = Set(try OpenASOMCPValidation.storefronts(storefronts))
    return try await backgroundModelStore.read { modelContext in
      let descriptor = FetchDescriptor<AppStorefrontReview>(
        predicate: #Predicate { review in
          review.appStoreID == appStoreID
        },
        sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)]
      )
      let filtered = try modelContext.fetch(descriptor).filter { review in
        if !storefronts.isEmpty && !storefronts.contains(review.storefront) { return false }
        if let ratingMin, review.rating < ratingMin { return false }
        if let ratingMax, review.rating > ratingMax { return false }
        if let version, review.version != version { return false }
        if let dateFrom, review.reviewedAt < dateFrom { return false }
        if let dateTo, review.reviewedAt > dateTo { return false }
        return true
      }
      let total = filtered.count
      let items = Array(filtered.dropFirst(page.offset).prefix(page.limit)).map(Self.review)
      return OpenASOMCPPage(
        items: items,
        nextCursor: OpenASOMCPValidation.nextCursor(
          offset: page.offset,
          limit: page.limit,
          returnedCount: items.count,
          totalCount: total
        ),
        total: total
      )
    }
  }

  func listKeywords(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    page: OpenASOMCPPageRequest = OpenASOMCPPageRequest(limit: nil, cursor: nil)
  ) async throws -> OpenASOMCPPage<OpenASOMCPKeywordSummary> {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = Set(try OpenASOMCPValidation.storefronts(storefronts))
    let platform = try platform.map(OpenASOMCPValidation.platform)
    return try await backgroundModelStore.read { modelContext in
      let descriptor = FetchDescriptor<TrackedAppKeyword>(
        predicate: #Predicate { track in
          track.appStoreID == appStoreID
        },
        sortBy: [
          SortDescriptor(\.storefront, order: .forward),
          SortDescriptor(\.term, order: .forward),
        ]
      )
      let tracks = try modelContext.fetch(descriptor).filter { track in
        if !storefronts.isEmpty && !storefronts.contains(track.storefront) { return false }
        if let platform, track.platform != platform { return false }
        return true
      }
      let metricsByQueryKey = try Self.metricsByQueryKey(
        queryKeys: Array(Set(tracks.map(\.queryKey))),
        in: modelContext
      )
      let total = tracks.count
      let items = Array(tracks.dropFirst(page.offset).prefix(page.limit)).map {
        Self.keywordSummary(track: $0, metrics: metricsByQueryKey[$0.queryKey])
      }
      return OpenASOMCPPage(
        items: items,
        nextCursor: OpenASOMCPValidation.nextCursor(
          offset: page.offset,
          limit: page.limit,
          returnedCount: items.count,
          totalCount: total
        ),
        total: total
      )
    }
  }

  func scoreKeywords(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil
  ) async throws -> OpenASOMCPKeywordScoreResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let page = try await listKeywords(
      appStoreID: appStoreID,
      storefronts: storefronts,
      platform: platform,
      page: OpenASOMCPPageRequest(limit: 200, cursor: nil)
    )
    let scores = page.items.map(Self.keywordScore)
    let summary = OpenASOMCPKeywordScoreSummary(
      totalCount: scores.count,
      defendCount: scores.filter { $0.priority == "defend" }.count,
      attackCount: scores.filter { $0.priority == "attack" }.count,
      longTailCount: scores.filter { $0.priority == "long_tail" }.count,
      brandCount: scores.filter { $0.priority == "brand" }.count,
      experimentalCount: scores.filter { $0.priority == "experimental" }.count,
      noisyCount: scores.filter { $0.priority == "noisy" }.count
    )
    return OpenASOMCPKeywordScoreResult(
      appStoreID: String(appStoreID),
      storefronts: Array(Set(scores.map(\.storefront))).sorted(),
      platform: platform,
      items: scores,
      summary: summary,
      notes: [
        "Scores are deterministic heuristics for triage, not search-volume forecasts.",
        "Use noisy keywords as pruning candidates unless separate ranking evidence proves relevance.",
        "Use defend keywords to monitor existing visibility and attack keywords to prioritize competitor opportunities.",
      ]
    )
  }

  func addKeywords(
    appStoreID: Int64,
    keywords: [String],
    storefronts: [String],
    platform: String? = nil
  ) async throws -> OpenASOMCPAddKeywordsResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let keywords = try OpenASOMCPValidation.keywords(keywords)
    let storefronts = try OpenASOMCPValidation.storefronts(storefronts)
    let platform = try OpenASOMCPValidation.platform(platform)
    guard !storefronts.isEmpty else {
      throw OpenASOError.providerUnavailable("Select at least one storefront.")
    }

    return try await backgroundModelStore.write { modelContext in
      guard let trackedApp = try Self.fetchTrackedApp(appStoreID: appStoreID, in: modelContext)
      else {
        throw OpenASOError.appNotFound
      }

      let existingKeys = Set(trackedApp.keywordTracks.map(\.identityKey))
      var mutableExistingKeys = existingKeys
      var insertedTracks: [TrackedAppKeyword] = []
      var skipped: [OpenASOMCPSkippedKeyword] = []

      for storefront in storefronts {
        for keyword in keywords {
          let identityKey = TrackedAppKeyword.makeIdentityKey(
            appStoreID: appStoreID,
            term: keyword,
            storefront: storefront,
            platform: platform
          )
          guard !mutableExistingKeys.contains(identityKey) else {
            skipped.append(
              OpenASOMCPSkippedKeyword(
                keyword: keyword,
                storefront: storefront,
                platform: platform.rawValue,
                reason: "already_tracked"
              ))
            continue
          }

          let query = try KeywordQuery.fetchOrInsert(
            term: keyword,
            storefront: storefront,
            platform: platform,
            in: modelContext
          )
          let track = TrackedAppKeyword(
            term: keyword,
            storefront: storefront,
            platform: platform,
            trackedApp: trackedApp,
            query: query
          )
          trackedApp.keywordTracks.append(track)
          modelContext.insert(track)
          insertedTracks.append(track)
          mutableExistingKeys.insert(identityKey)
        }
      }

      let metrics = try Self.metricsByQueryKey(
        queryKeys: insertedTracks.map(\.queryKey),
        in: modelContext
      )
      return OpenASOMCPAddKeywordsResult(
        summary: OpenASOMCPMutationSummary(
          inserted: insertedTracks.count,
          updated: 0,
          skipped: skipped.count,
          refreshed: 0,
          failed: 0
        ),
        inserted: insertedTracks.map {
          Self.keywordSummary(track: $0, metrics: metrics[$0.queryKey])
        },
        skipped: skipped
      )
    }
  }

  func updateKeywordNotes(
    appStoreID: Int64,
    keyword: String,
    storefront: String,
    platform: String?,
    notes: String
  ) async throws -> OpenASOMCPKeywordNotesResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let keyword = try OpenASOMCPValidation.keyword(keyword)
    let storefront = try OpenASOMCPValidation.storefront(storefront)
    let platform = try OpenASOMCPValidation.platform(platform)
    let identityKey = TrackedAppKeyword.makeIdentityKey(
      appStoreID: appStoreID,
      term: keyword,
      storefront: storefront,
      platform: platform
    )

    return try await backgroundModelStore.write { modelContext in
      var descriptor = FetchDescriptor<TrackedAppKeyword>(
        predicate: #Predicate { track in
          track.identityKey == identityKey
        }
      )
      descriptor.fetchLimit = 1
      guard let track = try modelContext.fetch(descriptor).first else {
        throw OpenASOError.appNotFound
      }
      track.notes = notes
      let metrics = try Self.metricsByQueryKey(queryKeys: [track.queryKey], in: modelContext)
      return OpenASOMCPKeywordNotesResult(
        track: Self.keywordSummary(track: track, metrics: metrics[track.queryKey]),
        summary: OpenASOMCPMutationSummary(
          inserted: 0,
          updated: 1,
          skipped: 0,
          refreshed: 0,
          failed: 0
        )
      )
    }
  }

  func listScreenshots(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    page: OpenASOMCPPageRequest = OpenASOMCPPageRequest(limit: nil, cursor: nil)
  ) async throws -> OpenASOMCPPage<OpenASOMCPScreenshot> {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = Set(try OpenASOMCPValidation.storefronts(storefronts))
    let platform = try platform.map(OpenASOMCPValidation.platform)
    return try await backgroundModelStore.read { modelContext in
      let descriptor = FetchDescriptor<AppStoreScreenshot>(
        predicate: #Predicate { screenshot in
          screenshot.appStoreID == appStoreID
        },
        sortBy: [
          SortDescriptor(\.storefront, order: .forward),
          SortDescriptor(\.platformRaw, order: .forward),
          SortDescriptor(\.sortOrder, order: .forward),
        ]
      )
      let screenshots = try modelContext.fetch(descriptor).filter { screenshot in
        if !storefronts.isEmpty && !storefronts.contains(screenshot.storefront) { return false }
        if let platform, screenshot.platformRaw != platform.rawValue { return false }
        return true
      }
      let total = screenshots.count
      let items = Array(screenshots.dropFirst(page.offset).prefix(page.limit)).map(Self.screenshot)
      return OpenASOMCPPage(
        items: items,
        nextCursor: OpenASOMCPValidation.nextCursor(
          offset: page.offset,
          limit: page.limit,
          returnedCount: items.count,
          totalCount: total
        ),
        total: total
      )
    }
  }

  func exportScreenshots(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    destinationDirectoryPath: String
  ) async throws -> OpenASOMCPScreenshotExportResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = Set(try OpenASOMCPValidation.storefronts(storefronts))
    let platform = try platform.map(OpenASOMCPValidation.platform)
    let destinationDirectory = try OpenASOMCPValidation.writableDirectory(
      destinationDirectoryPath,
      createIfNeeded: true
    )

    let exportJobs = try await backgroundModelStore.read { modelContext in
      guard let storeApp = try Self.fetchStoreApp(appStoreID: appStoreID, in: modelContext) else {
        throw OpenASOError.appNotFound
      }

      let descriptor = FetchDescriptor<AppStoreScreenshot>(
        predicate: #Predicate { screenshot in
          screenshot.appStoreID == appStoreID
        },
        sortBy: [
          SortDescriptor(\.storefront, order: .forward),
          SortDescriptor(\.platformRaw, order: .forward),
          SortDescriptor(\.sortOrder, order: .forward),
        ]
      )
      return try modelContext.fetch(descriptor).compactMap { screenshot -> ScreenshotDownloadJob? in
        if !storefronts.isEmpty && !storefronts.contains(screenshot.storefront) { return nil }
        if let platform, screenshot.platformRaw != platform.rawValue { return nil }
        return Self.screenshotDownloadJob(screenshot: screenshot, appName: storeApp.name)
      }
    }

    let result = await screenshotDownloadService.download(
      jobs: exportJobs, to: destinationDirectory)
    return OpenASOMCPScreenshotExportResult(
      destinationDirectoryPath: destinationDirectory.path,
      summary: OpenASOMCPMutationSummary(
        inserted: 0,
        updated: 0,
        skipped: 0,
        refreshed: result.completed.count,
        failed: result.failed.count
      ),
      completed: result.completed.map(Self.exportedScreenshot),
      failed: result.failed.map(Self.failedScreenshotExport)
    )
  }

  func fetchWebsiteMarkdown(urlString: String) async throws -> OpenASOMCPWebsiteMarkdownResult {
    let sourceURL = try OpenASOMCPValidation.webURL(urlString)
    let markdownURL = try Self.markdownNewURL(for: sourceURL)
    var request = URLRequest(url: markdownURL)
    request.setValue("text/markdown,text/plain,*/*", forHTTPHeaderField: "Accept")

    let data = try await validatedData(for: request, using: httpClient)
    guard let markdown = String(data: data, encoding: .utf8) else {
      throw OpenASOError.decodingFailed
    }
    return OpenASOMCPWebsiteMarkdownResult(
      sourceURLString: sourceURL.absoluteString,
      markdownURLString: markdownURL.absoluteString,
      markdown: markdown,
      byteCount: data.count,
      fetchedAt: now()
    )
  }

  func fetchAppWebsiteMarkdown(appStoreID: Int64, storefront: String) async throws
    -> OpenASOMCPAppWebsiteMarkdownResult
  {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefront = try OpenASOMCPValidation.storefront(storefront)
    let resolved = try await appResolver.resolve(appStoreID: appStoreID, storefrontCode: storefront)
    let app = Self.resolvedApp(resolved)
    var discoveredURLs = Self.websiteCandidates(from: resolved)
    if discoveredURLs.isEmpty {
      let appStoreCandidates =
        (try? await fetchAppStoreWebsiteCandidates(from: resolved, storefront: storefront)) ?? []
      discoveredURLs = Self.deduplicatedWebsiteCandidates(discoveredURLs + appStoreCandidates)
    }
    guard let selectedURL = discoveredURLs.first else {
      return OpenASOMCPAppWebsiteMarkdownResult(
        app: app,
        discoveredURLs: [],
        selectedURLString: nil,
        markdownResult: nil,
        statusMessage:
          "No public seller, support, privacy, or developer website URL was available from App Store metadata."
      )
    }

    do {
      let markdown = try await fetchWebsiteMarkdown(urlString: selectedURL)
      return OpenASOMCPAppWebsiteMarkdownResult(
        app: app,
        discoveredURLs: discoveredURLs,
        selectedURLString: selectedURL,
        markdownResult: markdown,
        statusMessage: nil
      )
    } catch {
      return OpenASOMCPAppWebsiteMarkdownResult(
        app: app,
        discoveredURLs: discoveredURLs,
        selectedURLString: selectedURL,
        markdownResult: nil,
        statusMessage: OpenASOError.map(error).localizedDescription
      )
    }
  }

  private func fetchAppStoreWebsiteCandidates(from resolvedApp: ResolvedApp, storefront: String)
    async throws -> [String]
  {
    let appStoreURL = Self.appStorePageURL(from: resolvedApp, storefront: storefront)
    var request = URLRequest(url: appStoreURL, timeoutInterval: 20)
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept")
    let data = try await validatedData(for: request, using: httpClient)
    guard let html = String(data: data, encoding: .utf8) else {
      throw OpenASOError.decodingFailed
    }
    return Self.websiteCandidates(fromAppStoreHTML: html)
  }

  func listCompetitors(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    limit: Int? = nil,
    lookbackDays: Int = 180,
    evidenceLimit: Int? = nil
  ) async throws -> [OpenASOMCPCompetitorSummary] {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = try OpenASOMCPValidation.storefronts(storefronts)
    let platform = try platform.map(OpenASOMCPValidation.platform)
    let limit = OpenASOMCPValidation.cappedLimit(limit, default: 12, maximum: 50)
    let evidenceLimit = OpenASOMCPValidation.cappedLimit(
      evidenceLimit,
      default: ResponseLimits.defaultCompetitorEvidence,
      maximum: ResponseLimits.maximumCompetitorEvidence
    )
    return try await backgroundModelStore.read { modelContext in
      try Self.deriveCompetitors(
        appStoreID: appStoreID,
        storefronts: storefronts,
        platform: platform,
        lookbackDays: lookbackDays,
        limit: limit,
        evidenceLimit: evidenceLimit,
        in: modelContext
      )
    }
  }

  func getRankedAppsForKeyword(
    keyword: String,
    storefront: String,
    platform: String? = nil,
    targetAppStoreID: Int64? = nil,
    limit: Int? = nil
  ) async throws -> OpenASOMCPKeywordRankingEvidence {
    let provider = try requireRankingProvider()
    let keyword = try OpenASOMCPValidation.keyword(keyword)
    let storefront = try OpenASOMCPValidation.storefront(storefront)
    let platform = try OpenASOMCPValidation.platform(platform)
    let limit = OpenASOMCPValidation.cappedLimit(
      limit,
      default: ResponseLimits.defaultRankingAppLimit,
      maximum: ResponseLimits.maximumRankingAppLimit
    )
    let targetAppStoreID = try targetAppStoreID.map(OpenASOMCPValidation.appStoreID)
    let page = try await Self.withRankingSearchTimeout {
      try await provider.search(
        keyword: keyword,
        storefrontCode: storefront,
        platform: platform,
        limit: limit
      )
    }
    return Self.keywordRankingEvidence(
      keyword: keyword,
      storefront: storefront,
      platform: platform,
      page: page,
      targetAppStoreID: targetAppStoreID,
      observedAt: now()
    )
  }

  func refreshKeywordRankings(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    limit: Int? = nil
  ) async throws -> OpenASOMCPKeywordRefreshResult {
    let provider = try requireRankingProvider()
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = Set(try OpenASOMCPValidation.storefronts(storefronts))
    let platform = try platform.map(OpenASOMCPValidation.platform)
    let trackLimit = OpenASOMCPValidation.cappedLimit(
      limit,
      default: ResponseLimits.defaultKeywordRefreshTrackLimit,
      maximum: ResponseLimits.maximumKeywordRefreshTrackLimit
    )
    let resultLimit = ResponseLimits.defaultRankingAppLimit

    let requestBatch = try await backgroundModelStore.read { modelContext in
      let descriptor = FetchDescriptor<TrackedAppKeyword>(
        predicate: #Predicate { track in
          track.appStoreID == appStoreID
        }
      )
      let matches = try modelContext.fetch(descriptor).filter { track in
        if !storefronts.isEmpty && !storefronts.contains(track.storefront) { return false }
        if let platform, track.platform != platform { return false }
        return true
      }
      let sorted = matches.sorted { lhs, rhs in
        lhs.identityKey < rhs.identityKey
      }
      return (
        requests: Array(sorted.prefix(trackLimit)).map { RankingRefreshRequest(track: $0) },
        totalCount: matches.count
      )
    }

    var fetched: [(RankingRefreshRequest, SearchRankingPage?, OpenASOError?)] = []
    for request in requestBatch.requests {
      do {
        let page = try await Self.withRankingSearchTimeout {
          try await provider.search(
            keyword: request.term,
            storefrontCode: request.storefront,
            platform: request.platform,
            limit: resultLimit
          )
        }
        fetched.append((request, page, nil))
      } catch {
        fetched.append((request, nil, OpenASOError.map(error)))
      }
    }

    let fetchedResults = fetched
    return try await backgroundModelStore.write { modelContext in
      var outcomes: [OpenASOMCPKeywordRefreshOutcome] = []
      for item in fetchedResults {
        if let page = item.1 {
          let observedAt = now()
          let track: TrackedAppKeyword
          if let rankingRefreshCoordinator {
            let pageResult = RankingRefreshPageResult(
              request: item.0,
              page: page,
              searchedAt: observedAt,
              observedHour: nil,
              submissionCount: 0,
              winningCount: 0,
              confidence: nil
            )
            track = try rankingRefreshCoordinator.persistRankingPage(
              pageResult,
              in: modelContext,
              rebuildDerivedStats: true,
              saveChanges: false,
              scheduleMetadataEnrichment: true
            ).keywordTrack
          } else {
            track = try Self.persistRankingPage(
              page,
              request: item.0,
              appStoreID: appStoreID,
              observedAt: observedAt,
              appCatalogService: appCatalogService,
              in: modelContext
            )
          }
          let metrics = try Self.metricsByQueryKey(queryKeys: [track.queryKey], in: modelContext)
          outcomes.append(
            OpenASOMCPKeywordRefreshOutcome(
              track: Self.keywordSummary(track: track, metrics: metrics[track.queryKey]),
              error: nil
            ))
        } else if let error = item.2,
          let track = try Self.fetchTrackedKeyword(
            identityKey: item.0.identityKey, in: modelContext)
        {
          track.statusMessage = "Ranking failed to refresh. \(error.localizedDescription)"
          let metrics = try Self.metricsByQueryKey(queryKeys: [track.queryKey], in: modelContext)
          outcomes.append(
            OpenASOMCPKeywordRefreshOutcome(
              track: Self.keywordSummary(track: track, metrics: metrics[track.queryKey]),
              error: OpenASOMCPErrorDTO(error)
            ))
        }
      }
      let failures = outcomes.filter { $0.error != nil }.count
      return OpenASOMCPKeywordRefreshResult(
        summary: OpenASOMCPMutationSummary(
          inserted: 0,
          updated: 0,
          skipped: max(0, requestBatch.totalCount - requestBatch.requests.count),
          refreshed: outcomes.count - failures,
          failed: failures
        ),
        outcomes: outcomes
      )
    }
  }

  func refreshKeywordMetrics(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil
  ) async throws -> OpenASOMCPKeywordRefreshResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = Set(try OpenASOMCPValidation.storefronts(storefronts))
    let platform = try platform.map(OpenASOMCPValidation.platform)

    let trackIdentityKeys = try await backgroundModelStore.read { modelContext in
      let descriptor = FetchDescriptor<TrackedAppKeyword>(
        predicate: #Predicate { track in
          track.appStoreID == appStoreID
        }
      )
      return try modelContext.fetch(descriptor).filter { track in
        if !storefronts.isEmpty && !storefronts.contains(track.storefront) { return false }
        if let platform, track.platform != platform { return false }
        return true
      }.map(\.identityKey)
    }

    var refreshErrorsByIdentityKey: [String: String] = [:]
    if let keywordMetricsService {
      let popularityContextAppStoreID = await popularityContextAppStoreIDProvider()
      let webSession = await appleAdsWebSessionProvider()
      let refreshOutcomes = try await keywordMetricsService.refreshMetrics(
        for: trackIdentityKeys,
        popularityContextAppStoreID: popularityContextAppStoreID,
        webSession: webSession,
        using: backgroundModelStore
      )
      refreshErrorsByIdentityKey = try await backgroundModelStore.read { modelContext in
        var errors: [String: String] = [:]
        for outcome in refreshOutcomes where outcome.errorMessage != nil {
          guard let track = modelContext.model(for: outcome.trackID) as? TrackedAppKeyword else {
            continue
          }
          errors[track.identityKey] = outcome.errorMessage
        }
        return errors
      }
    } else {
      let message = "Popularity failed to fetch. Connect an Apple Ads web session in Settings."
      try await backgroundModelStore.write { modelContext in
        for identityKey in trackIdentityKeys {
          guard let track = try Self.fetchTrackedKeyword(identityKey: identityKey, in: modelContext)
          else { continue }
          track.statusMessage = message
        }
      }
      refreshErrorsByIdentityKey = Dictionary(
        uniqueKeysWithValues: trackIdentityKeys.map { ($0, message) })
    }

    let refreshErrors = refreshErrorsByIdentityKey
    return try await backgroundModelStore.read { modelContext in
      let tracks = try trackIdentityKeys.compactMap {
        try Self.fetchTrackedKeyword(identityKey: $0, in: modelContext)
      }
      let metrics = try Self.metricsByQueryKey(queryKeys: tracks.map(\.queryKey), in: modelContext)
      let outcomes = tracks.map { track in
        let metric = metrics[track.queryKey]
        let error =
          refreshErrors[track.identityKey]
          ?? Self.popularityStatusMessage(from: track.statusMessage)
        return OpenASOMCPKeywordRefreshOutcome(
          track: Self.keywordSummary(track: track, metrics: metric),
          error: error.map {
            OpenASOMCPErrorDTO(
              code: $0.localizedCaseInsensitiveContains("Connect an Apple Ads")
                ? "apple_ads_not_configured"
                : "keyword_popularity_unavailable",
              message: $0
            )
          }
        )
      }
      let failures = outcomes.filter { $0.error != nil }.count
      return OpenASOMCPKeywordRefreshResult(
        summary: OpenASOMCPMutationSummary(
          inserted: 0,
          updated: outcomes.count,
          skipped: 0,
          refreshed: outcomes.count - failures,
          failed: failures
        ),
        outcomes: outcomes
      )
    }
  }

  func suggestKeywords(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    limit: Int? = nil,
    websiteMarkdown: String? = nil
  ) async throws -> OpenASOMCPKeywordSuggestionResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = try await normalizedDiscoveryStorefronts(storefronts, appStoreID: appStoreID)
    let platform = try OpenASOMCPValidation.platform(platform)
    let limit = OpenASOMCPValidation.cappedLimit(
      limit,
      default: ResponseLimits.defaultLandscapeKeywordLimit,
      maximum: ResponseLimits.maximumLandscapeKeywordLimit
    )
    let app = try await appSummaryResolvingCatalog(
      appStoreID: appStoreID, storefront: storefronts.first ?? "us")
    let seeds = try await seedKeywords(
      appStoreID: appStoreID,
      storefronts: storefronts,
      limit: limit * 2,
      websiteMarkdown: websiteMarkdown
    )
    let candidates = try await verifyKeywordSeeds(
      seeds,
      appStoreID: appStoreID,
      storefronts: storefronts,
      platform: platform,
      limit: limit
    )
    return OpenASOMCPKeywordSuggestionResult(
      app: app,
      generatedAt: now(),
      candidates: candidates.candidates,
      errors: candidates.errors
    )
  }

  func refreshReviews(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    limitPerStorefront: Int? = nil
  ) async throws -> OpenASOMCPReviewRefreshResult {
    guard let reviewService else {
      throw OpenASOError.providerUnavailable(
        "Review refresh is not configured for this MCP server.")
    }
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = try await normalizedDiscoveryStorefronts(storefronts, appStoreID: appStoreID)
    let reviewLimit = OpenASOMCPValidation.cappedLimit(
      limitPerStorefront,
      default: ResponseLimits.defaultReviewRefreshLimit,
      maximum: ResponseLimits.maximumReviewRefreshLimit
    )

    _ = try await appSummaryResolvingCatalog(
      appStoreID: appStoreID, storefront: storefronts.first ?? "us")

    var fetchedByStorefront:
      [(
        storefront: String, reviews: [AppStorefrontReviewResult], reachedLimit: Bool,
        error: OpenASOError?
      )] = []
    for storefront in storefronts {
      do {
        var reviews: [AppStorefrontReviewResult] = []
        _ = try await reviewService.fetchReviewPages(appStoreID: appStoreID, storefront: storefront)
        { page in
          reviews.append(contentsOf: page)
          return reviews.count < reviewLimit
        }
        let reachedLimit = reviews.count >= reviewLimit
        fetchedByStorefront.append(
          (storefront, Array(reviews.prefix(reviewLimit)), reachedLimit, nil))
      } catch {
        fetchedByStorefront.append((storefront, [], false, OpenASOError.map(error)))
      }
    }

    let fetchedResults = fetchedByStorefront
    return try await backgroundModelStore.write { modelContext in
      guard let storeApp = try Self.fetchStoreApp(appStoreID: appStoreID, in: modelContext) else {
        throw OpenASOError.appNotFound
      }
      var outcomes: [OpenASOMCPReviewRefreshOutcomeDTO] = []
      for fetched in fetchedResults {
        if let error = fetched.error {
          outcomes.append(
            OpenASOMCPReviewRefreshOutcomeDTO(
              appStoreID: String(appStoreID),
              storefront: fetched.storefront,
              fetchedReviews: 0,
              storedReviews: 0,
              reachedLimit: false,
              error: OpenASOMCPErrorDTO(error)
            ))
          continue
        }
        let stored = try reviewService.upsert(fetched.reviews, storeApp: storeApp, in: modelContext)
        outcomes.append(
          OpenASOMCPReviewRefreshOutcomeDTO(
            appStoreID: String(appStoreID),
            storefront: fetched.storefront,
            fetchedReviews: fetched.reviews.count,
            storedReviews: stored,
            reachedLimit: fetched.reachedLimit,
            error: nil
          ))
      }

      let failures = outcomes.filter { $0.error != nil }.count
      return OpenASOMCPReviewRefreshResult(
        summary: OpenASOMCPMutationSummary(
          inserted: outcomes.reduce(0) { $0 + $1.storedReviews },
          updated: 0,
          skipped: 0,
          refreshed: outcomes.reduce(0) { $0 + $1.fetchedReviews },
          failed: failures
        ),
        outcomes: outcomes,
        reviewLimitPerStorefront: reviewLimit,
        notes: outcomes.contains { $0.reachedLimit }
          ? [
            "Review refresh stopped at the per-storefront cap. Use list_reviews pagination to inspect stored reviews."
          ]
          : []
      )
    }
  }

  func downloadAllReviews(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    batchPageCount: Int? = nil
  ) async throws -> OpenASOMCPReviewDownloadResult {
    guard let reviewService else {
      throw OpenASOError.providerUnavailable(
        "Review refresh is not configured for this MCP server.")
    }
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = try await normalizedDiscoveryStorefronts(storefronts, appStoreID: appStoreID)
    let batchPageCount = OpenASOMCPValidation.cappedLimit(
      batchPageCount,
      default: ResponseLimits.defaultReviewDownloadBatchPageCount,
      maximum: ResponseLimits.maximumReviewDownloadBatchPageCount
    )

    _ = try await appSummaryResolvingCatalog(
      appStoreID: appStoreID, storefront: storefronts.first ?? "us")

    var outcomes: [OpenASOMCPReviewDownloadOutcomeDTO] = []
    for storefront in storefronts {
      var pendingReviews: [AppStorefrontReviewResult] = []
      var pendingPageCount = 0
      var fetchedReviews = 0
      var storedReviews = 0
      var batchCount = 0

      func flushPendingReviews() async throws {
        guard !pendingReviews.isEmpty else { return }
        let batch = pendingReviews
        let stored = try await backgroundModelStore.write { modelContext in
          guard let storeApp = try Self.fetchStoreApp(appStoreID: appStoreID, in: modelContext)
          else {
            throw OpenASOError.appNotFound
          }
          return try reviewService.upsert(batch, storeApp: storeApp, in: modelContext)
        }
        pendingReviews.removeAll(keepingCapacity: true)
        pendingPageCount = 0
        storedReviews += stored
        batchCount += 1
      }

      do {
        _ = try await reviewService.fetchReviewPages(appStoreID: appStoreID, storefront: storefront)
        { page in
          pendingReviews.append(contentsOf: page)
          pendingPageCount += 1
          fetchedReviews += page.count
          if pendingPageCount >= batchPageCount {
            try await flushPendingReviews()
          }
          return true
        }
        try await flushPendingReviews()
        outcomes.append(
          OpenASOMCPReviewDownloadOutcomeDTO(
            appStoreID: String(appStoreID),
            storefront: storefront,
            fetchedReviews: fetchedReviews,
            storedReviews: storedReviews,
            batchCount: batchCount,
            exhausted: true,
            error: nil
          ))
      } catch {
        var outcomeError = OpenASOError.map(error)
        if !pendingReviews.isEmpty {
          do {
            try await flushPendingReviews()
          } catch {
            outcomeError = OpenASOError.map(error)
          }
        }
        outcomes.append(
          OpenASOMCPReviewDownloadOutcomeDTO(
            appStoreID: String(appStoreID),
            storefront: storefront,
            fetchedReviews: fetchedReviews,
            storedReviews: storedReviews,
            batchCount: batchCount,
            exhausted: false,
            error: OpenASOMCPErrorDTO(outcomeError)
          ))
      }
    }

    let failures = outcomes.filter { $0.error != nil }.count
    return OpenASOMCPReviewDownloadResult(
      summary: OpenASOMCPMutationSummary(
        inserted: outcomes.reduce(0) { $0 + $1.storedReviews },
        updated: 0,
        skipped: 0,
        refreshed: outcomes.reduce(0) { $0 + $1.fetchedReviews },
        failed: failures
      ),
      outcomes: outcomes,
      batchPageCount: batchPageCount,
      notes: [
        "This tool exhausts each selected storefront and can be slow for large apps. Use refresh_reviews for a bounded most-recent sample.",
        "Review pages are persisted in batches so large downloads do not need to remain in memory.",
      ]
    )
  }

  func discoverKeywordLandscape(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    keywordLimit: Int? = nil,
    competitorLimit: Int? = nil,
    reviewsPerStorefront: Int? = nil,
    includeReviews: Bool = true,
    websiteMarkdown: String? = nil
  ) async throws -> OpenASOMCPKeywordLandscapeResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = try await normalizedDiscoveryStorefronts(storefronts, appStoreID: appStoreID)
    let platform = try OpenASOMCPValidation.platform(platform)
    let keywordLimit = OpenASOMCPValidation.cappedLimit(
      keywordLimit,
      default: ResponseLimits.defaultLandscapeKeywordLimit,
      maximum: ResponseLimits.maximumLandscapeKeywordLimit
    )
    let competitorLimit = OpenASOMCPValidation.cappedLimit(competitorLimit, default: 5, maximum: 10)
    let reviewsPerStorefront = OpenASOMCPValidation.cappedLimit(
      reviewsPerStorefront,
      default: 100,
      maximum: ResponseLimits.maximumReviewsPerLandscapeApp
    )
    let app = try await appSummaryResolvingCatalog(
      appStoreID: appStoreID, storefront: storefronts.first ?? "us")
    let seeds = try await seedKeywords(
      appStoreID: appStoreID,
      storefronts: storefronts,
      limit: keywordLimit * 2,
      websiteMarkdown: websiteMarkdown
    )
    let verification = try await verifyKeywordSeeds(
      seeds,
      appStoreID: appStoreID,
      storefronts: storefronts,
      platform: platform,
      limit: keywordLimit,
      persistResults: true
    )
    let competitors = try await landscapeCompetitors(
      from: verification.candidates,
      appStoreID: appStoreID,
      storefronts: storefronts,
      reviewLimitPerStorefront: reviewsPerStorefront,
      competitorLimit: competitorLimit,
      includeReviews: includeReviews
    )
    let notes = Self.landscapeNotes(
      candidates: verification.candidates, competitors: competitors, includeReviews: includeReviews)
    return OpenASOMCPKeywordLandscapeResult(
      app: app,
      generatedAt: now(),
      seedKeywords: seeds.map(\.keyword),
      verifiedKeywords: verification.candidates,
      competitors: competitors,
      notes: notes,
      errors: verification.errors
    )
  }

  func refreshCompetitorReviews(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    competitorLimit: Int? = nil,
    reviewsPerStorefront: Int? = nil
  ) async throws -> OpenASOMCPCompetitorReviewRefreshResult {
    guard let reviewService else {
      throw OpenASOError.providerUnavailable(
        "Review refresh is not configured for this MCP server.")
    }
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = try await normalizedDiscoveryStorefronts(storefronts, appStoreID: appStoreID)
    let platform = try platform.map(OpenASOMCPValidation.platform)
    let competitorLimit = OpenASOMCPValidation.cappedLimit(competitorLimit, default: 5, maximum: 10)
    let reviewLimit = OpenASOMCPValidation.cappedLimit(
      reviewsPerStorefront,
      default: ResponseLimits.defaultCompetitorReviewLimit,
      maximum: ResponseLimits.maximumCompetitorReviewLimit
    )
    let competitors = try await listCompetitors(
      appStoreID: appStoreID,
      storefronts: storefronts,
      platform: platform?.rawValue,
      limit: competitorLimit,
      evidenceLimit: 8
    )

    var fetched:
      [(
        competitor: OpenASOMCPCompetitorSummary, storefront: String,
        reviews: [AppStorefrontReviewResult], reachedLimit: Bool, error: OpenASOError?
      )] = []
    for competitor in competitors {
      guard let competitorID = Int64(competitor.appStoreID) else { continue }
      for storefront in storefronts {
        var reviews: [AppStorefrontReviewResult] = []
        do {
          _ = try await reviewService.fetchReviewPages(
            appStoreID: competitorID, storefront: storefront
          ) { page in
            reviews.append(contentsOf: page)
            return reviews.count < reviewLimit
          }
          fetched.append(
            (
              competitor, storefront, Array(reviews.prefix(reviewLimit)),
              reviews.count >= reviewLimit, nil
            ))
        } catch {
          fetched.append((competitor, storefront, [], false, OpenASOError.map(error)))
        }
      }
    }

    let fetchedResults = fetched
    return try await backgroundModelStore.write { modelContext in
      var outcomes: [OpenASOMCPReviewRefreshOutcomeDTO] = []
      for item in fetchedResults {
        guard let competitorID = Int64(item.competitor.appStoreID) else { continue }
        if let error = item.error {
          outcomes.append(
            OpenASOMCPReviewRefreshOutcomeDTO(
              appStoreID: item.competitor.appStoreID,
              storefront: item.storefront,
              fetchedReviews: 0,
              storedReviews: 0,
              reachedLimit: false,
              error: OpenASOMCPErrorDTO(error)
            ))
          continue
        }
        let storeApp =
          try Self.fetchStoreApp(appStoreID: competitorID, in: modelContext)
          ?? StoreApp(
            appStoreID: competitorID,
            bundleID: item.competitor.bundleID,
            name: item.competitor.name,
            sellerName: item.competitor.sellerName,
            iconURLString: item.competitor.iconURLString,
            defaultStorefront: item.storefront,
            defaultPlatform: platform ?? .iphone
          )
        if storeApp.modelContext == nil {
          modelContext.insert(storeApp)
        }
        let stored = try reviewService.upsert(item.reviews, storeApp: storeApp, in: modelContext)
        outcomes.append(
          OpenASOMCPReviewRefreshOutcomeDTO(
            appStoreID: item.competitor.appStoreID,
            storefront: item.storefront,
            fetchedReviews: item.reviews.count,
            storedReviews: stored,
            reachedLimit: item.reachedLimit,
            error: nil
          ))
      }
      let failures = outcomes.filter { $0.error != nil }.count
      return OpenASOMCPCompetitorReviewRefreshResult(
        competitors: competitors,
        summary: OpenASOMCPMutationSummary(
          inserted: outcomes.reduce(0) { $0 + $1.storedReviews },
          updated: 0,
          skipped: 0,
          refreshed: outcomes.reduce(0) { $0 + $1.fetchedReviews },
          failed: failures
        ),
        outcomes: outcomes,
        reviewLimitPerStorefront: reviewLimit,
        notes: [
          "Reviews were stored for follow-up analysis. Call list_reviews for each competitor appStoreID to summarize praise, complaints, feature requests, and version-specific issues.",
          "Competitors are selected from shared keyword ranking evidence, ordered by repeated appearances before rating volume.",
          "The review limit is applied per storefront. Select one storefront, such as us, for a compact recent sample.",
        ]
      )
    }
  }

  func exportCompetitorScreenshots(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    competitorLimit: Int? = nil,
    destinationDirectoryPath: String
  ) async throws -> OpenASOMCPCompetitorScreenshotExportResult {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let storefronts = try await normalizedDiscoveryStorefronts(storefronts, appStoreID: appStoreID)
    let platform = try platform.map(OpenASOMCPValidation.platform)
    let competitorLimit = OpenASOMCPValidation.cappedLimit(competitorLimit, default: 5, maximum: 10)
    let competitors = try await listCompetitors(
      appStoreID: appStoreID,
      storefronts: storefronts,
      platform: platform?.rawValue,
      limit: competitorLimit,
      evidenceLimit: 8
    )
    var exports: [OpenASOMCPScreenshotExportResult] = []
    var failures: [OpenASOMCPCompetitorScreenshotExportFailure] = []
    for competitor in competitors {
      guard let competitorID = Int64(competitor.appStoreID) else {
        failures.append(
          OpenASOMCPCompetitorScreenshotExportFailure(
            competitor: competitor,
            error: OpenASOMCPErrorDTO(
              code: "invalid_app_store_id",
              message: "Competitor appStoreID is not numeric: \(competitor.appStoreID)"
            )
          ))
        continue
      }
      do {
        exports.append(
          try await exportScreenshots(
            appStoreID: competitorID,
            storefronts: storefronts,
            platform: platform?.rawValue,
            destinationDirectoryPath: destinationDirectoryPath
          ))
      } catch {
        failures.append(
          OpenASOMCPCompetitorScreenshotExportFailure(
            competitor: competitor,
            error: OpenASOMCPErrorDTO(OpenASOError.map(error))
          ))
      }
    }
    let completed = exports.reduce(0) { $0 + $1.completed.count }
    let failed = exports.reduce(0) { $0 + $1.failed.count }
    let notes =
      completed == 0
      ? [
        "No competitor screenshots were exported. Run discover_keyword_landscape first so ranking metadata and screenshots can be stored."
      ]
      : [
        "Screenshots were exported for agent-side visual analysis. OpenASO does not perform OCR or vision captioning in-process."
      ]
    return OpenASOMCPCompetitorScreenshotExportResult(
      competitors: competitors,
      summary: OpenASOMCPMutationSummary(
        inserted: 0, updated: 0, skipped: 0, refreshed: completed, failed: failed + failures.count),
      exports: exports,
      failures: failures,
      notes: notes
    )
  }

  func getLocalizationResearchContext(
    appStoreID: Int64,
    storefronts: [String]? = nil,
    platform: String? = nil,
    competitorLimit: Int? = nil,
    includeTargetApp: Bool = true,
    refreshMissingMetadata: Bool = true,
    destinationDirectoryPath: String? = nil
  ) async throws -> OpenASOMCPLocalizationResearchContext {
    let appStoreID = try OpenASOMCPValidation.appStoreID(appStoreID)
    let requestedStorefronts = try OpenASOMCPValidation.storefronts(storefronts)
    let storefronts =
      requestedStorefronts.isEmpty ? Self.defaultLocalizationStorefronts : requestedStorefronts
    let analysisStorefronts = Self.storefrontsIncludingLocalizationBaseline(storefronts)
    let platform = try OpenASOMCPValidation.platform(platform)
    let competitorLimit = OpenASOMCPValidation.cappedLimit(
      competitorLimit,
      default: ResponseLimits.defaultLocalizationCompetitorLimit,
      maximum: ResponseLimits.maximumLocalizationCompetitorLimit
    )

    let competitors = try await listCompetitors(
      appStoreID: appStoreID,
      storefronts: analysisStorefronts,
      platform: platform.rawValue,
      limit: competitorLimit,
      evidenceLimit: ResponseLimits.overviewCompetitorEvidence
    )

    var subjects: [(role: String, appStoreID: Int64)] = []
    if includeTargetApp {
      subjects.append(("target", appStoreID))
    }
    for competitor in competitors {
      guard let competitorID = Int64(competitor.appStoreID),
        !subjects.contains(where: { $0.appStoreID == competitorID })
      else {
        continue
      }
      subjects.append(("competitor", competitorID))
    }

    var fetchErrors: [OpenASOMCPLocalizationFetchError] = []
    var summariesByAppID: [Int64: OpenASOMCPAppSummary] = [:]
    for subject in subjects {
      do {
        summariesByAppID[subject.appStoreID] = try await appSummaryResolvingCatalog(
          appStoreID: subject.appStoreID,
          storefront: Self.localizationBaselineStorefront
        )
      } catch {
        fetchErrors.append(
          OpenASOMCPLocalizationFetchError(
            appStoreID: String(subject.appStoreID),
            storefront: Self.localizationBaselineStorefront,
            error: OpenASOMCPErrorDTO(OpenASOError.map(error))
          ))
      }
    }

    if refreshMissingMetadata {
      for subject in subjects where summariesByAppID[subject.appStoreID] != nil {
        fetchErrors.append(
          contentsOf: try await refreshMissingLocalizationMetadata(
            appStoreID: subject.appStoreID,
            storefronts: analysisStorefronts
          ))
      }
    }

    var screenshotExportsByAppID: [Int64: OpenASOMCPScreenshotExportResult] = [:]
    if let destinationDirectoryPath {
      _ = try OpenASOMCPValidation.writableDirectory(destinationDirectoryPath, createIfNeeded: true)
      for subject in subjects where summariesByAppID[subject.appStoreID] != nil {
        screenshotExportsByAppID[subject.appStoreID] = try await exportScreenshots(
          appStoreID: subject.appStoreID,
          storefronts: analysisStorefronts,
          platform: platform.rawValue,
          destinationDirectoryPath: destinationDirectoryPath
        )
      }
    }

    let finalSubjects = subjects
    let finalSummariesByAppID = summariesByAppID
    let finalScreenshotExportsByAppID = screenshotExportsByAppID
    let appContexts = try await backgroundModelStore.read { modelContext in
      let languageCodesByStorefront = try Self.languageCodesByStorefront(in: modelContext)
      return try finalSubjects.compactMap { subject -> OpenASOMCPLocalizationAppContext? in
        guard
          let storeApp = try Self.fetchStoreApp(appStoreID: subject.appStoreID, in: modelContext),
          let app = finalSummariesByAppID[subject.appStoreID]
        else {
          return nil
        }
        return Self.localizationAppContext(
          role: subject.role,
          app: app,
          storeApp: storeApp,
          storefronts: storefronts,
          baselineStorefront: Self.localizationBaselineStorefront,
          platform: platform,
          languageCodesByStorefront: languageCodesByStorefront,
          screenshotExport: finalScreenshotExportsByAppID[subject.appStoreID]
        )
      }
    }

    return OpenASOMCPLocalizationResearchContext(
      appStoreID: String(appStoreID),
      generatedAt: now(),
      baselineStorefront: Self.localizationBaselineStorefront,
      storefronts: storefronts,
      platform: platform.rawValue,
      apps: appContexts,
      notes: Self.localizationResearchNotes(
        refreshMissingMetadata: refreshMissingMetadata,
        destinationDirectoryPath: destinationDirectoryPath
      ),
      errors: fetchErrors
    )
  }

  private func requireRankingProvider() throws -> any SearchRankingProvider {
    guard let rankingProvider else {
      throw OpenASOError.providerUnavailable(
        "Ranking search is not configured for this MCP server.")
    }
    return rankingProvider
  }

  static func withRankingSearchTimeout<T: Sendable>(
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: ResponseLimits.rankingSearchTimeoutNanoseconds)
        throw OpenASOError.providerUnavailable(
          "Ranking search timed out after 5 seconds. Reduce the keyword/storefront batch size and retry."
        )
      }

      guard let result = try await group.next() else {
        throw OpenASOError.providerUnavailable("Ranking search did not return a result.")
      }
      group.cancelAll()
      return result
    }
  }
}

extension OpenASOMCPService {
  fileprivate struct KeywordSeed: Hashable, Sendable {
    let keyword: String
    var sources: Set<String>
  }

  fileprivate struct KeywordVerificationResult: Sendable {
    let candidates: [OpenASOMCPKeywordCandidate]
    let errors: [OpenASOMCPKeywordVerificationError]
  }

  fileprivate struct KeywordMetricValue: Sendable {
    let popularityScore: Int?
    let difficultyScore: Int?
  }

  fileprivate struct LandscapeCompetitorAccumulator: Sendable {
    var app: OpenASOMCPRankedApp
    var occurrenceCount = 0
    var rankSum = 0
    var bestRank = Int.max
    var evidenceKeywords: Set<String> = []
    var totalRatingCount = 0

    mutating func add(keyword: String, app: OpenASOMCPRankedApp) {
      self.app = app
      occurrenceCount += 1
      rankSum += app.position
      bestRank = min(bestRank, app.position)
      evidenceKeywords.insert(keyword)
      totalRatingCount += app.ratingCount ?? 0
    }

    func result(reviews: [OpenASOMCPReview], screenshots: [OpenASOMCPScreenshot])
      -> OpenASOMCPLandscapeCompetitor
    {
      OpenASOMCPLandscapeCompetitor(
        id: app.appStoreID,
        app: app,
        occurrenceCount: occurrenceCount,
        bestRank: bestRank,
        averageRank: occurrenceCount == 0 ? 0 : Double(rankSum) / Double(occurrenceCount),
        totalRatingCount: totalRatingCount,
        evidenceKeywords: evidenceKeywords.sorted(),
        recentReviews: reviews,
        screenshots: screenshots
      )
    }
  }

  fileprivate func appSummaryResolvingCatalog(appStoreID: Int64, storefront: String) async throws
    -> OpenASOMCPAppSummary
  {
    if let summary = try await backgroundModelStore.read({ modelContext in
      try Self.fetchStoreApp(appStoreID: appStoreID, in: modelContext).map { storeApp in
        let trackedApp = try Self.fetchTrackedApp(appStoreID: appStoreID, in: modelContext)
        return Self.appSummary(storeApp: storeApp, trackedApp: trackedApp)
      }
    }) {
      return summary
    }

    let resolved = try await appResolver.resolve(appStoreID: appStoreID, storefrontCode: storefront)
    return try await backgroundModelStore.write { modelContext in
      let storeApp = try appCatalogService.upsertStoreApp(
        from: resolved, storefrontCode: storefront, in: modelContext)
      let trackedApp = try Self.fetchTrackedApp(appStoreID: appStoreID, in: modelContext)
      return Self.appSummary(storeApp: storeApp, trackedApp: trackedApp)
    }
  }

  fileprivate func refreshMissingLocalizationMetadata(
    appStoreID: Int64,
    storefronts: [String]
  ) async throws -> [OpenASOMCPLocalizationFetchError] {
    let missingStorefronts = try await backgroundModelStore.read { modelContext in
      try storefronts.filter { storefront in
        let key = AppStorefrontMetadata.makeIdentityKey(
          appStoreID: appStoreID, storefront: storefront)
        return try Self.fetchStorefrontMetadata(identityKey: key, in: modelContext) == nil
      }
    }

    var errors: [OpenASOMCPLocalizationFetchError] = []
    for storefront in missingStorefronts {
      do {
        let resolved = try await appResolver.resolve(
          appStoreID: appStoreID, storefrontCode: storefront)
        try await backgroundModelStore.write { modelContext in
          _ = try appCatalogService.upsertStoreApp(
            from: resolved,
            storefrontCode: storefront,
            in: modelContext
          )
        }
      } catch {
        errors.append(
          OpenASOMCPLocalizationFetchError(
            appStoreID: String(appStoreID),
            storefront: storefront,
            error: OpenASOMCPErrorDTO(OpenASOError.map(error))
          ))
      }
    }
    return errors
  }

  fileprivate func normalizedDiscoveryStorefronts(_ storefronts: [String]?, appStoreID: Int64)
    async throws -> [String]
  {
    let normalized = try OpenASOMCPValidation.storefronts(storefronts)
    if !normalized.isEmpty { return normalized }
    return ["us"]
  }

  fileprivate func seedKeywords(
    appStoreID: Int64,
    storefronts: [String],
    limit: Int,
    websiteMarkdown: String? = nil
  ) async throws -> [KeywordSeed] {
    let text = try await backgroundModelStore.read { modelContext in
      guard let storeApp = try Self.fetchStoreApp(appStoreID: appStoreID, in: modelContext) else {
        throw OpenASOError.appNotFound
      }
      return Self.keywordSeedText(storeApp: storeApp, storefronts: Set(storefronts))
    }

    let extracted = Self.extractKeywordSeeds(from: text)
    let websiteExtracted = websiteMarkdown.map(Self.extractKeywordSeeds(from:)) ?? []
    let appNameSeeds: [KeywordSeed] = try await backgroundModelStore.read { modelContext in
      guard let storeApp = try Self.fetchStoreApp(appStoreID: appStoreID, in: modelContext) else {
        return []
      }
      return Self.nameBasedKeywordSeeds(name: storeApp.name, subtitle: storeApp.subtitle)
    }
    var seedsByKeyword: [String: KeywordSeed] = [:]
    for seed in appNameSeeds {
      seedsByKeyword[seed.keyword, default: KeywordSeed(keyword: seed.keyword, sources: [])].sources
        .formUnion(seed.sources)
    }
    for keyword in extracted {
      seedsByKeyword[keyword, default: KeywordSeed(keyword: keyword, sources: [])].sources.insert(
        "app_metadata")
    }
    for keyword in websiteExtracted {
      seedsByKeyword[keyword, default: KeywordSeed(keyword: keyword, sources: [])].sources.insert(
        "website_markdown")
    }
    return seedsByKeyword.values
      .sorted {
        if $0.sources.count == $1.sources.count {
          return $0.keyword < $1.keyword
        }
        return $0.sources.count > $1.sources.count
      }
      .prefix(limit)
      .map { $0 }
  }

  fileprivate func verifyKeywordSeeds(
    _ seeds: [KeywordSeed],
    appStoreID: Int64,
    storefronts: [String],
    platform: AppPlatform,
    limit: Int,
    persistResults: Bool = false
  ) async throws -> KeywordVerificationResult {
    let provider = try requireRankingProvider()
    let trackedKeys = try await trackedQueryKeys(appStoreID: appStoreID)
    let metrics: [String: KeywordMetricValue] = try await backgroundModelStore.read {
      modelContext in
      try Self.metricValuesByQueryKey(
        queryKeys: seeds.flatMap { seed in
          storefronts.map {
            TrackedAppKeyword.makeQueryKey(term: seed.keyword, storefront: $0, platform: platform)
          }
        },
        in: modelContext
      )
    }
    var candidates: [OpenASOMCPKeywordCandidate] = []
    var errors: [OpenASOMCPKeywordVerificationError] = []
    var searchedCount = 0
    seedLoop: for seed in seeds {
      for storefront in storefronts {
        try Task.checkCancellation()
        guard searchedCount < ResponseLimits.keywordVerificationSearchBudget else {
          errors.append(
            OpenASOMCPKeywordVerificationError(
              keyword: seed.keyword,
              storefront: storefront,
              platform: platform.rawValue,
              error: OpenASOMCPErrorDTO(
                code: "verification_budget_exceeded",
                message:
                  "Keyword verification stopped after \(ResponseLimits.keywordVerificationSearchBudget) ranking searches to keep the MCP response inside the tool timeout. Run add_keywords or refresh_keyword_rankings in smaller batches for remaining seeds."
              )
            ))
          break seedLoop
        }
        let queryKey = TrackedAppKeyword.makeQueryKey(
          term: seed.keyword, storefront: storefront, platform: platform)
        let page: SearchRankingPage
        do {
          searchedCount += 1
          page = try await Self.withRankingSearchTimeout {
            try await provider.search(
              keyword: seed.keyword,
              storefrontCode: storefront,
              platform: platform,
              limit: ResponseLimits.defaultRankingAppLimit
            )
          }
        } catch {
          errors.append(
            OpenASOMCPKeywordVerificationError(
              keyword: seed.keyword,
              storefront: storefront,
              platform: platform.rawValue,
              error: OpenASOMCPErrorDTO(OpenASOError.map(error))
            ))
          continue
        }
        let evidence = Self.keywordRankingEvidence(
          keyword: seed.keyword,
          storefront: storefront,
          platform: platform,
          page: page,
          targetAppStoreID: appStoreID,
          observedAt: now()
        )
        let metric = metrics[queryKey]
        let confidence = Self.keywordConfidence(
          evidence: evidence, popularityScore: metric?.popularityScore)
        let reason = Self.keywordReason(
          evidence: evidence, popularityScore: metric?.popularityScore)
        var isTracked = trackedKeys.contains(queryKey)
        if persistResults {
          let request = RankingRefreshRequest(
            identityKey: TrackedAppKeyword.makeIdentityKey(
              appStoreID: appStoreID,
              term: seed.keyword,
              storefront: storefront,
              platform: platform
            ),
            queryKey: queryKey,
            term: seed.keyword,
            storefront: storefront,
            platform: platform
          )
          try await backgroundModelStore.write { modelContext in
            let observedAt = now()
            if let rankingRefreshCoordinator {
              _ = try Self.ensureTrackedKeyword(
                request: request,
                appStoreID: appStoreID,
                in: modelContext
              )
              let pageResult = RankingRefreshPageResult(
                request: request,
                page: page,
                searchedAt: observedAt,
                observedHour: nil,
                submissionCount: 0,
                winningCount: 0,
                confidence: nil
              )
              _ = try rankingRefreshCoordinator.persistRankingPage(
                pageResult,
                in: modelContext,
                rebuildDerivedStats: true,
                saveChanges: false,
                scheduleMetadataEnrichment: true
              )
            } else {
              _ = try Self.persistRankingPage(
                page,
                request: request,
                appStoreID: appStoreID,
                observedAt: observedAt,
                appCatalogService: appCatalogService,
                in: modelContext
              )
            }
          }
          isTracked = true
        }
        candidates.append(
          OpenASOMCPKeywordCandidate(
            id: queryKey,
            keyword: seed.keyword,
            storefront: storefront,
            platform: platform.rawValue,
            sources: seed.sources.sorted(),
            reason: reason,
            confidence: confidence,
            isTracked: isTracked,
            popularityScore: metric?.popularityScore,
            targetRank: evidence.targetRank,
            resultCount: evidence.resultCount,
            topRatedAppCount: evidence.topRatedAppCount,
            maximumRatingCount: evidence.maximumRatingCount,
            topApps: evidence.topApps
          ))
      }
    }
    let sortedCandidates =
      candidates
      .sorted {
        if $0.confidence == $1.confidence {
          return ($0.maximumRatingCount ?? 0) > ($1.maximumRatingCount ?? 0)
        }
        return $0.confidence > $1.confidence
      }
      .prefix(limit)
      .map { $0 }
    return KeywordVerificationResult(candidates: sortedCandidates, errors: errors)
  }

  fileprivate func trackedQueryKeys(appStoreID: Int64) async throws -> Set<String> {
    try await backgroundModelStore.read { modelContext in
      guard let trackedApp = try Self.fetchTrackedApp(appStoreID: appStoreID, in: modelContext)
      else {
        return []
      }
      return Set(trackedApp.keywordTracks.map(\.queryKey))
    }
  }

  fileprivate func landscapeCompetitors(
    from candidates: [OpenASOMCPKeywordCandidate],
    appStoreID: Int64,
    storefronts: [String],
    reviewLimitPerStorefront: Int,
    competitorLimit: Int,
    includeReviews: Bool
  ) async throws -> [OpenASOMCPLandscapeCompetitor] {
    var accumulators: [String: LandscapeCompetitorAccumulator] = [:]
    for candidate in candidates {
      for app in candidate.topApps where app.appStoreID != String(appStoreID) {
        var accumulator = accumulators[app.appStoreID] ?? LandscapeCompetitorAccumulator(app: app)
        accumulator.add(keyword: candidate.keyword, app: app)
        accumulators[app.appStoreID] = accumulator
      }
    }

    let selected = accumulators.values
      .sorted {
        if $0.occurrenceCount == $1.occurrenceCount {
          return $0.totalRatingCount > $1.totalRatingCount
        }
        return $0.occurrenceCount > $1.occurrenceCount
      }
      .prefix(competitorLimit)

    var results: [OpenASOMCPLandscapeCompetitor] = []
    for accumulator in selected {
      let competitorID = Int64(accumulator.app.appStoreID) ?? 0
      let reviews =
        includeReviews
        ? await fetchRecentReviewSamples(
          appStoreID: competitorID, storefronts: storefronts,
          limitPerStorefront: reviewLimitPerStorefront)
        : []
      let screenshots = try await screenshotSamples(appStoreID: competitorID)
      results.append(accumulator.result(reviews: reviews, screenshots: screenshots))
    }
    return results
  }

  fileprivate func fetchRecentReviewSamples(
    appStoreID: Int64, storefronts: [String], limitPerStorefront: Int
  ) async -> [OpenASOMCPReview] {
    guard let reviewService else { return [] }
    var reviews: [OpenASOMCPReview] = []
    for storefront in storefronts {
      var storefrontReviews: [OpenASOMCPReview] = []
      do {
        _ = try await reviewService.fetchReviewPages(appStoreID: appStoreID, storefront: storefront)
        { page in
          storefrontReviews.append(contentsOf: page.map(Self.reviewResult))
          return storefrontReviews.count < limitPerStorefront
        }
      } catch {
        continue
      }
      reviews.append(contentsOf: storefrontReviews.prefix(limitPerStorefront))
    }
    return reviews.sorted { $0.reviewedAt > $1.reviewedAt }
  }

  fileprivate func screenshotSamples(appStoreID: Int64) async throws -> [OpenASOMCPScreenshot] {
    try await backgroundModelStore.read { modelContext in
      let descriptor = FetchDescriptor<AppStoreScreenshot>(
        predicate: #Predicate { screenshot in
          screenshot.appStoreID == appStoreID
        },
        sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
      )
      return try modelContext.fetch(descriptor)
        .prefix(ResponseLimits.maximumScreenshotsPerLandscapeApp)
        .map(Self.screenshot)
    }
  }

  fileprivate static func keywordRankingEvidence(
    keyword: String,
    storefront: String,
    platform: AppPlatform,
    page: SearchRankingPage,
    targetAppStoreID: Int64?,
    observedAt: Date
  ) -> OpenASOMCPKeywordRankingEvidence {
    let topApps = page.items
      .sorted { $0.position < $1.position }
      .prefix(ResponseLimits.defaultRankingAppLimit)
      .map(Self.rankedApp)
    let topTen = topApps.prefix(10)
    return OpenASOMCPKeywordRankingEvidence(
      keyword: keyword,
      storefront: storefront,
      platform: platform.rawValue,
      resultCount: page.resultCount,
      source: page.source.rawValue,
      observedAt: observedAt,
      targetRank: targetAppStoreID.flatMap { id in
        page.items.first { $0.appStoreID == id }?.position
      },
      topRatedAppCount: topTen.filter {
        ($0.ratingCount ?? 0) >= ResponseLimits.bigAppRatingThreshold
      }.count,
      maximumRatingCount: topApps.compactMap(\.ratingCount).max(),
      topApps: topApps
    )
  }

  fileprivate static func rankedApp(_ item: SearchRankingItem) -> OpenASOMCPRankedApp {
    OpenASOMCPRankedApp(
      id: String(item.appStoreID),
      appStoreID: String(item.appStoreID),
      position: item.position,
      name: item.name,
      subtitle: item.subtitle,
      sellerName: item.sellerName,
      bundleID: item.bundleID,
      iconURLString: item.iconURLString,
      primaryGenreName: item.primaryGenreName,
      ratingCount: item.ratingCount,
      averageRating: item.averageRating,
      screenshotURLs: item.screenshotURLs
    )
  }

  fileprivate static func reviewResult(_ result: AppStorefrontReviewResult) -> OpenASOMCPReview {
    OpenASOMCPReview(
      reviewKey: AppStorefrontReview.makeReviewKey(
        appStoreID: result.appStoreID,
        storefront: result.storefront,
        reviewID: result.reviewID
      ),
      appStoreID: String(result.appStoreID),
      storefront: result.storefront,
      reviewID: result.reviewID,
      reviewerName: result.reviewerName,
      title: result.title,
      content: result.content,
      rating: result.rating,
      reviewedAt: result.reviewedAt,
      version: result.version,
      source: result.source.rawValue,
      observedAt: result.observedAt,
      assumedLanguageCode: nil,
      developerResponseBody: result.developerResponseBody,
      developerResponseState: result.developerResponseState
    )
  }

  fileprivate static func keywordSeedText(storeApp: StoreApp, storefronts: Set<String>) -> String {
    let metadataText = storeApp.storefrontMetadata
      .filter { storefronts.isEmpty || storefronts.contains($0.storefront) }
      .flatMap { metadata in
        [
          metadata.name,
          metadata.subtitle,
          metadata.primaryGenreName,
          metadata.descriptionText,
          metadata.releaseNotes,
        ].compactMap { $0 }
      }
      .joined(separator: " ")
    return [
      storeApp.name,
      storeApp.subtitle,
      storeApp.primaryGenreName,
      metadataText,
    ].compactMap { $0 }.joined(separator: " ")
  }

  fileprivate static func nameBasedKeywordSeeds(name: String, subtitle: String?) -> [KeywordSeed] {
    var seeds: [KeywordSeed] = []
    let cleanedName = normalizedKeyword(name.replacingOccurrences(of: "-", with: " "))
    if !cleanedName.isEmpty {
      seeds.append(KeywordSeed(keyword: cleanedName, sources: ["app_name"]))
    }
    if let subtitleKeyword = subtitle.map(normalizedKeyword), !subtitleKeyword.isEmpty {
      seeds.append(KeywordSeed(keyword: subtitleKeyword, sources: ["subtitle"]))
    }
    let tokens = keywordTokens(from: [name, subtitle].compactMap { $0 }.joined(separator: " "))
    for bigram in ngrams(tokens: tokens, size: 2).prefix(8) {
      seeds.append(KeywordSeed(keyword: bigram, sources: ["app_name"]))
    }
    return seeds
  }

  fileprivate static func extractKeywordSeeds(from text: String) -> [String] {
    let tokens = keywordTokens(from: text)
    let phrases = ngrams(tokens: tokens, size: 2) + ngrams(tokens: tokens, size: 3)
    var counts: [String: Int] = [:]
    for phrase in phrases {
      counts[phrase, default: 0] += 1
    }
    return
      counts
      .filter { isUsefulKeywordSeed($0.key, count: $0.value) }
      .sorted {
        if $0.value == $1.value { return $0.key < $1.key }
        return $0.value > $1.value
      }
      .map(\.key)
  }

  fileprivate static func isUsefulKeywordSeed(_ phrase: String, count: Int) -> Bool {
    let terms = phrase.split(separator: " ").map(String.init)
    guard (2...4).contains(terms.count) else { return false }
    let intentTerms: Set<String> = [
      "block", "blocker", "blocking", "detox", "focus", "limit", "limits", "lock", "restrict",
      "restriction", "schedule", "screen", "screentime", "time", "tracker", "web", "website",
      "websites", "zeitlimit", "bildschirmzeit", "sperre", "sperren", "bloqueo", "bloquear",
      "pantalla", "tiempo",
    ]
    if terms.contains(where: { intentTerms.contains($0) }) { return true }
    if phrase.contains("ai") || phrase.contains("tracker") || phrase.contains("counter") {
      return true
    }
    return count > 2
  }

  fileprivate static func keywordTokens(from text: String) -> [String] {
    let stopwords: Set<String> = [
      "the", "and", "for", "with", "your", "you", "our", "are", "this", "that", "from", "into",
      "will",
      "app", "apps", "get", "use", "using", "help", "helps", "any", "all", "new", "best", "less",
      "more",
      "have", "has", "but", "not", "can", "than", "then", "there", "their", "them", "was", "were",
      "out", "just", "simply", "whether", "need", "ace", "achieve", "build", "conquer", "master",
      "dein", "deine", "deinen", "deiner", "der", "die", "das", "und", "oder", "mit", "von", "zu",
      "para", "por", "con", "las", "los", "una", "uno", "del",
    ]
    return
      text
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.count > 1 && !stopwords.contains($0) && Int($0) == nil }
  }

  fileprivate static func ngrams(tokens: [String], size: Int) -> [String] {
    guard tokens.count >= size else { return [] }
    return (0...(tokens.count - size)).map { index in
      tokens[index..<(index + size)].joined(separator: " ")
    }
  }

  fileprivate static func normalizedKeyword(_ value: String) -> String {
    value
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static func keywordConfidence(
    evidence: OpenASOMCPKeywordRankingEvidence, popularityScore: Int?
  ) -> Double {
    var score = 0.2
    if let targetRank = evidence.targetRank {
      score += max(0, 0.35 - (Double(targetRank - 1) * 0.02))
    }
    score += min(0.25, Double(evidence.topRatedAppCount) * 0.05)
    if let maximumRatingCount = evidence.maximumRatingCount,
      maximumRatingCount >= ResponseLimits.bigAppRatingThreshold
    {
      score += 0.1
    }
    if let popularityScore {
      score += min(0.25, Double(popularityScore) / 400.0)
    }
    return min(score, 1.0)
  }

  fileprivate static func keywordReason(
    evidence: OpenASOMCPKeywordRankingEvidence, popularityScore: Int?
  ) -> String {
    var parts: [String] = []
    if let targetRank = evidence.targetRank {
      parts.append("target app ranks #\(targetRank)")
    } else {
      parts.append("target app is not in the sampled ranking results")
    }
    if evidence.topRatedAppCount > 0 {
      parts.append(
        "\(evidence.topRatedAppCount) top apps have at least \(ResponseLimits.bigAppRatingThreshold) ratings"
      )
    }
    if let popularityScore {
      parts.append("Apple Ads popularity \(popularityScore)")
    }
    return parts.joined(separator: "; ")
  }

  fileprivate static func landscapeNotes(
    candidates: [OpenASOMCPKeywordCandidate],
    competitors: [OpenASOMCPLandscapeCompetitor],
    includeReviews: Bool
  ) -> [String] {
    var notes: [String] = []
    if candidates.isEmpty {
      notes.append("No verified keyword candidates were found from the available app metadata.")
    }
    if competitors.isEmpty {
      notes.append("No competitors were derived from the verified keyword result sets.")
    }
    if includeReviews && competitors.allSatisfy(\.recentReviews.isEmpty) {
      notes.append(
        "No competitor review samples were returned; review feeds may be empty, unavailable, or not configured for the selected storefronts."
      )
    }
    return notes
  }

  fileprivate static func resolvedApp(_ app: ResolvedApp) -> OpenASOMCPResolvedApp {
    OpenASOMCPResolvedApp(
      id: String(app.appStoreID),
      appStoreID: String(app.appStoreID),
      bundleID: app.bundleID,
      name: app.name,
      subtitle: app.subtitle,
      sellerName: app.sellerName,
      iconURLString: app.iconURLString,
      version: app.version,
      primaryGenreName: app.primaryGenreName,
      defaultPlatform: app.defaultPlatform.rawValue,
      sellerURLString: app.sellerURLString,
      trackViewURLString: app.trackViewURLString,
      screenshotURLs: app.screenshotURLs,
      ipadScreenshotURLs: app.ipadScreenshotURLs,
      appletvScreenshotURLs: app.appletvScreenshotURLs
    )
  }

  fileprivate static func appSummary(trackedApp: TrackedApp) -> OpenASOMCPAppSummary {
    appSummary(storeApp: trackedApp.storeApp, trackedApp: trackedApp)
  }

  fileprivate static func appSummary(storeApp: StoreApp, trackedApp: TrackedApp?)
    -> OpenASOMCPAppSummary
  {
    let screenshots = storeApp.storefrontMetadata.flatMap(\.screenshots)
    return OpenASOMCPAppSummary(
      id: String(storeApp.appStoreID),
      appStoreID: String(storeApp.appStoreID),
      bundleID: storeApp.bundleID,
      name: storeApp.name,
      subtitle: storeApp.subtitle,
      sellerName: storeApp.sellerName,
      iconURLString: storeApp.iconURLString,
      defaultStorefront: storeApp.defaultStorefront,
      defaultPlatform: storeApp.defaultPlatform.rawValue,
      folder: trackedApp?.folder?.name,
      isTracked: trackedApp != nil,
      isPinned: trackedApp?.isPinned ?? false,
      createdAt: trackedApp?.createdAt,
      keywordCount: trackedApp?.keywordTracks.count ?? 0,
      reviewCount: storeApp.reviews.count,
      screenshotCount: screenshots.count,
      latestRating: storeApp.storefrontLatest
        .sorted { $0.observedAt > $1.observedAt }
        .first
        .map(ratingSummary),
      lastMetadataRefreshAt: storeApp.lastMetadataRefreshAt
    )
  }

  fileprivate static func storefrontMetadata(
    _ metadata: AppStorefrontMetadata,
    descriptionLimit: Int? = nil,
    releaseNotesLimit: Int? = nil
  ) -> OpenASOMCPStorefrontMetadata {
    OpenASOMCPStorefrontMetadata(
      storefront: metadata.storefront,
      name: metadata.name,
      subtitle: metadata.subtitle,
      sellerName: metadata.sellerName,
      descriptionText: metadata.descriptionText.map { truncated($0, to: descriptionLimit) },
      releaseNotes: metadata.releaseNotes.map { truncated($0, to: releaseNotesLimit) },
      iconURLString: metadata.iconURLString,
      version: metadata.version,
      primaryGenreName: metadata.primaryGenreName,
      source: metadata.source.rawValue,
      isAvailable: metadata.isAvailable,
      lastFetchedAt: metadata.lastFetchedAt,
      screenshotCount: metadata.screenshots.count
    )
  }

  fileprivate static func truncated(_ value: String, to limit: Int?) -> String {
    guard let limit, value.count > limit else { return value }
    return String(value.prefix(limit))
  }

  fileprivate static func ratingSummary(_ rating: LatestAppRating) -> OpenASOMCPRatingSummary {
    OpenASOMCPRatingSummary(
      storefront: rating.storefront,
      ratingCount: rating.ratingCount,
      averageRating: rating.averageRating,
      oneStarRatingCount: rating.oneStarRatingCount,
      twoStarRatingCount: rating.twoStarRatingCount,
      threeStarRatingCount: rating.threeStarRatingCount,
      fourStarRatingCount: rating.fourStarRatingCount,
      fiveStarRatingCount: rating.fiveStarRatingCount,
      observedAt: rating.observedAt,
      source: rating.source.rawValue
    )
  }

  fileprivate static func reviewSummary(reviews: [AppStorefrontReview]) -> OpenASOMCPReviewSummary {
    let totalRating = reviews.reduce(0) { $0 + $1.rating }
    return OpenASOMCPReviewSummary(
      totalCount: reviews.count,
      storefronts: Array(Set(reviews.map(\.storefront))).sorted(),
      latestReviewedAt: reviews.map(\.reviewedAt).max(),
      averageRating: reviews.isEmpty ? nil : Double(totalRating) / Double(reviews.count)
    )
  }

  fileprivate static func keywordOverviewSummary(tracks: [TrackedAppKeyword])
    -> OpenASOMCPKeywordOverviewSummary
  {
    OpenASOMCPKeywordOverviewSummary(
      totalCount: tracks.count,
      storefronts: Array(Set(tracks.map(\.storefront))).sorted(),
      latestRefreshAt: tracks.compactMap(\.lastRefreshAt).max()
    )
  }

  fileprivate static func screenshotSummary(screenshots: [AppStoreScreenshot])
    -> OpenASOMCPScreenshotSummary
  {
    OpenASOMCPScreenshotSummary(
      totalCount: screenshots.count,
      storefronts: Array(Set(screenshots.map(\.storefront))).sorted(),
      platforms: Array(Set(screenshots.map(\.platformRaw))).sorted(),
      latestFetchedAt: screenshots.map(\.lastFetchedAt).max()
    )
  }

  fileprivate static func localizationAppContext(
    role: String,
    app: OpenASOMCPAppSummary,
    storeApp: StoreApp,
    storefronts: [String],
    baselineStorefront: String,
    platform: AppPlatform,
    languageCodesByStorefront: [String: String],
    screenshotExport: OpenASOMCPScreenshotExportResult?
  ) -> OpenASOMCPLocalizationAppContext {
    let metadataByStorefront = Dictionary(
      uniqueKeysWithValues: storeApp.storefrontMetadata.map { ($0.storefront, $0) })
    let baselineMetadata = metadataByStorefront[baselineStorefront]
    let baselineSnapshot = baselineMetadata.map(localizationMetadataSnapshot)
    let baselineScreenshots = localizationScreenshots(
      metadata: baselineMetadata,
      platform: platform
    )
    let exportedFiles = screenshotExport?.completed ?? []

    let contexts = storefronts.map { storefront in
      let metadata = metadataByStorefront[storefront]
      let screenshots = localizationScreenshots(metadata: metadata, platform: platform)
      let storefrontExports = exportedFiles.filter {
        $0.metadata["storefront"] == storefront && $0.metadata["platform"] == platform.rawValue
      }
      var notes: [String] = []
      if metadata == nil {
        notes.append("No storefront metadata is stored for \(storefront).")
      }
      if baselineMetadata == nil {
        notes.append("No US baseline metadata is stored for comparison.")
      }
      if screenshots.isEmpty {
        notes.append("No \(platform.rawValue) screenshots are stored for \(storefront).")
      }
      if baselineScreenshots.isEmpty {
        notes.append("No US baseline \(platform.rawValue) screenshots are stored for comparison.")
      }

      return OpenASOMCPLocalizationStorefrontContext(
        storefront: storefront,
        languageCode: languageCodesByStorefront[storefront],
        metadata: metadata.map(localizationMetadataSnapshot),
        baselineMetadata: baselineSnapshot,
        comparison: localizationMetadataComparison(metadata: metadata, baseline: baselineMetadata),
        screenshots: screenshots,
        baselineScreenshots: baselineScreenshots,
        screenshotComparisons: localizationScreenshotComparisons(
          screenshots: screenshots,
          baselineScreenshots: baselineScreenshots,
          platform: platform
        ),
        exportedScreenshots: storefrontExports,
        notes: notes
      )
    }

    var notes: [String] = []
    if storeApp.supportedLanguageCodes.isEmpty {
      notes.append("No supported in-app language codes are stored for this app.")
    }
    if baselineMetadata == nil {
      notes.append(
        "US baseline metadata is missing; comparison fields default to false until it is fetched.")
    }

    return OpenASOMCPLocalizationAppContext(
      id: app.appStoreID,
      role: role,
      app: app,
      supportedLanguageCodes: storeApp.supportedLanguageCodes,
      supportedLanguageCodesSource: storeApp.supportedLanguageCodesSourceRaw,
      supportedLanguageCodesFetchedAt: storeApp.supportedLanguageCodesFetchedAt,
      baseline: baselineSnapshot,
      storefronts: contexts,
      screenshotExport: screenshotExport,
      notes: notes
    )
  }

  fileprivate static func localizationMetadataSnapshot(_ metadata: AppStorefrontMetadata)
    -> OpenASOMCPLocalizationMetadataSnapshot
  {
    OpenASOMCPLocalizationMetadataSnapshot(
      storefront: metadata.storefront,
      name: metadata.name,
      subtitle: metadata.subtitle,
      descriptionText: metadata.descriptionText.map {
        truncated($0, to: ResponseLimits.localizationDescriptionCharacters)
      },
      releaseNotes: metadata.releaseNotes.map {
        truncated($0, to: ResponseLimits.localizationReleaseNotesCharacters)
      },
      primaryGenreName: metadata.primaryGenreName,
      version: metadata.version,
      source: metadata.source.rawValue,
      isAvailable: metadata.isAvailable,
      lastFetchedAt: metadata.lastFetchedAt,
      screenshotCount: metadata.screenshots.count
    )
  }

  fileprivate static func localizationMetadataComparison(
    metadata: AppStorefrontMetadata?,
    baseline: AppStorefrontMetadata?
  ) -> OpenASOMCPLocalizationMetadataComparison {
    guard let metadata, let baseline else {
      return OpenASOMCPLocalizationMetadataComparison(
        nameDiffersFromUS: false,
        subtitleDiffersFromUS: false,
        descriptionDiffersFromUS: false
      )
    }
    return OpenASOMCPLocalizationMetadataComparison(
      nameDiffersFromUS: normalizedComparisonText(metadata.name)
        != normalizedComparisonText(baseline.name),
      subtitleDiffersFromUS: optionalComparisonTextDiffers(metadata.subtitle, baseline.subtitle),
      descriptionDiffersFromUS: optionalComparisonTextDiffers(
        metadata.descriptionText, baseline.descriptionText)
    )
  }

  fileprivate static func localizationScreenshots(
    metadata: AppStorefrontMetadata?,
    platform: AppPlatform
  ) -> [OpenASOMCPScreenshot] {
    (metadata?.screenshots ?? [])
      .filter { $0.platformRaw == platform.rawValue }
      .sorted {
        if $0.displayTypeRaw == $1.displayTypeRaw {
          return $0.sortOrder < $1.sortOrder
        }
        return $0.displayTypeRaw < $1.displayTypeRaw
      }
      .map(screenshot)
  }

  fileprivate static func localizationScreenshotComparisons(
    screenshots: [OpenASOMCPScreenshot],
    baselineScreenshots: [OpenASOMCPScreenshot],
    platform: AppPlatform
  ) -> [OpenASOMCPLocalizationScreenshotComparison] {
    let displayTypes = Set(screenshots.map(\.displayType)).union(
      baselineScreenshots.map(\.displayType)
    ).sorted()
    return displayTypes.map { displayType in
      let storefrontURLs =
        screenshots
        .filter { $0.displayType == displayType }
        .sorted { $0.sortOrder < $1.sortOrder }
        .map(\.urlString)
      let baselineURLs =
        baselineScreenshots
        .filter { $0.displayType == displayType }
        .sorted { $0.sortOrder < $1.sortOrder }
        .map(\.urlString)
      let storefrontURLSet = Set(storefrontURLs)
      let baselineURLSet = Set(baselineURLs)
      let added = storefrontURLSet.subtracting(baselineURLSet)
      let removed = baselineURLSet.subtracting(storefrontURLSet)
      return OpenASOMCPLocalizationScreenshotComparison(
        platform: platform.rawValue,
        displayType: displayType,
        screenshotURLsDifferFromUS: storefrontURLSet != baselineURLSet,
        screenshotURLAddedCount: added.count,
        screenshotURLRemovedCount: removed.count,
        screenshotURLSharedCount: storefrontURLSet.intersection(baselineURLSet).count,
        hasStorefrontScreenshots: !storefrontURLs.isEmpty,
        hasBaselineScreenshots: !baselineURLs.isEmpty,
        storefrontScreenshotURLs: storefrontURLs,
        baselineScreenshotURLs: baselineURLs
      )
    }
  }

  fileprivate static func languageCodesByStorefront(in modelContext: ModelContext) throws
    -> [String: String]
  {
    let stored = try modelContext.fetch(FetchDescriptor<Storefront>())
    var values = Dictionary(uniqueKeysWithValues: stored.map { ($0.code, $0.languageCode) })
    for (storefront, languageCode) in fallbackLocalizationLanguageCodes
    where values[storefront] == nil {
      values[storefront] = languageCode
    }
    return values
  }

  fileprivate static var fallbackLocalizationLanguageCodes: [String: String] {
    [
      "us": "en-US", "jp": "ja-JP", "cn": "zh-Hans", "gb": "en-GB", "de": "de-DE",
      "fr": "fr-FR", "ca": "en-CA", "au": "en-AU", "kr": "ko-KR", "br": "pt-BR",
      "mx": "es-MX", "es": "es-ES", "it": "it-IT", "nl": "nl-NL", "se": "sv-SE",
      "ch": "de-CH", "tr": "tr-TR", "in": "en-IN", "id": "id-ID", "sa": "ar-SA",
    ]
  }

  fileprivate static func storefrontsIncludingLocalizationBaseline(_ storefronts: [String])
    -> [String]
  {
    Array(Set(storefronts + [localizationBaselineStorefront])).sorted()
  }

  fileprivate static func localizationResearchNotes(
    refreshMissingMetadata: Bool,
    destinationDirectoryPath: String?
  ) -> [String] {
    var notes = [
      "OpenASO returns deterministic metadata and screenshot URL comparisons only; the agent should perform OCR, visual interpretation, and final localization recommendations.",
      "Supported language codes indicate in-app language availability and should not be treated as proof of localized App Store metadata.",
    ]
    if refreshMissingMetadata {
      notes.append(
        "Missing storefront metadata was refreshed where public App Store lookup data was available."
      )
    } else {
      notes.append(
        "Missing storefront metadata was not refreshed because refresh_missing_metadata was false.")
    }
    if destinationDirectoryPath == nil {
      notes.append(
        "No screenshot destination was provided, so screenshot file paths were not exported.")
    }
    return notes
  }

  fileprivate static func normalizedComparisonText(_ value: String?) -> String {
    value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ") ?? ""
  }

  fileprivate static func optionalComparisonTextDiffers(_ value: String?, _ baseline: String?)
    -> Bool
  {
    let normalizedValue = normalizedComparisonText(value)
    let normalizedBaseline = normalizedComparisonText(baseline)
    guard !normalizedValue.isEmpty || !normalizedBaseline.isEmpty else { return false }
    return normalizedValue != normalizedBaseline
  }

  fileprivate static func review(_ review: AppStorefrontReview) -> OpenASOMCPReview {
    OpenASOMCPReview(
      reviewKey: review.reviewKey,
      appStoreID: String(review.appStoreID),
      storefront: review.storefront,
      reviewID: review.reviewID,
      reviewerName: review.reviewerName,
      title: review.title,
      content: review.content,
      rating: review.rating,
      reviewedAt: review.reviewedAt,
      version: review.version,
      source: review.source.rawValue,
      observedAt: review.observedAt,
      assumedLanguageCode: review.assumedLanguageCode,
      developerResponseBody: review.developerResponseBody,
      developerResponseState: review.developerResponseState
    )
  }

  fileprivate static func keywordSummary(track: TrackedAppKeyword, metrics: KeywordDailyMetric?)
    -> OpenASOMCPKeywordSummary
  {
    let latest = track.latestSnapshot
    let previous = track.previousSnapshot
    let rankDelta: Int?
    if let latestRank = latest?.rank, let previousRank = previous?.rank {
      rankDelta = previousRank - latestRank
    } else {
      rankDelta = nil
    }

    return OpenASOMCPKeywordSummary(
      id: track.identityKey,
      trackIdentityKey: track.identityKey,
      appStoreID: String(track.appStoreID),
      keyword: track.term,
      queryKey: track.queryKey,
      storefront: track.storefront,
      platform: track.platform.rawValue,
      latestRank: latest?.rank,
      previousRank: previous?.rank,
      rankDelta: rankDelta,
      resultCount: latest?.resultCount ?? track.rankingAppCount,
      popularityScore: metrics?.popularityScore,
      difficultyScore: metrics?.difficultyScore,
      notes: track.notes,
      statusMessage: track.statusMessage,
      lastRefreshAt: track.lastRefreshAt,
      createdAt: track.createdAt
    )
  }

  fileprivate static func keywordScore(_ keyword: OpenASOMCPKeywordSummary)
    -> OpenASOMCPKeywordScore
  {
    let terms = keyword.keyword
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
    let genericTerms: Set<String> = [
      "a", "after", "an", "and", "app", "apps", "before", "certain", "for", "it", "need",
      "number", "of", "open", "the", "to", "wait", "waiting", "with",
    ]
    let strongIntentTerms: Set<String> = [
      "block", "blocker", "control", "detox", "focus", "limit", "productivity",
      "screen", "time", "website", "websites",
    ]
    let brandSignals = ["screenzen", "screen zen"]
    let hasBrandSignal = brandSignals.contains { keyword.keyword.lowercased().contains($0) }
    let strongIntentCount = terms.filter { strongIntentTerms.contains($0) }.count
    let genericRatio =
      terms.isEmpty
      ? 1.0 : Double(terms.filter { genericTerms.contains($0) }.count) / Double(terms.count)
    let hasRank = keyword.latestRank != nil
    let topRank = keyword.latestRank.map { $0 <= 3 } ?? false
    let visibleRank = keyword.latestRank.map { $0 <= 10 } ?? false
    let hasPopularity = (keyword.popularityScore ?? 0) >= 10

    var noiseScore = 0.0
    if terms.count <= 1 { noiseScore += 0.25 }
    if genericRatio >= 0.6 { noiseScore += 0.45 }
    if strongIntentCount == 0 && !hasBrandSignal { noiseScore += 0.3 }
    if !hasRank && !hasPopularity { noiseScore += 0.2 }
    noiseScore = min(noiseScore, 1.0)

    var relevanceScore = 0.0
    if hasBrandSignal { relevanceScore += 0.35 }
    if strongIntentCount > 0 { relevanceScore += min(0.35, Double(strongIntentCount) * 0.12) }
    if topRank { relevanceScore += 0.3 } else if visibleRank { relevanceScore += 0.2 }
    if hasPopularity { relevanceScore += 0.15 }
    if terms.count >= 3 { relevanceScore += 0.1 }
    relevanceScore = min(max(relevanceScore - (noiseScore * 0.25), 0.0), 1.0)

    let priority: String
    if noiseScore >= 0.65 && relevanceScore < 0.5 {
      priority = "noisy"
    } else if hasBrandSignal {
      priority = "brand"
    } else if topRank {
      priority = "defend"
    } else if visibleRank || hasPopularity {
      priority = "attack"
    } else if terms.count >= 3 && relevanceScore >= 0.35 {
      priority = "long_tail"
    } else {
      priority = "experimental"
    }

    let intent: String
    if hasBrandSignal {
      intent = "brand"
    } else if terms.contains(where: { ["block", "blocker", "limit", "control"].contains($0) }) {
      intent = "app_blocking"
    } else if terms.contains(where: { ["website", "websites"].contains($0) }) {
      intent = "website_blocking"
    } else if terms.contains(where: { ["focus", "productivity", "detox"].contains($0) }) {
      intent = "productivity"
    } else {
      intent = "unknown"
    }

    var rationale: [String] = []
    if let rank = keyword.latestRank { rationale.append("latest rank \(rank)") }
    if let popularity = keyword.popularityScore { rationale.append("popularity \(popularity)") }
    if strongIntentCount > 0 { rationale.append("\(strongIntentCount) strong intent term(s)") }
    if hasBrandSignal { rationale.append("contains brand signal") }
    if noiseScore >= 0.65 { rationale.append("mostly generic or ambiguous phrase") }
    if rationale.isEmpty { rationale.append("limited ranking and relevance evidence") }

    return OpenASOMCPKeywordScore(
      keyword: keyword.keyword,
      storefront: keyword.storefront,
      platform: keyword.platform,
      latestRank: keyword.latestRank,
      popularityScore: keyword.popularityScore,
      resultCount: keyword.resultCount,
      priority: priority,
      intent: intent,
      noiseScore: noiseScore,
      relevanceScore: relevanceScore,
      rationale: rationale
    )
  }

  fileprivate static func screenshot(_ screenshot: AppStoreScreenshot) -> OpenASOMCPScreenshot {
    OpenASOMCPScreenshot(
      id: screenshot.identityKey,
      appStoreID: String(screenshot.appStoreID),
      storefront: screenshot.storefront,
      platform: screenshot.platformRaw,
      displayType: screenshot.displayTypeRaw,
      sortOrder: screenshot.sortOrder,
      urlString: screenshot.urlString,
      width: screenshot.width,
      height: screenshot.height,
      source: screenshot.source.rawValue,
      lastFetchedAt: screenshot.lastFetchedAt
    )
  }

  fileprivate static func screenshotDownloadJob(screenshot: AppStoreScreenshot, appName: String)
    -> ScreenshotDownloadJob
  {
    ScreenshotDownloadJob(
      id: screenshot.identityKey,
      urlString: screenshot.urlString,
      relativeDirectoryComponents: [
        "OpenASO Screenshots",
        "\(appName) (\(screenshot.appStoreID))",
        screenshot.storefront,
        screenshot.platformRaw,
      ],
      filenameStem: "\(screenshot.displayTypeRaw)-\(screenshot.sortOrder)",
      metadata: [
        "appStoreID": String(screenshot.appStoreID),
        "storefront": screenshot.storefront,
        "platform": screenshot.platformRaw,
        "displayType": screenshot.displayTypeRaw,
        "sortOrder": String(screenshot.sortOrder),
      ],
      fallbackExtension: "jpg"
    )
  }

  fileprivate static func exportedScreenshot(_ download: DownloadedScreenshot)
    -> OpenASOMCPScreenshotExportedFile
  {
    OpenASOMCPScreenshotExportedFile(
      screenshotID: download.jobID,
      urlString: download.urlString,
      relativePath: download.relativePath,
      filePath: download.fileURL.path,
      byteCount: download.byteCount,
      metadata: download.metadata
    )
  }

  fileprivate static func failedScreenshotExport(_ failure: FailedScreenshotDownload)
    -> OpenASOMCPScreenshotExportFailure
  {
    OpenASOMCPScreenshotExportFailure(
      screenshotID: failure.jobID,
      urlString: failure.urlString,
      relativePath: failure.relativePath,
      errorDescription: failure.errorDescription,
      metadata: failure.metadata
    )
  }

  fileprivate static func markdownNewURL(for sourceURL: URL) throws -> URL {
    guard let url = URL(string: "https://markdown.new/\(sourceURL.absoluteString)") else {
      throw OpenASOError.providerUnavailable("Unable to construct markdown.new URL.")
    }
    return url
  }

  fileprivate static func appStoreID(fromPossibleURL value: String) -> Int64? {
    guard let url = URL(string: value) else { return nil }
    let path = url.path
    if let range = path.range(of: #"id(\d+)"#, options: .regularExpression) {
      return Int64(path[range].dropFirst(2))
    }
    return nil
  }

  fileprivate static func websiteCandidates(from resolvedApp: ResolvedApp) -> [String] {
    deduplicatedWebsiteCandidates(
      [
        resolvedApp.sellerURLString
      ].compactMap { value in
        guard let value, let url = try? OpenASOMCPValidation.webURL(value) else { return nil }
        guard !Self.isAppStoreURL(url) else { return nil }
        return url.absoluteString
      })
  }

  fileprivate static func appStorePageURL(from resolvedApp: ResolvedApp, storefront: String) -> URL
  {
    if let trackViewURLString = resolvedApp.trackViewURLString,
      let trackViewURL = URL(string: trackViewURLString),
      Self.isAppStoreURL(trackViewURL)
    {
      return trackViewURL
    }
    return URL(string: "https://apps.apple.com/\(storefront)/app/id\(resolvedApp.appStoreID)")!
  }

  fileprivate static func websiteCandidates(fromAppStoreHTML html: String) -> [String] {
    let normalizedHTML = htmlDecoded(html.replacingOccurrences(of: #"\/"#, with: "/"))
    let patterns = [
      #"https?://[^\s"'<>\\]+"#,
      #"href\s*=\s*["']([^"']+)["']"#,
    ]
    var candidates: [String] = []
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }
      let range = NSRange(normalizedHTML.startIndex..<normalizedHTML.endIndex, in: normalizedHTML)
      for match in regex.matches(in: normalizedHTML, range: range) {
        let captureIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let captureRange = Range(match.range(at: captureIndex), in: normalizedHTML) else {
          continue
        }
        let value = String(normalizedHTML[captureRange])
        guard let url = try? OpenASOMCPValidation.webURL(value) else { continue }
        guard !Self.isAppStoreURL(url), !Self.isAppleAssetURL(url) else { continue }
        let contextStart = normalizedHTML.index(
          captureRange.lowerBound,
          offsetBy: -min(
            120,
            normalizedHTML.distance(from: normalizedHTML.startIndex, to: captureRange.lowerBound))
        )
        let contextEnd = normalizedHTML.index(
          captureRange.upperBound,
          offsetBy: min(
            120, normalizedHTML.distance(from: captureRange.upperBound, to: normalizedHTML.endIndex)
          )
        )
        let context = String(normalizedHTML[contextStart..<contextEnd]).lowercased()
        guard
          Self.looksLikeDeveloperWebsiteContext(context) || Self.looksLikeDeveloperWebsiteURL(url)
        else { continue }
        candidates.append(url.absoluteString)
      }
    }
    return deduplicatedWebsiteCandidates(candidates)
  }

  fileprivate static func deduplicatedWebsiteCandidates(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard let url = try? OpenASOMCPValidation.webURL(value), !Self.isAppStoreURL(url),
        !Self.isAppleAssetURL(url)
      else {
        return nil
      }
      let string = url.absoluteString
      return seen.insert(string).inserted ? string : nil
    }
  }

  fileprivate static func looksLikeDeveloperWebsiteContext(_ value: String) -> Bool {
    [
      "privacy",
      "support",
      "developer website",
      "developer",
      "seller",
      "website",
      "marketing",
    ].contains { value.contains($0) }
  }

  fileprivate static func looksLikeDeveloperWebsiteURL(_ url: URL) -> Bool {
    let string = url.absoluteString.lowercased()
    return string.contains("privacy") || string.contains("support")
  }

  fileprivate static func htmlDecoded(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
  }

  fileprivate static func isAppStoreURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "apps.apple.com" || host.hasSuffix(".apps.apple.com")
  }

  fileprivate static func isAppleAssetURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "is1-ssl.mzstatic.com"
      || host == "is2-ssl.mzstatic.com"
      || host == "is3-ssl.mzstatic.com"
      || host == "is4-ssl.mzstatic.com"
      || host == "is5-ssl.mzstatic.com"
      || host.hasSuffix(".mzstatic.com")
      || host == "itunes.apple.com"
  }

  fileprivate static func popularityStatusMessage(from statusMessage: String?) -> String? {
    guard let statusMessage else { return nil }
    guard
      statusMessage.hasPrefix("Popularity failed to fetch.")
        || statusMessage.hasPrefix("Popularity unavailable.")
    else {
      return nil
    }
    return statusMessage
  }

  fileprivate static func fetchStoreApp(appStoreID: Int64, in modelContext: ModelContext) throws
    -> StoreApp?
  {
    var descriptor = FetchDescriptor<StoreApp>(
      predicate: #Predicate { storeApp in
        storeApp.appStoreID == appStoreID
      }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  fileprivate static func fetchStorefrontMetadata(
    identityKey: String, in modelContext: ModelContext
  ) throws -> AppStorefrontMetadata? {
    let targetIdentityKey = identityKey
    var descriptor = FetchDescriptor<AppStorefrontMetadata>(
      predicate: #Predicate { metadata in
        metadata.identityKey == targetIdentityKey
      }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  fileprivate static func fetchTrackedApp(appStoreID: Int64, in modelContext: ModelContext) throws
    -> TrackedApp?
  {
    var descriptor = FetchDescriptor<TrackedApp>(
      predicate: #Predicate { trackedApp in
        trackedApp.appStoreID == appStoreID
      }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  fileprivate static func fetchTrackedKeyword(identityKey: String, in modelContext: ModelContext)
    throws -> TrackedAppKeyword?
  {
    var descriptor = FetchDescriptor<TrackedAppKeyword>(
      predicate: #Predicate { track in
        track.identityKey == identityKey
      }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  @discardableResult
  fileprivate static func ensureTrackedKeyword(
    request: RankingRefreshRequest,
    appStoreID: Int64,
    in modelContext: ModelContext
  ) throws -> TrackedAppKeyword {
    if let existing = try fetchTrackedKeyword(identityKey: request.identityKey, in: modelContext) {
      return existing
    }
    guard let trackedApp = try fetchTrackedApp(appStoreID: appStoreID, in: modelContext) else {
      throw OpenASOError.appNotFound
    }
    let query = try KeywordQuery.fetchOrInsert(
      term: request.term,
      storefront: request.storefront,
      platform: request.platform,
      in: modelContext
    )
    let track = TrackedAppKeyword(
      term: request.term,
      storefront: request.storefront,
      platform: request.platform,
      trackedApp: trackedApp,
      query: query
    )
    trackedApp.keywordTracks.append(track)
    modelContext.insert(track)
    return track
  }

  @discardableResult
  fileprivate static func persistRankingPage(
    _ page: SearchRankingPage,
    request: RankingRefreshRequest,
    appStoreID: Int64,
    observedAt: Date,
    appCatalogService: AppCatalogService,
    in modelContext: ModelContext
  ) throws -> TrackedAppKeyword {
    guard let trackedApp = try fetchTrackedApp(appStoreID: appStoreID, in: modelContext) else {
      throw OpenASOError.appNotFound
    }
    let track = try ensureTrackedKeyword(
      request: request, appStoreID: trackedApp.appStoreID, in: modelContext)
    let query = track.query

    var catalogCache = try appCatalogService.makeSearchRankingPageCache(
      items: page.items,
      storefrontCode: request.storefront,
      in: modelContext
    )
    for item in page.items {
      _ = try appCatalogService.upsertStoreApp(
        from: item,
        storefrontCode: request.storefront,
        in: modelContext,
        cache: &catalogCache
      )
    }

    let source = page.source
    let snapshotKey = TrackedKeywordDailyRanking.makeSnapshotKey(
      trackIdentityKey: track.identityKey,
      searchedAt: observedAt,
      source: source
    )
    var snapshotDescriptor = FetchDescriptor<TrackedKeywordDailyRanking>(
      predicate: #Predicate { snapshot in
        snapshot.snapshotKey == snapshotKey
      }
    )
    snapshotDescriptor.fetchLimit = 1
    let snapshot =
      try modelContext.fetch(snapshotDescriptor).first
      ?? TrackedKeywordDailyRanking(
        rank: RankingMatcher.rank(for: trackedApp, in: page.items),
        searchedAt: observedAt,
        source: source,
        resultCount: page.resultCount,
        keywordTrack: track
      )
    if snapshot.modelContext == nil {
      modelContext.insert(snapshot)
      track.snapshots.append(snapshot)
    }
    snapshot.rank = RankingMatcher.rank(for: trackedApp, in: page.items)
    snapshot.searchedAt = observedAt
    snapshot.resultCount = page.resultCount
    snapshot.errorMessage = nil

    let observationKey = KeywordRankingCrawl.makeObservationKey(
      queryKey: request.queryKey,
      observedAt: observedAt,
      source: source
    )
    var observationDescriptor = FetchDescriptor<KeywordRankingCrawl>(
      predicate: #Predicate { crawl in
        crawl.observationKey == observationKey
      }
    )
    observationDescriptor.fetchLimit = 1
    let observation =
      try modelContext.fetch(observationDescriptor).first
      ?? KeywordRankingCrawl(
        keyword: request.term,
        storefront: request.storefront,
        platform: request.platform,
        observedAt: observedAt,
        source: source,
        resultCount: page.resultCount,
        query: query
      )
    if observation.modelContext == nil {
      modelContext.insert(observation)
      query.observations.append(observation)
    }
    observation.resultCount = page.resultCount

    var retainedAppStoreIDs: [Int64] = []
    for item in page.items {
      retainedAppStoreIDs.append(item.appStoreID)
      let itemKey = KeywordAppRanking.makeItemKey(
        observationKey: observation.observationKey, appStoreID: item.appStoreID)
      var itemDescriptor = FetchDescriptor<KeywordAppRanking>(
        predicate: #Predicate { ranking in
          ranking.itemKey == itemKey
        }
      )
      itemDescriptor.fetchLimit = 1
      let ranking =
        try modelContext.fetch(itemDescriptor).first
        ?? KeywordAppRanking(
          position: item.position,
          appStoreID: item.appStoreID,
          bundleID: item.bundleID,
          name: item.name,
          subtitle: item.subtitle,
          sellerName: item.sellerName,
          observation: observation
        )
      if ranking.modelContext == nil {
        modelContext.insert(ranking)
        observation.items.append(ranking)
      }
      ranking.position = item.position
      ranking.name = item.name
      ranking.subtitle = item.subtitle
      ranking.sellerName = item.sellerName
      ranking.bundleID = item.bundleID
      ranking.crawlKey = observation.observationKey
      ranking.queryKey = observation.queryKey
      ranking.storefront = observation.storefront
      ranking.platformRaw = observation.platformRaw
      ranking.observedAt = observation.observedAt

      let result =
        snapshot.topResults.first { $0.appStoreID == item.appStoreID }
        ?? TrackedKeywordRankedResult(
          position: item.position,
          appStoreID: item.appStoreID,
          bundleID: item.bundleID,
          name: item.name,
          subtitle: item.subtitle,
          sellerName: item.sellerName,
          snapshot: snapshot
        )
      if result.modelContext == nil {
        snapshot.topResults.append(result)
        modelContext.insert(result)
      }
      result.snapshotKey = snapshot.snapshotKey
      result.position = item.position
      result.appStoreID = item.appStoreID
      result.bundleID = item.bundleID
      result.name = item.name
      result.subtitle = item.subtitle
      result.sellerName = item.sellerName
      if result.snapshot !== snapshot {
        result.snapshot = snapshot
      }
    }

    let retainedAppStoreIDSet = Set(retainedAppStoreIDs)
    for result in snapshot.topResults where !retainedAppStoreIDSet.contains(result.appStoreID) {
      modelContext.delete(result)
    }
    snapshot.topResults.removeAll { !retainedAppStoreIDSet.contains($0.appStoreID) }
    for item in observation.items where !retainedAppStoreIDSet.contains(item.appStoreID) {
      modelContext.delete(item)
    }
    observation.items.removeAll { !retainedAppStoreIDSet.contains($0.appStoreID) }

    track.statusMessage = nil
    track.lastRefreshAt = observedAt
    track.rankingAppCount = page.resultCount
    return track
  }

  fileprivate static func metricsByQueryKey(
    queryKeys: [String],
    in modelContext: ModelContext
  ) throws -> [String: KeywordDailyMetric] {
    guard !queryKeys.isEmpty else { return [:] }
    let descriptor = FetchDescriptor<KeywordDailyMetric>(
      predicate: #Predicate { metrics in
        queryKeys.contains(metrics.queryKey)
      }
    )
    return Dictionary(
      uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.queryKey, $0) })
  }

  fileprivate static func metricValuesByQueryKey(
    queryKeys: [String],
    in modelContext: ModelContext
  ) throws -> [String: KeywordMetricValue] {
    try metricsByQueryKey(queryKeys: queryKeys, in: modelContext).mapValues {
      KeywordMetricValue(
        popularityScore: $0.popularityScore,
        difficultyScore: $0.difficultyScore
      )
    }
  }

  fileprivate static func deriveCompetitors(
    appStoreID: Int64,
    storefronts: [String],
    platform: AppPlatform?,
    lookbackDays: Int,
    limit: Int,
    evidenceLimit: Int,
    in modelContext: ModelContext
  ) throws -> [OpenASOMCPCompetitorSummary] {
    let trackedApp = try fetchTrackedApp(appStoreID: appStoreID, in: modelContext)
    let queryKeys = trackedApp.map { Set($0.keywordTracks.map(\.queryKey)) } ?? []
    guard !queryKeys.isEmpty else { return [] }

    let cutoff = Date().addingTimeInterval(-Double(max(1, lookbackDays)) * 86_400)
    let storefrontSet = Set(storefronts)
    let descriptor = FetchDescriptor<KeywordAppRanking>(
      predicate: #Predicate { ranking in
        queryKeys.contains(ranking.queryKey)
          && ranking.appStoreID != appStoreID
          && ranking.position <= 10
          && ranking.observedAt >= cutoff
      },
      sortBy: [
        SortDescriptor(\.observedAt, order: .reverse),
        SortDescriptor(\.position, order: .forward),
      ]
    )

    let rows = try modelContext.fetch(descriptor).filter { ranking in
      if !storefrontSet.isEmpty && !storefrontSet.contains(ranking.storefront) { return false }
      if let platform, ranking.platform != platform { return false }
      return true
    }

    var evidenceByApp: [Int64: CompetitorAccumulator] = [:]
    for row in rows {
      let components = KeywordQuery.components(from: row.queryKey)
      evidenceByApp[
        row.appStoreID,
        default: CompetitorAccumulator(
          appStoreID: row.appStoreID,
          name: row.name,
          sellerName: row.sellerName,
          bundleID: row.bundleID
        )
      ].add(row: row, keyword: components?.term ?? row.queryKey)
    }

    let appIDs = Array(evidenceByApp.keys)
    let storeApps = try storeAppsByID(appStoreIDs: appIDs, in: modelContext)

    return evidenceByApp.values
      .map { accumulator in
        accumulator.summary(
          storeApp: storeApps[accumulator.appStoreID],
          evidenceLimit: evidenceLimit
        )
      }
      .sorted {
        if $0.sharedKeywordCount == $1.sharedKeywordCount {
          if $0.occurrenceCount == $1.occurrenceCount {
            return $0.averageRank < $1.averageRank
          }
          return $0.occurrenceCount > $1.occurrenceCount
        }
        return $0.sharedKeywordCount > $1.sharedKeywordCount
      }
      .prefix(limit)
      .map { $0 }
  }

  fileprivate static func storeAppsByID(appStoreIDs: [Int64], in modelContext: ModelContext) throws
    -> [Int64: StoreApp]
  {
    guard !appStoreIDs.isEmpty else { return [:] }
    let descriptor = FetchDescriptor<StoreApp>(
      predicate: #Predicate { app in
        appStoreIDs.contains(app.appStoreID)
      }
    )
    return Dictionary(
      uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.appStoreID, $0) })
  }

  fileprivate static func freshnessWarnings(
    app: OpenASOMCPAppSummary,
    reviewSummary: OpenASOMCPReviewSummary,
    keywordSummary: OpenASOMCPKeywordOverviewSummary,
    screenshotSummary: OpenASOMCPScreenshotSummary,
    now: Date
  ) -> [String] {
    var warnings: [String] = []
    if app.keywordCount == 0 {
      warnings.append("No tracked keywords are available for this app.")
    }
    if reviewSummary.totalCount == 0 {
      warnings.append("No stored reviews are available for this app.")
    }
    if screenshotSummary.totalCount == 0 {
      warnings.append("No screenshot metadata is available for this app.")
    }
    if let latestRefreshAt = keywordSummary.latestRefreshAt,
      now.timeIntervalSince(latestRefreshAt) > 14 * 86_400
    {
      warnings.append("Keyword ranking data is older than 14 days.")
    }
    if let latestReviewedAt = reviewSummary.latestReviewedAt,
      now.timeIntervalSince(latestReviewedAt) > 90 * 86_400
    {
      warnings.append("Latest stored review is older than 90 days.")
    }
    return warnings
  }
}

private struct CompetitorAccumulator {
  let appStoreID: Int64
  var name: String
  var sellerName: String?
  var bundleID: String?
  var rankSum = 0
  var occurrenceCount = 0
  var bestRank = Int.max
  var latestObservedAt = Date.distantPast
  var evidenceByQueryKey: [String: OpenASOMCPCompetitorKeywordEvidence] = [:]

  mutating func add(row: KeywordAppRanking, keyword: String) {
    rankSum += row.position
    occurrenceCount += 1
    bestRank = min(bestRank, row.position)
    if row.observedAt > latestObservedAt {
      latestObservedAt = row.observedAt
      name = row.name
      sellerName = row.sellerName ?? sellerName
      bundleID = row.bundleID ?? bundleID
    }

    let existing = evidenceByQueryKey[row.queryKey]
    let evidence = OpenASOMCPCompetitorKeywordEvidence(
      queryKey: row.queryKey,
      keyword: keyword,
      storefront: row.storefront,
      platform: row.platformRaw,
      bestRank: min(existing?.bestRank ?? row.position, row.position),
      latestRank: (existing?.latestObservedAt ?? Date.distantPast) > row.observedAt
        ? existing?.latestRank ?? row.position
        : row.position,
      latestObservedAt: max(existing?.latestObservedAt ?? row.observedAt, row.observedAt)
    )
    evidenceByQueryKey[row.queryKey] = evidence
  }

  func summary(storeApp: StoreApp?, evidenceLimit: Int) -> OpenASOMCPCompetitorSummary {
    let averageRank = occurrenceCount == 0 ? 0 : Double(rankSum) / Double(occurrenceCount)
    return OpenASOMCPCompetitorSummary(
      id: String(appStoreID),
      appStoreID: String(appStoreID),
      name: storeApp?.name ?? name,
      sellerName: storeApp?.sellerName ?? sellerName,
      bundleID: storeApp?.bundleID ?? bundleID,
      iconURLString: storeApp?.iconURLString,
      sharedKeywordCount: evidenceByQueryKey.count,
      occurrenceCount: occurrenceCount,
      bestRank: bestRank,
      averageRank: averageRank,
      latestObservedAt: latestObservedAt,
      evidence: evidenceByQueryKey.values.sorted {
        if $0.bestRank == $1.bestRank {
          return $0.latestObservedAt > $1.latestObservedAt
        }
        return $0.bestRank < $1.bestRank
      }
      .prefix(evidenceLimit)
      .map { $0 }
    )
  }
}
