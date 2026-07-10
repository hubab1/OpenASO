import Foundation
import SwiftData

struct AppDetailRefreshAppSnapshot: Sendable {
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let defaultPlatform: AppPlatform
}

enum AppDetailRefreshWorkspace: Sendable {
    case keywords
    case ratings
    case pricing
}

enum AppDetailRefreshStorefrontSelection: Sendable {
    case all(codes: [String])
    case storefront(code: String)

    var codes: [String] {
        switch self {
        case .all(let codes):
            return codes
        case .storefront(let code):
            return [code]
        }
    }
}

struct AppDetailRefreshRequest: Sendable {
    let app: AppDetailRefreshAppSnapshot
    let workspace: AppDetailRefreshWorkspace
    let storefrontSelection: AppDetailRefreshStorefrontSelection
    let trackIdentityKeys: [String]
    let trigger: String
    let refreshKeywords: Bool
    let refreshMetrics: Bool
    let refreshRatings: Bool
    let refreshReviews: Bool
    let pricingStorefronts: [String]
    let recordsRatingsReviewsRefresh: Bool
    let popularityContextAppStoreID: Int64?
    let appleAdsWebSession: AppleAdsWebSession?
    let appStoreConnectCredentials: AppStoreConnectCredentials

    init(
        app: AppDetailRefreshAppSnapshot,
        workspace: AppDetailRefreshWorkspace,
        storefrontSelection: AppDetailRefreshStorefrontSelection,
        trackIdentityKeys: [String],
        trigger: String,
        refreshKeywords: Bool = true,
        refreshMetrics: Bool = true,
        refreshRatings: Bool = true,
        refreshReviews: Bool = true,
        pricingStorefronts: [String] = [],
        recordsRatingsReviewsRefresh: Bool = true,
        popularityContextAppStoreID: Int64?,
        appleAdsWebSession: AppleAdsWebSession?,
        appStoreConnectCredentials: AppStoreConnectCredentials
    ) {
        self.app = app
        self.workspace = workspace
        self.storefrontSelection = storefrontSelection
        self.trackIdentityKeys = trackIdentityKeys
        self.trigger = trigger
        self.refreshKeywords = refreshKeywords
        self.refreshMetrics = refreshMetrics
        self.refreshRatings = refreshRatings
        self.refreshReviews = refreshReviews
        self.pricingStorefronts = pricingStorefronts
        self.recordsRatingsReviewsRefresh = recordsRatingsReviewsRefresh
        self.popularityContextAppStoreID = popularityContextAppStoreID
        self.appleAdsWebSession = appleAdsWebSession
        self.appStoreConnectCredentials = appStoreConnectCredentials
    }
}

struct KeywordBackgroundRefreshOutcome: Sendable {
    let trackIdentityKey: String
    let error: OpenASOError?
}

private struct RankingPersistenceBatchOutcome: Sendable {
    let outcomes: [KeywordBackgroundRefreshOutcome]
    let statsRebuildRequests: Set<RankingStatsRebuildRequest>
    let successfulPageResults: [RankingRefreshPageResult]

    var failureCount: Int {
        outcomes.filter { $0.error != nil }.count
    }
}

private struct RankingRefreshWorkItem: Sendable {
    let fetchRequest: RankingRefreshRequest
    let targetRequests: [RankingRefreshRequest]
}

struct AppDetailRefreshResult: Sendable {
    let keywordOutcomes: [KeywordBackgroundRefreshOutcome]
    let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
    let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
    let pricingComparison: OpenASOMCPAppPricingComparison?
    let pricingError: OpenASOError?
    let firstError: OpenASOError?
}

