import Foundation
import SwiftData
import Synchronization
import Testing
@testable import OpenASO

@MainActor
struct RefreshObservabilityTests {
    @Test
    func requestsOutsideRefreshScopeAreNotRecorded() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant)
        let base = CountingHTTPClient()
        let client = ObservedHTTPClient(base: base, recorder: recorder, clock: .constant)
        let request = URLRequest(url: try #require(URL(string: "https://itunes.apple.com/search?term=outside")))

        _ = try await client.data(for: request)

        #expect(await base.requestCount() == 1)
        #expect(await recorder.completedSummaries().isEmpty)
        #expect(await recorder.activeRunCount() == 0)
    }

    @Test
    func classificationUsesFixedEnumsAndSummaryIsRedacted() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant)
        let client = ObservedHTTPClient(
            base: HeaderStatusHTTPClient(),
            recorder: recorder,
            clock: .constant
        )
        let runID = await recorder.begin(
            trigger: RefreshObservationTrigger(rawValueForObservation: "secret-trigger-value"),
            workspace: .keywords,
            requestedTrackCount: 7,
            requestedStorefrontCount: 2
        )
        let cases: [(String, Int, RefreshObservationProvider, RefreshObservationEndpoint, RefreshTransportResult)] = [
            ("https://itunes.apple.com/search?term=private-keyword", 200, .iTunesStore, .rankingSearch, .success),
            ("https://apps.apple.com/us/app/private-app/id1", 302, .appStoreWeb, .ratingsPage, .redirect),
            ("https://api.appstoreconnect.apple.com/v1/apps/1/customerReviews", 401, .appStoreConnect, .appStoreConnectReviews, .authenticationFailure),
            ("https://app-ads.apple.com/cm/api/v4/searchads/keywords/popularities", 404, .appleAdsWeb, .appleAdsPopularity, .notFound),
            ("https://api.searchads.apple.com/api/v5/campaigns", 429, .appleAdsAPI, .appleAdsAPI, .rateLimited),
            ("https://appleid.apple.com/auth/oauth2/token", 500, .appleIdentity, .appleIdentity, .serverFailure),
            ("https://example.invalid/private/path", 418, .unknown, .other, .clientFailure),
        ]

        try await RefreshObservationScope.$runID.withValue(runID) {
            for (urlString, statusCode, _, _, _) in cases {
                var request = URLRequest(url: try #require(URL(string: urlString)))
                request.setValue(String(statusCode), forHTTPHeaderField: "X-Test-Status")
                request.setValue("Bearer private-access-token", forHTTPHeaderField: "Authorization")
                request.setValue("private-cookie", forHTTPHeaderField: "Cookie")
                request.httpBody = Data("private-request-body".utf8)
                _ = try await client.data(for: request)
            }
        }
        await recorder.recordRankingWork(runID: runID, resolvedCount: 6, uniqueQueryCount: 4, missingCount: 1)
        await recorder.recordStage(runID: runID, stage: .rankings, attemptedCount: 7, failureCount: 1)
        let summary = try #require(await recorder.finish(runID: runID))

        #expect(summary.trigger == .other)
        #expect(summary.result == .partialFailure)
        #expect(summary.resolvedRankingCount == 6)
        #expect(summary.uniqueRankingQueryCount == 4)
        #expect(summary.missingRankingCount == 1)
        for (_, _, provider, endpoint, result) in cases {
            let providerSummary = try #require(summary.providers[provider])
            #expect(providerSummary.requestCount == 1)
            #expect(providerSummary.endpointCounts[endpoint] == 1)
            #expect(providerSummary.resultCounts[result] == 1)
        }

        let logMessage = summary.redactedLogMessage.lowercased()
        for secret in [
            "private-keyword",
            "private-app",
            "private/path",
            "private-access-token",
            "private-cookie",
            "private-request-body",
            "secret-trigger-value",
        ] {
            #expect(!logMessage.contains(secret))
        }
    }

    @Test
    func nonHTTPAndThrownNetworkFailuresAreClassified() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant)
        let runID = await recorder.begin(
            trigger: .manual,
            workspace: .keywords,
            requestedTrackCount: 1,
            requestedStorefrontCount: 1
        )
        let nonHTTPClient = ObservedHTTPClient(
            base: NonHTTPClient(),
            recorder: recorder,
            clock: .constant
        )
        let networkClient = ObservedHTTPClient(
            base: NetworkFailureHTTPClient(),
            recorder: recorder,
            clock: .constant
        )
        let url = try #require(URL(string: "https://itunes.apple.com/lookup?id=1&country=us"))

        await RefreshObservationScope.$runID.withValue(runID) {
            _ = try? await nonHTTPClient.data(for: URLRequest(url: url))
            _ = try? await networkClient.data(for: URLRequest(url: url))
        }
        let summary = try #require(await recorder.finish(runID: runID))
        let provider = try #require(summary.providers[.iTunesStore])

        #expect(provider.requestCount == 2)
        #expect(provider.resultCounts[.nonHTTPResponse] == 1)
        #expect(provider.resultCounts[.networkFailure] == 1)
    }

    @Test
    func recorderAggregatesConcurrentEventsAndBoundsCompletedSummaries() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant, maximumCompletedSummaryCount: 2)
        let firstRunID = await recorder.begin(
            trigger: .manual,
            workspace: .keywords,
            requestedTrackCount: 120,
            requestedStorefrontCount: 1
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 1 ... 120 {
                group.addTask {
                    await recorder.recordRequest(
                        runID: firstRunID,
                        provider: .iTunesStore,
                        endpoint: .rankingSearch,
                        result: index.isMultiple(of: 10) ? .rateLimited : .success,
                        durationNanoseconds: UInt64(index),
                        isRetry: index.isMultiple(of: 12)
                    )
                }
            }
        }
        await recorder.recordStage(
            runID: firstRunID,
            stage: .rankings,
            attemptedCount: 120,
            failureCount: 12
        )
        let first = try #require(await recorder.finish(runID: firstRunID))
        let firstProvider = try #require(first.providers[.iTunesStore])

        #expect(firstProvider.requestCount == 120)
        #expect(firstProvider.retryCount == 10)
        #expect(firstProvider.totalDurationNanoseconds == 7_260)
        #expect(firstProvider.maximumDurationNanoseconds == 120)
        #expect(firstProvider.resultCounts[.rateLimited] == 12)
        #expect(firstProvider.resultCounts[.success] == 108)
        #expect(first.result == .partialFailure)
        #expect(first.redactedLogMessage.contains("totalDurationNs=7260"))
        #expect(first.redactedLogMessage.contains("maxDurationNs=120"))
        #expect(first.redactedLogMessage.contains("endpoints=[rankingSearch=120]"))

        let secondRunID = await recorder.begin(
            trigger: .daily,
            workspace: .ratings,
            requestedTrackCount: 0,
            requestedStorefrontCount: 1
        )
        await recorder.recordCancellation(runID: secondRunID)
        _ = await recorder.finish(runID: secondRunID)
        let thirdRunID = await recorder.begin(
            trigger: .manualAll,
            workspace: .keywords,
            requestedTrackCount: 0,
            requestedStorefrontCount: 0
        )
        _ = await recorder.finish(runID: thirdRunID)
        let completed = await recorder.completedSummaries()

        #expect(completed.map(\.id) == [secondRunID, thirdRunID])
        #expect(completed.first?.result == .cancelled)
        #expect(await recorder.activeRunCount() == 0)
    }

    @Test
    func gateRetryPreservesRunScopeAndRecordsPhysicalRetry() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant)
        let transport = ObservedSequenceHTTPClient(steps: [
            ObservationHTTPClientStep(
                statusCode: 429,
                headers: ["Retry-After": "0"]
            ),
            ObservationHTTPClientStep(statusCode: 200),
        ])
        let client = ProviderHTTPClientPipeline.make(
            transport: transport,
            mode: .enabled(ProviderRequestPolicies(default: ProviderRequestPolicy(
                minimumIntervalNanoseconds: 0,
                maximumAttempts: 2,
                baseBackoffNanoseconds: 0,
                maximumBackoffNanoseconds: 0,
                maximumElapsedNanoseconds: 1_000_000_000,
                jitterFraction: 0
            ))),
            refreshMetricsRecorder: recorder,
            refreshObservationClock: .constant
        )
        let runID = await recorder.begin(
            trigger: .manual,
            workspace: .ratings,
            requestedTrackCount: 0,
            requestedStorefrontCount: 1
        )

        let output = try await RefreshObservationScope.$runID.withValue(runID) {
            try await client.data(for: URLRequest(
                url: try #require(URL(string: "https://itunes.apple.com/lookup?id=123&country=us"))
            ))
        }
        await recorder.recordStage(
            runID: runID,
            stage: .ratings,
            attemptedCount: 1,
            failureCount: 0
        )
        let summary = try #require(await recorder.finish(runID: runID))
        let provider = try #require(summary.providers[.iTunesStore])

        #expect((output.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await transport.attempts() == [
            ObservedTransportAttempt(runID: runID, isRetry: false),
            ObservedTransportAttempt(runID: runID, isRetry: true),
        ])
        #expect(provider.requestCount == 2)
        #expect(provider.retryCount == 1)
        #expect(provider.endpointCounts[.ratingsLookup] == 2)
        #expect(provider.resultCounts[.rateLimited] == 1)
        #expect(provider.resultCounts[.success] == 1)
        #expect(summary.result == .success)
    }

    @Test
    func cancellationDuringInitialPacingIsObservedWithoutStartingTransport() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant)
        let transport = CountingHTTPClient()
        let providerClock = ObservabilityManualProviderClock()
        let client = ProviderHTTPClientPipeline.make(
            transport: transport,
            mode: .enabled(ProviderRequestPolicies(default: ProviderRequestPolicy(
                minimumIntervalNanoseconds: 100,
                maximumAttempts: 1,
                baseBackoffNanoseconds: 0,
                maximumBackoffNanoseconds: 0,
                maximumElapsedNanoseconds: 0,
                jitterFraction: 0
            ))),
            refreshMetricsRecorder: recorder,
            refreshObservationClock: .constant,
            providerRequestClock: providerClock.clock
        )
        let firstRequest = URLRequest(
            url: try #require(URL(string: "https://itunes.apple.com/search?term=first"))
        )
        _ = try await client.data(for: firstRequest)
        let runID = await recorder.begin(
            trigger: .manual,
            workspace: .keywords,
            requestedTrackCount: 1,
            requestedStorefrontCount: 1
        )
        let pacedRequest = URLRequest(
            url: try #require(URL(string: "https://itunes.apple.com/search?term=paced"))
        )
        let task = Task {
            try await RefreshObservationScope.$runID.withValue(runID) {
                try await client.data(for: pacedRequest)
            }
        }
        #expect(await waitForObservabilitySleep(100, in: providerClock))

        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let summary = try #require(await recorder.finish(runID: runID))

        #expect(await transport.requestCount() == 1)
        #expect(summary.providers.isEmpty)
        #expect(summary.observedCancellation)
        #expect(summary.result == .cancelled)
    }

    @Test
    func cancellationDuringGateBackoffIsObservedWithoutStartingRetry() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant)
        let transport = ObservedSequenceHTTPClient(steps: [
            ObservationHTTPClientStep(statusCode: 503),
            ObservationHTTPClientStep(statusCode: 200),
        ])
        let providerClock = ObservabilityManualProviderClock()
        let client = ProviderHTTPClientPipeline.make(
            transport: transport,
            mode: .enabled(ProviderRequestPolicies(default: ProviderRequestPolicy(
                minimumIntervalNanoseconds: 0,
                maximumAttempts: 2,
                baseBackoffNanoseconds: 100,
                maximumBackoffNanoseconds: 100,
                maximumElapsedNanoseconds: 1_000,
                jitterFraction: 0
            ))),
            refreshMetricsRecorder: recorder,
            refreshObservationClock: .constant,
            providerRequestClock: providerClock.clock
        )
        let runID = await recorder.begin(
            trigger: .manual,
            workspace: .ratings,
            requestedTrackCount: 0,
            requestedStorefrontCount: 1
        )
        let task = Task {
            try await RefreshObservationScope.$runID.withValue(runID) {
                try await client.data(for: URLRequest(
                    url: URL(string: "https://itunes.apple.com/lookup?id=123&country=us")!
                ))
            }
        }
        #expect(await waitForObservabilitySleep(100, in: providerClock))

        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let summary = try #require(await recorder.finish(runID: runID))
        let provider = try #require(summary.providers[.iTunesStore])

        #expect(await transport.attempts() == [
            ObservedTransportAttempt(runID: runID, isRetry: false),
        ])
        #expect(provider.requestCount == 1)
        #expect(provider.retryCount == 0)
        #expect(provider.resultCounts[.serverFailure] == 1)
        #expect(summary.observedCancellation)
        #expect(summary.result == .cancelled)
    }

    @Test
    func detachedMetadataEnrichmentClearsRefreshScope() async throws {
        let recorder = RefreshMetricsRecorder(clock: .constant)
        let base = CountingHTTPClient()
        let client = ObservedHTTPClient(base: base, recorder: recorder, clock: .constant)
        let completion = AsyncTestSignal()
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: EmptyRankingProvider(),
            appCatalogService: AppCatalogService(appResolver: EmptyAppResolver()),
            metadataEnrichmentHandler: { _ in
                let url = URL(string: "https://itunes.apple.com/lookup?id=999&country=us")!
                _ = try? await client.data(for: URLRequest(url: url))
                await completion.signal()
            }
        )
        let pageResult = RankingRefreshPageResult(
            request: RankingRefreshRequest(
                identityKey: "123::scope::us::iphone",
                queryKey: "scope::us::iphone",
                term: "scope",
                storefront: "us",
                platform: .iphone
            ),
            page: SearchRankingPage(
                items: [
                    SearchRankingItem(
                        position: 1,
                        appStoreID: 999,
                        bundleID: "example.private",
                        name: "Private Name",
                        sellerName: "Private Seller"
                    ),
                ],
                source: .iTunesFallback
            ),
            searchedAt: .now,
            observedHour: nil,
            submissionCount: 1,
            winningCount: 1,
            confidence: nil
        )
        let runID = await recorder.begin(
            trigger: .manual,
            workspace: .keywords,
            requestedTrackCount: 1,
            requestedStorefrontCount: 1
        )

        await RefreshObservationScope.$runID.withValue(runID) {
            coordinator.scheduleTopRankingMetadataEnrichment(for: pageResult)
            await completion.wait()
        }
        let summary = try #require(await recorder.finish(runID: runID))

        #expect(await base.requestCount() == 1)
        #expect(summary.providers.isEmpty)
    }

    @Test
    func largeAppDetailRefreshFixtureIsRepeatableAndSeparatesSemanticFromPhysicalWork() async throws {
        let keywordCount = 128
        let base = RankingHTTPClient()
        let fixture = try makeKeywordRefreshFixture(
            keywordCount: keywordCount,
            includesMissingTrack: true,
            httpClient: base
        )

        let firstResult = await fixture.service.refresh(fixture.request)
        let secondResult = await fixture.service.refresh(fixture.request)
        let summaries = await fixture.recorder.completedSummaries()
        let persistedTrackCount = try await fixture.backgroundModelStore.fetch(
            FetchDescriptor<TrackedKeywordDailyRanking>()
        ) { snapshots in
            Set(snapshots.map(\.trackIdentityKey)).count
        }
        let persistedQueryCount = try await fixture.backgroundModelStore.fetch(
            FetchDescriptor<KeywordRankingCrawl>()
        ) { observations in
            Set(observations.map(\.queryKey)).count
        }

        #expect(firstResult.keywordOutcomes.count == keywordCount + 1)
        #expect(firstResult.keywordOutcomes.filter { $0.error != nil }.count == 1)
        #expect(secondResult.keywordOutcomes.count == keywordCount + 1)
        #expect(secondResult.keywordOutcomes.filter { $0.error != nil }.count == 1)
        #expect(summaries.count == 2)
        #expect(await base.requestCount() == keywordCount * 2)
        #expect(persistedTrackCount == keywordCount)
        #expect(persistedQueryCount == keywordCount)

        for summary in summaries {
            let rankings = try #require(summary.stages[.rankings])
            let metrics = try #require(summary.stages[.keywordMetrics])
            let ratings = try #require(summary.stages[.ratings])
            let reviews = try #require(summary.stages[.reviews])
            let provider = try #require(summary.providers[.iTunesStore])

            #expect(summary.requestedTrackCount == keywordCount + 1)
            #expect(summary.requestedStorefrontCount == 2)
            #expect(summary.resolvedRankingCount == keywordCount)
            #expect(summary.uniqueRankingQueryCount == keywordCount)
            #expect(summary.missingRankingCount == 1)
            #expect(rankings.attemptedCount == keywordCount + 1)
            #expect(rankings.successCount == keywordCount)
            #expect(rankings.failureCount == 1)
            #expect(!rankings.isSkipped)
            #expect(metrics.isSkipped)
            #expect(ratings.isSkipped)
            #expect(reviews.isSkipped)
            #expect(provider.requestCount == keywordCount)
            #expect(provider.endpointCounts[.rankingSearch] == keywordCount)
            #expect(provider.resultCounts[.success] == keywordCount)
            #expect(summary.result == .partialFailure)
        }
    }

    @Test
    func appDetailRefreshDeduplicatesMixedNormalizedQueriesAndPersistsEveryTrack() async throws {
        let base = RankingHTTPClient()
        let fixture = try makeKeywordRefreshFixture(
            trackSpecifications: [
                KeywordRefreshTrackSpecification(
                    appStoreID: 101,
                    term: " Pages ",
                    storefront: " US ",
                    platform: .iphone
                ),
                KeywordRefreshTrackSpecification(
                    appStoreID: 202,
                    term: "pages",
                    storefront: "us",
                    platform: .iphone
                ),
                KeywordRefreshTrackSpecification(
                    appStoreID: 303,
                    term: "pages",
                    storefront: "US",
                    platform: .ipad
                ),
                KeywordRefreshTrackSpecification(
                    appStoreID: 404,
                    term: "Numbers",
                    storefront: "us",
                    platform: .iphone
                ),
            ],
            storefrontCodes: [" US ", "us"],
            httpClient: base
        )

        let result = await fixture.service.refresh(fixture.request)
        let summary = try #require(await fixture.recorder.completedSummaries().only)
        let rankings = try #require(summary.stages[.rankings])
        let provider = try #require(summary.providers[.iTunesStore])
        let persisted = try await fixture.backgroundModelStore.read { modelContext in
            let tracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
            let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
            let crawls = try modelContext.fetch(FetchDescriptor<KeywordRankingCrawl>())
            return (
                trackCount: tracks.count,
                refreshedTrackCount: tracks.filter { $0.lastRefreshAt != nil && $0.statusMessage == nil }.count,
                snapshotIdentityKeys: Set(snapshots.map(\.trackIdentityKey)),
                crawlQueryKeys: Set(crawls.map(\.queryKey))
            )
        }

        #expect(result.keywordOutcomes.count == 4)
        #expect(result.keywordOutcomes.allSatisfy { $0.error == nil })
        #expect(await base.requestCount() == 3)
        #expect(summary.resolvedRankingCount == 4)
        #expect(summary.uniqueRankingQueryCount == 3)
        #expect(rankings.attemptedCount == 4)
        #expect(rankings.successCount == 4)
        #expect(provider.requestCount == 3)
        #expect(provider.endpointCounts[.rankingSearch] == 3)
        #expect(persisted.trackCount == 4)
        #expect(persisted.refreshedTrackCount == 4)
        #expect(persisted.snapshotIdentityKeys == Set(result.keywordOutcomes.map(\.trackIdentityKey)))
        #expect(persisted.crawlQueryKeys == Set([
            "numbers::us::iphone",
            "pages::us::ipad",
            "pages::us::iphone",
        ]))
    }

    @Test
    func duplicateRankingCancellationFansFailureOutAfterOneProviderRequest() async throws {
        let base = CountingCancelledRankingHTTPClient()
        let fixture = try makeKeywordRefreshFixture(
            trackSpecifications: [
                KeywordRefreshTrackSpecification(
                    appStoreID: 101,
                    term: " Pages ",
                    storefront: " US ",
                    platform: .iphone
                ),
                KeywordRefreshTrackSpecification(
                    appStoreID: 202,
                    term: "pages",
                    storefront: "us",
                    platform: .iphone
                ),
            ],
            storefrontCodes: ["us"],
            httpClient: base
        )

        let result = await fixture.service.refresh(fixture.request)
        let summary = try #require(await fixture.recorder.completedSummaries().only)
        let rankings = try #require(summary.stages[.rankings])
        let provider = try #require(summary.providers[.iTunesStore])
        let persisted = try await fixture.backgroundModelStore.read { modelContext in
            let tracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
            let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
            return (
                failedTrackCount: tracks.filter { $0.statusMessage != nil }.count,
                snapshotCount: snapshots.count
            )
        }

        #expect(result.keywordOutcomes.count == 2)
        #expect(result.keywordOutcomes.allSatisfy { $0.error != nil })
        #expect(await base.requestCount() == 1)
        #expect(summary.resolvedRankingCount == 2)
        #expect(summary.uniqueRankingQueryCount == 1)
        #expect(rankings.attemptedCount == 2)
        #expect(rankings.failureCount == 2)
        #expect(provider.requestCount == 1)
        #expect(provider.resultCounts[.cancelled] == 1)
        #expect(summary.observedCancellation)
        #expect(summary.result == .cancelled)
        #expect(persisted.failedTrackCount == 2)
        #expect(persisted.snapshotCount == 0)
    }

    @Test
    func realRefreshClassifiesObservedTransportCancellationAsCancelled() async throws {
        let base = CancelledRankingHTTPClient()
        let fixture = try makeKeywordRefreshFixture(
            keywordCount: 1,
            includesMissingTrack: false,
            httpClient: base
        )

        let result = await fixture.service.refresh(fixture.request)
        let summary = try #require(await fixture.recorder.completedSummaries().only)
        let rankings = try #require(summary.stages[.rankings])
        let provider = try #require(summary.providers[.iTunesStore])
        let persistedFailureCount = try await fixture.backgroundModelStore.fetch(
            FetchDescriptor<TrackedAppKeyword>()
        ) { tracks in
            tracks.filter { $0.statusMessage != nil }.count
        }

        #expect(result.keywordOutcomes.count == 1)
        #expect(result.keywordOutcomes.first?.error != nil)
        #expect(rankings.attemptedCount == 1)
        #expect(rankings.failureCount == 1)
        #expect(provider.requestCount == 1)
        #expect(provider.resultCounts[.cancelled] == 1)
        #expect(summary.observedCancellation)
        #expect(summary.result == .cancelled)
        #expect(persistedFailureCount == 1)
    }

}

