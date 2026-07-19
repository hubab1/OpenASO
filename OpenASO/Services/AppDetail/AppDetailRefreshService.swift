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

private struct KeywordRefreshResult: Sendable {
    let outcomes: [KeywordBackgroundRefreshOutcome]
    let metricsError: OpenASOError?
}

private struct RankingPersistenceBatchOutcome: Sendable {
    let outcomes: [KeywordBackgroundRefreshOutcome]
    let statsRebuildRequests: Set<RankingStatsRebuildRequest>
    let successfulPageResults: [RankingRefreshPageResult]

    var failureCount: Int {
        outcomes.filter { $0.error != nil }.count
    }
}

struct AppDetailRefreshResult: Sendable {
    let keywordOutcomes: [KeywordBackgroundRefreshOutcome]
    let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
    let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
    let firstError: OpenASOError?
    let wasCancelled: Bool

    init(
        keywordOutcomes: [KeywordBackgroundRefreshOutcome],
        ratingOutcomes: [AppStorefrontRatingRefreshOutcome],
        reviewOutcomes: [AppStorefrontReviewRefreshOutcome],
        firstError: OpenASOError?,
        wasCancelled: Bool = false
    ) {
        self.keywordOutcomes = keywordOutcomes
        self.ratingOutcomes = ratingOutcomes
        self.reviewOutcomes = reviewOutcomes
        self.firstError = firstError
        self.wasCancelled = wasCancelled
    }

    static let cancelled = AppDetailRefreshResult(
        keywordOutcomes: [],
        ratingOutcomes: [],
        reviewOutcomes: [],
        firstError: nil,
        wasCancelled: true
    )
}

