import Dispatch
import Foundation

enum RefreshObservationProvider: String, CaseIterable, Hashable, Sendable {
    case appStoreConnect
    case appStoreWeb
    case appleAdsAPI
    case appleAdsWeb
    case appleIdentity
    case iTunesStore
    case unknown
}

enum RefreshObservationEndpoint: String, CaseIterable, Hashable, Sendable {
    case appStoreConnectReviews
    case appleAdsAPI
    case appleAdsPopularity
    case appleIdentity
    case customerReviews
    case other
    case rankingSearch
    case ratingsLookup
    case ratingsPage
}

enum RefreshTransportResult: String, CaseIterable, Hashable, Sendable {
    case authenticationFailure
    case cancelled
    case clientFailure
    case decodingFailure
    case networkFailure
    case nonHTTPResponse
    case notFound
    case otherFailure
    case providerFailure
    case rateLimited
    case redirect
    case serverFailure
    case success
    case unexpectedResponse
}

enum RefreshObservationStage: String, CaseIterable, Hashable, Sendable {
    case keywordMetrics
    case rankings
    case ratings
    case reviews
}

enum RefreshObservationTrigger: String, Hashable, Sendable {
    case afterAddApp
    case afterAddKeyword
    case afterImportKeywords
    case daily
    case manual
    case manualAll
    case other

    init(rawValueForObservation rawValue: String) {
        switch rawValue {
        case "after_add_app":
            self = .afterAddApp
        case "after_add_keyword":
            self = .afterAddKeyword
        case "after_import_keywords":
            self = .afterImportKeywords
        case "daily_refresh":
            self = .daily
        case "manual":
            self = .manual
        case "manual_all":
            self = .manualAll
        default:
            self = .other
        }
    }
}

enum RefreshObservationWorkspace: String, Hashable, Sendable {
    case keywords
    case ratings

    init(_ workspace: AppDetailRefreshWorkspace) {
        switch workspace {
        case .keywords:
            self = .keywords
        case .ratings:
            self = .ratings
        }
    }
}

enum RefreshRunResult: String, Hashable, Sendable {
    case cancelled
    case failure
    case partialFailure
    case success
}

struct RefreshStageSummary: Equatable, Sendable {
    let attemptedCount: Int
    let successCount: Int
    let failureCount: Int
    let isSkipped: Bool

    init(attemptedCount: Int, failureCount: Int, isSkipped: Bool = false) {
        let attemptedCount = max(0, attemptedCount)
        let failureCount = min(max(0, failureCount), attemptedCount)
        self.attemptedCount = attemptedCount
        self.successCount = attemptedCount - failureCount
        self.failureCount = failureCount
        self.isSkipped = isSkipped
    }

    static let skipped = RefreshStageSummary(attemptedCount: 0, failureCount: 0, isSkipped: true)
}

struct RefreshProviderRequestSummary: Equatable, Sendable {
    var requestCount = 0
    var retryCount = 0
    var totalDurationNanoseconds: UInt64 = 0
    var maximumDurationNanoseconds: UInt64 = 0
    var endpointCounts: [RefreshObservationEndpoint: Int] = [:]
    var resultCounts: [RefreshTransportResult: Int] = [:]
}

struct RefreshRunSummary: Equatable, Sendable {
    let id: UUID
    let trigger: RefreshObservationTrigger
    let workspace: RefreshObservationWorkspace
    let requestedTrackCount: Int
    let requestedStorefrontCount: Int
    let resolvedRankingCount: Int
    let uniqueRankingQueryCount: Int
    let missingRankingCount: Int
    let stages: [RefreshObservationStage: RefreshStageSummary]
    let providers: [RefreshObservationProvider: RefreshProviderRequestSummary]
    let durationNanoseconds: UInt64
    let observedCancellation: Bool
    let result: RefreshRunResult

    var redactedLogMessage: String {
        let providerText = providers
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { provider, summary in
                let endpoints = summary.endpointCounts
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .joined(separator: ",")
                let results = summary.resultCounts
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .joined(separator: ",")
                return "\(provider.rawValue){requests=\(summary.requestCount),retries=\(summary.retryCount),totalDurationNs=\(summary.totalDurationNanoseconds),maxDurationNs=\(summary.maximumDurationNanoseconds),endpoints=[\(endpoints)],results=[\(results)]}"
            }
            .joined(separator: ";")
        let stageText = stages
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { stage, summary in
                "\(stage.rawValue){attempted=\(summary.attemptedCount),failures=\(summary.failureCount),skipped=\(summary.isSkipped)}"
            }
            .joined(separator: ";")
        return "Refresh completed id=\(id.uuidString) trigger=\(trigger.rawValue) workspace=\(workspace.rawValue) result=\(result.rawValue) observedCancellation=\(observedCancellation) durationMs=\(durationNanoseconds / 1_000_000) requestedTracks=\(requestedTrackCount) requestedStorefronts=\(requestedStorefrontCount) resolvedRankings=\(resolvedRankingCount) uniqueRankingQueries=\(uniqueRankingQueryCount) missingRankings=\(missingRankingCount) stages=[\(stageText)] providers=[\(providerText)]"
    }
}

