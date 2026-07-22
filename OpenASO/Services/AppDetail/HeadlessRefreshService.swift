import Foundation

struct HeadlessRefreshRunRequest: Hashable, Sendable {
    let id: UUID
    let scheduledFor: Date
    let refreshRatingsAndReviews: Bool

    init(
        id: UUID = UUID(),
        scheduledFor: Date,
        refreshRatingsAndReviews: Bool
    ) {
        self.id = id
        self.scheduledFor = scheduledFor
        self.refreshRatingsAndReviews = refreshRatingsAndReviews
    }
}

enum HeadlessRefreshRunDisposition: String, Hashable, Sendable {
    case noWork
    case success
    case partialFailure
    case failure
    case cancelled
    case skippedAlreadyRunning
    case rejectedRequestConflict
}

enum HeadlessRefreshAppDisposition: String, Hashable, Sendable {
    case success
    case partialFailure
    case failure
    case cancelled
}

struct HeadlessRefreshIssue: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case planUnavailable
        case appRefreshFailed
        case requestIdentityConflict
    }

    let kind: Kind

    var title: String {
        switch kind {
        case .planUnavailable:
            "Refresh plan unavailable"
        case .appRefreshFailed:
            "App refresh failed"
        case .requestIdentityConflict:
            "Refresh request rejected"
        }
    }

    var message: String {
        switch kind {
        case .planUnavailable:
            "The automatic refresh plan could not be prepared."
        case .appRefreshFailed:
            "One app could not complete its automatic refresh."
        case .requestIdentityConflict:
            "A refresh request reused an existing run identifier with different settings."
        }
    }
}

struct HeadlessRefreshAppExecutionResult: Hashable, Sendable {
    let disposition: HeadlessRefreshAppDisposition
    let ratingsReviewsAttempted: Bool
    let ratingsReviewsFullySucceeded: Bool
    let issue: HeadlessRefreshIssue?

    init(
        disposition: HeadlessRefreshAppDisposition,
        ratingsReviewsAttempted: Bool = false,
        ratingsReviewsFullySucceeded: Bool = false,
        issue: HeadlessRefreshIssue? = nil
    ) {
        precondition(!ratingsReviewsFullySucceeded || ratingsReviewsAttempted)
        self.disposition = disposition
        self.ratingsReviewsAttempted = ratingsReviewsAttempted
        self.ratingsReviewsFullySucceeded = ratingsReviewsFullySucceeded
        self.issue = issue
    }

    static func succeeded(
        ratingsReviewsAttempted: Bool = false
    ) -> Self {
        Self(
            disposition: .success,
            ratingsReviewsAttempted: ratingsReviewsAttempted,
            ratingsReviewsFullySucceeded: ratingsReviewsAttempted
        )
    }
}

enum HeadlessRefreshAppStageDisposition: Hashable, Sendable {
    case success
    case partialFailure
    case failure
}

enum HeadlessRefreshAppResultAdapter {
    static func map(
        metadataStatus: AppMetadataRefreshStatus,
        detailResult: AppDetailRefreshResult?,
        request: AppDetailRefreshRequest
    ) -> HeadlessRefreshAppExecutionResult {
        let ratingsAttempted = request.refreshRatings
            && !(detailResult?.ratingOutcomes.isEmpty ?? true)
        let reviewsAttempted = request.refreshReviews
            && !(detailResult?.reviewOutcomes.isEmpty ?? true)
        let ratingsReviewsAttempted = ratingsAttempted || reviewsAttempted
        let ratingsReviewsFullySucceeded = ratingsReviewsAttempted
            && (!request.refreshRatings || (
                ratingsAttempted
                    && detailResult?.ratingOutcomes.allSatisfy { $0.error == nil } == true
            ))
            && (!request.refreshReviews || (
                reviewsAttempted
                    && detailResult?.reviewOutcomes.allSatisfy { $0.error == nil } == true
            ))

        if detailResult?.wasCancelled == true {
            return HeadlessRefreshAppExecutionResult(
                disposition: .cancelled,
                ratingsReviewsAttempted: ratingsReviewsAttempted,
                ratingsReviewsFullySucceeded: false
            )
        }

        let metadataDisposition = switch metadataStatus {
        case .succeeded:
            HeadlessRefreshAppStageDisposition.success
        case .partial:
            HeadlessRefreshAppStageDisposition.partialFailure
        case .failed:
            HeadlessRefreshAppStageDisposition.failure
        }
        let detailDisposition: HeadlessRefreshAppStageDisposition = detailResult.map {
            Self.detailDisposition(for: $0, request: request)
        } ?? .failure
        let disposition: HeadlessRefreshAppDisposition
        switch (metadataDisposition, detailDisposition) {
        case (.success, .success):
            disposition = .success
        case (.failure, .failure):
            disposition = .failure
        default:
            disposition = .partialFailure
        }

        return HeadlessRefreshAppExecutionResult(
            disposition: disposition,
            ratingsReviewsAttempted: ratingsReviewsAttempted,
            ratingsReviewsFullySucceeded: ratingsReviewsFullySucceeded,
            issue: disposition == .success ? nil : HeadlessRefreshIssue(kind: .appRefreshFailed)
        )
    }