private actor AppDetailRefreshQueue {
    private struct Waiter: Sendable {
        let jobID: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeJobID: UUID?
    private var waiters: [Waiter] = []

    func acquire(jobID: UUID) async throws {
        try Task.checkCancellation()
        guard activeJobID != nil else {
            activeJobID = jobID
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(jobID: jobID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelPending(jobID: jobID) }
        }
    }

    func release(jobID: UUID) {
        guard activeJobID == jobID else {
            assertionFailure("Attempted to release a refresh queue permit owned by another job.")
            return
        }
        guard !waiters.isEmpty else {
            activeJobID = nil
            return
        }
        let next = waiters.removeFirst()
        activeJobID = next.jobID
        next.continuation.resume()
    }

    private func cancelPending(jobID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.jobID == jobID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

final class AppDetailRefreshService: Sendable {
    private static let rankingFetchConcurrency = 4
    private static let rankingPersistenceBatchSize = 5

    private let refreshQueue = AppDetailRefreshQueue()
    private let backgroundModelStore: BackgroundModelStore
    private let refreshCoordinator: RankingRefreshCoordinator
    private let keywordMetricsService: KeywordMetricsService
    private let appStorefrontRatingService: AppStorefrontRatingService
    private let appStorefrontReviewService: AppStorefrontReviewService
    private let appStoreConnectReviewService: AppStoreConnectReviewService
    private let progressStore: AppRefreshProgressStore?
    private let refreshMetricsRecorder: RefreshMetricsRecorder?
    private let ratingsReviewsRefreshRecorder: (@Sendable (Date) async -> Void)?

    init(
        backgroundModelStore: BackgroundModelStore,
        refreshCoordinator: RankingRefreshCoordinator,
        keywordMetricsService: KeywordMetricsService,
        appStorefrontRatingService: AppStorefrontRatingService,
        appStorefrontReviewService: AppStorefrontReviewService,
        appStoreConnectReviewService: AppStoreConnectReviewService,
        progressStore: AppRefreshProgressStore? = nil,
        refreshMetricsRecorder: RefreshMetricsRecorder? = nil,
        ratingsReviewsRefreshRecorder: (@Sendable (Date) async -> Void)? = nil
    ) {
        self.backgroundModelStore = backgroundModelStore
        self.refreshCoordinator = refreshCoordinator
        self.keywordMetricsService = keywordMetricsService
        self.appStorefrontRatingService = appStorefrontRatingService
        self.appStorefrontReviewService = appStorefrontReviewService
        self.appStoreConnectReviewService = appStoreConnectReviewService
        self.progressStore = progressStore
        self.refreshMetricsRecorder = refreshMetricsRecorder
        self.ratingsReviewsRefreshRecorder = ratingsReviewsRefreshRecorder
    }

    func refresh(_ request: AppDetailRefreshRequest) async -> AppDetailRefreshResult {
        do {
            return try await refreshCancellable(request)
        } catch {
            if Task.isCancelled {
                return .cancelled
            }
            return AppDetailRefreshResult(
                keywordOutcomes: [],
                ratingOutcomes: [],
                reviewOutcomes: [],
                firstError: OpenASOError.map(error)
            )
        }
    }

    func refreshCancellable(
        _ request: AppDetailRefreshRequest
    ) async throws -> AppDetailRefreshResult {
        try Task.checkCancellation()
        let jobID = UUID()
        await progressStore?.queuePendingAppRefresh()

        do {
            try Task.checkCancellation()
            try await refreshQueue.acquire(jobID: jobID)
        } catch {
            await progressStore?.cancelPendingAppRefresh()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }

        await progressStore?.beginPendingAppRefresh()
        do {
            try Task.checkCancellation()
            let result = try await performObservedRefresh(request)
            await refreshQueue.release(jobID: jobID)
            return result
        } catch {
            await refreshQueue.release(jobID: jobID)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func performObservedRefresh(
        _ request: AppDetailRefreshRequest
    ) async throws -> AppDetailRefreshResult {
        guard let refreshMetricsRecorder else {
            return try await performRefresh(request)
        }

        let runID = await refreshMetricsRecorder.begin(
            trigger: RefreshObservationTrigger(rawValueForObservation: request.trigger),
            workspace: RefreshObservationWorkspace(request.workspace),
            requestedTrackCount: request.trackIdentityKeys.count,
            requestedStorefrontCount: Set(request.storefrontSelection.codes.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }).count
        )
        do {
            try Task.checkCancellation()
            let result = try await RefreshObservationScope.$runID.withValue(runID) {
                try await performRefresh(request)
            }
            await refreshMetricsRecorder.finish(runID: runID)
            return result
        } catch {
            if Task.isCancelled {
                await refreshMetricsRecorder.recordCancellation(runID: runID)
            }
            await refreshMetricsRecorder.finish(runID: runID)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func performRefresh(
        _ request: AppDetailRefreshRequest
    ) async throws -> AppDetailRefreshResult {
        let refreshID = await progressStore?.beginRefresh(request)
        return try await AppRefreshProgressScope.$refreshID.withValue(refreshID) {
            do {
                try Task.checkCancellation()
                let keywordRefreshResult: KeywordRefreshResult
                let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
                let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]

                switch request.workspace {
                case .keywords:
                    keywordRefreshResult = try await refreshKeywords(request)
                    if request.refreshRatings || request.refreshReviews {
                        (ratingOutcomes, reviewOutcomes) = try await refreshRatingsAndReviews(request)
                    } else {
                        await recordStage(.ratings, attemptedCount: 0, failureCount: 0, isSkipped: true)
                        await recordStage(.reviews, attemptedCount: 0, failureCount: 0, isSkipped: true)
                        ratingOutcomes = []
                        reviewOutcomes = []
                    }
                case .ratings:
                    if request.refreshRatings || request.refreshReviews {
                        (ratingOutcomes, reviewOutcomes) = try await refreshRatingsAndReviews(request)
                    } else {
                        await recordStage(.ratings, attemptedCount: 0, failureCount: 0, isSkipped: true)
                        await recordStage(.reviews, attemptedCount: 0, failureCount: 0, isSkipped: true)
                        ratingOutcomes = []
                        reviewOutcomes = []
                    }
                    keywordRefreshResult = try await refreshKeywords(request)
                }

                try Task.checkCancellation()
                let firstError = firstRefreshError(
                    workspace: request.workspace,
                    keywordOutcomes: keywordRefreshResult.outcomes,
                    keywordMetricsError: keywordRefreshResult.metricsError,
                    ratingOutcomes: ratingOutcomes,
                    reviewOutcomes: reviewOutcomes
                )
                await progressStore?.updatePhase(.finishing)
                if let refreshID {
                    await progressStore?.finish(refreshID: refreshID, error: firstError)
                }

                return AppDetailRefreshResult(
                    keywordOutcomes: keywordRefreshResult.outcomes,
                    ratingOutcomes: ratingOutcomes,
                    reviewOutcomes: reviewOutcomes,
                    firstError: firstError
                )
            } catch {
                if Task.isCancelled {
                    if let refreshID {
                        await progressStore?.cancelRefresh(refreshID: refreshID)
                    }
                    throw CancellationError()
                }

                let mappedError = OpenASOError.map(error)
                if let refreshID {
                    await progressStore?.finish(refreshID: refreshID, error: mappedError)
                }
                return AppDetailRefreshResult(
                    keywordOutcomes: [],
                    ratingOutcomes: [],
                    reviewOutcomes: [],
                    firstError: mappedError
                )
            }
        }
    }

    private func refreshKeywords(
        _ request: AppDetailRefreshRequest
    ) async throws -> KeywordRefreshResult {
        try Task.checkCancellation()
        guard request.refreshKeywords, !request.trackIdentityKeys.isEmpty else {
            await progressStore?.updateStep(.keywords, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await progressStore?.updateStep(.metrics, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await recordStage(.rankings, attemptedCount: 0, failureCount: 0, isSkipped: true)
            await recordStage(.keywordMetrics, attemptedCount: 0, failureCount: 0, isSkipped: true)
            try Task.checkCancellation()
            return KeywordRefreshResult(outcomes: [], metricsError: nil)
        }

        var didRecordRankingStage = false
        var didRecordMetricsStage = false
        do {
            await progressStore?.updatePhase(.refreshingKeywords)
            let (rankingRequests, missingOutcomes) = try await backgroundModelStore.read { modelContext in
                try Task.checkCancellation()
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
            try Task.checkCancellation()

            let missingFailureCount = missingOutcomes.count
            let rankingRequestGroups = RankingRequestGroup.normalizedGroups(for: rankingRequests)
            await recordRankingWork(
                resolvedCount: rankingRequests.count,
                uniqueQueryCount: rankingRequestGroups.count,
                missingCount: missingFailureCount
            )
            if rankingRequests.isEmpty {
                await progressStore?.updateStep(
                    .keywords,
                    status: missingFailureCount > 0 ? .failed : .skipped,
                    completed: missingFailureCount,
                    total: request.trackIdentityKeys.count,
                    failureCount: missingFailureCount
                )
            }

            let keywordOutcomes = try await refreshRankings(
                rankingRequestGroups,
                trigger: request.trigger,
                missingFailureCount: missingFailureCount,
                totalRequestedCount: request.trackIdentityKeys.count
            )
            let combinedKeywordOutcomes = missingOutcomes + keywordOutcomes
            await recordStage(
                .rankings,
                attemptedCount: combinedKeywordOutcomes.count,
                failureCount: combinedKeywordOutcomes.filter { $0.error != nil }.count
            )
            didRecordRankingStage = true
            try Task.checkCancellation()

            let metricsError: OpenASOError?
            if request.refreshMetrics {
                await progressStore?.updatePhase(.refreshingMetrics)
                do {
                    try Task.checkCancellation()
                    let metricResult = try await keywordMetricsService.refreshMetricsBatch(
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
                    await recordStage(
                        .keywordMetrics,
                        attemptedCount: metricResult.outcomes.count,
                        failureCount: metricResult.failureCount
                    )
                    try Task.checkCancellation()
                    metricsError = metricResult.firstErrorMessage.map(OpenASOError.providerUnavailable)
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    let mappedError = OpenASOError.map(error)
                    let attemptedCount = rankingRequests.count
                    await progressStore?.updateStep(
                        .metrics,
                        status: .failed,
                        completed: attemptedCount,
                        total: attemptedCount,
                        failureCount: attemptedCount > 0 ? 1 : 0
                    )
                    await recordStage(
                        .keywordMetrics,
                        attemptedCount: attemptedCount,
                        failureCount: attemptedCount > 0 ? 1 : 0
                    )
                    metricsError = mappedError
                }
                didRecordMetricsStage = true
            } else {
                await progressStore?.updateStep(.metrics, status: .skipped, completed: 0, total: 0, failureCount: 0)
                await recordStage(.keywordMetrics, attemptedCount: 0, failureCount: 0, isSkipped: true)
                didRecordMetricsStage = true
                metricsError = nil
            }

            try Task.checkCancellation()
            return KeywordRefreshResult(
                outcomes: combinedKeywordOutcomes,
                metricsError: metricsError
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let mappedError = OpenASOError.map(error)
            await progressStore?.updateStep(
                .keywords,
                status: .failed,
                completed: request.trackIdentityKeys.count,
                total: request.trackIdentityKeys.count,
                failureCount: request.trackIdentityKeys.count
            )
            if !didRecordRankingStage {
                await recordStage(
                    .rankings,
                    attemptedCount: request.trackIdentityKeys.count,
                    failureCount: request.trackIdentityKeys.count
                )
            }
            if !didRecordMetricsStage {
                await recordStage(
                    .keywordMetrics,
                    attemptedCount: request.refreshMetrics ? request.trackIdentityKeys.count : 0,
                    failureCount: request.refreshMetrics ? request.trackIdentityKeys.count : 0,
                    isSkipped: !request.refreshMetrics
                )
            }
            return KeywordRefreshResult(
                outcomes: request.trackIdentityKeys.map {
                    KeywordBackgroundRefreshOutcome(trackIdentityKey: $0, error: mappedError)
                },
                metricsError: nil
            )
        }
    }

    private func refreshRankings(
        _ requestGroups: [RankingRequestGroup],
        trigger: String,
        missingFailureCount: Int,
        totalRequestedCount: Int
    ) async throws -> [KeywordBackgroundRefreshOutcome] {
        try Task.checkCancellation()
        guard !requestGroups.isEmpty else { return [] }

        let resolvedTrackCount = requestGroups.reduce(into: 0) { count, group in
            count += group.targetRequests.count
        }

        if trigger == "daily_refresh" {
            await refreshCoordinator.recordRefreshTriggered()
        }
        let rankingPageFetcher = await refreshCoordinator.makeRankingPageFetcher()
        await refreshCoordinator.captureKeywordRefreshStarted(trigger: trigger, trackCount: resolvedTrackCount)
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
        var completedCount = 0
        var failureCount = 0

        func flushPendingPageResults() async throws {
            guard !pendingPageResults.isEmpty else { return }

            try Task.checkCancellation()
            let pageResults = pendingPageResults
            pendingPageResults.removeAll(keepingCapacity: true)
            let batchOutcome = try await persistRankingPageBatch(pageResults)
            outcomes.append(contentsOf: batchOutcome.outcomes)
            statsRebuildRequests.formUnion(batchOutcome.statsRebuildRequests)
            failureCount += batchOutcome.failureCount
            for pageResult in batchOutcome.successfulPageResults {
                try Task.checkCancellation()
                refreshCoordinator.scheduleTopRankingMetadataEnrichment(for: pageResult)
            }
        }

        try await withThrowingTaskGroup(
            of: (RankingRequestGroup, Result<RankingRefreshPageResult, OpenASOError>).self
        ) { group in
            var nextRequestGroupIndex = 0
            var activeFetchCount = 0

            func enqueueNextFetchIfPossible() {
                guard activeFetchCount < Self.rankingFetchConcurrency,
                      nextRequestGroupIndex < requestGroups.count else {
                    return
                }

                let requestGroup = requestGroups[nextRequestGroupIndex]
                guard group.addTaskUnlessCancelled(operation: {
                    try Task.checkCancellation()
                    let result = await rankingPageFetcher(requestGroup.providerRequest)
                    try Task.checkCancellation()
                    return (requestGroup, result)
                }) else {
                    return
                }
                nextRequestGroupIndex += 1
                activeFetchCount += 1
            }

            for _ in 0..<min(Self.rankingFetchConcurrency, requestGroups.count) {
                enqueueNextFetchIfPossible()
            }

            while let (requestGroup, result) = try await group.next() {
                try Task.checkCancellation()
                activeFetchCount -= 1

                switch result {
                case .success(let pageResult):
                    for targetPageResult in requestGroup.pageResults(fanningOut: pageResult) {
                        pendingPageResults.append(targetPageResult)
                        if pendingPageResults.count >= Self.rankingPersistenceBatchSize {
                            try await flushPendingPageResults()
                        }
                    }
                case .failure(let error):
                    for targetRequest in requestGroup.targetRequests {
                        try Task.checkCancellation()
                        do {
                            try await backgroundModelStore.write { modelContext in
                                try Task.checkCancellation()
                                _ = try refreshCoordinator.recordRefreshFailure(
                                    identityKey: targetRequest.identityKey,
                                    error: error,
                                    in: modelContext,
                                    saveChanges: false
                                )
                            }
                            try Task.checkCancellation()
                        } catch {
                            if Task.isCancelled {
                                throw CancellationError()
                            }
                        }
                        outcomes.append(KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: targetRequest.identityKey,
                            error: error
                        ))
                    }
                    failureCount += requestGroup.targetRequests.count
                }

                completedCount += requestGroup.targetRequests.count
                await progressStore?.updateStep(
                    .keywords,
                    status: completedCount >= resolvedTrackCount
                        ? (failureCount + missingFailureCount > 0 ? .failed : .completed)
                        : .running,
                    completed: completedCount + missingFailureCount,
                    total: totalRequestedCount,
                    failureCount: failureCount + missingFailureCount
                )
                try Task.checkCancellation()

                enqueueNextFetchIfPossible()
            }
        }

        try Task.checkCancellation()
        try await flushPendingPageResults()
        await progressStore?.updateStep(
            .keywords,
            status: failureCount + missingFailureCount > 0 ? .failed : .completed,
            completed: completedCount + missingFailureCount,
            total: totalRequestedCount,
            failureCount: failureCount + missingFailureCount
        )

        if !statsRebuildRequests.isEmpty {
            try Task.checkCancellation()
            let requests = statsRebuildRequests
            do {
                try await backgroundModelStore.write { modelContext in
                    try Task.checkCancellation()
                    refreshCoordinator.rebuildDerivedStats(for: requests, in: modelContext)
                }
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
            }
        }

        try Task.checkCancellation()
        await refreshCoordinator.captureKeywordRefreshCompleted(
            trigger: trigger,
            trackCount: resolvedTrackCount,
            failureCount: outcomes.filter { $0.error != nil }.count
        )
        try Task.checkCancellation()
        return outcomes
    }

    private func persistRankingPageBatch(
        _ pageResults: [RankingRefreshPageResult]
    ) async throws -> RankingPersistenceBatchOutcome {
        try Task.checkCancellation()
        do {
            let outcome = try await backgroundModelStore.write { modelContext in
                try Task.checkCancellation()
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
            try Task.checkCancellation()
            return outcome
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let mappedError = OpenASOError.map(error)
            do {
                try await backgroundModelStore.write { modelContext in
                    try Task.checkCancellation()
                    for pageResult in pageResults {
                        _ = try? refreshCoordinator.recordRefreshFailure(
                            identityKey: pageResult.request.identityKey,
                            error: mappedError,
                            in: modelContext,
                            saveChanges: false
                        )
                    }
                }
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
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
    ) async throws -> ([AppStorefrontRatingRefreshOutcome], [AppStorefrontReviewRefreshOutcome]) {
        try Task.checkCancellation()
        guard request.refreshRatings || request.refreshReviews else {
            await progressStore?.updateStep(.ratings, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await progressStore?.updateStep(.reviews, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await recordStage(.ratings, attemptedCount: 0, failureCount: 0, isSkipped: true)
            await recordStage(.reviews, attemptedCount: 0, failureCount: 0, isSkipped: true)
            return ([], [])
        }

        var didRecordRatingsStage = false
        var didRecordReviewsStage = false
        do {
            let storefrontCodes = request.storefrontSelection.codes
            let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
            if request.refreshRatings {
                await progressStore?.updatePhase(.refreshingRatings)
                ratingOutcomes = try await appStorefrontRatingService.fetchRatingOutcomes(
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
                try Task.checkCancellation()
                try await persistRatingOutcomes(ratingOutcomes, for: request.app)
                await recordStage(
                    .ratings,
                    attemptedCount: ratingOutcomes.count,
                    failureCount: ratingOutcomes.filter { $0.error != nil }.count
                )
                didRecordRatingsStage = true
                try Task.checkCancellation()
            } else {
                await progressStore?.updateStep(.ratings, status: .skipped, completed: 0, total: 0, failureCount: 0)
                await recordStage(.ratings, attemptedCount: 0, failureCount: 0, isSkipped: true)
                didRecordRatingsStage = true
                ratingOutcomes = []
            }

            let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
            if request.refreshReviews {
                try Task.checkCancellation()
                await progressStore?.updatePhase(.refreshingReviews)
                reviewOutcomes = try await refreshReviews(
                    request: request,
                    storefrontCodes: storefrontCodes
                )
                await recordStage(
                    .reviews,
                    attemptedCount: reviewOutcomes.count,
                    failureCount: reviewOutcomes.filter { $0.error != nil }.count
                )
                didRecordReviewsStage = true
            } else {
                await progressStore?.updateStep(.reviews, status: .skipped, completed: 0, total: 0, failureCount: 0)
                await recordStage(.reviews, attemptedCount: 0, failureCount: 0, isSkipped: true)
                didRecordReviewsStage = true
                reviewOutcomes = []
            }
            let outcomes = (ratingOutcomes, reviewOutcomes)
            if request.recordsRatingsReviewsRefresh, didSuccessfullyRefreshRatingsOrReviews(outcomes) {
                try Task.checkCancellation()
                await ratingsReviewsRefreshRecorder?(.now)
                try Task.checkCancellation()
            }
            return outcomes
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let mappedError = OpenASOError.map(error)
            let storefrontCount = Set(request.storefrontSelection.codes.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }).count
            await progressStore?.updateStep(
                .ratings,
                status: .failed,
                completed: request.storefrontSelection.codes.count,
                total: request.storefrontSelection.codes.count,
                failureCount: max(1, request.storefrontSelection.codes.count)
            )
            if !didRecordRatingsStage {
                let attemptedCount = request.refreshRatings ? max(1, storefrontCount) : 0
                await recordStage(
                    .ratings,
                    attemptedCount: attemptedCount,
                    failureCount: attemptedCount,
                    isSkipped: !request.refreshRatings
                )
            }
            if !didRecordReviewsStage {
                let attemptedCount = request.refreshReviews ? max(1, storefrontCount) : 0
                await recordStage(
                    .reviews,
                    attemptedCount: attemptedCount,
                    failureCount: attemptedCount,
                    isSkipped: !request.refreshReviews
                )
            }
            let ratingOutcome = AppStorefrontRatingRefreshOutcome(
                storefront: "all",
                result: nil,
                error: mappedError
            )
            return ([ratingOutcome], [])
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
        try Task.checkCancellation()
        guard
            request.appStoreConnectCredentials.isComplete,
            let bundleID = request.app.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty
        else {
            return try await refreshStorefrontReviews(request: request, storefrontCodes: storefrontCodes)
        }

        do {
            await progressStore?.updateStep(.reviews, status: .running, completed: 0, total: 1, failureCount: 0)
            try Task.checkCancellation()
            let app = try await appStoreConnectReviewService.resolveApp(
                bundleID: bundleID,
                using: request.appStoreConnectCredentials
            )
            try Task.checkCancellation()
            var storedCount = 0
            try Task.checkCancellation()
            let fetchedCount = try await appStoreConnectReviewService.fetchReviewPages(
                appStoreConnectAppID: app.id,
                appStoreID: request.app.appStoreID,
                credentials: request.appStoreConnectCredentials,
            ) { pageReviews in
                try Task.checkCancellation()
                let pageStoredCount = try await backgroundModelStore.write { modelContext in
                    try Task.checkCancellation()
                    let storeApp = try storeApp(for: request.app, in: modelContext)
                    return try appStoreConnectReviewService.upsert(pageReviews, storeApp: storeApp, in: modelContext)
                }
                try Task.checkCancellation()
                storedCount += pageStoredCount
                return pageStoredCount == pageReviews.count
            }
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            return try await refreshStorefrontReviews(request: request, storefrontCodes: storefrontCodes)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
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
        try Task.checkCancellation()
        try await backgroundModelStore.write { modelContext in
            try Task.checkCancellation()
            let storeApp = try storeApp(for: app, in: modelContext)
            for outcome in outcomes {
                appStorefrontRatingService.persist(outcome, for: storeApp, in: modelContext)
            }
        }
        try Task.checkCancellation()
    }

    private func refreshStorefrontReviews(
        request: AppDetailRefreshRequest,
        storefrontCodes: [String]
    ) async throws -> [AppStorefrontReviewRefreshOutcome] {
        try Task.checkCancellation()
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

        for storefront in targetStorefronts {
            try Task.checkCancellation()
            do {
                var storedCount = 0
                let fetchedCount = try await appStorefrontReviewService.fetchReviewPages(
                    appStoreID: request.app.appStoreID,
                    storefront: storefront
                ) { pageReviews in
                    try Task.checkCancellation()
                    let pageStoredCount = try await backgroundModelStore.write { modelContext in
                        try Task.checkCancellation()
                        let storeApp = try storeApp(for: request.app, in: modelContext)
                        return try appStorefrontReviewService.upsert(
                            pageReviews,
                            storeApp: storeApp,
                            in: modelContext
                        )
                    }
                    try Task.checkCancellation()
                    storedCount += pageStoredCount
                    return pageStoredCount == pageReviews.count
                }
                try Task.checkCancellation()
                outcomes.append(AppStorefrontReviewRefreshOutcome(
                    storefront: storefront,
                    fetchedReviews: fetchedCount,
                    storedReviews: storedCount,
                    error: nil
                ))
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                failureCount += 1
                outcomes.append(AppStorefrontReviewRefreshOutcome(
                    storefront: storefront,
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: OpenASOError.map(error)
                ))
            }

            completedCount += 1
            await progressStore?.updateStep(
                .reviews,
                status: completedCount >= targetStorefronts.count ? (failureCount > 0 ? .failed : .completed) : .running,
                completed: completedCount,
                total: targetStorefronts.count,
                failureCount: failureCount
            )
            try Task.checkCancellation()
        }

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

    private func recordRankingWork(
        resolvedCount: Int,
        uniqueQueryCount: Int,
        missingCount: Int
    ) async {
        guard let runID = RefreshObservationScope.runID, let refreshMetricsRecorder else { return }
        await refreshMetricsRecorder.recordRankingWork(
            runID: runID,
            resolvedCount: resolvedCount,
            uniqueQueryCount: uniqueQueryCount,
            missingCount: missingCount
        )
    }

    private func recordStage(
        _ stage: RefreshObservationStage,
        attemptedCount: Int,
        failureCount: Int,
        isSkipped: Bool = false
    ) async {
        guard let runID = RefreshObservationScope.runID, let refreshMetricsRecorder else { return }
        await refreshMetricsRecorder.recordStage(
            runID: runID,
            stage: stage,
            attemptedCount: attemptedCount,
            failureCount: failureCount,
            isSkipped: isSkipped
        )
    }

    private func firstRefreshError(
        workspace: AppDetailRefreshWorkspace,
        keywordOutcomes: [KeywordBackgroundRefreshOutcome],
        keywordMetricsError: OpenASOError?,
        ratingOutcomes: [AppStorefrontRatingRefreshOutcome],
        reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
    ) -> OpenASOError? {
        let keywordError = keywordOutcomes.first(where: { $0.error != nil })?.error
        let ratingError = ratingOutcomes.first(where: { $0.error != nil })?.error
        let reviewError = reviewOutcomes.first(where: { $0.error != nil })?.error

        switch workspace {
        case .keywords:
            return keywordError ?? keywordMetricsError ?? ratingError ?? reviewError
        case .ratings:
            return ratingError ?? reviewError ?? keywordError ?? keywordMetricsError
        }
    }
}