private extension RefreshObservationClock {
    static let constant = RefreshObservationClock(nowNanoseconds: { 1_000 })
}

private struct HeaderStatusHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let statusCode = Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "") ?? 200
        let url = request.url ?? URL(string: "https://example.invalid")!
        return (Data(), makeHTTPURLResponse(url: url, statusCode: statusCode))
    }
}

private actor CountingHTTPClient: HTTPClient {
    private var count = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        let url = request.url ?? URL(string: "https://example.invalid")!
        return (Data(), makeHTTPURLResponse(url: url, statusCode: 200))
    }

    func requestCount() -> Int {
        count
    }
}

private struct NonHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        return (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
    }
}

private struct NetworkFailureHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private struct ObservationHTTPClientStep: Sendable {
    let statusCode: Int
    var headers: [String: String] = [:]
}

private struct ObservedTransportAttempt: Equatable, Sendable {
    let runID: UUID?
    let isRetry: Bool
}

private actor ObservedSequenceHTTPClient: HTTPClient {
    private var steps: [ObservationHTTPClientStep]
    private var recordedAttempts: [ObservedTransportAttempt] = []

    init(steps: [ObservationHTTPClientStep]) {
        self.steps = steps
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedAttempts.append(ObservedTransportAttempt(
            runID: RefreshObservationScope.runID,
            isRetry: ProviderRequestObservationScope.isRetryAttempt
        ))
        guard !steps.isEmpty else {
            throw OpenASOError.providerUnavailable("Unexpected observed transport request.")
        }
        let step = steps.removeFirst()
        let url = request.url ?? URL(string: "https://example.invalid")!
        return (
            Data(),
            makeHTTPURLResponse(
                url: url,
                statusCode: step.statusCode,
                headerFields: step.headers
            )
        )
    }

    func attempts() -> [ObservedTransportAttempt] {
        recordedAttempts
    }
}