    private static func detailDisposition(
        for result: AppDetailRefreshResult,
        request: AppDetailRefreshRequest
    ) -> HeadlessRefreshAppStageDisposition {
        let isMissingRequestedOutcome =
            (request.refreshRatings && result.ratingOutcomes.isEmpty)
            || (request.refreshReviews && result.reviewOutcomes.isEmpty)
        guard result.firstError != nil || isMissingRequestedOutcome else {
            return .success
        }
        let hasSuccessfulOutcome = result.keywordOutcomes.contains { $0.error == nil }
            || result.ratingOutcomes.contains { $0.error == nil }
            || result.reviewOutcomes.contains { $0.error == nil }
        return hasSuccessfulOutcome ? .partialFailure : .failure
    }
}

struct HeadlessRefreshAppAdapter: Sendable {
    typealias MetadataRefresher = @Sendable (
        _ request: AppMetadataRefreshRequest
    ) async throws -> AppMetadataRefreshResult
    typealias DetailRefresher = @Sendable (
        _ request: AppDetailRefreshRequest
    ) async throws -> AppDetailRefreshResult

    private let refreshMetadata: MetadataRefresher
    private let refreshDetail: DetailRefresher

    init(
        refreshMetadata: @escaping MetadataRefresher,
        refreshDetail: @escaping DetailRefresher
    ) {
        self.refreshMetadata = refreshMetadata
        self.refreshDetail = refreshDetail
    }

    func refresh(
        _ plan: HeadlessRefreshAppPlan
    ) async throws -> HeadlessRefreshAppExecutionResult {
        try Task.checkCancellation()
        let metadataStatus: AppMetadataRefreshStatus
        do {
            metadataStatus = try await refreshMetadata(plan.metadataRequest).status
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            metadataStatus = .failed
        }

        try Task.checkCancellation()
        let detailResult: AppDetailRefreshResult?
        do {
            let result = try await refreshDetail(plan.appDetailRequest)
            if result.wasCancelled {
                throw CancellationError()
            }
            detailResult = result
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            detailResult = nil
        }
        try Task.checkCancellation()

        return HeadlessRefreshAppResultAdapter.map(
            metadataStatus: metadataStatus,
            detailResult: detailResult,
            request: plan.appDetailRequest
        )
    }
}

struct HeadlessRefreshRunSummary: Hashable, Sendable {
    let runID: UUID
    let activeRunID: UUID?
    let scheduledFor: Date
    let startedAt: Date
    let finishedAt: Date
    let disposition: HeadlessRefreshRunDisposition
    let plannedAppCount: Int
    let completedAppCount: Int
    let successfulAppCount: Int
    let partialFailureAppCount: Int
    let failedAppCount: Int
    let ratingsReviewsAttempted: Bool
    let ratingsReviewsFullySucceeded: Bool
    let issue: HeadlessRefreshIssue?
}

enum HeadlessRefreshRunPhase: String, Hashable, Sendable {
    case planning
    case refreshing
    case finishing
}

struct HeadlessRefreshActiveSnapshot: Hashable, Sendable {
    let runID: UUID
    let scheduledFor: Date
    let startedAt: Date
    let phase: HeadlessRefreshRunPhase
    let plannedAppCount: Int?
    let completedAppCount: Int
    let currentAppStoreID: Int64?
}

