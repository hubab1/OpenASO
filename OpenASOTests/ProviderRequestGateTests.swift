import Foundation
import Synchronization
import Testing
@testable import OpenASO

@MainActor
struct ProviderRequestGateTests {
    @Test
    func pacesRequestsPerProviderWithoutSerializingDifferentProviders() async throws {
        let sameProviderClock = AdvancingProviderClock()
        let sameProviderTransport = ControlledProviderHTTPClient(now: sameProviderClock.now)
        let sameProviderGate = makeGate(
            base: sameProviderTransport,
            policy: makePolicy(minimumIntervalNanoseconds: 100, maximumAttempts: 1),
            clock: sameProviderClock.clock
        )
        let first = request("https://itunes.apple.com/search?term=first")
        let second = request("https://itunes.apple.com/search?term=second")

        let firstOutput = Task { try await sameProviderGate.data(for: first) }
        await sameProviderTransport.waitForRequestCount(1)
        let secondOutput = Task { try await sameProviderGate.data(for: second) }
        await sameProviderTransport.waitForRequestCount(2)
        #expect(await sameProviderTransport.resumeRequest(1))
        #expect(await sameProviderTransport.resumeRequest(2))
        _ = try await (firstOutput.value, secondOutput.value)

        #expect(await sameProviderTransport.startTimes().sorted() == [0, 100])

        let independentClock = AdvancingProviderClock()
        let independentTransport = ScriptedProviderHTTPClient(
            steps: [.response(), .response()],
            now: independentClock.now
        )
        let independentGate = makeGate(
            base: independentTransport,
            policy: makePolicy(minimumIntervalNanoseconds: 100, maximumAttempts: 1),
            clock: independentClock.clock
        )

        async let iTunesOutput = independentGate.data(
            for: request("https://itunes.apple.com/search?term=provider-a")
        )
        async let appStoreOutput = independentGate.data(
            for: request("https://apps.apple.com/us/app/id123")
        )
        _ = try await (iTunesOutput, appStoreOutput)

        #expect(await independentTransport.startTimes().sorted() == [0, 0])
    }

    @Test
    func unknownOriginsNormalizeDefaultPortsForPacing() async throws {
        let clock = AdvancingProviderClock()
        let transport = ControlledProviderHTTPClient(now: clock.now)
        let gate = makeGate(
            base: transport,
            policy: makePolicy(minimumIntervalNanoseconds: 100, maximumAttempts: 1),
            clock: clock.clock
        )
        let first = Task {
            try await gate.data(for: request("https://example.test/first"))
        }
        await transport.waitForRequestCount(1)
        let second = Task {
            try await gate.data(for: request("https://example.test:443/second"))
        }
        await transport.waitForRequestCount(2)

        #expect(await transport.resumeRequest(1))
        #expect(await transport.resumeRequest(2))
        _ = try await (first.value, second.value)
        #expect(await transport.startTimes() == [0, 100])
    }