private final class ObservabilityManualProviderClock: Sendable {
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

    var clock: ProviderRequestClock {
        ProviderRequestClock(
            nowNanoseconds: { self.state.withLock(\.now) },
            nowDate: { Date(timeIntervalSince1970: 0) },
            sleepUntilNanoseconds: sleep
        )
    }

    var pendingDeadlines: [UInt64] {
        state.withLock { $0.pending.values.map(\.deadline) }
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

private func waitForObservabilitySleep(
    _ deadline: UInt64,
    in clock: ObservabilityManualProviderClock
) async -> Bool {
    for _ in 0 ..< 2_000 {
        if clock.pendingDeadlines.contains(deadline) {
            return true
        }
        await Task.yield()
    }
    return false
}

private actor RankingHTTPClient: HTTPClient {
    private var count = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        let url = request.url ?? URL(string: "https://itunes.apple.com/search")!
        return (
            Data("{\"results\":[]}".utf8),
            makeHTTPURLResponse(url: url, statusCode: 200)
        )
    }

    func requestCount() -> Int {
        count
    }
}

private struct CancelledRankingHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw CancellationError()
    }
}

private actor CountingCancelledRankingHTTPClient: HTTPClient {
    private var count = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        throw CancellationError()
    }

    func requestCount() -> Int {
        count
    }
}

