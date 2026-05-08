import Foundation
import SwiftData

struct RankingRefreshRequest: Sendable {
    let identityKey: String
    let queryKey: String
    let term: String
    let storefront: String
    let platform: AppPlatform

    init(
        identityKey: String,
        queryKey: String,
        term: String,
        storefront: String,
        platform: AppPlatform
    ) {
        self.identityKey = identityKey
        self.queryKey = queryKey
        self.term = term
        self.storefront = storefront
        self.platform = platform
    }

    init(track: TrackedAppKeyword) {
        self.identityKey = track.identityKey
        self.queryKey = track.queryKey
        self.term = track.term
        self.storefront = track.storefront
        self.platform = track.platform
    }
}

struct RankingRefreshPageResult: Sendable {
    let request: RankingRefreshRequest
    let page: SearchRankingPage
    let searchedAt: Date
    let observedHour: Int?
    let submissionCount: Int
    let winningCount: Int
    let confidence: String?
}

struct RankingMetadataEnrichmentRequest: Hashable, Sendable {
    let appStoreID: Int64
    let storefront: String
    let platform: AppPlatform
}

struct RankingStatsRebuildRequest: Hashable, Sendable {
    let queryKey: String
    let trackedAppID: Int64
    let storefront: String
    let platformRaw: String

    init(track: TrackedAppKeyword) {
        self.queryKey = track.queryKey
        self.trackedAppID = track.trackedApp.appStoreID
        self.storefront = track.storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.platformRaw = track.platform.rawValue
    }

    init?(pageRequest: RankingRefreshRequest) {
        let parts = pageRequest.identityKey.split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false)
        guard let appStoreIDValue = parts.first, let trackedAppID = Int64(appStoreIDValue) else {
            return nil
        }
        self.queryKey = pageRequest.queryKey
        self.trackedAppID = trackedAppID
        self.storefront = pageRequest.storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.platformRaw = pageRequest.platform.rawValue
    }

    var platform: AppPlatform {
        AppPlatform(rawValue: platformRaw) ?? .iphone
    }
}

final class RankingRefreshCoordinator: Sendable {
    private let rankingProvider: any SearchRankingProvider
    private let appCatalogService: AppCatalogService
    private let analyticsService: AnalyticsService
    private let refreshTriggerRecorder: (@Sendable (Date) async -> Void)?
    private let metadataEnrichmentHandler: (@Sendable ([RankingMetadataEnrichmentRequest]) async -> Void)?

    @MainActor
    init(
        rankingProvider: any SearchRankingProvider,
        appCatalogService: AppCatalogService,
        analyticsService: AnalyticsService? = nil,
        refreshTriggerRecorder: (@Sendable (Date) async -> Void)? = nil,
        metadataEnrichmentHandler: (@Sendable ([RankingMetadataEnrichmentRequest]) async -> Void)? = nil
    ) {
        self.rankingProvider = rankingProvider
        self.appCatalogService = appCatalogService
        self.analyticsService = analyticsService ?? AnalyticsService(
            settingsStore: AppSettingsStore(defaults: UserDefaults(suiteName: "com.openaso.analytics.noop") ?? .standard),
            client: NoOpAnalyticsClient()
        )
        self.refreshTriggerRecorder = refreshTriggerRecorder
        self.metadataEnrichmentHandler = metadataEnrichmentHandler
    }

    @MainActor
    func refresh(
        track: TrackedAppKeyword,
        in modelContext: ModelContext,
        limit: Int = SearchRankingCrawl.fullKeywordRankingLimit
    ) async -> Result<TrackedKeywordDailyRanking, OpenASOError> {
        await refresh(
            track: track,
            in: modelContext,
            limit: limit,
            recordsTrigger: true
        )
    }