    @Test
    func concurrentIdenticalSafeRequestsShareOnePhysicalRequest() async throws {
        let transport = ControlledProviderHTTPClient()
        let gate = makeGate(base: transport)
        let target = request("https://itunes.apple.com/search?term=shared")

        let first = Task { try await gate.data(for: target) }
        await transport.waitForRequestCount(1)
        let second = Task { try await gate.data(for: target) }
        let joined = await waitForWaiterCount(2, in: gate)

        #expect(joined)
        #expect(await transport.requestCount() == 1)
        #expect(await transport.resumeRequest(1, data: Data("shared".utf8)))
        #expect(try await first.value.0 == Data("shared".utf8))
        #expect(try await second.value.0 == Data("shared".utf8))
        #expect(await gate.snapshot() == ProviderRequestGateSnapshot(
            inFlightRequestCount: 0,
            waiterCount: 0
        ))
    }

    @Test
    func requestFingerprintSeparatesCredentialsBodiesAndRefreshRuns() async throws {
        var firstCredentialsRequest = request("https://itunes.apple.com/search?term=private")
        firstCredentialsRequest.setValue("Bearer account-a", forHTTPHeaderField: "Authorization")
        var secondCredentialsRequest = firstCredentialsRequest
        secondCredentialsRequest.setValue("Bearer account-b", forHTTPHeaderField: "Authorization")
        try await expectDistinctPhysicalRequests(firstCredentialsRequest, secondCredentialsRequest)

        var firstBodyRequest = request(
            "https://app-ads.apple.com/cm/api/v2/keywords/popularities?adamId=1",
            method: "POST"
        )
        firstBodyRequest.setValue("cookie=account-a", forHTTPHeaderField: "Cookie")
        firstBodyRequest.httpBody = Data(#"{"terms":["first"]}"#.utf8)
        var secondBodyRequest = firstBodyRequest
        secondBodyRequest.httpBody = Data(#"{"terms":["second"]}"#.utf8)
        try await expectDistinctPhysicalRequests(firstBodyRequest, secondBodyRequest)

        let defaultExecutionRequest = request("https://itunes.apple.com/lookup?id=execution")
        var serviceTypeRequest = defaultExecutionRequest
        serviceTypeRequest.networkServiceType = .responsiveData
        try await expectDistinctPhysicalRequests(defaultExecutionRequest, serviceTypeRequest)

        var constrainedRequest = defaultExecutionRequest
        constrainedRequest.allowsConstrainedNetworkAccess.toggle()
        try await expectDistinctPhysicalRequests(defaultExecutionRequest, constrainedRequest)

        var http3Request = defaultExecutionRequest
        http3Request.assumesHTTP3Capable.toggle()
        try await expectDistinctPhysicalRequests(defaultExecutionRequest, http3Request)

        var dnssecRequest = defaultExecutionRequest
        dnssecRequest.requiresDNSSECValidation.toggle()
        try await expectDistinctPhysicalRequests(defaultExecutionRequest, dnssecRequest)

        let transport = ControlledProviderHTTPClient()
        let gate = makeGate(base: transport)
        let sharedRequest = request("https://itunes.apple.com/lookup?id=123")
        let firstRunID = UUID()
        let secondRunID = UUID()
        let first = Task {
            try await RefreshObservationScope.$runID.withValue(firstRunID) {
                try await gate.data(for: sharedRequest)
            }
        }
        let second = Task {
            try await RefreshObservationScope.$runID.withValue(secondRunID) {
                try await gate.data(for: sharedRequest)
            }
        }

        await transport.waitForRequestCount(2)
        #expect(await transport.resumeRequest(1))
        #expect(await transport.resumeRequest(2))
        _ = try await (first.value, second.value)
    }

    @Test
    func unknownMutationsArePacedButNeverRetriedOrDeduplicated() async throws {
        let controlledTransport = ControlledProviderHTTPClient()
        let gate = makeGate(base: controlledTransport)
        var mutation = request(
            "https://api.appstoreconnect.apple.com/v1/customerReviewResponses",
            method: "POST"
        )
        mutation.httpBody = Data(#"{"data":"same mutation"}"#.utf8)

        let first = Task { try await gate.data(for: mutation) }
        let second = Task { try await gate.data(for: mutation) }
        await controlledTransport.waitForRequestCount(2)

        #expect(await gate.snapshot().inFlightRequestCount == 0)
        #expect(await controlledTransport.resumeRequest(1))
        #expect(await controlledTransport.resumeRequest(2))
        _ = try await (first.value, second.value)

        let retryTransport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 200)]
        )
        let retryGate = makeGate(
            base: retryTransport,
            policy: makePolicy(maximumAttempts: 3)
        )
        let output = try await retryGate.data(for: mutation)

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 503)
        #expect(await retryTransport.requestCount() == 1)
    }

    @Test
    func streamedBodiesAreNeverRetriedOrDeduplicated() async throws {
        func streamedPopularityRequest() -> URLRequest {
            var streamedRequest = request(
                "https://app-ads.apple.com/cm/api/v2/keywords/popularities?adamId=1",
                method: "POST"
            )
            streamedRequest.httpBodyStream = InputStream(
                data: Data(#"{"terms":["shared"]}"#.utf8)
            )
            return streamedRequest
        }

        let controlledTransport = ControlledProviderHTTPClient()
        let gate = makeGate(base: controlledTransport)
        let first = Task { try await gate.data(for: streamedPopularityRequest()) }
        let second = Task { try await gate.data(for: streamedPopularityRequest()) }
        await controlledTransport.waitForRequestCount(2)

        #expect(await gate.snapshot().inFlightRequestCount == 0)
        #expect(await controlledTransport.resumeRequest(1))
        #expect(await controlledTransport.resumeRequest(2))
        _ = try await (first.value, second.value)

        let retryTransport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 200)]
        )
        let retryGate = makeGate(
            base: retryTransport,
            policy: makePolicy(maximumAttempts: 3)
        )
        let output = try await retryGate.data(for: streamedPopularityRequest())

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 503)
        #expect(await retryTransport.requestCount() == 1)
    }

    @Test
    func replaySafeHEADAndPopularityRequestsRetryAndDeduplicate() async throws {
        let headRequest = request(
            "https://itunes.apple.com/search?term=head",
            method: "HEAD"
        )
        try await expectRetryAndDeduplication(for: headRequest)

        var popularityRequest = request(
            "https://app-ads.apple.com/cm/api/v2/keywords/popularities?adamId=1",
            method: "POST"
        )
        popularityRequest.httpBody = Data(#"{"terms":["shared"]}"#.utf8)
        try await expectRetryAndDeduplication(for: popularityRequest)
    }

    @Test
    func identityTokenPostsRetryButDoNotDeduplicate() async throws {
        var tokenRequest = request(
            "https://appleid.apple.com/auth/oauth2/token",
            method: "POST"
        )
        tokenRequest.httpBody = Data("grant_type=client_credentials".utf8)

        let controlledTransport = ControlledProviderHTTPClient()
        let gate = makeGate(base: controlledTransport)
        let first = Task { try await gate.data(for: tokenRequest) }
        let second = Task { try await gate.data(for: tokenRequest) }
        await controlledTransport.waitForRequestCount(2)

        #expect(await gate.snapshot().inFlightRequestCount == 0)
        #expect(await controlledTransport.resumeRequest(1))
        #expect(await controlledTransport.resumeRequest(2))
        _ = try await (first.value, second.value)

        let clock = AdvancingProviderClock()
        let retryTransport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 200)],
            now: clock.now
        )
        let retryGate = makeGate(
            base: retryTransport,
            policy: makePolicy(
                maximumAttempts: 2,
                baseBackoffNanoseconds: 10,
                maximumElapsedNanoseconds: 100
            ),
            clock: clock.clock
        )
        let output = try await retryGate.data(for: tokenRequest)

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await retryTransport.requestCount() == 2)
    }

    @Test
    func nearMatchPopularityAndIdentityPostsRemainPaceOnly() async throws {
        let nearMatches = [
            "https://app-ads.apple.com/cm/api/v2/keywords/popularities/delete?adamId=1",
            "http://app-ads.apple.com/cm/api/v2/keywords/popularities?adamId=1",
            "https://app-ads.apple.com:444/cm/api/v2/keywords/popularities?adamId=1",
            "https://app-ads.apple.com/cm/api/v2/keywords/popularities?adamId=1&action=delete",
            "http://appleid.apple.com/auth/oauth2/token",
            "https://appleid.apple.com/auth/oauth2/token?unexpected=1",
        ]

        for url in nearMatches {
            let transport = ScriptedProviderHTTPClient(
                steps: [.response(statusCode: 503), .response(statusCode: 200)]
            )
            let gate = makeGate(
                base: transport,
                policy: makePolicy(maximumAttempts: 2)
            )
            let output = try await gate.data(for: request(url, method: "POST"))

            #expect((output.1 as? HTTPURLResponse)?.statusCode == 503)
            #expect(await transport.requestCount() == 1)
        }
    }

    @Test
    func cancellingOneWaiterDoesNotCancelSharedTransport() async throws {
        let transport = ControlledProviderHTTPClient()
        let gate = makeGate(base: transport)
        let target = request("https://itunes.apple.com/search?term=waiters")
        let first = Task { try await gate.data(for: target) }
        await transport.waitForRequestCount(1)
        let second = Task { try await gate.data(for: target) }
        #expect(await waitForWaiterCount(2, in: gate))

        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }

        #expect(await transport.cancellationCount() == 0)
        #expect(await gate.snapshot().waiterCount == 1)
        #expect(await transport.resumeRequest(1, data: Data("survivor".utf8)))
        #expect(try await second.value.0 == Data("survivor".utf8))
    }

    @Test
    func cancelledDeduplicatedWaiterNeverObservesSharedFailure() async throws {
        let transport = ControlledProviderHTTPClient(cancelsPendingRequests: false)
        let gate = makeGate(base: transport)
        let task = Task {
            try await gate.data(
                for: request("https://itunes.apple.com/search?term=cancelled-failure")
            )
        }
        await transport.waitForRequestCount(1)

        task.cancel()
        #expect(await transport.failRequest(1, with: .badServerResponse))

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func finalWaiterCancellationCancelsTransportAndStaleCompletionCannotWin() async throws {
        let transport = ControlledProviderHTTPClient(cancelsPendingRequests: false)
        let gate = makeGate(base: transport)
        let target = request("https://itunes.apple.com/search?term=generation")
        let first = Task { try await gate.data(for: target) }
        await transport.waitForRequestCount(1)
        let second = Task { try await gate.data(for: target) }
        #expect(await waitForWaiterCount(2, in: gate))

        first.cancel()
        second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        await transport.waitForCancellationCount(1)
        #expect(await gate.snapshot().inFlightRequestCount == 0)

        let fresh = Task { try await gate.data(for: target) }
        await transport.waitForRequestCount(2)
        #expect(await waitForWaiterCount(1, in: gate))

        #expect(await transport.resumeRequest(1, data: Data("stale".utf8)))
        await Task.yield()
        #expect(await gate.snapshot() == ProviderRequestGateSnapshot(
            inFlightRequestCount: 1,
            waiterCount: 1
        ))

        #expect(await transport.resumeRequest(2, data: Data("fresh".utf8)))
        #expect(try await fresh.value.0 == Data("fresh".utf8))
    }

    @Test
    func preCancelledCallerNeverStartsTransport() async throws {
        let latch = AsyncProviderLatch()
        let transport = ControlledProviderHTTPClient()
        let gate = makeGate(base: transport)
        let target = request("https://itunes.apple.com/search?term=cancelled")
        let task = Task {
            await latch.wait()
            return try await gate.data(for: target)
        }
        await latch.waitUntilWaiting()

        task.cancel()
        await latch.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await transport.requestCount() == 0)
        #expect(await gate.snapshot().inFlightRequestCount == 0)
    }

    @Test
    func cancellationWinsWhenTransportThrowsADifferentError() async throws {
        let transport = ControlledProviderHTTPClient(cancelsPendingRequests: false)
        let gate = makeGate(base: transport)
        let task = Task {
            try await gate.data(
                for: request(
                    "https://api.appstoreconnect.apple.com/v1/mutation",
                    method: "POST"
                )
            )
        }
        await transport.waitForRequestCount(1)

        task.cancel()
        await transport.waitForCancellationCount(1)
        #expect(await transport.failRequest(1, with: .badServerResponse))

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func numericRetryAfterIsUsedWithoutJitter() async throws {
        let clock = AdvancingProviderClock()
        let randomness = SequenceProviderRandomness([0])
        let transport = ScriptedProviderHTTPClient(
            steps: [
                .response(statusCode: 429, headers: ["Retry-After": "2"]),
                .response(statusCode: 200),
            ],
            now: clock.now
        )
        let gate = makeGate(
            base: transport,
            policy: makePolicy(
                maximumAttempts: 2,
                maximumElapsedNanoseconds: 3_000_000_000,
                jitterFraction: 1
            ),
            clock: clock.clock,
            randomness: randomness.randomness
        )

        let output = try await gate.data(
            for: request("https://itunes.apple.com/search?term=retry-after")
        )

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await transport.startTimes() == [0, 2_000_000_000])
        #expect(randomness.callCount == 0)
    }

    @Test
    func terminalRetryAfterStillAppliesProviderCooldown() async throws {
        let clock = ManualProviderClock()
        let transport = ControlledProviderHTTPClient(now: clock.now)
        let gate = makeGate(
            base: transport,
            policy: makePolicy(maximumAttempts: 1),
            clock: clock.clock
        )
        let first = Task {
            try await gate.data(
                for: request("https://itunes.apple.com/search?term=terminal-rate-limit")
            )
        }
        await transport.waitForRequestCount(1)
        #expect(await transport.resumeRequest(
            1,
            statusCode: 429,
            headers: ["Retry-After": "0.2"]
        ))
        #expect((try await first.value.1 as? HTTPURLResponse)?.statusCode == 429)

        let second = Task {
            try await gate.data(
                for: request("https://itunes.apple.com/search?term=after-rate-limit")
            )
        }
        #expect(await waitForPendingSleep(200_000_000, in: clock))
        #expect(await transport.requestCount() == 1)

        clock.advance(to: 200_000_000)
        await transport.waitForRequestCount(2)
        #expect(await transport.resumeRequest(2))
        _ = try await second.value
        #expect(await transport.startTimes() == [0, 200_000_000])
    }

    @Test
    func paceOnlyRetryAfterStillAppliesProviderCooldown() async throws {
        let clock = ManualProviderClock()
        let transport = ControlledProviderHTTPClient(now: clock.now)
        let gate = makeGate(
            base: transport,
            policy: makePolicy(maximumAttempts: 3),
            clock: clock.clock
        )
        let mutation = Task {
            try await gate.data(
                for: request("https://itunes.apple.com/mutation", method: "POST")
            )
        }
        await transport.waitForRequestCount(1)
        #expect(await transport.resumeRequest(
            1,
            statusCode: 429,
            headers: ["Retry-After": "0.2"]
        ))
        #expect((try await mutation.value.1 as? HTTPURLResponse)?.statusCode == 429)

        let next = Task {
            try await gate.data(
                for: request("https://itunes.apple.com/search?term=after-mutation-rate-limit")
            )
        }
        #expect(await waitForPendingSleep(200_000_000, in: clock))
        #expect(await transport.requestCount() == 1)

        clock.advance(to: 200_000_000)
        await transport.waitForRequestCount(2)
        #expect(await transport.resumeRequest(2))
        _ = try await next.value
    }

    @Test
    func HTTPDateRetryAfterUsesInjectedWallClock() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_735_689_600)
        let clock = AdvancingProviderClock(baseDate: baseDate)
        let transport = ScriptedProviderHTTPClient(
            steps: [
                .response(
                    statusCode: 503,
                    headers: ["Retry-After": "Wed, 01 Jan 2025 00:00:03 GMT"]
                ),
                .response(statusCode: 200),
            ],
            now: clock.now
        )
        let gate = makeGate(
            base: transport,
            policy: makePolicy(
                maximumAttempts: 2,
                maximumElapsedNanoseconds: 4_000_000_000
            ),
            clock: clock.clock
        )

        let output = try await gate.data(
            for: request("https://apps.apple.com/us/app/id123")
        )

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await transport.startTimes() == [0, 3_000_000_000])
    }

    @Test
    func exponentialBackoffIsCappedAndDeterministicallyJittered() async throws {
        let clock = AdvancingProviderClock()
        let randomness = SequenceProviderRandomness([0, 1, 0.5])
        let transport = ScriptedProviderHTTPClient(
            steps: [
                .response(statusCode: 503),
                .response(statusCode: 503),
                .response(statusCode: 503),
                .response(statusCode: 200),
            ],
            now: clock.now
        )
        let gate = makeGate(
            base: transport,
            policy: makePolicy(
                maximumAttempts: 4,
                baseBackoffNanoseconds: 100,
                maximumBackoffNanoseconds: 250,
                maximumElapsedNanoseconds: 1_000,
                jitterFraction: 0.5
            ),
            clock: clock.clock,
            randomness: randomness.randomness
        )

        _ = try await gate.data(
            for: request("https://itunes.apple.com/search?term=backoff")
        )

        #expect(await transport.startTimes() == [0, 50, 250, 438])
        #expect(randomness.callCount == 3)
    }

    @Test
    func attemptAndElapsedBudgetsStopRetries() async throws {
        let attemptClock = AdvancingProviderClock()
        let attemptTransport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 503), .response(statusCode: 200)],
            now: attemptClock.now
        )
        let attemptGate = makeGate(
            base: attemptTransport,
            policy: makePolicy(
                maximumAttempts: 2,
                baseBackoffNanoseconds: 10,
                maximumElapsedNanoseconds: 100
            ),
            clock: attemptClock.clock
        )
        let attemptOutput = try await attemptGate.data(
            for: request("https://itunes.apple.com/search?term=attempt-cap")
        )

        #expect((attemptOutput.1 as? HTTPURLResponse)?.statusCode == 503)
        #expect(await attemptTransport.requestCount() == 2)

        let elapsedClock = AdvancingProviderClock()
        let elapsedTransport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 200)],
            now: elapsedClock.now
        )
        let elapsedGate = makeGate(
            base: elapsedTransport,
            policy: makePolicy(
                maximumAttempts: 3,
                baseBackoffNanoseconds: 600,
                maximumBackoffNanoseconds: 600,
                maximumElapsedNanoseconds: 500
            ),
            clock: elapsedClock.clock
        )
        let elapsedOutput = try await elapsedGate.data(
            for: request("https://itunes.apple.com/search?term=elapsed-cap")
        )

        #expect((elapsedOutput.1 as? HTTPURLResponse)?.statusCode == 503)
        #expect(await elapsedTransport.requestCount() == 1)
    }

    @Test
    func pacingCannotPushRetryDispatchPastElapsedBudget() async throws {
        let clock = AdvancingProviderClock()
        let transport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 200)],
            now: clock.now
        )
        let gate = makeGate(
            base: transport,
            policy: makePolicy(
                minimumIntervalNanoseconds: 200,
                maximumAttempts: 2,
                baseBackoffNanoseconds: 10,
                maximumElapsedNanoseconds: 100
            ),
            clock: clock.clock
        )

        let output = try await gate.data(
            for: request("https://itunes.apple.com/search?term=paced-elapsed-cap")
        )

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 503)
        #expect(await transport.startTimes() == [0])
    }

    @Test
    func authenticationAndPermanentResponsesAreNotRetried() async throws {
        for statusCode in [400, 401, 403, 404] {
            let transport = ScriptedProviderHTTPClient(
                steps: [.response(statusCode: statusCode), .response(statusCode: 200)]
            )
            let gate = makeGate(
                base: transport,
                policy: makePolicy(maximumAttempts: 3)
            )

            let output = try await gate.data(
                for: request("https://api.searchads.apple.com/api/v5/campaigns")
            )

            #expect((output.1 as? HTTPURLResponse)?.statusCode == statusCode)
            #expect(await transport.requestCount() == 1)
        }
    }

    @Test
    func onlyTransientTransportErrorsAreRetried() async throws {
        let transientClock = AdvancingProviderClock()
        let transientTransport = ScriptedProviderHTTPClient(
            steps: [.urlError(.timedOut), .response(statusCode: 200)],
            now: transientClock.now
        )
        let transientGate = makeGate(
            base: transientTransport,
            policy: makePolicy(
                maximumAttempts: 2,
                baseBackoffNanoseconds: 10,
                maximumElapsedNanoseconds: 100
            ),
            clock: transientClock.clock
        )

        _ = try await transientGate.data(
            for: request("https://itunes.apple.com/search?term=transport")
        )
        #expect(await transientTransport.requestCount() == 2)

        for errorCode in [URLError.Code.badURL, .userAuthenticationRequired] {
            let permanentTransport = ScriptedProviderHTTPClient(
                steps: [.urlError(errorCode), .response(statusCode: 200)]
            )
            let permanentGate = makeGate(
                base: permanentTransport,
                policy: makePolicy(maximumAttempts: 2)
            )

            await #expect(throws: URLError.self) {
                _ = try await permanentGate.data(
                    for: request("https://itunes.apple.com/search?term=permanent")
                )
            }
            #expect(await permanentTransport.requestCount() == 1)
        }
    }

    @Test
    func cancellationDuringBackoffStopsBeforeAnotherAttempt() async throws {
        let clock = ManualProviderClock()
        let transport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 200)],
            now: clock.now
        )
        let gate = makeGate(
            base: transport,
            policy: makePolicy(
                maximumAttempts: 2,
                baseBackoffNanoseconds: 100,
                maximumElapsedNanoseconds: 1_000
            ),
            clock: clock.clock
        )
        let task = Task {
            try await gate.data(
                for: request("https://itunes.apple.com/search?term=cancel-backoff")
            )
        }
        #expect(await waitForPendingSleep(100, in: clock))

        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.requestCount() == 1)
        #expect(await gate.snapshot().inFlightRequestCount == 0)
    }

    @Test
    func lateWakeupsRevalidateActualDispatchSpacing() async throws {
        let clock = ManualProviderClock()
        let transport = ControlledProviderHTTPClient(now: clock.now)
        let gate = makeGate(
            base: transport,
            policy: makePolicy(minimumIntervalNanoseconds: 100, maximumAttempts: 1),
            clock: clock.clock
        )
        let first = Task {
            try await gate.data(for: request("https://itunes.apple.com/search?term=late-a"))
        }
        await transport.waitForRequestCount(1)
        let second = Task {
            try await gate.data(for: request("https://itunes.apple.com/search?term=late-b"))
        }
        let third = Task {
            try await gate.data(for: request("https://itunes.apple.com/search?term=late-c"))
        }
        #expect(await waitForPendingSleepCount(2, deadline: 100, in: clock))

        clock.advance(to: 1_000)
        await transport.waitForRequestCount(2)
        #expect(await waitForPendingSleep(1_100, in: clock))
        #expect(await transport.requestCount() == 2)

        #expect(await transport.resumeRequest(1))
        #expect(await transport.resumeRequest(2))
        clock.advance(to: 1_100)
        await transport.waitForRequestCount(3)
        #expect(await transport.resumeRequest(3))
        _ = try await (first.value, second.value, third.value)

        #expect(await transport.startTimes() == [0, 1_000, 1_100])
    }

    @Test
    func cancellingPacingWaitDoesNotReserveGhostSlot() async throws {
        let clock = ManualProviderClock()
        let transport = ControlledProviderHTTPClient(now: clock.now)
        let gate = makeGate(
            base: transport,
            policy: makePolicy(minimumIntervalNanoseconds: 100, maximumAttempts: 1),
            clock: clock.clock
        )
        let first = Task {
            try await gate.data(for: request("https://itunes.apple.com/search?term=ghost-a"))
        }
        await transport.waitForRequestCount(1)
        let cancelled = Task {
            try await gate.data(for: request("https://itunes.apple.com/search?term=ghost-b"))
        }
        #expect(await waitForPendingSleep(100, in: clock))

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }

        let replacement = Task {
            try await gate.data(for: request("https://itunes.apple.com/search?term=ghost-c"))
        }
        #expect(await waitForPendingSleep(100, in: clock))
        clock.advance(to: 100)
        await transport.waitForRequestCount(2)

        #expect(await transport.resumeRequest(1))
        #expect(await transport.resumeRequest(2))
        _ = try await (first.value, replacement.value)
        #expect(await transport.startTimes() == [0, 100])
    }

    @Test
    func providerCooldownIsRecheckedImmediatelyBeforeDispatch() async throws {
        let clock = ManualProviderClock()
        let transport = ControlledProviderHTTPClient(now: clock.now)
        let gate = makeGate(
            base: transport,
            policy: makePolicy(
                minimumIntervalNanoseconds: 50_000_000,
                maximumAttempts: 2,
                baseBackoffNanoseconds: 10_000_000,
                maximumElapsedNanoseconds: 500_000_000
            ),
            clock: clock.clock
        )
        let firstRequest = request("https://itunes.apple.com/search?term=cooldown-a")
        let secondRequest = request("https://itunes.apple.com/search?term=cooldown-b")
        let first = Task { try await gate.data(for: firstRequest) }
        await transport.waitForRequestCount(1)
        let second = Task { try await gate.data(for: secondRequest) }
        #expect(await waitForPendingSleep(50_000_000, in: clock))

        #expect(await transport.resumeRequest(
            1,
            statusCode: 429,
            headers: ["Retry-After": "0.2"]
        ))
        #expect(await waitForPendingSleep(200_000_000, in: clock))

        clock.advance(to: 50_000_000)
        #expect(await waitForPendingSleepCount(
            2,
            deadline: 200_000_000,
            in: clock
        ))
        #expect(await transport.requestCount() == 1)

        clock.advance(to: 200_000_000)
        await transport.waitForRequestCount(2)
        #expect(await waitForPendingSleep(250_000_000, in: clock))
        #expect(await transport.resumeRequest(2, data: Data("request-2".utf8)))

        clock.advance(to: 250_000_000)
        await transport.waitForRequestCount(3)
        #expect(await transport.resumeRequest(3, data: Data("request-3".utf8)))

        let firstData = try await first.value.0
        let secondData = try await second.value.0
        #expect(Set([firstData, secondData]) == Set([
            Data("request-2".utf8),
            Data("request-3".utf8),
        ]))
        #expect(await transport.startTimes() == [0, 200_000_000, 250_000_000])
    }

    private func expectDistinctPhysicalRequests(
        _ firstRequest: URLRequest,
        _ secondRequest: URLRequest
    ) async throws {
        let transport = ControlledProviderHTTPClient()
        let gate = makeGate(base: transport)
        let first = Task { try await gate.data(for: firstRequest) }
        let second = Task { try await gate.data(for: secondRequest) }

        await transport.waitForRequestCount(2)
        #expect(await transport.resumeRequest(1))
        #expect(await transport.resumeRequest(2))
        _ = try await (first.value, second.value)
    }

    private func expectRetryAndDeduplication(for target: URLRequest) async throws {
        let controlledTransport = ControlledProviderHTTPClient()
        let gate = makeGate(base: controlledTransport)
        let first = Task { try await gate.data(for: target) }
        await controlledTransport.waitForRequestCount(1)
        let second = Task { try await gate.data(for: target) }

        #expect(await waitForWaiterCount(2, in: gate))
        #expect(await controlledTransport.requestCount() == 1)
        #expect(await controlledTransport.resumeRequest(1))
        _ = try await (first.value, second.value)

        let clock = AdvancingProviderClock()
        let retryTransport = ScriptedProviderHTTPClient(
            steps: [.response(statusCode: 503), .response(statusCode: 200)],
            now: clock.now
        )
        let retryGate = makeGate(
            base: retryTransport,
            policy: makePolicy(
                maximumAttempts: 2,
                baseBackoffNanoseconds: 10,
                maximumElapsedNanoseconds: 100
            ),
            clock: clock.clock
        )
        let output = try await retryGate.data(for: target)

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await retryTransport.requestCount() == 2)
    }
}

