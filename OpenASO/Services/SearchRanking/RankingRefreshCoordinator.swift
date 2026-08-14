import Foundation
import OSLog
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

private struct NormalizedRankingQueryKey: Hashable, Sendable {
    let term: String
    let storefront: String
    let platform: AppPlatform

    init(request: RankingRefreshRequest) {
        self.term = request.term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.storefront = request.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.platform = request.platform
    }
}

struct RankingRequestGroup: Sendable {
    let providerRequest: RankingRefreshRequest
    private(set) var targetRequests: [RankingRefreshRequest]

    static func normalizedGroups(for requests: [RankingRefreshRequest]) -> [Self] {
        var groups: [Self] = []
        var groupIndexByKey: [NormalizedRankingQueryKey: Int] = [:]
        groups.reserveCapacity(requests.count)
        groupIndexByKey.reserveCapacity(requests.count)

        for request in requests {
            let key = NormalizedRankingQueryKey(request: request)
            if let groupIndex = groupIndexByKey[key] {
                groups[groupIndex].targetRequests.append(request)
                continue
            }

            let normalizedTerm = request.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedStorefront = request.storefront
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let providerRequest = RankingRefreshRequest(
                identityKey: request.identityKey,
                queryKey: KeywordQuery.makeQueryKey(
                    term: normalizedTerm,
                    storefront: normalizedStorefront,
                    platform: request.platform
                ),
                term: normalizedTerm,
                storefront: normalizedStorefront,
                platform: request.platform
            )
            groupIndexByKey[key] = groups.count
            groups.append(Self(
                providerRequest: providerRequest,
                targetRequests: [request]
            ))
        }

        return groups
    }

    func pageResults(fanningOut pageResult: RankingRefreshPageResult) -> [RankingRefreshPageResult] {
        targetRequests.map { targetRequest in
            RankingRefreshPageResult(
                request: targetRequest,
                page: pageResult.page,
                searchedAt: pageResult.searchedAt,
                observedHour: pageResult.observedHour,
                submissionCount: pageResult.submissionCount,
                winningCount: pageResult.winningCount,
                confidence: pageResult.confidence
            )
        }
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

/// Context-bound result from the synchronous shared-observation transaction.
/// It must never cross an actor or `ModelContext` boundary.
struct RankingObservationPersistenceResult {
    let observation: RankingCrawlRecord
    let appliedIncomingPage: Bool
}

/// Context-bound result from a tracked ranking persistence transaction.
/// The SwiftData snapshot must remain on the owning model executor; the
/// canonical page result is Sendable and may be scheduled after commit.
struct RankingPagePersistenceResult {
    let snapshot: TrackedKeywordDailyRanking
    let canonicalPageResult: RankingRefreshPageResult
    let appliedSharedObservation: Bool
}

struct RankingMetadataEnrichmentRequest: Hashable, Sendable {
    let appStoreID: Int64
    let storefront: String
    let platform: AppPlatform
}

struct RankingCatalogEvidenceFingerprint: Hashable, Sendable {
    // Retain a compact, process-local digest rather than the full metadata and
    // screenshot arrays for every result seen during a long multi-keyword run.
    let storefront: String
    let sourceRaw: String
    let requestedPlatformRaw: String
    let appStoreID: Int64
    let metadataDigest: Int

    init(item: SearchRankingItem, pageResult: RankingRefreshPageResult) {
        self.storefront = pageResult.request.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.sourceRaw = pageResult.page.source.rawValue
        self.requestedPlatformRaw = pageResult.request.platform.rawValue
        self.appStoreID = item.appStoreID
        var hasher = Hasher()
        hasher.combine(item.bundleID)
        hasher.combine(item.name)
        hasher.combine(item.subtitle)
        hasher.combine(item.sellerName)
        hasher.combine(item.iconURLString)
        hasher.combine(item.releaseDate)
        hasher.combine(item.currentVersionReleaseDate)
        hasher.combine(item.version)
        hasher.combine(item.primaryGenreID)
        hasher.combine(item.primaryGenreName)
        hasher.combine(item.descriptionText)
        hasher.combine(item.releaseNotes)
        hasher.combine(item.supportedLanguageCodes)
        hasher.combine(item.screenshotURLs)
        hasher.combine(item.ipadScreenshotURLs)
        hasher.combine(item.appletvScreenshotURLs)
        hasher.combine(item.ratingCount)
        hasher.combine(item.averageRating)
        hasher.combine(item.platform)
        self.metadataDigest = hasher.finalize()
    }
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

private struct RankingModelContextHasPendingChangesError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Save or discard pending edits before refreshing keyword rankings."
    }
}

final class RankingRefreshCoordinator: Sendable {
    // RankingCrawlRecord is the canonical full-page history. Retain only the
    // useful legacy preview rows on TrackedKeywordDailyRanking so each refresh
    // does not write the same 200-result page twice.