    @MainActor
    private func refresh(
        track: TrackedAppKeyword,
        in modelContext: ModelContext,
        limit: Int,
        recordsTrigger: Bool,
        rebuildDerivedStats: Bool = true
    ) async -> Result<TrackedKeywordDailyRanking, OpenASOError> {
        let request = RankingRefreshRequest(track: track)

        let pageResult = await refreshPage(for: request, limit: limit, recordsTrigger: recordsTrigger)
        switch pageResult {
        case .success(let pageResult):
            do {
                return .success(try persistRankingPage(
                    pageResult,
                    in: modelContext,
                    rebuildDerivedStats: rebuildDerivedStats
                ))
            } catch {
                return .failure(OpenASOError.map(error))
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    @MainActor
    func refreshPage(
        for request: RankingRefreshRequest,
        limit: Int = SearchRankingCrawl.fullKeywordRankingLimit,
        recordsTrigger: Bool = true
    ) async -> Result<RankingRefreshPageResult, OpenASOError> {
        if recordsTrigger {
            await recordRefreshTriggered()
        }
        do {
            let page = try await rankingProvider.search(
                keyword: request.term,
                storefrontCode: request.storefront,
                platform: request.platform,
                limit: limit
            )
            return .success(RankingRefreshPageResult(
                request: request,
                page: page,
                searchedAt: .now,
                observedHour: nil,
                submissionCount: 1,
                winningCount: 1,
                confidence: "single_source"
            ))
        } catch {
            return .failure(OpenASOError.map(error))
        }
    }

    @MainActor
    func makeRankingPageFetcher(
        limit: Int = SearchRankingCrawl.fullKeywordRankingLimit
    ) -> @Sendable (RankingRefreshRequest) async -> Result<RankingRefreshPageResult, OpenASOError> {
        let rankingProvider = rankingProvider
        return { request in
            do {
                let page = try await rankingProvider.search(
                    keyword: request.term,
                    storefrontCode: request.storefront,
                    platform: request.platform,
                    limit: limit
                )
                return .success(RankingRefreshPageResult(
                    request: request,
                    page: page,
                    searchedAt: .now,
                    observedHour: nil,
                    submissionCount: 1,
                    winningCount: 1,
                    confidence: "single_source"
                ))
            } catch {
                return .failure(OpenASOError.map(error))
            }
        }
    }

    @discardableResult
    func persistRankingPage(
        _ pageResult: RankingRefreshPageResult,
        in modelContext: ModelContext,
        rebuildDerivedStats: Bool = true,
        saveChanges: Bool = true,
        scheduleMetadataEnrichment: Bool = true
    ) throws -> TrackedKeywordDailyRanking {
        guard let track = try fetchTrackedAppKeyword(identityKey: pageResult.request.identityKey, in: modelContext) else {
            throw OpenASOError.appNotFound
        }

        return try persistRankingPage(
            pageResult.page,
            searchedAt: pageResult.searchedAt,
            observedHour: pageResult.observedHour,
            submissionCount: pageResult.submissionCount,
            winningCount: pageResult.winningCount,
            confidence: pageResult.confidence,
            track: track,
            trackedApp: track.trackedApp,
            in: modelContext,
            rebuildDerivedStats: rebuildDerivedStats,
            saveChanges: saveChanges,
            scheduleMetadataEnrichment: scheduleMetadataEnrichment
        )
    }

    @discardableResult
    func recordRefreshFailure(
        identityKey: String,
        error: OpenASOError,
        in modelContext: ModelContext,
        saveChanges: Bool = true
    ) throws -> PersistentIdentifier? {
        guard let track = try fetchTrackedAppKeyword(identityKey: identityKey, in: modelContext) else {
            return nil
        }

        track.statusMessage = "Ranking failed to refresh. \(error.localizedDescription)"
        if saveChanges {
            try modelContext.save()
        }
        return track.persistentModelID
    }

    private func persistRankingPage(
        _ page: SearchRankingPage,
        searchedAt: Date,
        observedHour: Int?,
        submissionCount: Int,
        winningCount: Int,
        confidence: String?,
        track: TrackedAppKeyword,
        trackedApp: TrackedApp,
        in modelContext: ModelContext,
        rebuildDerivedStats: Bool,
        saveChanges: Bool,
        scheduleMetadataEnrichment: Bool
    ) throws -> TrackedKeywordDailyRanking {
            let snapshotKey = TrackedKeywordDailyRanking.makeSnapshotKey(
                trackIdentityKey: track.identityKey,
                searchedAt: searchedAt,
                source: page.source
            )
            let observationKey = KeywordRankingCrawl.makeObservationKey(
                queryKey: track.queryKey,
                observedAt: searchedAt,
                source: page.source
            )

            let snapshot = try fetchTrackedKeywordDailyRanking(
                snapshotKey: snapshotKey,
                track: track,
                searchedAt: searchedAt,
                source: page.source,
                in: modelContext
            ) ?? TrackedKeywordDailyRanking(
                rank: RankingMatcher.rank(for: trackedApp, in: page.items),
                searchedAt: searchedAt,
                source: page.source,
                resultCount: page.resultCount,
                keywordTrack: track
            )
            let observation = try fetchKeywordRankingCrawl(
                observationKey: observationKey,
                queryKey: track.queryKey,
                observedAt: searchedAt,
                source: page.source,
                in: modelContext
            ) ?? KeywordRankingCrawl(
                keyword: track.term,
                storefront: track.storefront,
                platform: track.platform,
                observedAt: searchedAt,
                source: page.source,
                resultCount: page.resultCount,
                query: track.query,
                observedHour: observedHour,
                submissionCount: submissionCount,
                winningCount: winningCount,
                confidence: confidence
            )

            let isNewSnapshot = snapshot.modelContext == nil
            let isNewObservation = observation.modelContext == nil

            if isNewSnapshot {
                modelContext.insert(snapshot)
            }
            if isNewObservation {
                modelContext.insert(observation)
            }

            snapshot.snapshotKey = snapshotKey
            snapshot.trackIdentityKey = track.identityKey
            snapshot.rank = RankingMatcher.rank(for: trackedApp, in: page.items)
            snapshot.searchedAt = searchedAt
            snapshot.source = page.source
            snapshot.resultCount = page.resultCount
            snapshot.errorMessage = nil
            snapshot.keywordTrack = track

            observation.observationKey = observationKey
            observation.queryKey = track.queryKey
            observation.query = track.query
            observation.keyword = track.term.trimmingCharacters(in: .whitespacesAndNewlines)
            observation.storefront = track.storefront.lowercased()
            observation.platform = track.platform
            observation.observedAt = searchedAt
            observation.observedHour = observedHour ?? KeywordRankingCrawl.utcHourBucket(for: searchedAt)
            observation.source = page.source
            observation.resultCount = page.resultCount
            observation.submissionCount = submissionCount
            observation.winningCount = winningCount
            observation.confidenceRaw = confidence

            var catalogCache = try appCatalogService.makeSearchRankingPageCache(
                items: page.items,
                storefrontCode: track.storefront,
                in: modelContext
            )
            var ratingCache = try makeRatingPageCache(
                items: page.items,
                storefront: track.storefront,
                observedAt: snapshot.searchedAt,
                in: modelContext
            )

            for item in page.items {
                _ = try appCatalogService.upsertStoreApp(
                    from: item,
                    storefrontCode: track.storefront,
                    in: modelContext,
                    cache: &catalogCache
                )
                upsertStorefrontRating(
                    from: item,
                    storefront: track.storefront,
                    observedAt: snapshot.searchedAt,
                    in: modelContext,
                    cache: &ratingCache
                )

                upsertRankedResult(
                    from: item,
                    snapshot: snapshot,
                    snapshotKey: snapshotKey,
                    in: modelContext
                )
                upsertObservationItem(
                    from: item,
                    observation: observation,
                    in: modelContext
                )
            }
            pruneRankedResults(for: snapshot, keeping: page.items.map(\.appStoreID), in: modelContext)
            pruneObservationItems(for: observation, keeping: page.items.map(\.appStoreID), in: modelContext)

            if rebuildDerivedStats {
                self.rebuildDerivedStats(for: [RankingStatsRebuildRequest(track: track)], in: modelContext)
            }

            track.statusMessage = nil
            track.lastRefreshAt = snapshot.searchedAt
            track.rankingAppCount = page.resultCount
            if isNewSnapshot {
                track.snapshots.append(snapshot)
            }

            if saveChanges {
                try modelContext.save()
            }
            if scheduleMetadataEnrichment {
                scheduleTopRankingMetadataEnrichment(
                    items: page.items,
                    storefront: track.storefront,
                    platform: track.platform
                )
            }
            return snapshot
    }

    func scheduleTopRankingMetadataEnrichment(for pageResult: RankingRefreshPageResult) {
        scheduleTopRankingMetadataEnrichment(
            items: pageResult.page.items,
            storefront: pageResult.request.storefront,
            platform: pageResult.request.platform
        )
    }

    private func scheduleTopRankingMetadataEnrichment(
        items: [SearchRankingItem],
        storefront: String,
        platform: AppPlatform
    ) {
        guard let metadataEnrichmentHandler else { return }
        let requests = Self.topRankingEnrichmentRequests(
            items: items,
            storefront: storefront,
            platform: platform
        )
        guard !requests.isEmpty else { return }

        Task {
            await metadataEnrichmentHandler(requests)
        }
    }

    static let metadataEnrichmentTopResultLimit = 20
    static let metadataEnrichmentFreshnessInterval: TimeInterval = 60 * 60 * 24 * 5

    static func topRankingEnrichmentRequests(
        items: [SearchRankingItem],
        storefront: String,
        platform: AppPlatform
    ) -> [RankingMetadataEnrichmentRequest] {
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seenAppStoreIDs = Set<Int64>()
        return items
            .sorted { $0.position < $1.position }
            .prefix(metadataEnrichmentTopResultLimit)
            .compactMap { item in
                guard seenAppStoreIDs.insert(item.appStoreID).inserted else {
                    return nil
                }
                return RankingMetadataEnrichmentRequest(
                    appStoreID: item.appStoreID,
                    storefront: normalizedStorefront,
                    platform: platform
                )
            }
    }

    private func upsertRankedResult(
        from item: SearchRankingItem,
        snapshot: TrackedKeywordDailyRanking,
        snapshotKey: String,
        in modelContext: ModelContext
    ) {
        let storedResult = snapshot.topResults.first { $0.appStoreID == item.appStoreID } ?? TrackedKeywordRankedResult(
            position: item.position,
            appStoreID: item.appStoreID,
            bundleID: item.bundleID,
            name: item.name,
            subtitle: item.subtitle,
            sellerName: item.sellerName,
            snapshot: snapshot
        )
        if storedResult.modelContext == nil {
            snapshot.topResults.append(storedResult)
            modelContext.insert(storedResult)
        }
        assignIfChanged(storedResult, \.snapshotKey, snapshotKey)
        assignIfChanged(storedResult, \.position, item.position)
        assignIfChanged(storedResult, \.appStoreID, item.appStoreID)
        assignIfChanged(storedResult, \.bundleID, item.bundleID)
        assignIfChanged(storedResult, \.name, item.name)
        assignIfChanged(storedResult, \.subtitle, item.subtitle)
        assignIfChanged(storedResult, \.sellerName, item.sellerName)
        if storedResult.snapshot !== snapshot {
            storedResult.snapshot = snapshot
        }
    }

    private func upsertObservationItem(
        from item: SearchRankingItem,
        observation: KeywordRankingCrawl,
        in modelContext: ModelContext
    ) {
        let observationItem = observation.items.first { $0.appStoreID == item.appStoreID } ?? KeywordAppRanking(
            position: item.position,
            appStoreID: item.appStoreID,
            bundleID: item.bundleID,
            name: item.name,
            subtitle: item.subtitle,
            sellerName: item.sellerName,
            observation: observation
        )
        if observationItem.modelContext == nil {
            observation.items.append(observationItem)
            modelContext.insert(observationItem)
        }
        assignIfChanged(observationItem, \.position, item.position)
        assignIfChanged(observationItem, \.appStoreID, item.appStoreID)
        assignIfChanged(observationItem, \.bundleID, item.bundleID)
        assignIfChanged(observationItem, \.name, item.name)
        assignIfChanged(observationItem, \.subtitle, item.subtitle)
        assignIfChanged(observationItem, \.sellerName, item.sellerName)
        assignIfChanged(observationItem, \.crawlKey, observation.observationKey)
        assignIfChanged(observationItem, \.queryKey, observation.queryKey)
        assignIfChanged(observationItem, \.storefront, observation.storefront)
        assignIfChanged(observationItem, \.platform, observation.platform)
        assignIfChanged(observationItem, \.observedAt, observation.observedAt)
        assignIfChanged(observationItem, \.itemKey, KeywordAppRanking.makeItemKey(
            observationKey: observation.observationKey,
            appStoreID: item.appStoreID
        ))
        if observationItem.observation !== observation {
            observationItem.observation = observation
        }
    }

    private func pruneRankedResults(
        for snapshot: TrackedKeywordDailyRanking,
        keeping appStoreIDs: [Int64],
        in modelContext: ModelContext
    ) {
        let retainedAppStoreIDs = Set(appStoreIDs)
        let staleResults = snapshot.topResults.filter { !retainedAppStoreIDs.contains($0.appStoreID) }
        for result in staleResults {
            modelContext.delete(result)
        }
        snapshot.topResults.removeAll { !retainedAppStoreIDs.contains($0.appStoreID) }
    }

    private func pruneObservationItems(
        for observation: KeywordRankingCrawl,
        keeping appStoreIDs: [Int64],
        in modelContext: ModelContext
    ) {
        let retainedAppStoreIDs = Set(appStoreIDs)
        let staleItems = observation.items.filter { !retainedAppStoreIDs.contains($0.appStoreID) }
        for item in staleItems {
            modelContext.delete(item)
        }
        observation.items.removeAll { !retainedAppStoreIDs.contains($0.appStoreID) }
    }

    private func fetchTrackedKeywordDailyRanking(
        snapshotKey: String,
        track: TrackedAppKeyword,
        searchedAt: Date,
        source: RankingSource,
        in modelContext: ModelContext
    ) throws -> TrackedKeywordDailyRanking? {
        let targetSnapshotKey = snapshotKey
        var descriptor = FetchDescriptor<TrackedKeywordDailyRanking>(
            predicate: #Predicate { snapshot in
                snapshot.snapshotKey == targetSnapshotKey
            }
        )
        descriptor.fetchLimit = 1
        if let snapshot = try modelContext.fetch(descriptor).first {
            return snapshot
        }

        let targetDayBucket = KeywordRankingCrawl.utcDayBucket(for: searchedAt)
        return track.snapshots
            .filter {
                $0.source == source
                    && KeywordRankingCrawl.utcDayBucket(for: $0.searchedAt) == targetDayBucket
            }
            .max { $0.searchedAt < $1.searchedAt }
    }

    private func fetchTrackedAppKeyword(
        identityKey: String,
        in modelContext: ModelContext
    ) throws -> TrackedAppKeyword? {
        let targetIdentityKey = identityKey
        var descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.identityKey == targetIdentityKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchKeywordRankingCrawl(
        observationKey: String,
        queryKey: String,
        observedAt: Date,
        source: RankingSource,
        in modelContext: ModelContext
    ) throws -> KeywordRankingCrawl? {
        let targetObservationKey = observationKey
        var descriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { observation in
                observation.observationKey == targetObservationKey
            }
        )
        descriptor.fetchLimit = 1
        if let observation = try modelContext.fetch(descriptor).first {
            return observation
        }

        let targetQueryKey = queryKey
        let fallbackDescriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { observation in
                observation.queryKey == targetQueryKey
            }
        )
        let targetDayBucket = KeywordRankingCrawl.utcDayBucket(for: observedAt)
        return try modelContext.fetch(fallbackDescriptor)
            .filter {
                $0.source == source
                    && KeywordRankingCrawl.utcDayBucket(for: $0.observedAt) == targetDayBucket
            }
            .max { $0.observedAt < $1.observedAt }
    }

    private struct RatingPageCache {
        var latestByIdentityKey: [String: LatestAppRating]
        var snapshotsByIdentityKey: [String: AppDailyRating]
    }

    private func makeRatingPageCache(
        items: [SearchRankingItem],
        storefront: String,
        observedAt: Date,
        in modelContext: ModelContext
    ) throws -> RatingPageCache {
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedStorefront.isEmpty else {
            return RatingPageCache(latestByIdentityKey: [:], snapshotsByIdentityKey: [:])
        }

        let ratingDate = LatestAppRating.ratingDateString(for: observedAt)
        let appStoreIDs = Set(items.lazy.filter {
            $0.ratingCount != nil || $0.averageRating != nil
        }.map(\.appStoreID))
        let latestKeys = appStoreIDs.map {
            LatestAppRating.makeIdentityKey(appStoreID: $0, storefront: normalizedStorefront)
        }
        let snapshotKeys = appStoreIDs.map {
            AppDailyRating.makeIdentityKey(appStoreID: $0, storefront: normalizedStorefront, ratingDate: ratingDate)
        }

        return RatingPageCache(
            latestByIdentityKey: try fetchLatestRatings(identityKeys: latestKeys, in: modelContext),
            snapshotsByIdentityKey: try fetchRatingSnapshots(identityKeys: snapshotKeys, in: modelContext)
        )
    }

    private func upsertStorefrontRating(
        from item: SearchRankingItem,
        storefront: String,
        observedAt: Date,
        in modelContext: ModelContext,
        cache: inout RatingPageCache
    ) {
        guard item.ratingCount != nil || item.averageRating != nil else { return }

        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedStorefront.isEmpty else { return }

        let ratingDate = LatestAppRating.ratingDateString(for: observedAt)
        let snapshotKey = AppDailyRating.makeIdentityKey(
            appStoreID: item.appStoreID,
            storefront: normalizedStorefront,
            ratingDate: ratingDate
        )
        let snapshot = cache.snapshotsByIdentityKey[snapshotKey] ?? AppDailyRating(
            appStoreID: item.appStoreID,
            storefront: normalizedStorefront,
            ratingCount: item.ratingCount,
            averageRating: item.averageRating,
            ratingDate: ratingDate,
            observedAt: observedAt,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source",
            source: .iTunesSearch
        )
        if snapshot.modelContext != nil, observedAt < snapshot.observedAt {
            return
        }
        if snapshot.modelContext == nil {
            modelContext.insert(snapshot)
            cache.snapshotsByIdentityKey[snapshotKey] = snapshot
        }
        let snapshotChanged = snapshot.modelContext == nil
            || snapshot.ratingCount != item.ratingCount
            || snapshot.averageRating != item.averageRating
            || snapshot.ratingDate != ratingDate
            || snapshot.submissionCount != 1
            || snapshot.winningCount != 1
            || snapshot.confidenceRaw != "single_source"
            || snapshot.source != .iTunesSearch
        if snapshotChanged {
            snapshot.ratingCount = item.ratingCount
            snapshot.averageRating = item.averageRating
            snapshot.ratingDate = ratingDate
            snapshot.observedAt = observedAt
            snapshot.submissionCount = 1
            snapshot.winningCount = 1
            snapshot.confidenceRaw = "single_source"
            snapshot.source = .iTunesSearch
        }

        let latestKey = LatestAppRating.makeIdentityKey(
            appStoreID: item.appStoreID,
            storefront: normalizedStorefront
        )
        let latest = cache.latestByIdentityKey[latestKey] ?? LatestAppRating(
            appStoreID: item.appStoreID,
            storefront: normalizedStorefront,
            ratingCount: item.ratingCount,
            averageRating: item.averageRating,
            ratingDate: ratingDate,
            observedAt: observedAt,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source",
            source: .iTunesSearch
        )
        if latest.modelContext != nil, observedAt < latest.observedAt {
            return
        }
        if latest.modelContext == nil {
            modelContext.insert(latest)
            cache.latestByIdentityKey[latestKey] = latest
        }
        let latestChanged = latest.modelContext == nil
            || latest.ratingCount != item.ratingCount
            || latest.averageRating != item.averageRating
            || latest.ratingDate != ratingDate
            || latest.submissionCount != 1
            || latest.winningCount != 1
            || latest.confidenceRaw != "single_source"
            || latest.source != .iTunesSearch
        if latestChanged {
            latest.ratingCount = item.ratingCount
            latest.averageRating = item.averageRating
            latest.ratingDate = ratingDate
            latest.observedAt = observedAt
            latest.submissionCount = 1
            latest.winningCount = 1
            latest.confidenceRaw = "single_source"
            latest.source = .iTunesSearch
        }
    }

    private func fetchLatestRating(identityKey: String, in modelContext: ModelContext) throws -> LatestAppRating? {
        let targetIdentityKey = identityKey
        var descriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                latest.identityKey == targetIdentityKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRatingSnapshot(identityKey: String, in modelContext: ModelContext) throws -> AppDailyRating? {
        let targetIdentityKey = identityKey
        var descriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { snapshot in
                snapshot.identityKey == targetIdentityKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchLatestRatings(identityKeys: [String], in modelContext: ModelContext) throws -> [String: LatestAppRating] {
        guard !identityKeys.isEmpty else { return [:] }

        let targetIdentityKeys = identityKeys
        let descriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                targetIdentityKeys.contains(latest.identityKey)
            }
        )

        return Dictionary(uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.identityKey, $0) })
    }