@MainActor
private func makeGate(
    base: any HTTPClient,
    policy: ProviderRequestPolicy = makePolicy(),
    clock: ProviderRequestClock = AdvancingProviderClock().clock,
    randomness: ProviderRequestRandomness = ProviderRequestRandomness(unitInterval: { 0.5 })
) -> ProviderRequestGate {
    ProviderRequestGate(
        base: base,
        policies: ProviderRequestPolicies(default: policy),
        clock: clock,
        randomness: randomness
    )
}

private func makePolicy(
    minimumIntervalNanoseconds: UInt64 = 0,
    maximumAttempts: Int = 1,
    baseBackoffNanoseconds: UInt64 = 100,
    maximumBackoffNanoseconds: UInt64 = 1_000,
    maximumElapsedNanoseconds: UInt64 = 10_000,
    jitterFraction: Double = 0
) -> ProviderRequestPolicy {
    ProviderRequestPolicy(
        minimumIntervalNanoseconds: minimumIntervalNanoseconds,
        maximumAttempts: maximumAttempts,
        baseBackoffNanoseconds: baseBackoffNanoseconds,
        maximumBackoffNanoseconds: maximumBackoffNanoseconds,
        maximumElapsedNanoseconds: maximumElapsedNanoseconds,
        jitterFraction: jitterFraction
    )
}