actor AppPricingCache {
    private var comparisonsByAppStoreID: [Int64: OpenASOMCPAppPricingComparison] = [:]

    func comparison(appStoreID: Int64, requestedStorefronts: [String]?) -> OpenASOMCPAppPricingComparison? {
        guard let comparison = comparisonsByAppStoreID[appStoreID] else { return nil }
        guard let requestedStorefronts else { return comparison }
        let cachedStorefronts = Set(comparison.storefronts.map(Self.normalizedStorefront))
        let requested = Set(requestedStorefronts.map(Self.normalizedStorefront))
        return requested.isSubset(of: cachedStorefronts) ? comparison : nil
    }

    func store(_ comparison: OpenASOMCPAppPricingComparison) {
        for appStoreID in comparison.appStoreIDs.compactMap(Int64.init) {
            comparisonsByAppStoreID[appStoreID] = comparison
        }
    }

    private static func normalizedStorefront(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private actor AppDetailRefreshQueue {
    private struct Job: Sendable {
        let request: AppDetailRefreshRequest
        let operation: @Sendable (AppDetailRefreshRequest) async -> AppDetailRefreshResult
        let continuation: CheckedContinuation<AppDetailRefreshResult, Never>
    }

    private var pendingJobs: [Job] = []
    private var isDraining = false

    func enqueue(
        _ request: AppDetailRefreshRequest,
        operation: @escaping @Sendable (AppDetailRefreshRequest) async -> AppDetailRefreshResult
    ) async -> AppDetailRefreshResult {
        await withCheckedContinuation { continuation in
            pendingJobs.append(Job(
                request: request,
                operation: operation,
                continuation: continuation
            ))
            startDrainingIfNeeded()
        }
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            await drain()
        }
    }

    private func nextJob() -> Job? {
        guard !pendingJobs.isEmpty else {
            isDraining = false
            return nil
        }
        return pendingJobs.removeFirst()
    }

    private func drain() async {
        while let job = nextJob() {
            let result = await job.operation(job.request)
            job.continuation.resume(returning: result)
        }
    }
}

final class AppDetailRefreshService: Sendable {
    private static let rankingFetchConcurrency = 4
    // Mirrors AppStorefrontRatingService.ratingFetchConcurrency.
    private static let reviewFetchConcurrency = 6
    private static let rankingPersistenceBatchSize = 5

    private let refreshQueue = AppDetailRefreshQueue()
    private let backgroundModelStore: BackgroundModelStore
    private let refreshCoordinator: RankingRefreshCoordinator
    private let keywordMetricsService: KeywordMetricsService
    private let appStorefrontRatingService: AppStorefrontRatingService
    private let appStorefrontReviewService: AppStorefrontReviewService
    private let appStoreConnectReviewService: AppStoreConnectReviewService
    private let progressStore: AppRefreshProgressStore?
    private let ratingsReviewsRefreshRecorder: (@Sendable (Date) async -> Void)?
    private let pricingRefresh: (
        @Sendable (
            Int64,
            [String],
            @escaping @Sendable (Int, Int, Int) async -> Void
        ) async throws -> OpenASOMCPAppPricingComparison
    )?
    private let pricingCache: AppPricingCache?

    init(
        backgroundModelStore: BackgroundModelStore,
        refreshCoordinator: RankingRefreshCoordinator,
        keywordMetricsService: KeywordMetricsService,
        appStorefrontRatingService: AppStorefrontRatingService,
        appStorefrontReviewService: AppStorefrontReviewService,
        appStoreConnectReviewService: AppStoreConnectReviewService,
        progressStore: AppRefreshProgressStore? = nil,
        ratingsReviewsRefreshRecorder: (@Sendable (Date) async -> Void)? = nil,
        pricingRefresh: (
            @Sendable (
                Int64,
                [String],
                @escaping @Sendable (Int, Int, Int) async -> Void
            ) async throws -> OpenASOMCPAppPricingComparison
        )? = nil,
        pricingCache: AppPricingCache? = nil
    ) {
        self.backgroundModelStore = backgroundModelStore
        self.refreshCoordinator = refreshCoordinator
        self.keywordMetricsService = keywordMetricsService
        self.appStorefrontRatingService = appStorefrontRatingService
        self.appStorefrontReviewService = appStorefrontReviewService
        self.appStoreConnectReviewService = appStoreConnectReviewService
        self.progressStore = progressStore
        self.ratingsReviewsRefreshRecorder = ratingsReviewsRefreshRecorder
        self.pricingRefresh = pricingRefresh
        self.pricingCache = pricingCache
    }

    func refresh(_ request: AppDetailRefreshRequest) async -> AppDetailRefreshResult {
        await progressStore?.queuePendingAppRefresh()
        return await refreshQueue.enqueue(request) { [self] request in
            await progressStore?.beginPendingAppRefresh()
            return await performRefresh(request)
        }
    }

    private func performRefresh(_ request: AppDetailRefreshRequest) async -> AppDetailRefreshResult {
        await progressStore?.beginRefresh(request)
        let keywordOutcomes: [KeywordBackgroundRefreshOutcome]
        let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
        let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
        let pricingComparison: OpenASOMCPAppPricingComparison?
        let pricingError: OpenASOError?

        switch request.workspace {
        case .keywords, .ratings:
            pricingComparison = nil
            pricingError = nil
            // Keywords and ratings/reviews touch disjoint models and endpoints;
            // run them concurrently and let writes serialize on the model store.
            async let keywordsTask = refreshKeywords(request)
            async let ratingsReviewsTask = refreshRatingsAndReviews(request)
            keywordOutcomes = await keywordsTask
            (ratingOutcomes, reviewOutcomes) = await ratingsReviewsTask
        case .pricing:
            keywordOutcomes = []
            ratingOutcomes = []
            reviewOutcomes = []
            let pricingResult = await refreshPricing(request)
            pricingComparison = pricingResult.comparison
            pricingError = pricingResult.error
        }

        let firstError = pricingError ?? firstRefreshError(
            workspace: request.workspace,
            keywordOutcomes: keywordOutcomes,
            ratingOutcomes: ratingOutcomes,
            reviewOutcomes: reviewOutcomes
        )
        await progressStore?.updatePhase(.finishing)
        await progressStore?.finish(error: firstError)

        return AppDetailRefreshResult(
            keywordOutcomes: keywordOutcomes,
            ratingOutcomes: ratingOutcomes,
            reviewOutcomes: reviewOutcomes,
            pricingComparison: pricingComparison,
            pricingError: pricingError,
            firstError: firstError
        )
    }

    private func refreshPricing(_ request: AppDetailRefreshRequest) async
        -> (comparison: OpenASOMCPAppPricingComparison?, error: OpenASOError?)
    {
        await progressStore?.updatePhase(.refreshingPricing)
        guard let pricingRefresh else {
            await progressStore?.updateStep(.pricing, status: .failed, completed: 0, total: 0, failureCount: 1)
            return (nil, .providerUnavailable("The pricing refresh service is unavailable."))
        }

        let storefronts = request.pricingStorefronts.isEmpty
            ? Self.pricingStorefronts(from: request.storefrontSelection)
            : request.pricingStorefronts
        await progressStore?.updateStep(
            .pricing,
            status: storefronts.isEmpty ? .skipped : .running,
            completed: 0,
            total: storefronts.count,
            failureCount: 0
        )

        do {
            let comparison = try await pricingRefresh(
                request.app.appStoreID,
                storefronts
            ) { completed, total, failureCount in
                await self.progressStore?.updateStep(
                    .pricing,
                    status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                    completed: completed,
                    total: total,
                    failureCount: failureCount
                )
            }
            await pricingCache?.store(comparison)
            try await AppPricingPersistence.store(comparison, using: backgroundModelStore)
            return (comparison, nil)
        } catch {
            await progressStore?.updateStep(
                .pricing,
                status: .failed,
                completed: 0,
                total: storefronts.count,
                failureCount: max(1, storefronts.count)
            )
            return (nil, OpenASOError.map(error))
        }
    }

    private static func pricingStorefronts(from selection: AppDetailRefreshStorefrontSelection) -> [String] {
        let selected = selection.codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Array(Set(selected + ["us"])).sorted()
    }

    private func refreshKeywords(_ request: AppDetailRefreshRequest) async -> [KeywordBackgroundRefreshOutcome] {
        guard request.refreshKeywords || request.refreshMetrics, !request.trackIdentityKeys.isEmpty else {
            await progressStore?.updateStep(.keywords, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await progressStore?.updateStep(.metrics, status: .skipped, completed: 0, total: 0, failureCount: 0)
            return []
        }

        do {
            await progressStore?.updatePhase(.refreshingKeywords)
            let (rankingRequests, missingOutcomes) = try await backgroundModelStore.read { modelContext in
                let targetIdentityKeys = request.trackIdentityKeys
                let descriptor = FetchDescriptor<TrackedAppKeyword>(
                    predicate: #Predicate { track in
                        targetIdentityKeys.contains(track.identityKey)
                    }
                )
                let tracks = try modelContext.fetch(descriptor)
                let foundIdentityKeys = Set(tracks.map(\.identityKey))
                let missingOutcomes = request.trackIdentityKeys
                    .filter { !foundIdentityKeys.contains($0) }
                    .map { KeywordBackgroundRefreshOutcome(trackIdentityKey: $0, error: .appNotFound) }
                return (tracks.map(RankingRefreshRequest.init), missingOutcomes)
            }

            let missingFailureCount = missingOutcomes.count
            if rankingRequests.isEmpty {
                await progressStore?.updateStep(
                    .keywords,
                    status: missingFailureCount > 0 ? .failed : .skipped,
                    completed: missingFailureCount,
                    total: request.trackIdentityKeys.count,
                    failureCount: missingFailureCount
                )
            }

            let keywordOutcomes: [KeywordBackgroundRefreshOutcome]
            if request.refreshKeywords {
                keywordOutcomes = await refreshRankings(
                    rankingRequests,
                    trigger: request.trigger,
                    missingFailureCount: missingFailureCount,
                    totalRequestedCount: request.trackIdentityKeys.count
                )
            } else {
                await progressStore?.updateStep(
                    .keywords,
                    status: .skipped,
                    completed: 0,
                    total: 0,
                    failureCount: 0
                )
                keywordOutcomes = []
            }

            if request.refreshMetrics {
                await progressStore?.updatePhase(.refreshingMetrics)
                _ = try await keywordMetricsService.refreshMetrics(
                    for: rankingRequests.map(\.identityKey),
                    popularityContextAppStoreID: request.popularityContextAppStoreID,
                    webSession: request.appleAdsWebSession,
                    using: backgroundModelStore,
                    progress: { completed, total, failureCount in
                        await self.progressStore?.updateStep(
                            .metrics,
                            status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                            completed: completed,
                            total: total,
                            failureCount: failureCount
                        )
                    }
                )
            } else {
                await progressStore?.updateStep(.metrics, status: .skipped, completed: 0, total: 0, failureCount: 0)
            }

            return missingOutcomes + keywordOutcomes
        } catch {
            let mappedError = OpenASOError.map(error)
            await progressStore?.updateStep(
                .keywords,
                status: .failed,
                completed: request.trackIdentityKeys.count,
                total: request.trackIdentityKeys.count,
                failureCount: request.trackIdentityKeys.count
            )
            return request.trackIdentityKeys.map {
                KeywordBackgroundRefreshOutcome(trackIdentityKey: $0, error: mappedError)
            }
        }
    }

    private func refreshRankings(
        _ rankingRequests: [RankingRefreshRequest],
        trigger: String,
        missingFailureCount: Int,
        totalRequestedCount: Int
    ) async -> [KeywordBackgroundRefreshOutcome] {
        guard !rankingRequests.isEmpty else { return [] }

        if trigger == "daily_refresh" {
            await refreshCoordinator.recordRefreshTriggered()
        }
        let rankingPageFetcher = await refreshCoordinator.makeRankingPageFetcher()
        await refreshCoordinator.captureKeywordRefreshStarted(trigger: trigger, trackCount: rankingRequests.count)
        await progressStore?.updateStep(
            .keywords,
            status: .running,
            completed: missingFailureCount,
            total: totalRequestedCount,
            failureCount: missingFailureCount
        )

        var outcomes: [KeywordBackgroundRefreshOutcome] = []
        var statsRebuildRequests = Set<RankingStatsRebuildRequest>()
        var pendingPageResults: [RankingRefreshPageResult] = []
        let workItems = rankingRefreshWorkItems(from: rankingRequests)
        var completedCount = 0
        var failureCount = 0

        func flushPendingPageResults() async {
            guard !pendingPageResults.isEmpty else { return }

            let pageResults = pendingPageResults
            pendingPageResults.removeAll(keepingCapacity: true)
            let batchOutcome = await persistRankingPageBatch(pageResults)
            outcomes.append(contentsOf: batchOutcome.outcomes)
            statsRebuildRequests.formUnion(batchOutcome.statsRebuildRequests)
            failureCount += batchOutcome.failureCount
            for pageResult in batchOutcome.successfulPageResults {
                refreshCoordinator.scheduleTopRankingMetadataEnrichment(for: pageResult)
            }
        }

        await withTaskGroup(of: (RankingRefreshWorkItem, Result<RankingRefreshPageResult, OpenASOError>).self) { group in
            var nextWorkItemIndex = 0
            var activeFetchCount = 0

            func enqueueNextFetchIfPossible() {
                guard activeFetchCount < Self.rankingFetchConcurrency,
                      nextWorkItemIndex < workItems.count else {
                    return
                }

                let workItem = workItems[nextWorkItemIndex]
                nextWorkItemIndex += 1
                activeFetchCount += 1
                group.addTask {
                    let result = await rankingPageFetcher(workItem.fetchRequest)
                    return (workItem, result)
                }
            }

            for _ in 0..<min(Self.rankingFetchConcurrency, workItems.count) {
                enqueueNextFetchIfPossible()
            }

            while let (workItem, result) = await group.next() {
                activeFetchCount -= 1
                // Refill the freed fetch slot before any persistence work so the
                // fetch window stays saturated while batches flush to the store.
                enqueueNextFetchIfPossible()

                switch result {
                case .success(let pageResult):
                    pendingPageResults.append(contentsOf: pageResults(from: pageResult, for: workItem.targetRequests))
                    if pendingPageResults.count >= Self.rankingPersistenceBatchSize {
                        await flushPendingPageResults()
                    }
                case .failure(let error):
                    for rankingRequest in workItem.targetRequests {
                        try? await backgroundModelStore.write { modelContext in
                            _ = try refreshCoordinator.recordRefreshFailure(
                                identityKey: rankingRequest.identityKey,
                                error: error,
                                in: modelContext,
                                saveChanges: false
                            )
                        }
                        outcomes.append(KeywordBackgroundRefreshOutcome(trackIdentityKey: rankingRequest.identityKey, error: error))
                    }
                    failureCount += workItem.targetRequests.count
                }

                completedCount += workItem.targetRequests.count
                await progressStore?.updateStep(
                    .keywords,
                    status: completedCount >= rankingRequests.count
                        ? (failureCount + missingFailureCount > 0 ? .failed : .completed)
                        : .running,
                    completed: completedCount + missingFailureCount,
                    total: totalRequestedCount,
                    failureCount: failureCount + missingFailureCount
                )
            }
        }

        await flushPendingPageResults()
        await progressStore?.updateStep(
            .keywords,
            status: failureCount + missingFailureCount > 0 ? .failed : .completed,
            completed: completedCount + missingFailureCount,
            total: totalRequestedCount,
            failureCount: failureCount + missingFailureCount
        )

        if !statsRebuildRequests.isEmpty {
            let requests = statsRebuildRequests
            try? await backgroundModelStore.write { modelContext in
                refreshCoordinator.rebuildDerivedStats(for: requests, in: modelContext)
            }
        }

        await refreshCoordinator.captureKeywordRefreshCompleted(
            trigger: trigger,
            trackCount: rankingRequests.count,
            failureCount: outcomes.filter { $0.error != nil }.count
        )
        return outcomes
    }

    private func rankingRefreshWorkItems(from requests: [RankingRefreshRequest]) -> [RankingRefreshWorkItem] {
        Dictionary(grouping: requests, by: \.queryKey)
            .values
            .map { groupedRequests in
                let orderedRequests = groupedRequests.sorted { lhs, rhs in
                    lhs.identityKey.localizedStandardCompare(rhs.identityKey) == .orderedAscending
                }
                return RankingRefreshWorkItem(
                    fetchRequest: orderedRequests[0],
                    targetRequests: orderedRequests
                )
            }
            .sorted { lhs, rhs in
                lhs.fetchRequest.queryKey.localizedStandardCompare(rhs.fetchRequest.queryKey) == .orderedAscending
            }
    }

    private func pageResults(
        from pageResult: RankingRefreshPageResult,
        for targetRequests: [RankingRefreshRequest]
    ) -> [RankingRefreshPageResult] {
        targetRequests.map { request in
            RankingRefreshPageResult(
                request: request,
                page: pageResult.page,
                searchedAt: pageResult.searchedAt,
                observedHour: pageResult.observedHour,
                submissionCount: pageResult.submissionCount,
                winningCount: pageResult.winningCount,
                confidence: targetRequests.count > 1 ? "shared_query_fetch" : pageResult.confidence
            )
        }
    }

    private func persistRankingPageBatch(
        _ pageResults: [RankingRefreshPageResult]
    ) async -> RankingPersistenceBatchOutcome {
        do {
            return try await backgroundModelStore.write { modelContext in
                var outcomes: [KeywordBackgroundRefreshOutcome] = []
                var statsRebuildRequests = Set<RankingStatsRebuildRequest>()
                var successfulPageResults: [RankingRefreshPageResult] = []

                for pageResult in pageResults {
                    do {
                        _ = try refreshCoordinator.persistRankingPage(
                            pageResult,
                            in: modelContext,
                            rebuildDerivedStats: false,
                            saveChanges: false,
                            scheduleMetadataEnrichment: false
                        )
                        if let statsRebuildRequest = RankingStatsRebuildRequest(pageRequest: pageResult.request) {
                            statsRebuildRequests.insert(statsRebuildRequest)
                        }
                        successfulPageResults.append(pageResult)
                        outcomes.append(KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: pageResult.request.identityKey,
                            error: nil
                        ))
                    } catch {
                        let mappedError = OpenASOError.map(error)
                        _ = try? refreshCoordinator.recordRefreshFailure(
                            identityKey: pageResult.request.identityKey,
                            error: mappedError,
                            in: modelContext,
                            saveChanges: false
                        )
                        outcomes.append(KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: pageResult.request.identityKey,
                            error: mappedError
                        ))
                    }
                }

                return RankingPersistenceBatchOutcome(
                    outcomes: outcomes,
                    statsRebuildRequests: statsRebuildRequests,
                    successfulPageResults: successfulPageResults
                )
            }
        } catch {
            let mappedError = OpenASOError.map(error)
            try? await backgroundModelStore.write { modelContext in
                for pageResult in pageResults {
                    _ = try? refreshCoordinator.recordRefreshFailure(
                        identityKey: pageResult.request.identityKey,
                        error: mappedError,
                        in: modelContext,
                        saveChanges: false
                    )
                }
            }
            return RankingPersistenceBatchOutcome(
                outcomes: pageResults.map {
                    KeywordBackgroundRefreshOutcome(trackIdentityKey: $0.request.identityKey, error: mappedError)
                },
                statsRebuildRequests: [],
                successfulPageResults: []
            )
        }
    }

    private func refreshRatingsAndReviews(
        _ request: AppDetailRefreshRequest
    ) async -> ([AppStorefrontRatingRefreshOutcome], [AppStorefrontReviewRefreshOutcome]) {
        guard request.refreshRatings || request.refreshReviews else {
            await progressStore?.updateStep(.ratings, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await progressStore?.updateStep(.reviews, status: .skipped, completed: 0, total: 0, failureCount: 0)
            return ([], [])
        }

        let storefrontCodes = request.storefrontSelection.codes
        // Ratings and reviews hit disjoint endpoints; overlap the network legs
        // while writes stay serialized on the background model store.
        async let ratingsTask = refreshRatingsBranch(request, storefrontCodes: storefrontCodes)
        async let reviewsTask = refreshReviewsBranch(request, storefrontCodes: storefrontCodes)
        let outcomes = (await ratingsTask, await reviewsTask)
        if request.recordsRatingsReviewsRefresh, didSuccessfullyRefreshRatingsOrReviews(outcomes) {
            await ratingsReviewsRefreshRecorder?(.now)
        }
        return outcomes
    }

    private func refreshRatingsBranch(
        _ request: AppDetailRefreshRequest,
        storefrontCodes: [String]
    ) async -> [AppStorefrontRatingRefreshOutcome] {
        guard request.refreshRatings else {
            await progressStore?.updateStep(.ratings, status: .skipped, completed: 0, total: 0, failureCount: 0)
            return []
        }

        await progressStore?.updatePhase(.refreshingRatings)
        let ratingOutcomes = await appStorefrontRatingService.fetchRatingOutcomes(
            appStoreID: request.app.appStoreID,
            appName: request.app.name,
            storefronts: storefrontCodes,
            progress: { completed, total, failureCount in
                await self.progressStore?.updateStep(
                    .ratings,
                    status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                    completed: completed,
                    total: total,
                    failureCount: failureCount
                )
            }
        )
        do {
            try await persistRatingOutcomes(ratingOutcomes, for: request.app)
            return ratingOutcomes
        } catch {
            await progressStore?.updateStep(
                .ratings,
                status: .failed,
                completed: storefrontCodes.count,
                total: storefrontCodes.count,
                failureCount: max(1, storefrontCodes.count)
            )
            return [
                AppStorefrontRatingRefreshOutcome(
                    storefront: "all",
                    result: nil,
                    error: OpenASOError.map(error)
                )
            ]
        }
    }

    private func refreshReviewsBranch(
        _ request: AppDetailRefreshRequest,
        storefrontCodes: [String]
    ) async -> [AppStorefrontReviewRefreshOutcome] {
        guard request.refreshReviews else {
            await progressStore?.updateStep(.reviews, status: .skipped, completed: 0, total: 0, failureCount: 0)
            return []
        }

        await progressStore?.updatePhase(.refreshingReviews)
        do {
            return try await refreshReviews(request: request, storefrontCodes: storefrontCodes)
        } catch {
            await progressStore?.updateStep(
                .reviews,
                status: .failed,
                completed: storefrontCodes.count,
                total: storefrontCodes.count,
                failureCount: max(1, storefrontCodes.count)
            )
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "all",
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: OpenASOError.map(error)
                )
            ]
        }
    }

    private func didSuccessfullyRefreshRatingsOrReviews(
        _ outcomes: ([AppStorefrontRatingRefreshOutcome], [AppStorefrontReviewRefreshOutcome])
    ) -> Bool {
        let attemptedAnyRefresh = !outcomes.0.isEmpty || !outcomes.1.isEmpty
        guard attemptedAnyRefresh else { return false }

        return outcomes.0.allSatisfy { $0.error == nil }
            && outcomes.1.allSatisfy { $0.error == nil }
    }

    private func refreshReviews(
        request: AppDetailRefreshRequest,
        storefrontCodes: [String]
    ) async throws -> [AppStorefrontReviewRefreshOutcome] {
        guard
            request.appStoreConnectCredentials.isComplete,
            let bundleID = request.app.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty
        else {
            return try await refreshStorefrontReviews(request: request, storefrontCodes: storefrontCodes)
        }

        do {
            await progressStore?.updateStep(.reviews, status: .running, completed: 0, total: 1, failureCount: 0)
            let app = try await appStoreConnectReviewService.resolveApp(
                bundleID: bundleID,
                using: request.appStoreConnectCredentials
            )
            var storedCount = 0
            let fetchedCount = try await appStoreConnectReviewService.fetchReviewPages(
                appStoreConnectAppID: app.id,
                appStoreID: request.app.appStoreID,
                credentials: request.appStoreConnectCredentials,
            ) { pageReviews in
                let pageStoredCount = try await backgroundModelStore.write { modelContext in
                    let storeApp = try storeApp(for: request.app, in: modelContext)
                    return try appStoreConnectReviewService.upsert(pageReviews, storeApp: storeApp, in: modelContext)
                }
                storedCount += pageStoredCount
                return pageStoredCount == pageReviews.count
            }
            await progressStore?.updateStep(
                .reviews,
                status: .completed,
                completed: 1,
                total: 1,
                failureCount: 0
            )
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "app-store-connect",
                    fetchedReviews: fetchedCount,
                    storedReviews: storedCount,
                    error: nil
                )
            ]
        } catch OpenASOError.appNotFound {
            return try await refreshStorefrontReviews(request: request, storefrontCodes: storefrontCodes)
        } catch {
            await progressStore?.updateStep(
                .reviews,
                status: .failed,
                completed: 1,
                total: 1,
                failureCount: 1
            )
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "app-store-connect",
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: OpenASOError.map(error)
                )
            ]
        }
    }

    private func persistRatingOutcomes(
        _ outcomes: [AppStorefrontRatingRefreshOutcome],
        for app: AppDetailRefreshAppSnapshot
    ) async throws {
        try await backgroundModelStore.write { modelContext in
            let storeApp = try storeApp(for: app, in: modelContext)
            for outcome in outcomes {
                appStorefrontRatingService.persist(outcome, for: storeApp, in: modelContext)
            }
        }
    }

    private func refreshStorefrontReviews(
        request: AppDetailRefreshRequest,
        storefrontCodes: [String]
    ) async throws -> [AppStorefrontReviewRefreshOutcome] {
        let targetStorefronts = AppStorefrontReviewService.normalizedStorefronts(from: storefrontCodes)
        guard !targetStorefronts.isEmpty else {
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "all",
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: .providerUnavailable("No storefronts were available for reviews refresh.")
                )
            ]
        }

        var outcomes: [AppStorefrontReviewRefreshOutcome] = []
        var completedCount = 0
        var failureCount = 0
        await progressStore?.updateStep(.reviews, status: .running, completed: 0, total: targetStorefronts.count, failureCount: 0)

        // Overlap the per-storefront review crawls with a bounded window
        // (mirrors AppStorefrontRatingService); writes stay serialized on the
        // background model store.
        await withTaskGroup(of: AppStorefrontReviewRefreshOutcome.self) { group in
            var nextIndex = 0
            var activeCount = 0

            func enqueueNextFetchIfPossible() {
                guard activeCount < Self.reviewFetchConcurrency,
                      nextIndex < targetStorefronts.count else {
                    return
                }

                let storefront = targetStorefronts[nextIndex]
                nextIndex += 1
                activeCount += 1
                group.addTask {
                    do {
                        var storedCount = 0
                        let fetchedCount = try await self.appStorefrontReviewService.fetchReviewPages(
                            appStoreID: request.app.appStoreID,
                            storefront: storefront
                        ) { pageReviews in
                            let pageStoredCount = try await self.backgroundModelStore.write { modelContext in
                                let storeApp = try self.storeApp(for: request.app, in: modelContext)
                                return try self.appStorefrontReviewService.upsert(
                                    pageReviews,
                                    storeApp: storeApp,
                                    in: modelContext
                                )
                            }
                            storedCount += pageStoredCount
                            return pageStoredCount == pageReviews.count
                        }
                        return AppStorefrontReviewRefreshOutcome(
                            storefront: storefront,
                            fetchedReviews: fetchedCount,
                            storedReviews: storedCount,
                            error: nil
                        )
                    } catch {
                        return AppStorefrontReviewRefreshOutcome(
                            storefront: storefront,
                            fetchedReviews: 0,
                            storedReviews: 0,
                            error: OpenASOError.map(error)
                        )
                    }
                }
            }

            for _ in 0..<min(Self.reviewFetchConcurrency, targetStorefronts.count) {
                enqueueNextFetchIfPossible()
            }

            while let outcome = await group.next() {
                activeCount -= 1
                enqueueNextFetchIfPossible()
                outcomes.append(outcome)
                if outcome.error != nil {
                    failureCount += 1
                }
                completedCount += 1
                await progressStore?.updateStep(
                    .reviews,
                    status: completedCount >= targetStorefronts.count ? (failureCount > 0 ? .failed : .completed) : .running,
                    completed: completedCount,
                    total: targetStorefronts.count,
                    failureCount: failureCount
                )
            }
        }

        outcomes.sort { $0.storefront < $1.storefront }
        return outcomes
    }

    private func storeApp(
        for app: AppDetailRefreshAppSnapshot,
        in modelContext: ModelContext
    ) throws -> StoreApp {
        let targetAppStoreID = app.appStoreID
        let descriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { storeApp in
                storeApp.appStoreID == targetAppStoreID
            }
        )

        let storeApp = try modelContext.fetch(descriptor).first ?? StoreApp(
            appStoreID: app.appStoreID,
            bundleID: app.bundleID,
            name: app.name,
            subtitle: app.subtitle,
            sellerName: app.sellerName,
            iconURLString: nil,
            defaultPlatform: app.defaultPlatform
        )
        if storeApp.modelContext == nil {
            modelContext.insert(storeApp)
        }
        updateIfChanged(&storeApp.bundleID, app.bundleID)
        updateIfChanged(&storeApp.name, app.name)
        updateIfChanged(&storeApp.subtitle, app.subtitle)
        updateIfChanged(&storeApp.sellerName, app.sellerName)
        if storeApp.defaultPlatform != app.defaultPlatform {
            storeApp.defaultPlatform = app.defaultPlatform
        }
        return storeApp
    }

    private func updateIfChanged<Value: Equatable>(_ value: inout Value, _ newValue: Value) {
        if value != newValue {
            value = newValue
        }
    }

    private func firstRefreshError(
        workspace: AppDetailRefreshWorkspace,
        keywordOutcomes: [KeywordBackgroundRefreshOutcome],
        ratingOutcomes: [AppStorefrontRatingRefreshOutcome],
        reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
    ) -> OpenASOError? {
        let keywordError = keywordOutcomes.first(where: { $0.error != nil })?.error
        let ratingError = ratingOutcomes.first(where: { $0.error != nil })?.error
        let reviewError = reviewOutcomes.first(where: { $0.error != nil })?.error

        switch workspace {
        case .keywords:
            return keywordError ?? ratingError ?? reviewError
        case .ratings:
            return ratingError ?? reviewError ?? keywordError
        case .pricing:
            return nil
        }
    }
}
