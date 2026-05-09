import SwiftData
import SwiftUI

struct AppKeywordsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query private var tracks: [TrackedAppKeyword]

    let trackedApp: TrackedApp
    let searchText: String
    let selectedStorefrontFilter: StorefrontFilter
    let selectedDateRange: TrendDateRange
    let selectedPlatformFilter: PlatformFilter
    let popularityFilterRange: ClosedRange<Double>
    let difficultyFilterRange: ClosedRange<Double>
    let positionFilterRange: ClosedRange<Double>
    let changeFilterRange: ClosedRange<Double>
    let showsOnlyChangedKeywords: Bool
    let refreshToken: Int
    let reportError: (String) -> Void

    @State private var metricsByQueryKey: [String: KeywordMetricsSnapshot] = [:]
    @State private var insightsDataset = KeywordInsightsDataset(appStoreID: 0, series: [], source: .local)
    @State private var keywordRows: [KeywordWorkspaceRow] = []
    @State private var derivedRowsSignature: String?

    init(
        trackedApp: TrackedApp,
        searchText: String,
        selectedStorefrontFilter: StorefrontFilter,
        selectedDateRange: TrendDateRange,
        selectedPlatformFilter: PlatformFilter,
        popularityFilterRange: ClosedRange<Double>,
        difficultyFilterRange: ClosedRange<Double>,
        positionFilterRange: ClosedRange<Double>,
        changeFilterRange: ClosedRange<Double>,
        showsOnlyChangedKeywords: Bool,
        refreshToken: Int,
        reportError: @escaping (String) -> Void
    ) {
        self.trackedApp = trackedApp
        self.searchText = searchText
        self.selectedStorefrontFilter = selectedStorefrontFilter
        self.selectedDateRange = selectedDateRange
        self.selectedPlatformFilter = selectedPlatformFilter
        self.popularityFilterRange = popularityFilterRange
        self.difficultyFilterRange = difficultyFilterRange
        self.positionFilterRange = positionFilterRange
        self.changeFilterRange = changeFilterRange
        self.showsOnlyChangedKeywords = showsOnlyChangedKeywords
        self.refreshToken = refreshToken
        self.reportError = reportError

        let appStoreID = trackedApp.appStoreID
        let sortBy = [
            SortDescriptor(\TrackedAppKeyword.term, order: .forward),
            SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
            SortDescriptor(\TrackedAppKeyword.platformRaw, order: .forward)
        ]

        switch selectedStorefrontFilter {
        case .all:
            _tracks = Query(
                filter: #Predicate<TrackedAppKeyword> { track in
                    track.appStoreID == appStoreID
                },
                sort: sortBy
            )
        case .storefront(let code, _):
            let storefrontCode = code
            _tracks = Query(
                filter: #Predicate<TrackedAppKeyword> { track in
                    track.appStoreID == appStoreID && track.storefront == storefrontCode
                },
                sort: sortBy
            )
        }
    }

    private var rowReloadSignature: String {
        [
            String(refreshToken),
            String(services.backgroundModelStoreRevision),
            String(trackedApp.appStoreID),
            selectedPlatformFilter.id,
            tracksSignature,
            selectedDateRange.id,
            searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            popularityFilterRange.description,
            difficultyFilterRange.description,
            positionFilterRange.description,
            changeFilterRange.description,
            String(showsOnlyChangedKeywords)
        ].joined(separator: "::")
    }

    private var tracksSignature: String {
        tracks.map { track in
            [
                track.identityKey,
                String(track.lastRefreshAt?.timeIntervalSinceReferenceDate ?? 0),
                String(track.rankingAppCount ?? -1),
                track.statusMessage ?? ""
            ].joined(separator: "|")
        }
        .joined(separator: "::")
    }

    private var isLoadingKeywordRows: Bool {
        derivedRowsSignature != rowReloadSignature
    }

    private func insightsSignature(for rows: [KeywordWorkspaceRow]) -> String {
        [
            String(refreshToken),
            selectedDateRange.id,
            selectedPlatformFilter.id,
            rows.map(\.track.identityKey).joined(separator: "|")
        ].joined(separator: "::")
    }

    private var insightsSummary: KeywordInsightsSummary {
        KeywordInsightsSummary(dataset: insightsDataset)
    }

    private var storefrontLookup: [String: StorefrontDefinition] {
        Dictionary(uniqueKeysWithValues: storefrontDefinitions.map { ($0.code, $0) })
    }

    private var storefrontDefinitions: [StorefrontDefinition] {
        ((try? services.storefrontCatalog.bundledStorefronts()) ?? []).map {
            StorefrontDefinition(
                code: $0.code.lowercased(),
                name: $0.name,
                flagEmoji: $0.flagEmoji,
                title: "\($0.flagEmoji) \($0.name)"
            )
        }
    }

    private struct SnapshotBuckets {
        let latestByTrackKey: [String: KeywordRankingCrawlSummary]
        let trendByTrackKey: [String: [KeywordRankingCrawlSummary]]
        let topResultsByCrawlKey: [String: [KeywordRankingAppSummary]]
    }

    private static let rankingFetchChunkSize = 500

    private func makeFilteredRows(
        from tracks: [TrackedAppKeyword],
        snapshotBuckets: SnapshotBuckets
    ) -> [KeywordWorkspaceRow] {
        let storefrontLookup = storefrontLookup
        var rows: [KeywordWorkspaceRow] = []
        rows.reserveCapacity(tracks.count)

        for track in tracks {
            guard let row = makeRow(
                for: track,
                snapshotBuckets: snapshotBuckets,
                storefrontLookup: storefrontLookup
            ) else {
                continue
            }

            rows.append(row)
        }

        return rows
            .filter(matchesPosition)
            .filter(matchesChange)
            .filter(matchesChangedOnly)
            .sorted(by: rowSort)
    }

    var body: some View {
        let rows = keywordRows
        VStack(alignment: .leading, spacing: 0) {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No Keywords Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Add one or more keywords and choose countries to start tracking this app.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                KeywordTableView(
                    rows: rows,
                    isLoadingRows: isLoadingKeywordRows,
                    trackedAppStoreID: trackedApp.appStoreID,
                    chartSelectionScope: selectedStorefrontFilter.id,
                    insightsSummary: insightsSummary,
                    storefronts: storefrontDefinitions,
                    modelContext: modelContext,
                    appCatalogService: services.appCatalogService,
                    appIconStore: services.appIconStore
                )
                    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: rowReloadSignature) {
            await updateKeywordRows()
        }
        .task(id: insightsSignature(for: rows)) {
            await reloadInsights(visibleTracks: rows.map(\.track))
        }
    }

    private func updateKeywordRows() async {
        let signature = rowReloadSignature
        do {
            let searchFilteredTracks = tracks
                .filter(matchesPlatform)
                .filter(matchesSearch)
            let loadedMetrics = try await loadMetricsSnapshots(for: searchFilteredTracks.map(\.queryKey))
            metricsByQueryKey = loadedMetrics
            let filteredTracks = searchFilteredTracks.filter(matchesMetrics)
            let snapshotBuckets = try fetchSnapshotBuckets(for: filteredTracks)
            keywordRows = makeFilteredRows(
                from: filteredTracks,
                snapshotBuckets: snapshotBuckets
            )
        } catch {
            metricsByQueryKey = [:]
            keywordRows = []
            reportError(OpenASOError.map(error).localizedDescription)
        }
        derivedRowsSignature = signature
    }

    private func loadMetricsSnapshots(for queryKeys: [String]) async throws -> [String: KeywordMetricsSnapshot] {
        guard !queryKeys.isEmpty else {
            return [:]
        }

        if let backgroundModelStore = services.backgroundModelStore {
            return try await backgroundModelStore.read { modelContext in
                try KeywordMetricsSnapshot.map(for: queryKeys, in: modelContext)
            }
        }

        return try KeywordMetricsSnapshot.map(for: queryKeys, in: modelContext)
    }

    private func matchesSearch(for track: TrackedAppKeyword) -> Bool {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return true
        }

        return track.term.localizedStandardContains(trimmedSearch)
    }

    private func matchesPlatform(for track: TrackedAppKeyword) -> Bool {
        selectedPlatformFilter.matches(track.platform)
    }

    private func reloadInsights(visibleTracks: [TrackedAppKeyword]) async {
        guard !visibleTracks.isEmpty else {
            insightsDataset = KeywordInsightsDataset(appStoreID: trackedApp.appStoreID, series: [], source: .local)
            return
        }

        insightsDataset = await services.keywordInsightsService.dataset(
            for: trackedApp,
            tracks: visibleTracks,
            dateRange: selectedDateRange,
            in: modelContext
        )
    }

    private func makeRow(
        for track: TrackedAppKeyword,
        snapshotBuckets: SnapshotBuckets,
        storefrontLookup: [String: StorefrontDefinition]
    ) -> KeywordWorkspaceRow? {
        let latestSnapshot = snapshotBuckets.latestByTrackKey[track.identityKey]
        let trendSnapshots = snapshotBuckets.trendByTrackKey[track.identityKey] ?? []
        let rankingApps = latestSnapshot.map { snapshotBuckets.topResultsByCrawlKey[$0.id] ?? [] } ?? []

        return KeywordWorkspaceRow(
            track: track,
            storefront: storefrontLookup[track.storefront],
            metrics: metricsByQueryKey[track.queryKey],
            latestSnapshot: latestSnapshot,
            trendSnapshots: trendSnapshots,
            rankingApps: rankingApps
        )
    }

    private func matchesMetrics(for track: TrackedAppKeyword) -> Bool {
        let metrics = metricsByQueryKey[track.queryKey]
        return matches(metrics?.popularityScore, in: popularityFilterRange, configuration: .popularity)
            && matches(metrics?.difficultyScore, in: difficultyFilterRange, configuration: .difficulty)
    }

    private func fetchSnapshotBuckets(for tracks: [TrackedAppKeyword]) throws -> SnapshotBuckets {
        guard !tracks.isEmpty else {
            return SnapshotBuckets(latestByTrackKey: [:], trendByTrackKey: [:], topResultsByCrawlKey: [:])
        }

        let queryKeys = Array(Set(tracks.map(\.queryKey)))
        let tracksByQueryKey = Dictionary(grouping: tracks, by: \.queryKey)
        let trendCrawls = try fetchTrendCrawls(queryKeys: queryKeys)
        let latestCrawlsByQueryKey = try fetchLatestCrawlsByQueryKey(queryKeys: queryKeys)
        let latestCrawlKeys = Set(latestCrawlsByQueryKey.values.map(\.observationKey))
        let trackedItemsByCrawlKey = try fetchTrackedRankingItemsByCrawlKey(
            queryKeys: queryKeys,
            cutoffDate: selectedDateRange.cutoffDate,
            latestCrawlKeys: latestCrawlKeys
        )
        let latestItemsByCrawlKey = try fetchRankingItemsByCrawlKey(
            crawlKeys: latestCrawlKeys
        )
        var latestByTrackKey: [String: KeywordRankingCrawlSummary] = [:]
        var trendByTrackKey: [String: [KeywordRankingCrawlSummary]] = [:]
        var topResultsByCrawlKey: [String: [KeywordRankingAppSummary]] = [:]

        for (crawlKey, items) in latestItemsByCrawlKey {
            topResultsByCrawlKey[crawlKey] = items
                .sorted { $0.position < $1.position }
                .map(KeywordRankingAppSummary.init)
        }

        for (queryKey, crawl) in latestCrawlsByQueryKey {
            guard let crawlTracks = tracksByQueryKey[queryKey] else {
                continue
            }

            let trackedItem = trackedItemsByCrawlKey[crawl.observationKey]
            let summary = KeywordRankingCrawlSummary(crawl: crawl, rank: trackedItem?.position)

            for track in crawlTracks {
                latestByTrackKey[track.identityKey] = summary
            }
        }

        for crawl in trendCrawls {
            guard let crawlTracks = tracksByQueryKey[crawl.queryKey] else {
                continue
            }

            let trackedItem = trackedItemsByCrawlKey[crawl.observationKey]
            let summary = KeywordRankingCrawlSummary(crawl: crawl, rank: trackedItem?.position)

            for track in crawlTracks {
                trendByTrackKey[track.identityKey, default: []].append(summary)
            }
        }

        return SnapshotBuckets(
            latestByTrackKey: latestByTrackKey,
            trendByTrackKey: trendByTrackKey,
            topResultsByCrawlKey: topResultsByCrawlKey
        )
    }

    private func fetchTrendCrawls(queryKeys: [String]) throws -> [KeywordRankingCrawl] {
        let sortBy = [SortDescriptor(\KeywordRankingCrawl.observedAt, order: .forward)]

        guard let cutoffDate = selectedDateRange.cutoffDate else {
            let descriptor = FetchDescriptor<KeywordRankingCrawl>(
                predicate: #Predicate { crawl in
                    queryKeys.contains(crawl.queryKey)
                },
                sortBy: sortBy
            )
            return try modelContext.fetch(descriptor)
        }

        let descriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { crawl in
                queryKeys.contains(crawl.queryKey) && crawl.observedAt >= cutoffDate
            },
            sortBy: sortBy
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchLatestCrawlsByQueryKey(queryKeys: [String]) throws -> [String: KeywordRankingCrawl] {
        let descriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { crawl in
                queryKeys.contains(crawl.queryKey)
            },
            sortBy: [
                SortDescriptor(\KeywordRankingCrawl.queryKey, order: .forward),
                SortDescriptor(\KeywordRankingCrawl.observedAt, order: .reverse)
            ]
        )
        let crawls = try modelContext.fetch(descriptor)
        var latestByQueryKey: [String: KeywordRankingCrawl] = [:]
        latestByQueryKey.reserveCapacity(queryKeys.count)

        for crawl in crawls where latestByQueryKey[crawl.queryKey] == nil {
            latestByQueryKey[crawl.queryKey] = crawl

            if latestByQueryKey.count == queryKeys.count {
                break
            }
        }

        return latestByQueryKey
    }

    private func fetchTrackedRankingItemsByCrawlKey(
        queryKeys: [String],
        cutoffDate: Date?,
        latestCrawlKeys: Set<String>
    ) throws -> [String: KeywordAppRanking] {
        guard !queryKeys.isEmpty else { return [:] }

        let appStoreID = trackedApp.appStoreID
        let items = try fetchTrackedRankingItems(
            queryKeys: queryKeys,
            appStoreID: appStoreID,
            cutoffDate: cutoffDate
        )
        var itemsByCrawlKey: [String: KeywordAppRanking] = [:]
        itemsByCrawlKey.reserveCapacity(items.count)

        for item in items {
            itemsByCrawlKey[item.crawlKey] = item
        }

        let missingLatestCrawlKeys = latestCrawlKeys.subtracting(itemsByCrawlKey.keys)
        guard !missingLatestCrawlKeys.isEmpty else {
            return itemsByCrawlKey
        }

        for item in try fetchTrackedRankingItemsByCrawlKeys(
            crawlKeys: missingLatestCrawlKeys,
            appStoreID: appStoreID
        ) {
            itemsByCrawlKey[item.crawlKey] = item
        }

        return itemsByCrawlKey
    }

    private func fetchTrackedRankingItems(
        queryKeys: [String],
        appStoreID: Int64,
        cutoffDate: Date?
    ) throws -> [KeywordAppRanking] {
        guard let cutoffDate else {
            let descriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { ranking in
                    queryKeys.contains(ranking.queryKey) && ranking.appStoreID == appStoreID
                },
                sortBy: [
                    SortDescriptor(\KeywordAppRanking.queryKey, order: .forward),
                    SortDescriptor(\KeywordAppRanking.observedAt, order: .forward)
                ]
            )
            return try modelContext.fetch(descriptor)
        }

        let descriptor = FetchDescriptor<KeywordAppRanking>(
            predicate: #Predicate { ranking in
                queryKeys.contains(ranking.queryKey)
                    && ranking.appStoreID == appStoreID
                    && ranking.observedAt >= cutoffDate
            },
            sortBy: [
                SortDescriptor(\KeywordAppRanking.queryKey, order: .forward),
                SortDescriptor(\KeywordAppRanking.observedAt, order: .forward)
            ]
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchTrackedRankingItemsByCrawlKeys(
        crawlKeys: Set<String>,
        appStoreID: Int64
    ) throws -> [KeywordAppRanking] {
        guard !crawlKeys.isEmpty else { return [] }

        let crawlKeyChunks = Array(crawlKeys).chunked(into: Self.rankingFetchChunkSize)
        var items: [KeywordAppRanking] = []

        for crawlKeyChunk in crawlKeyChunks {
            let descriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { ranking in
                    crawlKeyChunk.contains(ranking.crawlKey) && ranking.appStoreID == appStoreID
                }
            )
            items.append(contentsOf: try modelContext.fetch(descriptor))
        }

        return items
    }

    private func fetchRankingItemsByCrawlKey(
        crawlKeys: Set<String>
    ) throws -> [String: [KeywordAppRanking]] {
        guard !crawlKeys.isEmpty else { return [:] }

        let crawlKeyChunks = Array(crawlKeys).chunked(into: Self.rankingFetchChunkSize)
        var itemsByCrawlKey: [String: [KeywordAppRanking]] = [:]

        for crawlKeyChunk in crawlKeyChunks {
            let descriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { ranking in
                    crawlKeyChunk.contains(ranking.crawlKey) && ranking.position <= 5
                },
                sortBy: [
                    SortDescriptor(\KeywordAppRanking.observedAt, order: .forward),
                    SortDescriptor(\KeywordAppRanking.position, order: .forward)
                ]
            )

            for result in try modelContext.fetch(descriptor) {
                itemsByCrawlKey[result.crawlKey, default: []].append(result)
            }
        }

        return itemsByCrawlKey
    }

    private func matchesPosition(_ row: KeywordWorkspaceRow) -> Bool {
        matches(row.currentRank, in: positionFilterRange, configuration: .position)
    }

    private func matchesChange(_ row: KeywordWorkspaceRow) -> Bool {
        matches(row.trendDelta, in: changeFilterRange, configuration: .change)
    }

    private func matchesChangedOnly(_ row: KeywordWorkspaceRow) -> Bool {
        guard showsOnlyChangedKeywords else {
            return true
        }

        guard let trendDelta = row.trendDelta else {
            return false
        }

        return trendDelta != 0
    }

    private func matches(_ value: Int?, in range: ClosedRange<Double>, configuration: MetricFilterRange) -> Bool {
        if configuration.isDefault(range) {
            return true
        }

        guard let value else {
            return false
        }

        return range.contains(Double(value))
    }

    private func rowSort(_ lhs: KeywordWorkspaceRow, _ rhs: KeywordWorkspaceRow) -> Bool {
        switch (lhs.currentRank, rhs.currentRank) {
        case let (left?, right?):
            if left == right {
                return lhs.track.term.localizedCaseInsensitiveCompare(rhs.track.term) == .orderedAscending
            }
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.track.term.localizedCaseInsensitiveCompare(rhs.track.term) == .orderedAscending
        }
    }
}