private actor AsyncTestSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct EmptyRankingProvider: SearchRankingProvider {
    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        SearchRankingPage(items: [], source: .iTunesFallback)
    }
}

private struct EmptyAppResolver: AppResolver {
    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        throw OpenASOError.appNotFound
    }

    func searchApps(named query: String, storefrontCode: String, limit: Int) async throws -> [ResolvedApp] {
        []
    }
}

@MainActor
private struct KeywordRefreshFixture {
    let service: AppDetailRefreshService
    let request: AppDetailRefreshRequest
    let recorder: RefreshMetricsRecorder
    let backgroundModelStore: BackgroundModelStore
}

private struct KeywordRefreshTrackSpecification {
    let appStoreID: Int64
    let term: String
    let storefront: String
    let platform: AppPlatform
}

@MainActor
private func makeKeywordRefreshFixture(
    keywordCount: Int,
    includesMissingTrack: Bool,
    httpClient: any HTTPClient
) throws -> KeywordRefreshFixture {
    let trackSpecifications = (0 ..< keywordCount).map { index in
        KeywordRefreshTrackSpecification(
            appStoreID: 123,
            term: "baseline-private-keyword-\(index)",
            storefront: "us",
            platform: .iphone
        )
    }
    let additionalIdentityKeys = includesMissingTrack
        ? [TrackedAppKeyword.makeIdentityKey(
            appStoreID: 123,
            term: "missing-private-keyword",
            storefront: "us",
            platform: .iphone
        )]
        : []
    return try makeKeywordRefreshFixture(
        trackSpecifications: trackSpecifications,
        additionalIdentityKeys: additionalIdentityKeys,
        storefrontCodes: ["US", "us", " GB "],
        httpClient: httpClient
    )
}