private func request(_ urlString: String, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: URL(string: urlString)!)
    request.httpMethod = method
    return request
}

private func waitForWaiterCount(
    _ expectedCount: Int,
    in gate: ProviderRequestGate
) async -> Bool {
    for _ in 0 ..< 2_000 {
        if await gate.snapshot().waiterCount == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}

private func waitForPendingSleep(
    _ deadline: UInt64,
    in clock: ManualProviderClock
) async -> Bool {
    for _ in 0 ..< 2_000 {
        if clock.pendingDeadlines.contains(deadline) {
            return true
        }
        await Task.yield()
    }
    return false
}

private func waitForPendingSleepCount(
    _ expectedCount: Int,
    deadline: UInt64,
    in clock: ManualProviderClock
) async -> Bool {
    for _ in 0 ..< 2_000 {
        if clock.pendingDeadlines.filter({ $0 == deadline }).count == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}

private final class AdvancingProviderClock: Sendable {
    private struct State {
        var now: UInt64 = 0
        var deadlines: [UInt64] = []
    }

    private let state = Mutex(State())
    private let baseDate: Date

    init(baseDate: Date = Date(timeIntervalSince1970: 0)) {
        self.baseDate = baseDate
    }

    var clock: ProviderRequestClock {
        ProviderRequestClock(
            nowNanoseconds: now,
            nowDate: {
                self.baseDate.addingTimeInterval(Double(self.now()) / 1_000_000_000)
            },
            sleepUntilNanoseconds: { deadline in
                try Task.checkCancellation()
                self.state.withLock { state in
                    state.deadlines.append(deadline)
                    state.now = max(state.now, deadline)
                }
                try Task.checkCancellation()
            }
        )
    }

    func now() -> UInt64 {
        state.withLock { $0.now }
    }
}

private final class ManualProviderClock: Sendable {
    private struct PendingSleep {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: UInt64 = 0
        var pending: [UUID: PendingSleep] = [:]
        var cancelledBeforeRegistration: Set<UUID> = []
    }

    private let state = Mutex(State())
    private let baseDate: Date

    init(baseDate: Date = Date(timeIntervalSince1970: 0)) {
        self.baseDate = baseDate
    }

    var clock: ProviderRequestClock {
        ProviderRequestClock(
            nowNanoseconds: now,
            nowDate: {
                self.baseDate.addingTimeInterval(Double(self.now()) / 1_000_000_000)
            },
            sleepUntilNanoseconds: sleep
        )
    }

    var pendingDeadlines: [UInt64] {
        state.withLock { $0.pending.values.map(\.deadline) }
    }

    func now() -> UInt64 {
        state.withLock { $0.now }
    }

    func advance(to deadline: UInt64) {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now = max(state.now, deadline)
            let readyIDs = state.pending.compactMap { id, sleep in
                sleep.deadline <= state.now ? id : nil
            }
            return readyIDs.compactMap { state.pending.removeValue(forKey: $0)?.continuation }
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func sleep(until deadline: UInt64) async throws {
        try Task.checkCancellation()
        let sleepID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var resumesImmediately = false
                var resumesCancelled = false
                state.withLock { state in
                    if state.cancelledBeforeRegistration.remove(sleepID) != nil || Task.isCancelled {
                        resumesCancelled = true
                    } else if deadline <= state.now {
                        resumesImmediately = true
                    } else {
                        state.pending[sleepID] = PendingSleep(
                            deadline: deadline,
                            continuation: continuation
                        )
                    }
                }
                if resumesCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if resumesImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation = self.state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let pending = state.pending.removeValue(forKey: sleepID) {
                    return pending.continuation
                }
                state.cancelledBeforeRegistration.insert(sleepID)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class SequenceProviderRandomness: Sendable {
    private struct State {
        var values: [Double]
        var callCount = 0
    }

    private let state: Mutex<State>

    init(_ values: [Double]) {
        self.state = Mutex(State(values: values))
    }

    var randomness: ProviderRequestRandomness {
        ProviderRequestRandomness {
            self.state.withLock { state in
                defer { state.callCount += 1 }
                guard !state.values.isEmpty else { return 0.5 }
                return state.values.removeFirst()
            }
        }
    }

    var callCount: Int {
        state.withLock { $0.callCount }
    }
}

private actor ScriptedProviderHTTPClient: HTTPClient {
    enum Step: Sendable {
        case response(statusCode: Int = 200, headers: [String: String] = [:], data: Data = Data())
        case urlError(URLError.Code)
    }

    private var steps: [Step]
    private let nowProvider: @Sendable () -> UInt64
    private var starts: [UInt64] = []

    init(
        steps: [Step],
        now: @escaping @Sendable () -> UInt64 = { 0 }
    ) {
        self.steps = steps
        self.nowProvider = now
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        starts.append(nowProvider())
        guard !steps.isEmpty else {
            throw UnexpectedProviderRequest()
        }
        let step = steps.removeFirst()
        switch step {
        case .response(let statusCode, let headers, let data):
            return (
                data,
                makeHTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.invalid")!,
                    statusCode: statusCode,
                    headerFields: headers
                )
            )
        case .urlError(let code):
            throw URLError(code)
        }
    }

    func requestCount() -> Int {
        starts.count
    }

    func startTimes() -> [UInt64] {
        starts
    }
}

private actor ControlledProviderHTTPClient: HTTPClient {
    private struct PendingRequest {
        let request: URLRequest
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
    }

    private let cancelsPendingRequests: Bool
    private let nowProvider: @Sendable () -> UInt64
    private var nextRequestID = 0
    private var pending: [Int: PendingRequest] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var starts: [UInt64] = []
    private var cancellations = 0

    init(
        cancelsPendingRequests: Bool = true,
        now: @escaping @Sendable () -> UInt64 = { 0 }
    ) {
        self.cancelsPendingRequests = cancelsPendingRequests
        self.nowProvider = now
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        nextRequestID += 1
        let requestID = nextRequestID
        starts.append(nowProvider())
        resumeCountWaitersIfNeeded()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[requestID] = PendingRequest(
                    request: request,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelRequest(requestID)
            }
        }
    }

    func requestCount() -> Int {
        nextRequestID
    }

    func cancellationCount() -> Int {
        cancellations
    }

    func startTimes() -> [UInt64] {
        starts
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        guard nextRequestID < expectedCount else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((expectedCount, continuation))
        }
    }

    func waitForCancellationCount(_ expectedCount: Int) async {
        guard cancellations < expectedCount else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((expectedCount, continuation))
        }
    }

    func resumeRequest(
        _ requestID: Int,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        data: Data = Data()
    ) -> Bool {
        guard let pending = pending.removeValue(forKey: requestID) else { return false }
        pending.continuation.resume(returning: (
            data,
            makeHTTPURLResponse(
                url: pending.request.url ?? URL(string: "https://example.invalid")!,
                statusCode: statusCode,
                headerFields: headers
            )
        ))
        return true
    }

    func failRequest(_ requestID: Int, with code: URLError.Code) -> Bool {
        guard let pending = pending.removeValue(forKey: requestID) else { return false }
        pending.continuation.resume(throwing: URLError(code))
        return true
    }

    private func cancelRequest(_ requestID: Int) {
        cancellations += 1
        if cancelsPendingRequests,
           let pending = pending.removeValue(forKey: requestID) {
            pending.continuation.resume(throwing: CancellationError())
        }
        resumeCancellationWaitersIfNeeded()
    }

    private func resumeCountWaitersIfNeeded() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in countWaiters {
            if nextRequestID >= expectedCount {
                continuation.resume()
            } else {
                remaining.append((expectedCount, continuation))
            }
        }
        countWaiters = remaining
    }

    private func resumeCancellationWaitersIfNeeded() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in cancellationWaiters {
            if cancellations >= expectedCount {
                continuation.resume()
            } else {
                remaining.append((expectedCount, continuation))
            }
        }
        cancellationWaiters = remaining
    }
}

private actor AsyncProviderLatch {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let observers = waitingObservers
            waitingObservers.removeAll()
            for observer in observers {
                observer.resume()
            }
        }
    }

    func waitUntilWaiting() async {
        guard !waiters.isEmpty else {
            await withCheckedContinuation { continuation in
                waitingObservers.append(continuation)
            }
            return
        }
    }

    func release() {
        isReleased = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private struct UnexpectedProviderRequest: Error, Sendable {}
