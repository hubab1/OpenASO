import CryptoKit
import Dispatch
import Foundation

struct ProviderRequestPolicy: Equatable, Sendable {
    let minimumIntervalNanoseconds: UInt64
    let maximumAttempts: Int
    let baseBackoffNanoseconds: UInt64
    let maximumBackoffNanoseconds: UInt64
    let maximumElapsedNanoseconds: UInt64
    let jitterFraction: Double

    init(
        minimumIntervalNanoseconds: UInt64,
        maximumAttempts: Int,
        baseBackoffNanoseconds: UInt64,
        maximumBackoffNanoseconds: UInt64,
        maximumElapsedNanoseconds: UInt64,
        jitterFraction: Double
    ) {
        self.minimumIntervalNanoseconds = minimumIntervalNanoseconds
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseBackoffNanoseconds = baseBackoffNanoseconds
        self.maximumBackoffNanoseconds = max(baseBackoffNanoseconds, maximumBackoffNanoseconds)
        self.maximumElapsedNanoseconds = maximumElapsedNanoseconds
        if jitterFraction.isFinite {
            self.jitterFraction = min(max(0, jitterFraction), 1)
        } else {
            self.jitterFraction = 0
        }
    }
}

struct ProviderRequestPolicies: Sendable {
    private let defaultPolicy: ProviderRequestPolicy
    private let overrides: [RefreshObservationProvider: ProviderRequestPolicy]

    init(
        default defaultPolicy: ProviderRequestPolicy,
        overrides: [RefreshObservationProvider: ProviderRequestPolicy] = [:]
    ) {
        self.defaultPolicy = defaultPolicy
        self.overrides = overrides
    }

    func policy(for provider: RefreshObservationProvider) -> ProviderRequestPolicy {
        overrides[provider] ?? defaultPolicy
    }
}

struct ProviderRequestClock: Sendable {
    private let nowNanosecondsProvider: @Sendable () -> UInt64
    private let nowDateProvider: @Sendable () -> Date
    private let sleepUntilProvider: @Sendable (UInt64) async throws -> Void

    init(
        nowNanoseconds: @escaping @Sendable () -> UInt64,
        nowDate: @escaping @Sendable () -> Date,
        sleepUntilNanoseconds: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.nowNanosecondsProvider = nowNanoseconds
        self.nowDateProvider = nowDate
        self.sleepUntilProvider = sleepUntilNanoseconds
    }

    func nowNanoseconds() -> UInt64 {
        nowNanosecondsProvider()
    }

    func nowDate() -> Date {
        nowDateProvider()
    }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        try await sleepUntilProvider(deadline)
    }

    static let live = ProviderRequestClock(
        nowNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        },
        nowDate: {
            Date()
        },
        sleepUntilNanoseconds: { deadline in
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return }
            try await Task.sleep(nanoseconds: deadline - now)
        }
    )
}

struct ProviderRequestRandomness: Sendable {
    private let unitIntervalProvider: @Sendable () -> Double

    init(unitInterval: @escaping @Sendable () -> Double) {
        self.unitIntervalProvider = unitInterval
    }

    func unitInterval() -> Double {
        let value = unitIntervalProvider()
        guard value.isFinite else { return 0.5 }
        return min(max(0, value), 1)
    }

    static let live = ProviderRequestRandomness {
        Double.random(in: 0 ... 1)
    }
}

struct ProviderRequestGateSnapshot: Equatable, Sendable {
    let inFlightRequestCount: Int
    let waiterCount: Int
}