    private let rankingProvider: any SearchRankingProvider
    private let appCatalogService: AppCatalogService
    private let analyticsService: AnalyticsService
    private let now: @Sendable () -> Date
    private let refreshTriggerRecorder: (@Sendable (Date) async -> Void)?
    private let metadataEnrichmentScheduler: (@Sendable ([RankingMetadataEnrichmentRequest]) -> Void)?
    private let persistenceMutationCheckpoint: (@Sendable () throws -> Void)?

    @MainActor
    init(
        rankingProvider: any SearchRankingProvider,
        appCatalogService: AppCatalogService,
        analyticsService: AnalyticsService? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        refreshTriggerRecorder: (@Sendable (Date) async -> Void)? = nil,
        metadataEnrichmentHandler: (@Sendable ([RankingMetadataEnrichmentRequest]) async -> Void)? = nil,
        metadataEnrichmentScheduler: (@Sendable ([RankingMetadataEnrichmentRequest]) -> Void)? = nil,
        persistenceMutationCheckpoint: (@Sendable () throws -> Void)? = nil
    ) {
        self.rankingProvider = rankingProvider
        self.appCatalogService = appCatalogService
        self.analyticsService = analyticsService ?? AnalyticsService(
            settingsStore: AppSettingsStore(defaults: UserDefaults(suiteName: "com.openaso.analytics.noop") ?? .standard),
            client: NoOpAnalyticsClient()
        )
        self.now = now
        self.refreshTriggerRecorder = refreshTriggerRecorder
        self.persistenceMutationCheckpoint = persistenceMutationCheckpoint
        if let metadataEnrichmentScheduler {
            self.metadataEnrichmentScheduler = metadataEnrichmentScheduler
        } else if let metadataEnrichmentHandler {
            self.metadataEnrichmentScheduler = { requests in
                Task {
                    await RefreshObservationScope.$runID.withValue(nil) {
                        await metadataEnrichmentHandler(requests)
                    }
                }
            }
        } else {
            self.metadataEnrichmentScheduler = nil
        }
    }

    @MainActor
    func refresh(
        track: TrackedAppKeyword,
        in modelContext: ModelContext
    ) async -> Result<TrackedKeywordDailyRanking, OpenASOError> {
        await refresh(
            track: track,
            in: modelContext,
            recordsTrigger: true
        )
    }

    @MainActor
    private func refresh(
        track: TrackedAppKeyword,
        in modelContext: ModelContext,
        recordsTrigger: Bool,
        rebuildDerivedStats: Bool = true
    ) async -> Result<TrackedKeywordDailyRanking, OpenASOError> {
        let request = RankingRefreshRequest(track: track)

        let pageResult = await refreshPage(
            for: request,
            limit: SearchRankingCrawl.fullKeywordRankingLimit,
            recordsTrigger: recordsTrigger
        )
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
            return .success(try await fetchRankingPage(for: request, limit: limit))
        } catch {
            return .failure(OpenASOError.map(error))
        }
    }

    /// Performs only the provider await and produces an immutable page result.
    /// Callers that need cancellation semantics should use this throwing API
    /// rather than the legacy `Result` wrapper above.
    func fetchRankingPage(
        for request: RankingRefreshRequest,
        limit: Int = SearchRankingCrawl.fullKeywordRankingLimit
    ) async throws -> RankingRefreshPageResult {
        try Task.checkCancellation()
        let providerPage = try await rankingProvider.search(
            keyword: request.term,
            storefrontCode: request.storefront,
            platform: request.platform,
            limit: limit
        )
        try Task.checkCancellation()
        return RankingRefreshPageResult(
            request: request,
            page: providerPage.canonicalized(limit: limit),
            searchedAt: now(),
            observedHour: nil,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source"
        )
    }