struct HeadlessRefreshSnapshot: Hashable, Sendable {
    let activeRun: HeadlessRefreshActiveSnapshot?
    let recentRuns: [HeadlessRefreshRunSummary]
}

enum HeadlessRefreshEvent: Hashable, Sendable {
    case runStarted(runID: UUID, scheduledFor: Date, startedAt: Date)
    case planLoaded(runID: UUID, plannedAppCount: Int)
    case appStarted(
        runID: UUID,
        appStoreID: Int64,
        position: Int,
        total: Int
    )
    case appFinished(
        runID: UUID,
        appStoreID: Int64,
        position: Int,
        total: Int,
        disposition: HeadlessRefreshAppDisposition
    )
    case runFinished(HeadlessRefreshRunSummary)
    case runSkipped(requestRunID: UUID, activeRunID: UUID, at: Date)
    case completedRunReused(
        requestRunID: UUID,
        priorDisposition: HeadlessRefreshRunDisposition,
        at: Date
    )
    case runRejected(requestRunID: UUID, at: Date)
}

struct HeadlessRefreshDependencies: Sendable {
    let loadPlan: @Sendable (
        _ request: HeadlessRefreshRunRequest
    ) async throws -> HeadlessRefreshPlan
    let refreshApp: @Sendable (
        _ plan: HeadlessRefreshAppPlan
    ) async throws -> HeadlessRefreshAppExecutionResult
    let now: @Sendable () -> Date
    let recordEvent: @Sendable (_ event: HeadlessRefreshEvent) async -> Void

    init(
        loadPlan: @escaping @Sendable (
            _ request: HeadlessRefreshRunRequest
        ) async throws -> HeadlessRefreshPlan,
        refreshApp: @escaping @Sendable (
            _ plan: HeadlessRefreshAppPlan
        ) async throws -> HeadlessRefreshAppExecutionResult,
        now: @escaping @Sendable () -> Date = { .now },
        recordEvent: @escaping @Sendable (
            _ event: HeadlessRefreshEvent
        ) async -> Void = { _ in }
    ) {
        self.loadPlan = loadPlan
        self.refreshApp = refreshApp
        self.now = now
        self.recordEvent = recordEvent
    }
}