struct RefreshObservationClock: Sendable {
    private let nowProvider: @Sendable () -> UInt64

    init(nowNanoseconds: @escaping @Sendable () -> UInt64) {
        self.nowProvider = nowNanoseconds
    }

    func nowNanoseconds() -> UInt64 {
        nowProvider()
    }

    static let live = RefreshObservationClock {
        DispatchTime.now().uptimeNanoseconds
    }
}

enum RefreshObservationScope {
    @TaskLocal static var runID: UUID?
}

actor RefreshMetricsRecorder {
    private struct ActiveRun: Sendable {
        let id: UUID
        let trigger: RefreshObservationTrigger
        let workspace: RefreshObservationWorkspace
        let requestedTrackCount: Int
        let requestedStorefrontCount: Int
        let startedAtNanoseconds: UInt64
        var resolvedRankingCount = 0
        var uniqueRankingQueryCount = 0
        var missingRankingCount = 0
        var observedCancellation = false
        var stages: [RefreshObservationStage: RefreshStageSummary] = [:]
        var providers: [RefreshObservationProvider: RefreshProviderRequestSummary] = [:]
    }

    private let clock: RefreshObservationClock
    private let maximumCompletedSummaryCount: Int
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var completed: [RefreshRunSummary] = []

    init(
        clock: RefreshObservationClock = .live,
        maximumCompletedSummaryCount: Int = 20
    ) {
        self.clock = clock
        self.maximumCompletedSummaryCount = max(1, maximumCompletedSummaryCount)
    }

    func begin(
        trigger: RefreshObservationTrigger,
        workspace: RefreshObservationWorkspace,
        requestedTrackCount: Int,
        requestedStorefrontCount: Int
    ) -> UUID {
        let id = UUID()
        activeRuns[id] = ActiveRun(
            id: id,
            trigger: trigger,
            workspace: workspace,
            requestedTrackCount: max(0, requestedTrackCount),
            requestedStorefrontCount: max(0, requestedStorefrontCount),
            startedAtNanoseconds: clock.nowNanoseconds()
        )
        return id
    }

    func recordRankingWork(
        runID: UUID,
        resolvedCount: Int,
        uniqueQueryCount: Int,
        missingCount: Int
    ) {
        guard var run = activeRuns[runID] else { return }
        run.resolvedRankingCount = max(0, resolvedCount)
        run.uniqueRankingQueryCount = min(max(0, uniqueQueryCount), run.resolvedRankingCount)
        run.missingRankingCount = max(0, missingCount)
        activeRuns[runID] = run
    }

    func recordStage(
        runID: UUID,
        stage: RefreshObservationStage,
        attemptedCount: Int,
        failureCount: Int,
        isSkipped: Bool = false
    ) {
        guard var run = activeRuns[runID] else { return }
        run.stages[stage] = RefreshStageSummary(
            attemptedCount: attemptedCount,
            failureCount: failureCount,
            isSkipped: isSkipped
        )
        activeRuns[runID] = run
    }

    func recordRequest(
        runID: UUID,
        provider: RefreshObservationProvider,
        endpoint: RefreshObservationEndpoint,
        result: RefreshTransportResult,
        durationNanoseconds: UInt64,
        isRetry: Bool = false
    ) {
        guard var run = activeRuns[runID] else { return }
        var providerSummary = run.providers[provider] ?? RefreshProviderRequestSummary()
        providerSummary.requestCount += 1
        if isRetry {
            providerSummary.retryCount += 1
        }
        providerSummary.totalDurationNanoseconds = providerSummary.totalDurationNanoseconds.addingWithoutOverflow(durationNanoseconds)
        providerSummary.maximumDurationNanoseconds = max(
            providerSummary.maximumDurationNanoseconds,
            durationNanoseconds
        )
        providerSummary.endpointCounts[endpoint, default: 0] += 1
        providerSummary.resultCounts[result, default: 0] += 1
        if result == .cancelled {
            run.observedCancellation = true
        }
        run.providers[provider] = providerSummary
        activeRuns[runID] = run
    }

    func recordCancellation(runID: UUID) {
        guard var run = activeRuns[runID] else { return }
        run.observedCancellation = true
        activeRuns[runID] = run
    }

    @discardableResult
    func finish(runID: UUID) -> RefreshRunSummary? {
        guard let run = activeRuns.removeValue(forKey: runID) else { return nil }
        let failureCount = run.stages.values.reduce(0) { $0 + $1.failureCount }
        let successCount = run.stages.values.reduce(0) { $0 + $1.successCount }
        let observedCancellation = run.observedCancellation
        let result: RefreshRunResult
        if observedCancellation {
            result = .cancelled
        } else if failureCount == 0 {
            result = .success
        } else if successCount > 0 {
            result = .partialFailure
        } else {
            result = .failure
        }

        let summary = RefreshRunSummary(
            id: run.id,
            trigger: run.trigger,
            workspace: run.workspace,
            requestedTrackCount: run.requestedTrackCount,
            requestedStorefrontCount: run.requestedStorefrontCount,
            resolvedRankingCount: run.resolvedRankingCount,
            uniqueRankingQueryCount: run.uniqueRankingQueryCount,
            missingRankingCount: run.missingRankingCount,
            stages: run.stages,
            providers: run.providers,
            durationNanoseconds: elapsedNanoseconds(
                since: run.startedAtNanoseconds,
                endingAt: clock.nowNanoseconds()
            ),
            observedCancellation: observedCancellation,
            result: result
        )
        completed.append(summary)
        if completed.count > maximumCompletedSummaryCount {
            completed.removeFirst(completed.count - maximumCompletedSummaryCount)
        }
        OpenASOLog.refresh.info("\(summary.redactedLogMessage, privacy: .public)")
        return summary
    }

    func completedSummaries() -> [RefreshRunSummary] {
        completed
    }

    func activeRunCount() -> Int {
        activeRuns.count
    }
}