    @MainActor
    func makeRankingPageFetcher() -> @Sendable (RankingRefreshRequest) async -> Result<RankingRefreshPageResult, OpenASOError> {
        let coordinator = self
        return { request in
            do {
                return .success(try await coordinator.fetchRankingPage(
                    for: request,
                    limit: SearchRankingCrawl.fullKeywordRankingLimit
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
        if saveChanges {
            guard !modelContext.hasChanges else {
                throw RankingModelContextHasPendingChangesError()
            }
            let committedResult: RankingPagePersistenceResult
            do {
                committedResult = try persistRankingPageTransaction(
                    pageResult,
                    in: modelContext,
                    rebuildDerivedStats: rebuildDerivedStats
                )
                try modelContext.save()
            } catch {
                // SwiftData's transaction block does not restore a context's
                // in-memory graph when its closure throws. Explicit rollback
                // prevents a later save from committing a partial crawl.
                modelContext.rollback()
                throw error
            }
            if scheduleMetadataEnrichment, committedResult.appliedSharedObservation {
                scheduleTopRankingMetadataEnrichment(for: committedResult.canonicalPageResult)
            }
            return committedResult.snapshot
        }
        return try persistRankingPageTransaction(
            pageResult,
            in: modelContext,
            rebuildDerivedStats: rebuildDerivedStats
        ).snapshot
    }

    /// Mutates only the supplied model context. It never saves or starts
    /// metadata work, allowing an outer actor-owned transaction to commit
    /// before any enrichment side effect is scheduled.
    func persistRankingPageTransaction(
        _ pageResult: RankingRefreshPageResult,
        in modelContext: ModelContext,
        rebuildDerivedStats: Bool = true,
        catalogEvidenceAppStoreIDs: Set<Int64>? = nil
    ) throws -> RankingPagePersistenceResult {
        guard let track = try fetchTrackedAppKeyword(identityKey: pageResult.request.identityKey, in: modelContext) else {
            throw OpenASOError.appNotFound
        }
        let requestTerm = pageResult.request.term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trackTerm = track.term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let requestStorefront = pageResult.request.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trackStorefront = track.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard pageResult.request.queryKey == track.queryKey,
              requestTerm == trackTerm,
              requestStorefront == trackStorefront,
              pageResult.request.platform == track.platform
        else {
            throw OpenASOError.unexpectedResponse
        }

        let canonicalPageResult = pageResult.canonicalized(
            limit: SearchRankingCrawl.fullKeywordRankingLimit
        )
        return try persistRankingPage(
            canonicalPageResult,
            track: track,
            trackedApp: track.trackedApp,
            in: modelContext,
            rebuildDerivedStats: rebuildDerivedStats,
            catalogEvidenceAppStoreIDs: catalogEvidenceAppStoreIDs
        )
    }

    @discardableResult
    func recordRefreshFailure(
        identityKey: String,
        error: OpenASOError,
        in modelContext: ModelContext,
        saveChanges: Bool = true
    ) throws -> PersistentIdentifier? {
        if saveChanges, modelContext.hasChanges {
            throw RankingModelContextHasPendingChangesError()
        }
        do {
            guard let track = try fetchTrackedAppKeyword(identityKey: identityKey, in: modelContext) else {
                return nil
            }

            try TrackedKeywordRefreshStatusStore.set(
                "Ranking failed to refresh. \(error.localizedDescription)",
                domain: .ranking,
                for: track,
                in: modelContext
            )
            if saveChanges {
                try modelContext.save()
            }
            return track.persistentModelID
        } catch {
            if saveChanges {
                modelContext.rollback()
            }
            throw error
        }
    }

    private func persistRankingPage(
        _ pageResult: RankingRefreshPageResult,
        track: TrackedAppKeyword,
        trackedApp: TrackedApp,
        in modelContext: ModelContext,
        rebuildDerivedStats: Bool,
        catalogEvidenceAppStoreIDs: Set<Int64>?
    ) throws -> RankingPagePersistenceResult {
        let page = pageResult.page
        let searchedAt = pageResult.searchedAt
        let incomingSnapshotKey = TrackedKeywordDailyRanking.makeSnapshotKey(
            trackIdentityKey: track.identityKey,
            searchedAt: searchedAt,
            source: page.source
        )
        let existingSnapshot = try fetchTrackedKeywordDailyRanking(
            snapshotKey: incomingSnapshotKey,
            track: track,
            searchedAt: searchedAt,
            source: page.source,
            in: modelContext
        )
        let sharedResult = try persistSharedRankingObservation(
            pageResult,
            query: track.query,
            in: modelContext,
            catalogEvidenceAppStoreIDs: catalogEvidenceAppStoreIDs
        )
        let incomingWinsTrackedSnapshot = existingSnapshot.map { $0.searchedAt < searchedAt } ?? true
        let snapshot: TrackedKeywordDailyRanking
        if incomingWinsTrackedSnapshot {
            snapshot = existingSnapshot ?? TrackedKeywordDailyRanking(
                rank: RankingMatcher.rank(for: trackedApp, in: page.items),
                searchedAt: searchedAt,
                source: page.source,
                resultCount: page.resultCount,
                keywordTrack: track
            )
            let isNewSnapshot = snapshot.modelContext == nil
            if isNewSnapshot {
                modelContext.insert(snapshot)
            }

            snapshot.snapshotKey = incomingSnapshotKey
            snapshot.trackIdentityKey = track.identityKey
            snapshot.rank = RankingMatcher.rank(for: trackedApp, in: page.items)
            snapshot.searchedAt = searchedAt
            snapshot.source = page.source
            snapshot.resultCount = page.resultCount
            snapshot.errorMessage = nil
            snapshot.keywordTrack = track

            track.rankingAppCount = page.resultCount
            if isNewSnapshot {
                track.snapshots.append(snapshot)
            }
        } else {
            snapshot = existingSnapshot!
        }

        if incomingWinsTrackedSnapshot {
            let linkedCrawl: RankingCrawlRecord
            if sharedResult.appliedIncomingPage {
                linkedCrawl = sharedResult.observation
            } else if try observation(
                sharedResult.observation,
                exactlyMatches: pageResult.page,
                in: modelContext
            ) {
                linkedCrawl = sharedResult.observation
            } else {
                linkedCrawl = try persistTrackedRecoveryObservation(
                    pageResult,
                    snapshotKey: snapshot.snapshotKey,
                    in: modelContext
                )
            }
            try upsertTrackedRankingLink(
                snapshotKey: snapshot.snapshotKey,
                crawl: linkedCrawl,
                in: modelContext
            )
        }

        try persistenceMutationCheckpoint?()

        if rebuildDerivedStats {
            try self.rebuildDerivedStats(
                for: [RankingStatsRebuildRequest(track: track)],
                in: modelContext
            )
        }

        try TrackedKeywordRefreshStatusStore.set(
            nil,
            domain: .ranking,
            for: track,
            updatedAt: searchedAt,
            in: modelContext
        )
        track.lastRefreshAt = max(track.lastRefreshAt ?? .distantPast, searchedAt)

        return RankingPagePersistenceResult(
            snapshot: snapshot,
            canonicalPageResult: pageResult,
            appliedSharedObservation: sharedResult.appliedIncomingPage
        )
    }

    /// Upserts the app-independent ranking observation and its shared catalog
    /// and rating data. The caller owns the surrounding transaction and save.
    /// No tracked-app model is read or written by this primitive.
    @discardableResult
    func persistSharedRankingObservation(
        _ pageResult: RankingRefreshPageResult,
        query: KeywordQuery,
        in modelContext: ModelContext,
        catalogEvidenceAppStoreIDs: Set<Int64>? = nil
    ) throws -> RankingObservationPersistenceResult {
        let pageResult = pageResult.canonicalized(
            limit: SearchRankingCrawl.fullKeywordRankingLimit
        )
        let requestTerm = pageResult.request.term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let queryTerm = query.term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let requestStorefront = pageResult.request.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let queryStorefront = query.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard query.queryKey == pageResult.request.queryKey,
              requestTerm == queryTerm,
              requestStorefront == queryStorefront,
              pageResult.request.platform == query.platform
        else {
            throw OpenASOError.unexpectedResponse
        }

        let observationKey = RankingCrawlRecord.makeObservationKey(
            queryKey: pageResult.request.queryKey,
            observedAt: pageResult.searchedAt,
            source: pageResult.page.source
        )
        let existingObservation = try fetchKeywordRankingCrawl(
            observationKey: observationKey,
            queryKey: pageResult.request.queryKey,
            observedAt: pageResult.searchedAt,
            source: pageResult.page.source,
            in: modelContext
        )
        if let existingObservation,
           existingObservation.observedAt >= pageResult.searchedAt {
            return RankingObservationPersistenceResult(
                observation: existingObservation,
                appliedIncomingPage: false
            )
        }

        let observation = existingObservation ?? RankingCrawlRecord(
            keyword: pageResult.request.term,
            storefront: pageResult.request.storefront,
            platform: pageResult.request.platform,
            observedAt: pageResult.searchedAt,
            source: pageResult.page.source,
            resultCount: pageResult.page.resultCount,
            query: query,
            observedHour: pageResult.observedHour,
            submissionCount: pageResult.submissionCount,
            winningCount: pageResult.winningCount,
            confidence: pageResult.confidence
        )
        if observation.modelContext == nil {
            modelContext.insert(observation)
        }

        observation.observationKey = observationKey
        observation.queryKey = pageResult.request.queryKey
        observation.keyword = pageResult.request.term
            .trimmingCharacters(in: .whitespacesAndNewlines)
        observation.storefront = pageResult.request.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        observation.platform = pageResult.request.platform
        observation.observedAt = pageResult.searchedAt
        observation.observedHour = pageResult.observedHour
            ?? RankingCrawlRecord.utcHourBucket(for: pageResult.searchedAt)
        observation.source = pageResult.page.source
        observation.resultCount = pageResult.page.resultCount
        observation.submissionCount = pageResult.submissionCount
        observation.winningCount = pageResult.winningCount
        observation.confidenceRaw = pageResult.confidence

        let catalogItems = catalogEvidenceAppStoreIDs.map { includedAppStoreIDs in
            pageResult.page.items.filter { includedAppStoreIDs.contains($0.appStoreID) }
        } ?? pageResult.page.items
        var catalogCache = try appCatalogService.makeSearchRankingPageCache(
            items: catalogItems,
            storefrontCode: pageResult.request.storefront,
            in: modelContext
        )
        var ratingCache = try makeRatingPageCache(
            items: catalogItems,
            storefront: pageResult.request.storefront,
            observedAt: pageResult.searchedAt,
            in: modelContext
        )
        let currentObservationKey = observation.observationKey
        let existingObservationItems = try modelContext.fetch(
            FetchDescriptor<RankingFact>(
                predicate: #Predicate { fact in
                    fact.observation.observationKey == currentObservationKey
                }
            )
        )
        var observationItemsByAppStoreID = existingObservationItems.reduce(
            into: [Int64: RankingFact]()
        ) { result, observationItem in
            result[observationItem.appStoreID] = observationItem
        }
        let revisionsByKey = try RankingAppRevisionStore.revisions(
            for: pageResult.page.items.map(RankingAppRevisionPayload.init),
            in: modelContext
        )
        for item in pageResult.page.items {
            if catalogEvidenceAppStoreIDs?.contains(item.appStoreID) != false {
                let storeApp = try appCatalogService.upsertStoreApp(
                    from: item,
                    storefrontCode: pageResult.request.storefront,
                    rankingSource: pageResult.page.source,
                    fetchedAt: pageResult.searchedAt,
                    requestedPlatform: pageResult.request.platform,
                    in: modelContext,
                    cache: &catalogCache
                )
                upsertStorefrontRating(
                    from: item,
                    storefront: pageResult.request.storefront,
                    observedAt: pageResult.searchedAt,
                    source: storefrontRatingSource(for: pageResult.page.source),
                    storeApp: storeApp,
                    in: modelContext,
                    cache: &ratingCache
                )
            }
            let revisionKey = RankingAppRevisionPayload(item).revisionKey
            guard let revision = revisionsByKey[revisionKey] else {
                throw OpenASOError.unexpectedResponse
            }
            upsertObservationItem(
                from: item,
                revision: revision,
                observation: observation,
                in: modelContext,
                itemsByAppStoreID: &observationItemsByAppStoreID
            )
        }
        pruneObservationItems(
            Array(observationItemsByAppStoreID.values),
            keeping: pageResult.page.items.map(\.appStoreID),
            in: modelContext
        )

        return RankingObservationPersistenceResult(
            observation: observation,
            appliedIncomingPage: true
        )
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
        guard let metadataEnrichmentScheduler else { return }
        let requests = Self.topRankingEnrichmentRequests(
            items: items,
            storefront: storefront,
            platform: platform
        )
        guard !requests.isEmpty else { return }

        metadataEnrichmentScheduler(requests)
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

    private func upsertTrackedRankingLink(
        snapshotKey: String,
        crawl: RankingCrawlRecord,
        in modelContext: ModelContext
    ) throws {
        let targetSnapshotKey = snapshotKey
        var descriptor = FetchDescriptor<TrackedRankingCrawlLink>(
            predicate: #Predicate { link in
                link.snapshotKey == targetSnapshotKey
            }
        )
        descriptor.fetchLimit = 1
        if let link = try modelContext.fetch(descriptor).first {
            if link.crawl !== crawl {
                link.crawl = crawl
            }
        } else {
            modelContext.insert(TrackedRankingCrawlLink(snapshotKey: snapshotKey, crawl: crawl))
        }
    }

    private func observation(
        _ observation: RankingCrawlRecord,
        exactlyMatches page: SearchRankingPage,
        in modelContext: ModelContext
    ) throws -> Bool {
        let observationKey = observation.observationKey
        let facts = try modelContext.fetch(
            FetchDescriptor<RankingFact>(
                predicate: #Predicate { fact in
                    fact.observation.observationKey == observationKey
                }
            )
        )
        guard facts.count == page.items.count else { return false }
        let factsByAppStoreID = Dictionary(
            facts.map { ($0.appStoreID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        guard factsByAppStoreID.count == page.items.count else { return false }
        return page.items.allSatisfy { item in
            guard let fact = factsByAppStoreID[item.appStoreID] else { return false }
            return fact.position == item.position
                && fact.revision.revisionKey == RankingAppRevisionPayload(item).revisionKey
        }
    }

    private func persistTrackedRecoveryObservation(
        _ pageResult: RankingRefreshPageResult,
        snapshotKey: String,
        in modelContext: ModelContext
    ) throws -> RankingCrawlRecord {
        let recoveryKey = RankingCrawlRecord.makeTrackedRecoveryObservationKey(
            snapshotKey: snapshotKey
        )
        var descriptor = FetchDescriptor<RankingCrawlRecord>(
            predicate: #Predicate { crawl in
                crawl.observationKey == recoveryKey
            }
        )
        descriptor.fetchLimit = 1
        let observation = try modelContext.fetch(descriptor).first ?? RankingCrawlRecord(
            keyword: pageResult.request.term,
            storefront: pageResult.request.storefront,
            platform: pageResult.request.platform,
            observedAt: pageResult.searchedAt,
            source: pageResult.page.source,
            resultCount: pageResult.page.resultCount,
            observedHour: pageResult.observedHour,
            submissionCount: pageResult.submissionCount,
            winningCount: pageResult.winningCount,
            confidence: pageResult.confidence
        )
        if observation.modelContext == nil {
            modelContext.insert(observation)
        }
        observation.observationKey = recoveryKey
        observation.queryKey = pageResult.request.queryKey
        observation.keyword = pageResult.request.term
            .trimmingCharacters(in: .whitespacesAndNewlines)
        observation.storefront = pageResult.request.storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        observation.platform = pageResult.request.platform
        observation.observedAt = pageResult.searchedAt
        observation.observedHour = pageResult.observedHour
            ?? RankingCrawlRecord.utcHourBucket(for: pageResult.searchedAt)
        observation.source = pageResult.page.source
        observation.resultCount = pageResult.page.resultCount
        observation.submissionCount = pageResult.submissionCount
        observation.winningCount = pageResult.winningCount
        observation.confidenceRaw = pageResult.confidence

        let currentObservationKey = observation.observationKey
        let existingFacts = try modelContext.fetch(
            FetchDescriptor<RankingFact>(
                predicate: #Predicate { fact in
                    fact.observation.observationKey == currentObservationKey
                }
            )
        )
        var factsByAppStoreID = Dictionary(
            existingFacts.map { ($0.appStoreID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let payloads = pageResult.page.items.map(RankingAppRevisionPayload.init)
        let revisionsByKey = try RankingAppRevisionStore.revisions(
            for: payloads,
            in: modelContext
        )
        for (item, payload) in zip(pageResult.page.items, payloads) {
            guard let revision = revisionsByKey[payload.revisionKey] else {
                throw OpenASOError.unexpectedResponse
            }
            upsertObservationItem(
                from: item,
                revision: revision,
                observation: observation,
                in: modelContext,
                itemsByAppStoreID: &factsByAppStoreID
            )
        }
        pruneObservationItems(
            Array(factsByAppStoreID.values),
            keeping: pageResult.page.items.map(\.appStoreID),
            in: modelContext
        )
        return observation
    }

    private func upsertObservationItem(
        from item: SearchRankingItem,
        revision: RankingAppRevision,
        observation: RankingCrawlRecord,
        in modelContext: ModelContext,
        itemsByAppStoreID: inout [Int64: RankingFact]
    ) {
        let observationItem = itemsByAppStoreID[item.appStoreID] ?? RankingFact(
            position: item.position,
            appStoreID: item.appStoreID,
            revision: revision,
            observation: observation
        )
        if observationItem.modelContext == nil {
            modelContext.insert(observationItem)
            itemsByAppStoreID[item.appStoreID] = observationItem
        }
        if observationItem.position != item.position { observationItem.position = item.position }
        if observationItem.appStoreID != item.appStoreID { observationItem.appStoreID = item.appStoreID }
        if observationItem.revision !== revision { observationItem.revision = revision }
        if observationItem.observation !== observation {
            observationItem.observation = observation
        }
    }

    private func pruneObservationItems(
        _ observationItems: [RankingFact],
        keeping appStoreIDs: [Int64],
        in modelContext: ModelContext
    ) {
        let retainedAppStoreIDs = Set(appStoreIDs)
        let staleItems = observationItems.filter { !retainedAppStoreIDs.contains($0.appStoreID) }
        for item in staleItems {
            modelContext.delete(item)
        }
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

        let targetDayBucket = RankingCrawlRecord.utcDayBucket(for: searchedAt)
        return track.snapshots
            .filter {
                $0.source == source
                    && RankingCrawlRecord.utcDayBucket(for: $0.searchedAt) == targetDayBucket
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
    ) throws -> RankingCrawlRecord? {
        let targetObservationKey = observationKey
        var descriptor = FetchDescriptor<RankingCrawlRecord>(
            predicate: #Predicate { observation in
                observation.observationKey == targetObservationKey
            }
        )
        descriptor.fetchLimit = 1
        if let observation = try modelContext.fetch(descriptor).first {
            return observation
        }

        let targetQueryKey = queryKey
        let fallbackDescriptor = FetchDescriptor<RankingCrawlRecord>(
            predicate: #Predicate { observation in
                observation.queryKey == targetQueryKey
            }
        )
        let targetDayBucket = RankingCrawlRecord.utcDayBucket(for: observedAt)
        return try modelContext.fetch(fallbackDescriptor)
            .filter {
                $0.source == source
                    && RankingCrawlRecord.utcDayBucket(for: $0.observedAt) == targetDayBucket
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
        source: AppStorefrontSource,
        storeApp: StoreApp,
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
        let existingSnapshot = cache.snapshotsByIdentityKey[snapshotKey]
        let isNewSnapshot = existingSnapshot == nil
        let snapshot = existingSnapshot ?? AppDailyRating(
            appStoreID: item.appStoreID,
            storefront: normalizedStorefront,
            ratingCount: item.ratingCount,
            averageRating: item.averageRating,
            ratingDate: ratingDate,
            observedAt: observedAt,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source",
            source: source,
            storeApp: storeApp
        )
        if !isNewSnapshot, observedAt <= snapshot.observedAt {
            return
        }
        if isNewSnapshot {
            modelContext.insert(snapshot)
            cache.snapshotsByIdentityKey[snapshotKey] = snapshot
        }
        if snapshot.storeApp !== storeApp {
            snapshot.storeApp = storeApp
        }
        let snapshotChanged = isNewSnapshot
            || snapshot.observedAt != observedAt
            || snapshot.ratingCount != item.ratingCount
            || snapshot.averageRating != item.averageRating
            || snapshot.ratingDate != ratingDate
            || snapshot.submissionCount != 1
            || snapshot.winningCount != 1
            || snapshot.confidenceRaw != "single_source"
            || snapshot.source != source
        if snapshotChanged {
            snapshot.ratingCount = item.ratingCount
            snapshot.averageRating = item.averageRating
            snapshot.ratingDate = ratingDate
            snapshot.observedAt = observedAt
            snapshot.submissionCount = 1
            snapshot.winningCount = 1
            snapshot.confidenceRaw = "single_source"
            snapshot.source = source
        }

        let latestKey = LatestAppRating.makeIdentityKey(
            appStoreID: item.appStoreID,
            storefront: normalizedStorefront
        )
        let existingLatest = cache.latestByIdentityKey[latestKey]
        let isNewLatest = existingLatest == nil
        let latest = existingLatest ?? LatestAppRating(
            appStoreID: item.appStoreID,
            storefront: normalizedStorefront,
            ratingCount: item.ratingCount,
            averageRating: item.averageRating,
            ratingDate: ratingDate,
            observedAt: observedAt,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source",
            source: source,
            storeApp: storeApp
        )
        if !isNewLatest, observedAt <= latest.observedAt {
            return
        }
        if isNewLatest {
            modelContext.insert(latest)
            cache.latestByIdentityKey[latestKey] = latest
        }
        if latest.storeApp !== storeApp {
            latest.storeApp = storeApp
        }
        let latestChanged = isNewLatest
            || latest.observedAt != observedAt
            || latest.ratingCount != item.ratingCount
            || latest.averageRating != item.averageRating
            || latest.ratingDate != ratingDate
            || latest.submissionCount != 1
            || latest.winningCount != 1
            || latest.confidenceRaw != "single_source"
            || latest.source != source
        if latestChanged {
            latest.ratingCount = item.ratingCount
            latest.averageRating = item.averageRating
            latest.ratingDate = ratingDate
            latest.observedAt = observedAt
            latest.submissionCount = 1
            latest.winningCount = 1
            latest.confidenceRaw = "single_source"
            latest.source = source
        }
    }

    private func storefrontRatingSource(for rankingSource: RankingSource) -> AppStorefrontSource {
        switch rankingSource {
        case .appStoreWeb:
            return .appStorePage
        case .iTunesFallback:
            return .iTunesSearch
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
        var tracksByIdentityKey: [String: TrackedAppKeyword] = [:]
        for track in tracks where tracksByIdentityKey[track.identityKey] == nil {
            tracksByIdentityKey[track.identityKey] = track
        }
        let requestGroups = RankingRequestGroup.normalizedGroups(for: tracks.map(RankingRefreshRequest.init))

        for requestGroup in requestGroups {
            let result = await refreshPage(
                for: requestGroup.providerRequest,
                limit: SearchRankingCrawl.fullKeywordRankingLimit,
                recordsTrigger: false
            )
            switch result {
            case .success(let pageResult):
                for targetPageResult in requestGroup.pageResults(fanningOut: pageResult) {
                    guard let track = tracksByIdentityKey[targetPageResult.request.identityKey] else {
                        failureCount += 1
                        completedCount += 1
                        await progress?(completedCount, tracks.count, failureCount)
                        continue
                    }

                    do {
                        let snapshot = try persistRankingPage(
                            targetPageResult,
                            in: modelContext,
                            rebuildDerivedStats: false
                        )
                        statsRebuildRequests.insert(RankingStatsRebuildRequest(track: track))
                        outcomes.append(RefreshOutcome(
                            trackID: track.persistentModelID,
                            snapshotID: snapshot.persistentModelID,
                            rank: snapshot.rank,
                            searchedAt: snapshot.searchedAt,
                            error: nil
                        ))
                    } catch {
                        let mappedError = OpenASOError.map(error)
                        if modelContext.hasChanges {
                            OpenASOLog.refresh.error(
                                "Skipped ranking failure status because the model context has pending edits."
                            )
                        } else {
                            do {
                                try TrackedKeywordRefreshStatusStore.set(
                                    "Ranking failed to refresh. \(mappedError.localizedDescription)",
                                    domain: .ranking,
                                    for: track,
                                    in: modelContext
                                )
                                try modelContext.save()
                            } catch {
                                modelContext.rollback()
                                OpenASOLog.refresh.error(
                                    "Failed to persist ranking refresh status: \(String(reflecting: error), privacy: .private(mask: .hash))"
                                )
                            }
                        }
                        outcomes.append(RefreshOutcome(
                            trackID: track.persistentModelID,
                            snapshotID: nil,
                            rank: nil,
                            searchedAt: nil,
                            error: mappedError
                        ))
                        failureCount += 1
                    }
                    completedCount += 1
                    await progress?(completedCount, tracks.count, failureCount)
                }
            case .failure(let error):
                for targetRequest in requestGroup.targetRequests {
                    guard let track = tracksByIdentityKey[targetRequest.identityKey] else {
                        failureCount += 1
                        completedCount += 1
                        await progress?(completedCount, tracks.count, failureCount)
                        continue
                    }

                    if modelContext.hasChanges {
                        OpenASOLog.refresh.error(
                            "Skipped ranking failure status because the model context has pending edits."
                        )
                    } else {
                        do {
                            try TrackedKeywordRefreshStatusStore.set(
                                "Ranking failed to refresh. \(error.localizedDescription)",
                                domain: .ranking,
                                for: track,
                                in: modelContext
                            )
                            try modelContext.save()
                        } catch {
                            modelContext.rollback()
                            OpenASOLog.refresh.error(
                                "Failed to persist ranking refresh status: \(String(reflecting: error), privacy: .private(mask: .hash))"
                            )
                        }
                    }
                    outcomes.append(RefreshOutcome(
                        trackID: track.persistentModelID,
                        snapshotID: nil,
                        rank: nil,
                        searchedAt: nil,
                        error: error
                    ))
                    failureCount += 1
                    completedCount += 1
                    await progress?(completedCount, tracks.count, failureCount)
                }
            }
        }
        if !statsRebuildRequests.isEmpty {
            if modelContext.hasChanges {
                OpenASOLog.refresh.error(
                    "Skipped ranking statistics rebuild because the model context has pending edits."
                )
            } else {
                do {
                    try rebuildDerivedStats(for: statsRebuildRequests, in: modelContext)
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    OpenASOLog.refresh.error(
                        "Failed to rebuild ranking statistics: \(String(reflecting: error), privacy: .private(mask: .hash))"
                    )
                }
            }
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
        in modelContext: ModelContext
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
    ) throws {
        // V6 computes ranking aggregates directly from indexed canonical facts.
        // Keep this compatibility entry point while older workflows are updated.
        _ = requests
        _ = modelContext
    }

    func rebuildDerivedStats(
        forQueryKey queryKey: String,
        in modelContext: ModelContext
    ) throws {
        _ = queryKey
        _ = modelContext
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

extension RankingRefreshPageResult {
    func canonicalized(limit: Int) -> RankingRefreshPageResult {
        RankingRefreshPageResult(
            request: request,
            page: page.canonicalized(limit: limit),
            searchedAt: searchedAt,
            observedHour: observedHour,
            submissionCount: submissionCount,
            winningCount: winningCount,
            confidence: confidence
        )
    }
}

extension SearchRankingPage {
    func canonicalized(limit: Int) -> SearchRankingPage {
        let boundedLimit = max(0, limit)
        var seenAppStoreIDs = Set<Int64>()
        let canonicalItems = items
            .sorted { lhs, rhs in
                if lhs.position != rhs.position {
                    return lhs.position < rhs.position
                }
                if lhs.appStoreID != rhs.appStoreID {
                    return lhs.appStoreID < rhs.appStoreID
                }
                return Self.canonicalTiePrecedes(lhs, rhs)
            }
            .compactMap { item in
                seenAppStoreIDs.insert(item.appStoreID).inserted
                    ? item
                    : nil
            }
            .prefix(boundedLimit)
        return SearchRankingPage(items: Array(canonicalItems), source: source)
    }

    private static func canonicalTiePrecedes(
        _ lhs: SearchRankingItem,
        _ rhs: SearchRankingItem
    ) -> Bool {
        let comparisons: [ComparisonResult] = [
            compare(lhs.bundleID, rhs.bundleID),
            compare(lhs.name, rhs.name),
            compare(lhs.subtitle, rhs.subtitle),
            compare(lhs.sellerName, rhs.sellerName),
            compare(lhs.iconURLString, rhs.iconURLString),
            compare(
                lhs.releaseDate.map { $0.timeIntervalSinceReferenceDate.bitPattern },
                rhs.releaseDate.map { $0.timeIntervalSinceReferenceDate.bitPattern }
            ),
            compare(
                lhs.currentVersionReleaseDate.map { $0.timeIntervalSinceReferenceDate.bitPattern },
                rhs.currentVersionReleaseDate.map { $0.timeIntervalSinceReferenceDate.bitPattern }
            ),
            compare(lhs.version, rhs.version),
            compare(lhs.primaryGenreID, rhs.primaryGenreID),
            compare(lhs.primaryGenreName, rhs.primaryGenreName),
            compare(lhs.descriptionText, rhs.descriptionText),
            compare(lhs.releaseNotes, rhs.releaseNotes),
            compare(lhs.supportedLanguageCodes, rhs.supportedLanguageCodes),
            compare(lhs.screenshotURLs, rhs.screenshotURLs),
            compare(lhs.ipadScreenshotURLs, rhs.ipadScreenshotURLs),
            compare(lhs.appletvScreenshotURLs, rhs.appletvScreenshotURLs),
            compare(lhs.ratingCount, rhs.ratingCount),
            compare(
                lhs.averageRating.map(\.bitPattern),
                rhs.averageRating.map(\.bitPattern)
            ),
            compare(lhs.platform.rawValue, rhs.platform.rawValue),
        ]
        return comparisons.first { $0 != .orderedSame } == .orderedAscending
    }

    private static func compare<Value: Comparable>(
        _ lhs: Value,
        _ rhs: Value
    ) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func compare<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none):
            return .orderedSame
        case (.none, .some):
            return .orderedAscending
        case (.some, .none):
            return .orderedDescending
        case (.some(let lhs), .some(let rhs)):
            return compare(lhs, rhs)
        }
    }

    private static func compare<Value: Comparable>(
        _ lhs: [Value],
        _ rhs: [Value]
    ) -> ComparisonResult {
        for (lhsValue, rhsValue) in zip(lhs, rhs) {
            let comparison = compare(lhsValue, rhsValue)
            if comparison != .orderedSame {
                return comparison
            }
        }
        return compare(lhs.count, rhs.count)
    }
}
