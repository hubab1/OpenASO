import Foundation
import Observation

enum AppRefreshPhase: Sendable {
    case preparing
    case refreshingKeywords
    case refreshingMetrics
    case refreshingRatings
    case refreshingReviews
    case finishing
    case completed
    case failed

    var title: String {
        switch self {
        case .preparing:
            return "Preparing refresh"
        case .refreshingKeywords:
            return "Refreshing keywords"
        case .refreshingMetrics:
            return "Refreshing metrics"
        case .refreshingRatings:
            return "Refreshing ratings"
        case .refreshingReviews:
            return "Refreshing reviews"
        case .finishing:
            return "Finishing refresh"
        case .completed:
            return "Refresh complete"
        case .failed:
            return "Refresh failed"
        }
    }
}

enum AppRefreshStep: Sendable {
    case keywords
    case metrics
    case ratings
    case reviews
}

enum AppRefreshStepStatus: Sendable {
    case pending
    case running
    case completed
    case skipped
    case failed

    var title: String {
        switch self {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .completed:
            return "Done"
        case .skipped:
            return "Skipped"
        case .failed:
            return "Failed"
        }
    }
}

struct AppRefreshStepProgress: Sendable {
    var status: AppRefreshStepStatus
    var completed: Int
    var total: Int
    var failureCount: Int

    static func pending(total: Int) -> AppRefreshStepProgress {
        AppRefreshStepProgress(status: total > 0 ? .pending : .skipped, completed: 0, total: total, failureCount: 0)
    }

    var isVisible: Bool {
        total > 0 || status != .skipped
    }

    static func combined(_ progresses: [AppRefreshStepProgress]) -> AppRefreshStepProgress {
        let visibleProgresses = progresses.filter(\.isVisible)
        let total = progresses.reduce(0) { $0 + $1.total }
        let completed = progresses.reduce(0) { $0 + $1.completed }
        let failureCount = progresses.reduce(0) { $0 + $1.failureCount }

        guard total > 0 || !visibleProgresses.isEmpty else {
            return .pending(total: 0)
        }

        let statuses = visibleProgresses.map(\.status)
        let status: AppRefreshStepStatus
        if statuses.contains(.failed) {
            status = .failed
        } else if statuses.contains(.running) {
            status = .running
        } else if statuses.contains(.pending) {
            status = .pending
        } else if statuses.contains(.completed) {
            status = .completed
        } else {
            status = .skipped
        }

        return AppRefreshStepProgress(
            status: status,
            completed: completed,
            total: total,
            failureCount: failureCount
        )
    }
}

struct AppRefreshProgress: Identifiable, Sendable {
    let id: UUID
    let appStoreID: Int64
    let appName: String
    let trigger: String
    let startedAt: Date

    var phase: AppRefreshPhase
    var keywordProgress: AppRefreshStepProgress
    var metricsProgress: AppRefreshStepProgress
    var ratingsProgress: AppRefreshStepProgress
    var reviewsProgress: AppRefreshStepProgress
    var completedAt: Date?
    var errorMessage: String?

    var keywordAndMetricsProgress: AppRefreshStepProgress {
        AppRefreshStepProgress.combined([keywordProgress, metricsProgress])
    }

    var completedUnits: Int {
        keywordProgress.completed + metricsProgress.completed + ratingsProgress.completed + reviewsProgress.completed
    }

    var totalUnits: Int {
        keywordProgress.total + metricsProgress.total + ratingsProgress.total + reviewsProgress.total
    }
}

@MainActor
@Observable
final class AppRefreshProgressStore: Sendable {
    private(set) var activeRefresh: AppRefreshProgress?
    private(set) var pendingKeywordTrackCountsByAppStoreID: [Int64: Int] = [:]

    @ObservationIgnored
    private var clearTask: Task<Void, Never>?

    var pendingKeywordTrackCount: Int {
        pendingKeywordTrackCountsByAppStoreID.values.reduce(0, +)
    }

    func queuePendingKeywordAddition(appStoreID: Int64, trackCount: Int) {
        guard trackCount > 0 else { return }
        pendingKeywordTrackCountsByAppStoreID[appStoreID, default: 0] += trackCount
    }