actor ProviderRequestGate: HTTPClient {
    private typealias Output = (Data, URLResponse)

    private enum RequestBehavior: Equatable, Sendable {
        case retryAndDeduplicate
        case retryOnly
        case paceOnly

        var allowsRetry: Bool {
            switch self {
            case .retryAndDeduplicate, .retryOnly:
                true
            case .paceOnly:
                false
            }
        }

        var allowsDeduplication: Bool {
            self == .retryAndDeduplicate
        }
    }

    private enum FailureClassification: Equatable, Sendable {
        case authentication
        case cancelled
        case permanent
        case rateLimited(retryAfterNanoseconds: UInt64?)
        case success
        case transient(retryAfterNanoseconds: UInt64?)

        var retryAfterNanoseconds: UInt64? {
            switch self {
            case .rateLimited(let retryAfterNanoseconds), .transient(let retryAfterNanoseconds):
                retryAfterNanoseconds
            case .authentication, .cancelled, .permanent, .success:
                nil
            }
        }

        var isRetryable: Bool {
            switch self {
            case .rateLimited, .transient:
                true
            case .authentication, .cancelled, .permanent, .success:
                false
            }
        }
    }

    private struct PacingKey: Hashable, Sendable {
        let provider: RefreshObservationProvider
        let unknownScheme: String?
        let unknownHost: String?
        let unknownPort: Int?

        init(classification: RefreshRequestClassification, url: URL?) {
            self.provider = classification.provider
            guard classification.provider == .unknown else {
                self.unknownScheme = nil
                self.unknownHost = nil
                self.unknownPort = nil
                return
            }

            let scheme = url?.scheme?.lowercased() ?? "unknown"
            self.unknownScheme = scheme
            self.unknownHost = url?.host()?.lowercased() ?? "unknown"
            self.unknownPort = url?.port ?? Self.defaultPort(for: scheme)
        }

        private static func defaultPort(for scheme: String) -> Int? {
            switch scheme {
            case "http": 80
            case "https": 443
            default: nil
            }
        }
    }

    private struct PacingState {
        var lastStartNanoseconds: UInt64?
        var cooldownUntilNanoseconds: UInt64 = 0
    }

    private struct RequestFingerprint: Hashable, Sendable {
        let digest: Data

        init?(request: URLRequest, refreshRunID: UUID?) {
            guard request.httpBodyStream == nil else { return nil }

            var canonical = Data()
            Self.append(request.httpMethod?.uppercased() ?? "GET", to: &canonical)
            Self.append(request.url?.absoluteString ?? "", to: &canonical)
            Self.append(request.mainDocumentURL?.absoluteString ?? "", to: &canonical)
            Self.append(String(request.cachePolicy.rawValue), to: &canonical)
            Self.append(String(request.timeoutInterval.bitPattern), to: &canonical)
            Self.append(String(request.networkServiceType.rawValue), to: &canonical)
            Self.append(request.httpShouldHandleCookies ? "1" : "0", to: &canonical)
            Self.append(request.httpShouldUsePipelining ? "1" : "0", to: &canonical)
            Self.append(request.allowsCellularAccess ? "1" : "0", to: &canonical)
            Self.append(request.allowsExpensiveNetworkAccess ? "1" : "0", to: &canonical)
            Self.append(request.allowsConstrainedNetworkAccess ? "1" : "0", to: &canonical)
            Self.append(request.assumesHTTP3Capable ? "1" : "0", to: &canonical)
            Self.append(String(request.attribution.rawValue), to: &canonical)
            Self.append(request.requiresDNSSECValidation ? "1" : "0", to: &canonical)
            Self.append(request.allowsPersistentDNS ? "1" : "0", to: &canonical)
            if #available(macOS 15.2, *) {
                Self.append(request.cookiePartitionIdentifier ?? "", to: &canonical)
            } else {
                Self.append("unavailable", to: &canonical)
            }
            if #available(macOS 26.1, *) {
                Self.append(request.allowsUltraConstrainedNetworkAccess ? "1" : "0", to: &canonical)
            } else {
                Self.append("unavailable", to: &canonical)
            }
            Self.append(refreshRunID?.uuidString ?? "", to: &canonical)

            let headers = (request.allHTTPHeaderFields ?? [:])
                .map { ($0.key.lowercased(), $0.value) }
                .sorted {
                    if $0.0 == $1.0 { return $0.1 < $1.1 }
                    return $0.0 < $1.0
                }
            for (name, value) in headers {
                Self.append(name, to: &canonical)
                Self.append(value, to: &canonical)
            }
            Self.append(request.httpBody ?? Data(), to: &canonical)

            self.digest = Data(SHA256.hash(data: canonical))
        }

        private static func append(_ value: String, to data: inout Data) {
            append(Data(value.utf8), to: &data)
        }

        private static func append(_ value: Data, to data: inout Data) {
            data.append(contentsOf: "\(value.count):".utf8)
            data.append(value)
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Output, any Error>
    }

    private struct InFlightRequest {
        let operationID: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private enum SharedResult {
        case failure(any Error)
        case success(Output)
    }

    private struct DispatchAttempt {
        let startedAtNanoseconds: UInt64
        let result: SharedResult
    }

    private enum RetrySource {
        case error(any Error)
        case response(Output)
    }

    private let base: any HTTPClient
    private let policies: ProviderRequestPolicies
    private let clock: ProviderRequestClock
    private let randomness: ProviderRequestRandomness
    private var pacingStates: [PacingKey: PacingState] = [:]
    private var inFlightRequests: [RequestFingerprint: InFlightRequest] = [:]

    init(
        base: any HTTPClient,
        policies: ProviderRequestPolicies,
        clock: ProviderRequestClock = .live,
        randomness: ProviderRequestRandomness = .live
    ) {
        self.base = base
        self.policies = policies
        self.clock = clock
        self.randomness = randomness
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()

        let classification = RefreshRequestClassification(request.url)
        let behavior = Self.behavior(for: request)
        let pacingKey = PacingKey(classification: classification, url: request.url)
        let policy = policies.policy(for: classification.provider)

        guard behavior.allowsDeduplication,
              let fingerprint = RequestFingerprint(
                  request: request,
                  refreshRunID: RefreshObservationScope.runID
              ) else {
            return try await perform(
                request,
                behavior: behavior,
                pacingKey: pacingKey,
                policy: policy
            )
        }

        return try await deduplicatedData(
            for: request,
            fingerprint: fingerprint,
            behavior: behavior,
            pacingKey: pacingKey,
            policy: policy
        )
    }

    func snapshot() -> ProviderRequestGateSnapshot {
        ProviderRequestGateSnapshot(
            inFlightRequestCount: inFlightRequests.count,
            waiterCount: inFlightRequests.values.reduce(0) { $0 + $1.waiters.count }
        )
    }

    private func deduplicatedData(
        for request: URLRequest,
        fingerprint: RequestFingerprint,
        behavior: RequestBehavior,
        pacingKey: PacingKey,
        policy: ProviderRequestPolicy
    ) async throws -> Output {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            do {
                let output: Output = try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    register(
                        waiterID: waiterID,
                        continuation: continuation,
                        request: request,
                        fingerprint: fingerprint,
                        behavior: behavior,
                        pacingKey: pacingKey,
                        policy: policy
                    )
                }
                try Task.checkCancellation()
                return output
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, for: fingerprint)
            }
        }
    }

    private func register(
        waiterID: UUID,
        continuation: CheckedContinuation<Output, any Error>,
        request: URLRequest,
        fingerprint: RequestFingerprint,
        behavior: RequestBehavior,
        pacingKey: PacingKey,
        policy: ProviderRequestPolicy
    ) {
        if var existing = inFlightRequests[fingerprint] {
            existing.waiters[waiterID] = Waiter(continuation: continuation)
            inFlightRequests[fingerprint] = existing
            return
        }

        let operationID = UUID()
        let task = Task {
            await self.runSharedRequest(
                request,
                fingerprint: fingerprint,
                operationID: operationID,
                behavior: behavior,
                pacingKey: pacingKey,
                policy: policy
            )
        }
        inFlightRequests[fingerprint] = InFlightRequest(
            operationID: operationID,
            task: task,
            waiters: [waiterID: Waiter(continuation: continuation)]
        )
    }

    private func runSharedRequest(
        _ request: URLRequest,
        fingerprint: RequestFingerprint,
        operationID: UUID,
        behavior: RequestBehavior,
        pacingKey: PacingKey,
        policy: ProviderRequestPolicy
    ) async {
        let result: SharedResult
        do {
            result = .success(try await perform(
                request,
                behavior: behavior,
                pacingKey: pacingKey,
                policy: policy
            ))
        } catch {
            result = .failure(error)
        }
        completeSharedRequest(
            fingerprint: fingerprint,
            operationID: operationID,
            result: result
        )
    }

    private func completeSharedRequest(
        fingerprint: RequestFingerprint,
        operationID: UUID,
        result: SharedResult
    ) {
        guard let request = inFlightRequests[fingerprint],
              request.operationID == operationID else {
            return
        }
        inFlightRequests[fingerprint] = nil

        for waiter in request.waiters.values {
            switch result {
            case .failure(let error):
                waiter.continuation.resume(throwing: error)
            case .success(let output):
                waiter.continuation.resume(returning: output)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for fingerprint: RequestFingerprint) {
        guard var request = inFlightRequests[fingerprint],
              let waiter = request.waiters.removeValue(forKey: waiterID) else {
            return
        }

        waiter.continuation.resume(throwing: CancellationError())
        guard request.waiters.isEmpty else {
            inFlightRequests[fingerprint] = request
            return
        }

        inFlightRequests[fingerprint] = nil
        request.task.cancel()
    }

    private func perform(
        _ request: URLRequest,
        behavior: RequestBehavior,
        pacingKey: PacingKey,
        policy: ProviderRequestPolicy
    ) async throws -> Output {
        var failedAttempt = 0
        var firstAttemptStartedAt: UInt64?
        var retryBudgetDeadline: UInt64?
        var retrySource: RetrySource?
        var notBeforeNanoseconds: UInt64?

        while true {
            try Task.checkCancellation()
            guard let attempt = try await dispatch(
                request,
                pacingKey: pacingKey,
                policy: policy,
                notBeforeNanoseconds: notBeforeNanoseconds,
                latestStartNanoseconds: retryBudgetDeadline
            ) else {
                switch retrySource {
                case .error(let error):
                    throw error
                case .response(let output):
                    return output
                case nil:
                    preconditionFailure("The initial request dispatch cannot exhaust a retry budget")
                }
            }

            if firstAttemptStartedAt == nil {
                firstAttemptStartedAt = attempt.startedAtNanoseconds
            }
            failedAttempt += 1

            switch attempt.result {
            case .success(let output):
                try Task.checkCancellation()
                let failure = classify(output.1)
                guard let firstAttemptStartedAt else {
                    preconditionFailure("A dispatched request must have a start time")
                }
                let retryDeadline = retryDeadline(
                    after: failure,
                    failedAttempt: failedAttempt,
                    firstAttemptStartedAt: firstAttemptStartedAt,
                    pacingKey: pacingKey,
                    policy: policy
                )
                guard behavior.allowsRetry, let retryDeadline else {
                    return output
                }
                retryBudgetDeadline = firstAttemptStartedAt.addingWithoutOverflow(
                    policy.maximumElapsedNanoseconds
                )
                retrySource = .response(output)
                notBeforeNanoseconds = retryDeadline
            case .failure(let error):
                try Task.checkCancellation()
                let failure = Self.classify(error)
                guard failure != .cancelled else { throw error }
                guard let firstAttemptStartedAt else {
                    preconditionFailure("A dispatched request must have a start time")
                }
                let retryDeadline = retryDeadline(
                    after: failure,
                    failedAttempt: failedAttempt,
                    firstAttemptStartedAt: firstAttemptStartedAt,
                    pacingKey: pacingKey,
                    policy: policy
                )
                guard behavior.allowsRetry, let retryDeadline else {
                    throw error
                }
                retryBudgetDeadline = firstAttemptStartedAt.addingWithoutOverflow(
                    policy.maximumElapsedNanoseconds
                )
                retrySource = .error(error)
                notBeforeNanoseconds = retryDeadline
            }
        }
    }

    private func dispatch(
        _ request: URLRequest,
        pacingKey: PacingKey,
        policy: ProviderRequestPolicy,
        notBeforeNanoseconds: UInt64?,
        latestStartNanoseconds: UInt64?
    ) async throws -> DispatchAttempt? {
        let operationNotBefore = notBeforeNanoseconds ?? 0

        while true {
            try Task.checkCancellation()
            let now = clock.nowNanoseconds()
            var state = pacingStates[pacingKey] ?? PacingState()
            let pacedStart = state.lastStartNanoseconds?.addingWithoutOverflow(
                policy.minimumIntervalNanoseconds
            ) ?? 0
            let deadline = max(
                max(now, operationNotBefore),
                max(state.cooldownUntilNanoseconds, pacedStart)
            )
            guard latestStartNanoseconds.map({ deadline <= $0 }) ?? true else {
                return nil
            }
            guard now >= deadline else {
                try await clock.sleep(untilNanoseconds: deadline)
                continue
            }

            try Task.checkCancellation()
            let startedAt = clock.nowNanoseconds()
            guard latestStartNanoseconds.map({ startedAt <= $0 }) ?? true else {
                return nil
            }
            state.lastStartNanoseconds = startedAt
            pacingStates[pacingKey] = state

            let result: SharedResult
            do {
                result = .success(try await base.data(for: request))
            } catch {
                result = .failure(error)
            }
            return DispatchAttempt(
                startedAtNanoseconds: startedAt,
                result: result
            )
        }
    }

    private func retryDeadline(
        after failure: FailureClassification,
        failedAttempt: Int,
        firstAttemptStartedAt: UInt64,
        pacingKey: PacingKey,
        policy: ProviderRequestPolicy
    ) -> UInt64? {
        guard failure.isRetryable else {
            return nil
        }

        let now = clock.nowNanoseconds()
        let delay: UInt64
        if let retryAfterNanoseconds = failure.retryAfterNanoseconds {
            delay = retryAfterNanoseconds
        } else {
            delay = jitteredBackoff(
                failedAttempt: failedAttempt,
                policy: policy
            )
        }

        let candidate = now.addingWithoutOverflow(delay)
        var state = pacingStates[pacingKey] ?? PacingState()
        state.cooldownUntilNanoseconds = max(state.cooldownUntilNanoseconds, candidate)
        pacingStates[pacingKey] = state

        guard failedAttempt < policy.maximumAttempts else { return nil }
        let budgetDeadline = firstAttemptStartedAt.addingWithoutOverflow(
            policy.maximumElapsedNanoseconds
        )
        guard candidate <= budgetDeadline else { return nil }
        return candidate
    }

    private func jitteredBackoff(
        failedAttempt: Int,
        policy: ProviderRequestPolicy
    ) -> UInt64 {
        var cappedBackoff = min(
            policy.baseBackoffNanoseconds,
            policy.maximumBackoffNanoseconds
        )
        if failedAttempt > 1 {
            for _ in 1 ..< failedAttempt {
                cappedBackoff = min(
                    cappedBackoff.multipliedWithoutOverflow(by: 2),
                    policy.maximumBackoffNanoseconds
                )
            }
        }

        guard cappedBackoff > 0, policy.jitterFraction > 0 else {
            return cappedBackoff
        }
        let upperBound = Double(cappedBackoff)
        let lowerBound = upperBound * (1 - policy.jitterFraction)
        let jittered = lowerBound + ((upperBound - lowerBound) * randomness.unitInterval())
        guard jittered < Double(UInt64.max) else { return .max }
        return UInt64(jittered.rounded(.up))
    }

    private func classify(_ response: URLResponse) -> FailureClassification {
        guard let response = response as? HTTPURLResponse else {
            return .permanent
        }

        let retryAfterNanoseconds = Self.retryAfterNanoseconds(
            from: response,
            now: clock.nowDate()
        )
        switch response.statusCode {
        case 200 ..< 300:
            return .success
        case 401, 403:
            return .authentication
        case 408, 425:
            return .transient(retryAfterNanoseconds: retryAfterNanoseconds)
        case 429:
            return .rateLimited(retryAfterNanoseconds: retryAfterNanoseconds)
        case 500 ..< 600:
            return .transient(retryAfterNanoseconds: retryAfterNanoseconds)
        default:
            return .permanent
        }
    }

    private static func classify(_ error: any Error) -> FailureClassification {
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled:
                return .cancelled
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return .authentication
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed:
                return .transient(retryAfterNanoseconds: nil)
            default:
                return .permanent
            }
        }
        if let error = error as? OpenASOError {
            switch error {
            case .networkUnavailable:
                return .transient(retryAfterNanoseconds: nil)
            case .rateLimited:
                return .rateLimited(retryAfterNanoseconds: nil)
            case .appNotFound,
                 .decodingFailed,
                 .emptyQuery,
                 .invalidAppStoreID,
                 .primaryProviderUnavailable,
                 .providerUnavailable,
                 .unexpectedResponse:
                return .permanent
            }
        }
        return .permanent
    }

    private static func behavior(for request: URLRequest) -> RequestBehavior {
        guard request.httpBodyStream == nil else {
            return .paceOnly
        }

        switch request.httpMethod?.uppercased() ?? "GET" {
        case "GET", "HEAD":
            return .retryAndDeduplicate
        case "POST" where isHTTPSRequest(
            request,
            host: "app-ads.apple.com",
            path: "/cm/api/v2/keywords/popularities",
            requiresAdamIDQuery: true
        ):
            return .retryAndDeduplicate
        case "POST" where isHTTPSRequest(
            request,
            host: "appleid.apple.com",
            path: "/auth/oauth2/token",
            requiresAdamIDQuery: false
        ):
            return .retryOnly
        default:
            return .paceOnly
        }
    }

    private static func isHTTPSRequest(
        _ request: URLRequest,
        host: String,
        path: String,
        requiresAdamIDQuery: Bool
    ) -> Bool {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host()?.lowercased() == host,
              (url.port ?? 443) == 443,
              url.user() == nil,
              url.password() == nil,
              url.path == path else {
            return false
        }

        guard requiresAdamIDQuery else {
            return url.query == nil
        }
        guard let queryItems = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "adamId",
              let adamID = queryItems[0].value,
              !adamID.isEmpty else {
            return false
        }
        return true
    }

    private static func retryAfterNanoseconds(
        from response: HTTPURLResponse,
        now: Date
    ) -> UInt64? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        if let seconds = Double(rawValue), seconds.isFinite, seconds >= 0 {
            return nanoseconds(fromSeconds: seconds)
        }

        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: rawValue) {
                return nanoseconds(fromSeconds: max(0, date.timeIntervalSince(now)))
            }
        }
        return nil
    }

    private static func nanoseconds(fromSeconds seconds: Double) -> UInt64 {
        let value = seconds * 1_000_000_000
        guard value < Double(UInt64.max) else { return .max }
        return UInt64(value.rounded(.up))
    }
}

private extension UInt64 {
    func addingWithoutOverflow(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }

    func multipliedWithoutOverflow(by other: UInt64) -> UInt64 {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : result
    }
}