    private func fetchRatingSnapshots(identityKeys: [String], in modelContext: ModelContext) throws -> [String: AppDailyRating] {
        guard !identityKeys.isEmpty else { return [:] }

        let targetIdentityKeys = identityKeys
        let descriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { snapshot in
                targetIdentityKeys.contains(snapshot.identityKey)
            }
        )

        return Dictionary(uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.identityKey, $0) })
    }

    @MainActor
    func refresh(
        tracks: [TrackedAppKeyword],
        in modelContext: ModelContext,
        limit: Int = SearchRankingCrawl.fullKeywordRankingLimit,
        analyticsTrigger: String? = nil,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async -> [RefreshOutcome] {
        if !tracks.isEmpty, analyticsTrigger == "daily_refresh" {
            await recordRefreshTriggered()
        }
        if let analyticsTrigger {
            await captureKeywordRefreshStarted(trigger: analyticsTrigger, trackCount: tracks.count)
        }

        var outcomes: [RefreshOutcome] = []
        var statsRebuildRequests = Set<RankingStatsRebuildRequest>()
        var completedCount = 0
        var failureCount = 0
        if !tracks.isEmpty {
            await progress?(0, tracks.count, 0)
        }
        for track in tracks {
            let result = await refresh(
                track: track,
                in: modelContext,
                limit: limit,
                recordsTrigger: false,
                rebuildDerivedStats: false
            )
            switch result {
            case .success(let snapshot):
                statsRebuildRequests.insert(RankingStatsRebuildRequest(track: track))
                outcomes.append(RefreshOutcome(
                    trackID: track.persistentModelID,
                    snapshotID: snapshot.persistentModelID,
                    rank: snapshot.rank,
                    searchedAt: snapshot.searchedAt,
                    error: nil
                ))
            case .failure(let error):
                track.statusMessage = "Ranking failed to refresh. \(error.localizedDescription)"
                try? modelContext.save()
                outcomes.append(RefreshOutcome(
                    trackID: track.persistentModelID,
                    snapshotID: nil,
                    rank: nil,
                    searchedAt: nil,
                    error: error
                ))
                failureCount += 1
            }
            completedCount += 1
            await progress?(completedCount, tracks.count, failureCount)
        }
        if !statsRebuildRequests.isEmpty {
            rebuildDerivedStats(for: statsRebuildRequests, in: modelContext)
            try? modelContext.save()
        }
        if let analyticsTrigger {
            await captureKeywordRefreshCompleted(
                trigger: analyticsTrigger,
                trackCount: tracks.count,
                failureCount: outcomes.filter { $0.error != nil }.count
            )
        }
        return outcomes
    }

    @MainActor
    func refreshStaleTracks(
        in modelContext: ModelContext,
        limit: Int = SearchRankingCrawl.fullKeywordRankingLimit
    ) async -> [RefreshOutcome] {
        let descriptor = FetchDescriptor<TrackedAppKeyword>()
        let tracks = (try? modelContext.fetch(descriptor)) ?? []
        let staleTracks = tracks.filter { track in
            guard let lastRefreshAt = track.lastRefreshAt else { return true }
            return Date.now.timeIntervalSince(lastRefreshAt) >= 60 * 60 * 24
        }
        return await refresh(
            tracks: staleTracks,
            in: modelContext,
            limit: limit,
            analyticsTrigger: "daily_refresh",
            progress: nil
        )
    }

    @MainActor
    func recordRefreshTriggered() async {
        await refreshTriggerRecorder?(.now)
    }

    @MainActor
    func captureKeywordRefreshStarted(trigger: String, trackCount: Int) async {
        analyticsService.capture(.keywordRefreshStarted(trigger: trigger, trackCount: trackCount))
    }

    @MainActor
    func captureKeywordRefreshCompleted(trigger: String, trackCount: Int, failureCount: Int) async {
        analyticsService.capture(.keywordRefreshCompleted(
            trigger: trigger,
            trackCount: trackCount,
            failureCount: failureCount
        ))
    }

    func rebuildDerivedStats(
        for requests: some Sequence<RankingStatsRebuildRequest>,
        in modelContext: ModelContext
    ) {
        let requests = Set(requests)
        for request in requests {
            rebuildAppKeywordStats(queryKey: request.queryKey, in: modelContext)
        }
    }

    private func rebuildAppKeywordStats(queryKey: String, in modelContext: ModelContext) {
        let metrics = try? fetchKeywordMetrics(queryKey: queryKey, in: modelContext)
        let observations = (try? fetchKeywordRankingCrawls(queryKey: queryKey, in: modelContext)) ?? []
        let existingStats = (try? fetchAppKeywordStats(queryKey: queryKey, in: modelContext)) ?? []

        struct KeywordAggregate {
            var appStoreID: Int64
            var keyword: String
            var storefront: String
            var platform: AppPlatform
            var bestRank: Int
            var latestRank: Int
            var averageRank: Double
            var observationCount: Int
            var firstSeenAt: Date
            var lastSeenAt: Date
        }

        var aggregates: [Int64: KeywordAggregate] = [:]
        for observation in observations.sorted(by: { $0.observedAt < $1.observedAt }) {
            for item in observation.items {
                if var aggregate = aggregates[item.appStoreID] {
                    aggregate.bestRank = min(aggregate.bestRank, item.position)
                    aggregate.latestRank = item.position
                    aggregate.averageRank = (
                        aggregate.averageRank * Double(aggregate.observationCount)
                        + Double(item.position)
                    ) / Double(aggregate.observationCount + 1)
                    aggregate.observationCount += 1
                    aggregate.firstSeenAt = min(aggregate.firstSeenAt, observation.observedAt)
                    aggregate.lastSeenAt = max(aggregate.lastSeenAt, observation.observedAt)
                    aggregates[item.appStoreID] = aggregate
                } else {
                    aggregates[item.appStoreID] = KeywordAggregate(
                        appStoreID: item.appStoreID,
                        keyword: observation.keyword,
                        storefront: observation.storefront,
                        platform: observation.platform,
                        bestRank: item.position,
                        latestRank: item.position,
                        averageRank: Double(item.position),
                        observationCount: 1,
                        firstSeenAt: observation.observedAt,
                        lastSeenAt: observation.observedAt
                    )
                }
            }
        }

        let existingStatsByAppStoreID = Dictionary(uniqueKeysWithValues: existingStats.map { ($0.appStoreID, $0) })
        for staleStats in existingStats where aggregates[staleStats.appStoreID] == nil {
            modelContext.delete(staleStats)
        }

        for aggregate in aggregates.values {
            let stats = existingStatsByAppStoreID[aggregate.appStoreID] ?? AppKeywordStats(
                appStoreID: aggregate.appStoreID,
                queryKey: queryKey,
                keyword: aggregate.keyword,
                storefront: aggregate.storefront,
                platform: aggregate.platform,
                rank: aggregate.latestRank,
                observedAt: aggregate.lastSeenAt,
                popularityScore: metrics?.popularityScore,
                difficultyScore: metrics?.difficultyScore
            )
            if stats.modelContext == nil {
                modelContext.insert(stats)
            }
            stats.keyword = aggregate.keyword
            stats.storefront = aggregate.storefront
            stats.platform = aggregate.platform
            stats.bestRank = aggregate.bestRank
            stats.latestRank = aggregate.latestRank
            stats.averageRank = aggregate.averageRank
            stats.observationCount = aggregate.observationCount
            stats.firstSeenAt = aggregate.firstSeenAt
            stats.lastSeenAt = aggregate.lastSeenAt
            stats.popularityScore = metrics?.popularityScore
            stats.difficultyScore = metrics?.difficultyScore
        }
    }

    private func upsertAppKeywordStats(
        item: KeywordAppRanking,
        observation: KeywordRankingCrawl,
        metrics: KeywordDailyMetric?,
        in modelContext: ModelContext
    ) {
        let identityKey = AppKeywordStats.makeIdentityKey(
            appStoreID: item.appStoreID,
            queryKey: observation.queryKey
        )

        let stats: AppKeywordStats
        if let existing = try? fetchAppKeywordStats(identityKey: identityKey, in: modelContext) {
            stats = existing
            let previousObservationCount = max(1, stats.observationCount)
            let previousAverage = stats.averageRank ?? Double(item.position)
            stats.averageRank = (
                previousAverage * Double(previousObservationCount)
                + Double(item.position)
            ) / Double(previousObservationCount + 1)
            stats.observationCount = previousObservationCount + 1
            stats.bestRank = min(stats.bestRank ?? item.position, item.position)
            stats.latestRank = item.position
            stats.firstSeenAt = min(stats.firstSeenAt, observation.observedAt)
            stats.lastSeenAt = max(stats.lastSeenAt, observation.observedAt)
        } else {
            stats = AppKeywordStats(
                appStoreID: item.appStoreID,
                queryKey: observation.queryKey,
                keyword: observation.keyword,
                storefront: observation.storefront,
                platform: observation.platform,
                rank: item.position,
                observedAt: observation.observedAt,
                popularityScore: metrics?.popularityScore,
                difficultyScore: metrics?.difficultyScore
            )
            modelContext.insert(stats)
        }

        stats.keyword = observation.keyword
        stats.storefront = observation.storefront
        stats.platform = observation.platform
        stats.popularityScore = metrics?.popularityScore
        stats.difficultyScore = metrics?.difficultyScore
    }

    private func fetchKeywordMetrics(queryKey: String, in modelContext: ModelContext) throws -> KeywordDailyMetric? {
        let targetQueryKey = queryKey
        var descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metrics in
                metrics.queryKey == targetQueryKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchAppKeywordStats(identityKey: String, in modelContext: ModelContext) throws -> AppKeywordStats? {
        let targetIdentityKey = identityKey
        var descriptor = FetchDescriptor<AppKeywordStats>(
            predicate: #Predicate { stats in
                stats.identityKey == targetIdentityKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchAppKeywordStats(queryKey: String, in modelContext: ModelContext) throws -> [AppKeywordStats] {
        let targetQueryKey = queryKey
        let descriptor = FetchDescriptor<AppKeywordStats>(
            predicate: #Predicate { stats in
                stats.queryKey == targetQueryKey
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchKeywordRankingCrawls(queryKey: String, in modelContext: ModelContext) throws -> [KeywordRankingCrawl] {
        let targetQueryKey = queryKey
        let descriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { observation in
                observation.queryKey == targetQueryKey
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchKeywordRankingCrawls(
        storefront: String,
        platform: AppPlatform,
        in modelContext: ModelContext
    ) throws -> [KeywordRankingCrawl] {
        let targetStorefront = storefront.lowercased()
        let targetPlatformRaw = platform.rawValue
        let descriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { observation in
                observation.storefront == targetStorefront
                    && observation.platformRaw == targetPlatformRaw
            }
        )
        return try modelContext.fetch(descriptor)
    }

    @discardableResult
    private func assignIfChanged<Root: AnyObject, Value: Equatable>(
        _ object: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) -> Bool {
        guard object[keyPath: keyPath] != value else { return false }
        object[keyPath: keyPath] = value
        return true
    }
}

struct RefreshOutcome {
    let trackID: PersistentIdentifier
    let snapshotID: PersistentIdentifier?
    let rank: Int?
    let searchedAt: Date?
    let error: OpenASOError?
}