    func clearPendingKeywordAdditions(appStoreID: Int64) {
        pendingKeywordTrackCountsByAppStoreID[appStoreID] = nil
    }

    func beginRefresh(_ request: AppDetailRefreshRequest) {
        clearTask?.cancel()
        clearTask = nil

        let storefrontCount = request.storefrontSelection.codes.count
        let usesAppStoreConnectReviews = request.appStoreConnectCredentials.isComplete
            && request.app.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        activeRefresh = AppRefreshProgress(
            id: UUID(),
            appStoreID: request.app.appStoreID,
            appName: request.app.name,
            trigger: request.trigger,
            startedAt: .now,
            phase: .preparing,
            keywordProgress: .pending(total: request.refreshKeywords ? request.trackIdentityKeys.count : 0),
            metricsProgress: .pending(total: request.refreshMetrics ? request.trackIdentityKeys.count : 0),
            ratingsProgress: .pending(total: request.refreshRatings ? storefrontCount : 0),
            reviewsProgress: .pending(total: request.refreshReviews ? (usesAppStoreConnectReviews ? 1 : storefrontCount) : 0),
            completedAt: nil,
            errorMessage: nil
        )
    }

    func beginAppleAdsPopularityRefresh(total: Int) {
        clearTask?.cancel()
        clearTask = nil

        activeRefresh = AppRefreshProgress(
            id: UUID(),
            appStoreID: 0,
            appName: "Apple Ads popularity",
            trigger: "apple_ads_connection",
            startedAt: .now,
            phase: .refreshingMetrics,
            keywordProgress: .pending(total: 0),
            metricsProgress: .pending(total: total),
            ratingsProgress: .pending(total: 0),
            reviewsProgress: .pending(total: 0),
            completedAt: nil,
            errorMessage: nil
        )
    }

    func updatePhase(_ phase: AppRefreshPhase) {
        guard var refresh = activeRefresh else { return }
        refresh.phase = phase
        activeRefresh = refresh
    }

    func updateStep(
        _ step: AppRefreshStep,
        status: AppRefreshStepStatus,
        completed: Int,
        total: Int,
        failureCount: Int
    ) {
        guard var refresh = activeRefresh else { return }
        let progress = AppRefreshStepProgress(
            status: status,
            completed: max(0, min(completed, total)),
            total: max(0, total),
            failureCount: max(0, failureCount)
        )
        switch step {
        case .keywords:
            refresh.keywordProgress = progress
        case .metrics:
            refresh.metricsProgress = progress
        case .ratings:
            refresh.ratingsProgress = progress
        case .reviews:
            refresh.reviewsProgress = progress
        }
        activeRefresh = refresh
    }

    func finish(error: OpenASOError?) {
        guard var refresh = activeRefresh else { return }
        refresh.phase = error == nil ? .completed : .failed
        refresh.completedAt = .now
        refresh.errorMessage = error?.localizedDescription
        refresh.keywordProgress = finalized(refresh.keywordProgress)
        refresh.metricsProgress = finalized(refresh.metricsProgress)
        refresh.ratingsProgress = finalized(refresh.ratingsProgress)
        refresh.reviewsProgress = finalized(refresh.reviewsProgress)
        activeRefresh = refresh
        scheduleClear(refreshID: refresh.id)
    }

    private func finalized(_ progress: AppRefreshStepProgress) -> AppRefreshStepProgress {
        guard progress.total > 0 else {
            return AppRefreshStepProgress(status: .skipped, completed: 0, total: 0, failureCount: progress.failureCount)
        }
        if progress.failureCount > 0 {
            return AppRefreshStepProgress(
                status: progress.completed >= progress.total ? .failed : progress.status,
                completed: progress.completed,
                total: progress.total,
                failureCount: progress.failureCount
            )
        }
        return AppRefreshStepProgress(
            status: .completed,
            completed: progress.total,
            total: progress.total,
            failureCount: 0
        )
    }

    private func scheduleClear(refreshID: UUID) {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                guard self?.activeRefresh?.id == refreshID else { return }
                self?.activeRefresh = nil
                self?.clearTask = nil
            }
        }
    }
}