struct ObservedHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let recorder: RefreshMetricsRecorder
    private let clock: RefreshObservationClock

    init(
        base: any HTTPClient,
        recorder: RefreshMetricsRecorder,
        clock: RefreshObservationClock = .live
    ) {
        self.base = base
        self.recorder = recorder
        self.clock = clock
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let runID = RefreshObservationScope.runID else {
            return try await base.data(for: request)
        }

        let classification = RefreshRequestClassification(request.url)
        let startedAt = clock.nowNanoseconds()
        do {
            let output = try await base.data(for: request)
            let duration = elapsedNanoseconds(since: startedAt, endingAt: clock.nowNanoseconds())
            await recorder.recordRequest(
                runID: runID,
                provider: classification.provider,
                endpoint: classification.endpoint,
                result: RefreshTransportClassifier.classify(output.1),
                durationNanoseconds: duration,
                isRetry: ProviderRequestObservationScope.isRetryAttempt
            )
            return output
        } catch {
            let duration = elapsedNanoseconds(since: startedAt, endingAt: clock.nowNanoseconds())
            await recorder.recordRequest(
                runID: runID,
                provider: classification.provider,
                endpoint: classification.endpoint,
                result: RefreshTransportClassifier.classify(error),
                durationNanoseconds: duration,
                isRetry: ProviderRequestObservationScope.isRetryAttempt
            )
            throw error
        }
    }
}

struct RefreshRequestClassification: Sendable {
    let provider: RefreshObservationProvider
    let endpoint: RefreshObservationEndpoint

    init(_ url: URL?) {
        let host = url?.host()?.lowercased() ?? ""
        let path = url?.path.lowercased() ?? ""
        switch host {
        case "itunes.apple.com":
            provider = .iTunesStore
            if path == "/search" {
                endpoint = .rankingSearch
            } else if path == "/lookup" {
                endpoint = .ratingsLookup
            } else if path.contains("/rss/customerreviews") {
                endpoint = .customerReviews
            } else {
                endpoint = .other
            }
        case "apps.apple.com":
            provider = .appStoreWeb
            endpoint = .ratingsPage
        case "api.appstoreconnect.apple.com":
            provider = .appStoreConnect
            endpoint = path.contains("customerreviews") ? .appStoreConnectReviews : .other
        case "app-ads.apple.com":
            provider = .appleAdsWeb
            endpoint = path.contains("/keywords/popularities") ? .appleAdsPopularity : .other
        case "api.searchads.apple.com":
            provider = .appleAdsAPI
            endpoint = .appleAdsAPI
        case "appleid.apple.com":
            provider = .appleIdentity
            endpoint = .appleIdentity
        default:
            provider = .unknown
            endpoint = .other
        }
    }
}

private enum RefreshTransportClassifier {
    static func classify(_ response: URLResponse) -> RefreshTransportResult {
        guard let response = response as? HTTPURLResponse else {
            return .nonHTTPResponse
        }
        switch response.statusCode {
        case 200 ..< 300:
            return .success
        case 300 ..< 400:
            return .redirect
        case 401, 403:
            return .authenticationFailure
        case 404:
            return .notFound
        case 429:
            return .rateLimited
        case 400 ..< 500:
            return .clientFailure
        case 500 ..< 600:
            return .serverFailure
        default:
            return .unexpectedResponse
        }
    }

    static func classify(_ error: any Error) -> RefreshTransportResult {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .networkFailure
        }
        guard let error = error as? OpenASOError else {
            return .otherFailure
        }
        switch error {
        case .appNotFound:
            return .notFound
        case .decodingFailed:
            return .decodingFailure
        case .networkUnavailable:
            return .networkFailure
        case .rateLimited:
            return .rateLimited
        case .unexpectedResponse:
            return .unexpectedResponse
        case .emptyQuery, .invalidAppStoreID, .primaryProviderUnavailable, .providerUnavailable:
            return .providerFailure
        }
    }
}

private func elapsedNanoseconds(since start: UInt64, endingAt end: UInt64) -> UInt64 {
    end >= start ? end - start : 0
}

private extension UInt64 {
    func addingWithoutOverflow(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }
}