actor HeadlessRefreshService {
    private struct ActiveRun {
        let request: HeadlessRefreshRunRequest
        let startedAt: Date
        var phase: HeadlessRefreshRunPhase
        var plannedAppCount: Int?
        var appResults: [HeadlessRefreshAppExecutionResult]
        var currentAppStoreID: Int64?

        var snapshot: HeadlessRefreshActiveSnapshot {
            HeadlessRefreshActiveSnapshot(
                runID: request.id,
                scheduledFor: request.scheduledFor,
                startedAt: startedAt,
                phase: phase,
                plannedAppCount: plannedAppCount,
                completedAppCount: appResults.count,
                currentAppStoreID: currentAppStoreID
            )
        }
    }

    private struct CompletedRun {
        let request: HeadlessRefreshRunRequest
        let summary: HeadlessRefreshRunSummary
    }

    private let dependencies: HeadlessRefreshDependencies
    private let recentRunLimit: Int
    private var activeRun: ActiveRun?
    private var recentRuns: [HeadlessRefreshRunSummary] = []
    private var completedRunsByID: [UUID: CompletedRun] = [:]

    init(
        recentRunLimit: Int = 10,
        dependencies: HeadlessRefreshDependencies
    ) {
        precondition(recentRunLimit > 0)
        self.recentRunLimit = recentRunLimit
        self.dependencies = dependencies
    }

    func snapshot() -> HeadlessRefreshSnapshot {
        HeadlessRefreshSnapshot(
            activeRun: activeRun?.snapshot,
            recentRuns: recentRuns
        )
    }

    func run(_ request: HeadlessRefreshRunRequest) async -> HeadlessRefreshRunSummary {
        if let completedRun = completedRunsByID[request.id] {
            guard completedRun.request == request else {
                return await rejectConflictingRequest(request)
            }
            await dependencies.recordEvent(.completedRunReused(
                requestRunID: request.id,
                priorDisposition: completedRun.summary.disposition,
                at: dependencies.now()
            ))
            return completedRun.summary
        }

        if let activeRun {
            guard activeRun.request.id != request.id || activeRun.request == request else {
                return await rejectConflictingRequest(request)
            }
            let now = dependencies.now()
            let summary = HeadlessRefreshRunSummary(
                runID: request.id,
                activeRunID: activeRun.request.id,
                scheduledFor: request.scheduledFor,
                startedAt: now,
                finishedAt: now,
                disposition: .skippedAlreadyRunning,
                plannedAppCount: 0,
                completedAppCount: 0,
                successfulAppCount: 0,
                partialFailureAppCount: 0,
                failedAppCount: 0,
                ratingsReviewsAttempted: false,
                ratingsReviewsFullySucceeded: false,
                issue: nil
            )
            await dependencies.recordEvent(.runSkipped(
                requestRunID: request.id,
                activeRunID: activeRun.request.id,
                at: now
            ))
            return summary
        }

        let startedAt = dependencies.now()
        activeRun = ActiveRun(
            request: request,
            startedAt: startedAt,
            phase: .planning,
            plannedAppCount: nil,
            appResults: [],
            currentAppStoreID: nil
        )
        await dependencies.recordEvent(.runStarted(
            runID: request.id,
            scheduledFor: request.scheduledFor,
            startedAt: startedAt
        ))

        do {
            try Task.checkCancellation()
            let plan = try await dependencies.loadPlan(request)
            try Task.checkCancellation()
            updateActiveRun(id: request.id) { activeRun in
                activeRun.phase = .refreshing
                activeRun.plannedAppCount = plan.apps.count
            }
            await dependencies.recordEvent(.planLoaded(
                runID: request.id,
                plannedAppCount: plan.apps.count
            ))
            try Task.checkCancellation()

            for (offset, appPlan) in plan.apps.enumerated() {
                try Task.checkCancellation()
                let position = offset + 1
                updateActiveRun(id: request.id) { activeRun in
                    activeRun.currentAppStoreID = appPlan.appStoreID
                }
                await dependencies.recordEvent(.appStarted(
                    runID: request.id,
                    appStoreID: appPlan.appStoreID,
                    position: position,
                    total: plan.apps.count
                ))
                do {
                    try Task.checkCancellation()
                } catch {
                    await dependencies.recordEvent(.appFinished(
                        runID: request.id,
                        appStoreID: appPlan.appStoreID,
                        position: position,
                        total: plan.apps.count,
                        disposition: .cancelled
                    ))
                    throw error
                }

                let result: HeadlessRefreshAppExecutionResult
                do {
                    result = try await dependencies.refreshApp(appPlan)
                } catch {
                    if Self.isCancellation(error) {
                        await dependencies.recordEvent(.appFinished(
                            runID: request.id,
                            appStoreID: appPlan.appStoreID,
                            position: position,
                            total: plan.apps.count,
                            disposition: .cancelled
                        ))
                        throw CancellationError()
                    }
                    result = HeadlessRefreshAppExecutionResult(
                        disposition: .failure,
                        issue: HeadlessRefreshIssue(kind: .appRefreshFailed)
                    )
                }

                if result.disposition == .cancelled {
                    await dependencies.recordEvent(.appFinished(
                        runID: request.id,
                        appStoreID: appPlan.appStoreID,
                        position: position,
                        total: plan.apps.count,
                        disposition: .cancelled
                    ))
                    throw CancellationError()
                }

                updateActiveRun(id: request.id) { activeRun in
                    activeRun.appResults.append(result)
                    activeRun.currentAppStoreID = nil
                }
                await dependencies.recordEvent(.appFinished(
                    runID: request.id,
                    appStoreID: appPlan.appStoreID,
                    position: position,
                    total: plan.apps.count,
                    disposition: result.disposition
                ))
                try Task.checkCancellation()
            }

            return await finish(
                request: request,
                startedAt: startedAt,
                plannedAppCount: plan.apps.count,
                disposition: Self.completedDisposition(
                    plannedAppCount: plan.apps.count,
                    results: activeRun?.appResults ?? []
                ),
                issue: activeRun?.appResults.compactMap(\.issue).first
            )
        } catch {
            let cancelled = Self.isCancellation(error)
            return await finish(
                request: request,
                startedAt: startedAt,
                plannedAppCount: activeRun?.plannedAppCount ?? 0,
                disposition: cancelled ? .cancelled : .failure,
                issue: cancelled ? nil : HeadlessRefreshIssue(kind: .planUnavailable)
            )
        }
    }

    private func updateActiveRun(
        id: UUID,
        _ update: (inout ActiveRun) -> Void
    ) {
        guard var run = activeRun, run.request.id == id else { return }
        update(&run)
        activeRun = run
    }

    private func finish(
        request: HeadlessRefreshRunRequest,
        startedAt: Date,
        plannedAppCount: Int,
        disposition: HeadlessRefreshRunDisposition,
        issue: HeadlessRefreshIssue?
    ) async -> HeadlessRefreshRunSummary {
        let results = activeRun?.request.id == request.id
            ? activeRun?.appResults ?? []
            : []
        updateActiveRun(id: request.id) { activeRun in
            activeRun.phase = .finishing
            activeRun.currentAppStoreID = nil
        }
        // A throwing adapter result is treated as failing before ratings/reviews
        // began. Once that stage starts, adapters return an explicit result so
        // aggregate facts remain truthful even when another provider fails.
        let ratingsReviewsResults = request.refreshRatingsAndReviews
            ? results.filter(\.ratingsReviewsAttempted)
            : []
        let summary = HeadlessRefreshRunSummary(
            runID: request.id,
            activeRunID: nil,
            scheduledFor: request.scheduledFor,
            startedAt: startedAt,
            finishedAt: dependencies.now(),
            disposition: disposition,
            plannedAppCount: plannedAppCount,
            completedAppCount: results.count,
            successfulAppCount: results.count { $0.disposition == .success },
            partialFailureAppCount: results.count { $0.disposition == .partialFailure },
            failedAppCount: results.count { $0.disposition == .failure },
            ratingsReviewsAttempted: !ratingsReviewsResults.isEmpty,
            ratingsReviewsFullySucceeded: !ratingsReviewsResults.isEmpty
                && ratingsReviewsResults.count == plannedAppCount
                && ratingsReviewsResults.allSatisfy(\.ratingsReviewsFullySucceeded),
            issue: issue
        )
        recentRuns.insert(summary, at: 0)
        completedRunsByID[request.id] = CompletedRun(
            request: request,
            summary: summary
        )
        if recentRuns.count > recentRunLimit {
            recentRuns.removeLast(recentRuns.count - recentRunLimit)
        }
        if activeRun?.request.id == request.id {
            activeRun = nil
        }
        await dependencies.recordEvent(.runFinished(summary))
        return summary
    }

    private func rejectConflictingRequest(
        _ request: HeadlessRefreshRunRequest
    ) async -> HeadlessRefreshRunSummary {
        let now = dependencies.now()
        let summary = HeadlessRefreshRunSummary(
            runID: request.id,
            activeRunID: activeRun?.request.id,
            scheduledFor: request.scheduledFor,
            startedAt: now,
            finishedAt: now,
            disposition: .rejectedRequestConflict,
            plannedAppCount: 0,
            completedAppCount: 0,
            successfulAppCount: 0,
            partialFailureAppCount: 0,
            failedAppCount: 0,
            ratingsReviewsAttempted: false,
            ratingsReviewsFullySucceeded: false,
            issue: HeadlessRefreshIssue(kind: .requestIdentityConflict)
        )
        await dependencies.recordEvent(.runRejected(
            requestRunID: request.id,
            at: now
        ))
        return summary
    }

    private static func completedDisposition(
        plannedAppCount: Int,
        results: [HeadlessRefreshAppExecutionResult]
    ) -> HeadlessRefreshRunDisposition {
        guard plannedAppCount > 0 else { return .noWork }
        let failureCount = results.count { $0.disposition == .failure }
        let partialFailureCount = results.count { $0.disposition == .partialFailure }
        if failureCount == plannedAppCount {
            return .failure
        }
        if failureCount > 0 || partialFailureCount > 0 {
            return .partialFailure
        }
        return .success
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task.isCancelled
    }
}