@MainActor
private func makeKeywordRefreshFixture(
    trackSpecifications: [KeywordRefreshTrackSpecification],
    additionalIdentityKeys: [String] = [],
    storefrontCodes: [String],
    httpClient: any HTTPClient
) throws -> KeywordRefreshFixture {
    let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
    let modelContext = ModelContext(container)
    var trackedAppsByID: [Int64: TrackedApp] = [:]
    var trackIdentityKeys: [String] = []
    trackIdentityKeys.reserveCapacity(trackSpecifications.count + additionalIdentityKeys.count)

    for specification in trackSpecifications {
        let trackedApp: TrackedApp
        if let existing = trackedAppsByID[specification.appStoreID] {
            trackedApp = existing
        } else {
            trackedApp = TrackedApp(
                appStoreID: specification.appStoreID,
                bundleID: "example.private.\(specification.appStoreID)",
                name: "Private App \(specification.appStoreID)",
                sellerName: "Private Seller",
                defaultPlatform: specification.platform
            )
            trackedAppsByID[specification.appStoreID] = trackedApp
            modelContext.insert(trackedApp)
        }

        let query = try KeywordQuery.fetchOrInsert(
            term: specification.term,
            storefront: specification.storefront,
            platform: specification.platform,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: specification.term,
            storefront: specification.storefront,
            platform: specification.platform,
            trackedApp: trackedApp,
            query: query
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)
        trackIdentityKeys.append(track.identityKey)
    }
    trackIdentityKeys.append(contentsOf: additionalIdentityKeys)
    try modelContext.save()

    let trackedApp = try #require(trackSpecifications.first.flatMap { trackedAppsByID[$0.appStoreID] })

    let recorder = RefreshMetricsRecorder(clock: .constant)
    let backgroundModelStore = BackgroundModelStore(modelContainer: container)
    let services = AppServices(
        httpClient: httpClient,
        defaults: makeIsolatedDefaults(),
        keychain: InMemoryKeychainService(),
        loadsEnvironmentCredentials: false,
        allowsIconNetworkFetches: false,
        backgroundModelStore: backgroundModelStore,
        refreshObservationClock: .constant,
        refreshMetricsRecorder: recorder,
        providerRequestGateMode: .disabled
    )
    let service = try #require(services.appDetailRefreshService)
    let request = AppDetailRefreshRequest(
        app: AppDetailRefreshAppSnapshot(
            appStoreID: trackedApp.appStoreID,
            bundleID: trackedApp.bundleID,
            name: trackedApp.name,
            subtitle: trackedApp.subtitle,
            sellerName: trackedApp.sellerName,
            defaultPlatform: trackedApp.defaultPlatform
        ),
        workspace: .keywords,
        storefrontSelection: .all(codes: storefrontCodes),
        trackIdentityKeys: trackIdentityKeys,
        trigger: "manual",
        refreshKeywords: true,
        refreshMetrics: false,
        refreshRatings: false,
        refreshReviews: false,
        recordsRatingsReviewsRefresh: false,
        popularityContextAppStoreID: nil,
        appleAdsWebSession: nil,
        appStoreConnectCredentials: AppStoreConnectCredentials(
            issuerID: "",
            keyID: "",
            privateKey: ""
        )
    )
    return KeywordRefreshFixture(
        service: service,
        request: request,
        recorder: recorder,
        backgroundModelStore: backgroundModelStore
    )
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "refresh.observability.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