#Preview("Keyword Workspace") {
    AppKeywordsPreviewHarness()
}

private struct AppKeywordsPreviewHarness: View {
    private let previewContainer: OpenASOPreviewContainer<TrackedApp>

    init() {
        self.previewContainer = OpenASOPreviewContainer(seed: Self.seed)
    }

    private var trackedApp: TrackedApp {
        previewContainer.seedData
    }

    var body: some View {
        AppKeywordsView(
            trackedApp: trackedApp,
            searchText: "",
            selectedStorefrontFilter: .all,
            selectedDateRange: .last30Days,
            selectedPlatformFilter: .all,
            popularityFilterRange: MetricFilterRange.popularity.defaultRange,
            difficultyFilterRange: MetricFilterRange.difficulty.defaultRange,
            positionFilterRange: MetricFilterRange.position.defaultRange,
            changeFilterRange: MetricFilterRange.change.defaultRange,
            showsOnlyChangedKeywords: false,
            refreshToken: 0,
            reportError: { _ in }
        )
        .openASOPreviewEnvironment(previewContainer)
        .frame(width: 1280, height: 760)
        .padding(24)
    }

    private static func seed(in modelContext: ModelContext) -> TrackedApp {
        let trackedApp = TrackedApp(
            appStoreID: 6448311069,
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            subtitle: "AI chatbot for writing and learning",
            sellerName: "OpenAI",
            defaultPlatform: .iphone
        )
        let storefronts = [
            Storefront(code: "us", name: "United States", flagEmoji: "US", languageCode: "en"),
            Storefront(code: "gb", name: "United Kingdom", flagEmoji: "GB", languageCode: "en"),
            Storefront(code: "ca", name: "Canada", flagEmoji: "CA", languageCode: "en")
        ]
        let competitors = [
            PreviewRankedApp(appStoreID: trackedApp.appStoreID, name: trackedApp.name, subtitle: trackedApp.subtitle, sellerName: trackedApp.sellerName ?? "OpenAI"),
            PreviewRankedApp(appStoreID: 310633997, name: "Google", subtitle: "Search, images and AI chatbot help", sellerName: "Google LLC"),
            PreviewRankedApp(appStoreID: 1444383602, name: "Perplexity", subtitle: "Ask anything with AI search", sellerName: "Perplexity AI, Inc."),
            PreviewRankedApp(appStoreID: 1668000334, name: "Microsoft Copilot", subtitle: "Your everyday AI companion", sellerName: "Microsoft Corporation"),
            PreviewRankedApp(appStoreID: 6479726147, name: "Claude", subtitle: "AI assistant for deep work", sellerName: "Anthropic PBC")
        ]
        let fixtures = [
            PreviewKeywordFixture(
                term: "ai chatbot",
                storefrontCode: "us",
                popularity: 92,
                difficulty: 64,
                ranks: [19, 12, 8, 5, 3, 2, 1],
                topApps: [0, 2, 3, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "essay writer",
                storefrontCode: "us",
                popularity: 88,
                difficulty: 83,
                ranks: [7, 7, 8, 8, 9, 11, 12],
                topApps: [2, 3, 0, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "homework help",
                storefrontCode: "gb",
                popularity: 76,
                difficulty: 71,
                ranks: [34, 31, 30, 28, 25, 21, 16],
                topApps: [3, 0, 2, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "ai image generator",
                storefrontCode: "ca",
                popularity: 84,
                difficulty: 91,
                ranks: [42, 39, 44, 36, 38, 29, 24],
                topApps: [1, 2, 4, 0, 3]
            ),
            PreviewKeywordFixture(
                term: "productivity ai",
                storefrontCode: "us",
                popularity: 58,
                difficulty: 46,
                ranks: [nil],
                errorMessage: "Lookup failed",
                topApps: []
            )
        ]

        modelContext.insert(trackedApp)
        storefronts.forEach(modelContext.insert)

        for fixture in fixtures {
            let query = try! KeywordQuery.fetchOrInsert(
                term: fixture.term,
                storefront: fixture.storefrontCode,
                platform: .iphone,
                in: modelContext
            )
            let track = TrackedAppKeyword(
                term: fixture.term,
                storefront: fixture.storefrontCode,
                platform: .iphone,
                trackedApp: trackedApp,
                query: query
            )
            track.statusMessage = fixture.errorMessage.map { "Ranking failed to refresh. \($0)" }

            let metrics = KeywordDailyMetric(
                queryKey: track.queryKey,
                keyword: track.term,
                storefront: track.storefront,
                platform: track.platform,
                popularityScore: fixture.popularity,
                difficultyScore: fixture.difficulty,
                source: .appleAdsPopularity
            )
            let snapshots = fixture.ranks.enumerated().map { offset, rank in
                TrackedKeywordDailyRanking(
                    rank: rank,
                    searchedAt: Calendar.current.date(
                        byAdding: .day,
                        value: offset - max(fixture.ranks.count - 1, 0),
                        to: .now
                    ) ?? .now,
                    source: .appStoreWeb,
                    resultCount: fixture.resultCount,
                    errorMessage: rank == nil ? fixture.errorMessage : nil,
                    keywordTrack: track
                )
            }

            trackedApp.keywordTracks.append(track)
            modelContext.insert(track)
            modelContext.insert(metrics)
            snapshots.forEach {
                track.snapshots.append($0)
                modelContext.insert($0)
            }

            if let latestSnapshot = snapshots.last {
                fixture.topApps.enumerated().forEach { position, competitorIndex in
                    let app = competitors[competitorIndex]
                    let result = TrackedKeywordRankedResult(
                        position: position + 1,
                        appStoreID: app.appStoreID,
                        bundleID: nil,
                        name: app.name,
                        subtitle: app.subtitle,
                        sellerName: app.sellerName,
                        snapshot: latestSnapshot
                    )
                    latestSnapshot.topResults.append(result)
                    modelContext.insert(result)
                }
            }
        }

        try? modelContext.save()
        return trackedApp
    }

    private struct PreviewKeywordFixture {
        let term: String
        let storefrontCode: String
        let popularity: Int?
        let difficulty: Int?
        let ranks: [Int?]
        let errorMessage: String?
        let resultCount: Int
        let topApps: [Int]

        init(
            term: String,
            storefrontCode: String,
            popularity: Int?,
            difficulty: Int?,
            ranks: [Int?],
            errorMessage: String? = nil,
            resultCount: Int = 50,
            topApps: [Int]
        ) {
            self.term = term
            self.storefrontCode = storefrontCode
            self.popularity = popularity
            self.difficulty = difficulty
            self.ranks = ranks
            self.errorMessage = errorMessage
            self.resultCount = resultCount
            self.topApps = topApps
        }
    }

    private struct PreviewRankedApp {
        let appStoreID: Int64
        let name: String
        let subtitle: String?
        let sellerName: String
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
