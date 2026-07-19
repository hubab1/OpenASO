import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchMetricsWorkflowTests {
    @Test
    func successfulRefreshPersistsSharedPopularityWithEphemeralContextProvenance() async throws {
        let observedAt = metricsTestDate
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 73))
        let fixture = try await makeFixture(httpClient: client, now: observedAt)
        let keyword = try #require(fixture.keywords.first)

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation
        )

        #expect(outcome.projectGeneration == fixture.project.generation)
        #expect(outcome.keywordGeneration == keyword.generation)
        #expect(outcome.queryKey == keyword.queryKey)
        #expect(outcome.term == keyword.term)
        #expect(outcome.storefront == keyword.storefront)
        #expect(outcome.platform == keyword.platform)
        #expect(outcome.popularityScore == 73)
        #expect(outcome.observedAt == observedAt)
        #expect(outcome.provenance == .requestedContext(appStoreID: metricsContextAppStoreID))
        #expect(outcome.disposition == .refreshed)
        #expect(outcome.issue == nil)

        let metric = try #require(try await storedMetric(
            queryKey: keyword.queryKey,
            in: fixture.backgroundStore
        ))
        #expect(metric.popularityScore == 73)
        #expect(metric.difficultyScore == nil)
        #expect(metric.source == .appleAdsPopularity)
        #expect(metric.updatedAt == observedAt)

        let requests = await client.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.storefronts == ["GB"])
        #expect(requests.first?.terms == [keyword.term])
        #expect(requests.first?.contextAppStoreID == metricsContextAppStoreID)
        #expect(requests.first?.cookieHeader == metricsSession.cookieHeader)
        #expect(requests.first?.xsrfToken == metricsSession.xsrfToken)
    }

    @Test
    func freshCacheNeedsNoAppleAdsConfigurationAndReportsUnknownDurableProvenance() async throws {
        let referenceDate = metricsTestDate
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 99))
        let fixture = try await makeFixture(
            httpClient: client,
            now: referenceDate,
            configuration: .missingContextAndSession
        )
        let keyword = try #require(fixture.keywords.first)
        let cachedAt = referenceDate.addingTimeInterval(-metricsDay)
        try await seedMetric(
            for: keyword,
            popularityScore: 61,
            updatedAt: cachedAt,
            in: fixture.backgroundStore
        )

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation
        )

        #expect(outcome.popularityScore == 61)
        #expect(outcome.observedAt == cachedAt)
        #expect(outcome.provenance == .sharedCacheContextUnknown)
        #expect(outcome.disposition == .freshCache)
        #expect(outcome.issue == nil)
        #expect(await client.recordedRequests().isEmpty)
    }

    @Test
    func cacheExactlySevenDaysOldRefreshesFromNetwork() async throws {
        let referenceDate = metricsTestDate
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 82))
        let fixture = try await makeFixture(httpClient: client, now: referenceDate)
        let keyword = try #require(fixture.keywords.first)
        try await seedMetric(
            for: keyword,
            popularityScore: 40,
            updatedAt: referenceDate.addingTimeInterval(
                -KeywordResearchMetricsWorkflow.freshnessInterval
            ),
            in: fixture.backgroundStore
        )

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation
        )

        #expect(outcome.disposition == .refreshed)
        #expect(outcome.popularityScore == 82)
        #expect(outcome.observedAt == referenceDate)
        #expect(await client.recordedRequests().count == 1)
    }

    @Test
    func missingContextReturnsStaleCacheFallbackWithoutProviderOrWrites() async throws {
        let referenceDate = metricsTestDate
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 90))
        let fixture = try await makeFixture(
            httpClient: client,
            now: referenceDate,
            configuration: .missingContext
        )
        let keyword = try #require(fixture.keywords.first)
        let staleAt = referenceDate.addingTimeInterval(-8 * metricsDay)
        try await seedMetric(
            for: keyword,
            popularityScore: 37,
            difficultyScore: 49,
            notes: "keep stale cache",
            updatedAt: staleAt,
            in: fixture.backgroundStore
        )

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation
        )

        #expect(outcome.disposition == .staleCacheFallback)
        #expect(outcome.popularityScore == 37)
        #expect(outcome.observedAt == staleAt)
        #expect(outcome.provenance == .sharedCacheContextUnknown)
        #expect(outcome.issue?.code == .missingContextApp)
        #expect(await client.recordedRequests().isEmpty)
        let metric = try await storedMetric(
            queryKey: keyword.queryKey,
            in: fixture.backgroundStore
        )
        #expect(metric?.notes == "keep stale cache")
    }

    @Test
    func missingContextDoesNotPresentDifficultyOnlyRowAsPopularityCache() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 90))
        let fixture = try await makeFixture(
            httpClient: client,
            now: metricsTestDate,
            configuration: .missingContext
        )
        let keyword = try #require(fixture.keywords.first)
        try await seedMetric(
            for: keyword,
            popularityScore: nil,
            difficultyScore: 74,
            notes: "difficulty only",
            updatedAt: metricsTestDate.addingTimeInterval(-metricsDay),
            in: fixture.backgroundStore
        )

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation
        )

        #expect(outcome.disposition == .unavailable)
        #expect(outcome.popularityScore == nil)
        #expect(outcome.observedAt == nil)
        #expect(outcome.provenance == nil)
        #expect(outcome.issue?.code == .missingContextApp)
        #expect(await client.recordedRequests().isEmpty)
    }

    @Test
    func missingSessionAndReconnectRequirementAreExplicitUnavailableOutcomes() async throws {
        let missingSessionClient = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 90))
        let missingSession = try await makeFixture(
            httpClient: missingSessionClient,
            now: metricsTestDate,
            configuration: .missingSession
        )
        let missingSessionKeyword = try #require(missingSession.keywords.first)

        let missingSessionOutcome = try await missingSession.workflow.refresh(
            projectGeneration: missingSession.project.generation,
            keywordGeneration: missingSessionKeyword.generation
        )

        #expect(missingSessionOutcome.disposition == .unavailable)
        #expect(missingSessionOutcome.popularityScore == nil)
        #expect(missingSessionOutcome.issue?.code == .missingSession)
        #expect(await missingSessionClient.recordedRequests().isEmpty)

        let reconnectClient = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 90))
        let reconnect = try await makeFixture(
            httpClient: reconnectClient,
            now: metricsTestDate,
            configuration: .reconnectRequired
        )
        let reconnectKeyword = try #require(reconnect.keywords.first)

        let reconnectOutcome = try await reconnect.workflow.refresh(
            projectGeneration: reconnect.project.generation,
            keywordGeneration: reconnectKeyword.generation
        )

        #expect(reconnectOutcome.disposition == .unavailable)
        #expect(reconnectOutcome.issue?.code == .reconnectRequired)
        #expect(await reconnectClient.recordedRequests().isEmpty)
        #expect(reconnect.services.appleAdsWebSessionStore.requiresReconnect(for: metricsSession))
    }

    @Test
    func unsupportedStorefrontAndMissingProviderValueProduceIndependentOutcomes() async throws {
        let client = ScriptedMetricsHTTPClient(
            defaultReply: .scores(defaultScore: nil),
            repliesByStorefront: [
                "GB": .status(400),
                "US": .scores(defaultScore: nil),
            ]
        )
        let fixture = try await makeFixture(
            httpClient: client,
            now: metricsTestDate,
            keywordSpecs: [
                KeywordSpec(term: "unsupported market", storefront: "gb", platform: .ipad),
                KeywordSpec(term: "missing value", storefront: "us", platform: .iphone),
            ]
        )
        let unsupported = fixture.keywords[0]
        let missing = fixture.keywords[1]
        let staleAt = metricsTestDate.addingTimeInterval(-8 * metricsDay)
        try await seedMetric(
            for: unsupported,
            popularityScore: 44,
            updatedAt: staleAt,
            in: fixture.backgroundStore
        )

        let result = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGenerations: fixture.keywords.map(\.generation)
        )

        #expect(result.outcomes.count == 2)
        #expect(result.outcomes[0].disposition == .staleCacheFallback)
        #expect(result.outcomes[0].popularityScore == 44)
        #expect(result.outcomes[0].issue?.code == .unsupportedStorefront)
        #expect(result.outcomes[1].disposition == .notFound)
        #expect(result.outcomes[1].popularityScore == nil)
        #expect(result.outcomes[1].issue == nil)
        #expect(try await metricCount(in: fixture.backgroundStore) == 1)
        #expect(try await storedMetric(queryKey: missing.queryKey, in: fixture.backgroundStore) == nil)
    }

    @Test
    func rateLimitedProviderReturnsSanitizedStructuredFallback() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .status(429))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation,
            policy: .requireNetwork
        )

        #expect(outcome.disposition == .unavailable)
        #expect(outcome.issue?.code == .rateLimited)
        #expect(outcome.issue?.message == "Apple is rate-limiting keyword popularity. Try again shortly.")
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
    }

    @Test
    func expiredCurrentSessionMarksReconnectAndPersistsNothing() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .status(403))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation,
            policy: .requireNetwork
        )

        #expect(outcome.disposition == .unavailable)
        #expect(outcome.issue?.code == .sessionExpired)
        #expect(outcome.popularityScore == nil)
        #expect(fixture.services.appleAdsWebSessionStore.requiresReconnect(for: metricsSession))
        #expect(fixture.services.appleAdsWebSessionStore.hasSession)
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
    }

    @Test
    func cancellationDuringProviderSuspensionPropagatesWithoutWritesOrReconnectMutation() async throws {
        let client = GatedMetricsHTTPClient(score: 76)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        task.cancel()
        await client.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
        #expect(!fixture.services.appleAdsWebSessionStore.requiresReconnect(for: metricsSession))
        #expect(await client.recordedRequests().count == 1)
    }

    @Test
    func keywordReplacementDuringProviderSuspensionRejectsLateEvidence() async throws {
        let client = GatedMetricsHTTPClient(score: 77)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        let projectAfterRemoval = try await fixture.projectStore.removeKeyword(
            revision: keyword.revision,
            from: fixture.project.revision
        )
        _ = try await fixture.projectStore.addKeyword(
            id: keyword.id,
            to: projectAfterRemoval.revision,
            term: "replacement membership",
            storefront: "us",
            platform: .iphone
        )
        await client.release()

        await #expect(throws: KeywordResearchProjectStoreError.staleKeywordRevision(keyword.id)) {
            _ = try await task.value
        }
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
    }

    @Test
    func keywordReplacementDuringProviderFailureRejectsLateFallback() async throws {
        let client = GatedMetricsHTTPClient(score: nil, statusCode: 500)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        let projectAfterRemoval = try await fixture.projectStore.removeKeyword(
            revision: keyword.revision,
            from: fixture.project.revision
        )
        _ = try await fixture.projectStore.addKeyword(
            id: keyword.id,
            to: projectAfterRemoval.revision,
            term: "replacement after provider failure",
            storefront: "us",
            platform: .iphone
        )
        await client.release()

        await #expect(throws: KeywordResearchProjectStoreError.staleKeywordRevision(keyword.id)) {
            _ = try await task.value
        }
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
    }

    @Test
    func projectReplacementDuringProviderSuspensionRejectsLateEvidence() async throws {
        let client = GatedMetricsHTTPClient(score: 78)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        try await fixture.projectStore.deleteProject(revision: fixture.project.revision)
        _ = try await fixture.projectStore.createProject(
            id: fixture.project.id,
            name: "Replacement project",
            defaultStorefront: "us",
            defaultPlatform: .iphone
        )
        await client.release()

        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(
            fixture.project.id
        )) {
            _ = try await task.value
        }
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
    }

    @Test
    func configurationChangeDuringProviderSuspensionDiscardsFetchedEvidence() async throws {
        let client = GatedMetricsHTTPClient(score: 79)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        fixture.services.settingsStore.savePopularityContextAppStoreID(
            metricsContextAppStoreID + 1
        )
        try fixture.services.appleAdsWebSessionStore.save(replacementMetricsSession)
        await client.release()

        let outcome = try await task.value
        #expect(outcome.disposition == .unavailable)
        #expect(outcome.issue?.code == .configurationChanged)
        #expect(outcome.popularityScore == nil)
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
        #expect(!fixture.services.appleAdsWebSessionStore.requiresReconnect(for: replacementMetricsSession))
    }

    @Test
    func newerConcurrentCacheSupersedesOlderProviderEvidenceMonotonically() async throws {
        let client = GatedMetricsHTTPClient(score: 63)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        let newerDate = metricsTestDate.addingTimeInterval(metricsDay)
        try await seedMetric(
            for: keyword,
            popularityScore: 96,
            difficultyScore: 51,
            notes: "newer concurrent cache",
            updatedAt: newerDate,
            in: fixture.backgroundStore
        )
        await client.release()

        let outcome = try await task.value
        #expect(outcome.disposition == .supersededByNewerCache)
        #expect(outcome.popularityScore == 96)
        #expect(outcome.observedAt == newerDate)
        #expect(outcome.provenance == .sharedCacheContextUnknown)
        let metric = try #require(try await storedMetric(
            queryKey: keyword.queryKey,
            in: fixture.backgroundStore
        ))
        #expect(metric.popularityScore == 96)
        #expect(metric.difficultyScore == 51)
        #expect(metric.notes == "newer concurrent cache")
        #expect(metric.updatedAt == newerDate)
    }

    @Test
    func providerNotFoundReportsMetricInsertedWhileRequestWasSuspended() async throws {
        let client = GatedMetricsHTTPClient(score: nil)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        let concurrentDate = metricsTestDate.addingTimeInterval(metricsDay)
        try await seedMetric(
            for: keyword,
            popularityScore: 94,
            difficultyScore: 58,
            notes: "inserted during provider request",
            updatedAt: concurrentDate,
            in: fixture.backgroundStore
        )
        await client.release()

        let outcome = try await task.value
        #expect(outcome.disposition == .notFound)
        #expect(outcome.popularityScore == 94)
        #expect(outcome.observedAt == concurrentDate)
        #expect(outcome.provenance == .sharedCacheContextUnknown)
        #expect(outcome.issue == nil)
        let metric = try #require(try await storedMetric(
            queryKey: keyword.queryKey,
            in: fixture.backgroundStore
        ))
        #expect(metric.popularityScore == 94)
        #expect(metric.difficultyScore == 58)
        #expect(metric.notes == "inserted during provider request")
        #expect(metric.updatedAt == concurrentDate)
    }

    @Test
    func providerFailureReportsPopularityInsertedWhileRequestWasSuspended() async throws {
        let client = GatedMetricsHTTPClient(score: nil, statusCode: 500)
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: keyword.generation,
                policy: .requireNetwork
            )
        }
        await client.waitUntilStarted()

        let concurrentDate = metricsTestDate.addingTimeInterval(metricsDay)
        try await seedMetric(
            for: keyword,
            popularityScore: 93,
            difficultyScore: 57,
            notes: "inserted during failed provider request",
            updatedAt: concurrentDate,
            in: fixture.backgroundStore
        )
        await client.release()

        let outcome = try await task.value
        #expect(outcome.disposition == .staleCacheFallback)
        #expect(outcome.popularityScore == 93)
        #expect(outcome.observedAt == concurrentDate)
        #expect(outcome.provenance == .sharedCacheContextUnknown)
        #expect(outcome.issue?.code == .providerFailure)
    }

    @Test
    func providerNotFoundDoesNotPresentDifficultyOnlyRowAsPopularityCache() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: nil))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        try await seedMetric(
            for: keyword,
            popularityScore: nil,
            difficultyScore: 76,
            notes: "difficulty only",
            updatedAt: metricsTestDate.addingTimeInterval(metricsDay),
            in: fixture.backgroundStore
        )

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation,
            policy: .requireNetwork
        )

        #expect(outcome.disposition == .notFound)
        #expect(outcome.popularityScore == nil)
        #expect(outcome.observedAt == nil)
        #expect(outcome.provenance == nil)
        #expect(outcome.issue == nil)
    }

    @Test
    func refreshedPopularityPreservesDifficultyAndNotesOnSharedMetric() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 88))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        try await seedMetric(
            for: keyword,
            popularityScore: 12,
            difficultyScore: 67,
            notes: "difficulty provenance must survive",
            updatedAt: metricsTestDate.addingTimeInterval(-8 * metricsDay),
            in: fixture.backgroundStore
        )

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation
        )

        #expect(outcome.disposition == .refreshed)
        #expect(outcome.popularityScore == 88)
        let metric = try #require(try await storedMetric(
            queryKey: keyword.queryKey,
            in: fixture.backgroundStore
        ))
        #expect(metric.popularityScore == 88)
        #expect(metric.difficultyScore == 67)
        #expect(metric.notes == "difficulty provenance must survive")
        #expect(metric.updatedAt == metricsTestDate)
    }

    @Test
    func batchSeparatesStorefrontsAndUsesSequentialHundredTermRequests() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 72))
        let fixture = try await makeFixture(
            httpClient: client,
            now: metricsTestDate,
            keywordSpecs: []
        )
        let specs = (0..<2).map {
            KeywordSpec(term: "gb-\(String(format: "%03d", $0))", storefront: "gb", platform: .ipad)
        } + (0..<102).map {
            KeywordSpec(term: "us-\(String(format: "%03d", $0))", storefront: "us", platform: .iphone)
        }
        let keywords = try await seedResearchKeywords(
            specs,
            projectGeneration: fixture.project.generation,
            in: fixture.backgroundStore
        )
        let input = Array(keywords.reversed())

        let result = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGenerations: input.map(\.generation),
            policy: .requireNetwork
        )

        #expect(result.outcomes.count == 104)
        #expect(result.outcomes.map(\.keywordGeneration) == input.map(\.generation))
        #expect(result.outcomes.allSatisfy {
            $0.disposition == .refreshed && $0.popularityScore == 72
        })
        let requests = await client.recordedRequests()
        #expect(requests.map(\.storefronts) == [["GB"], ["US"], ["US"]])
        #expect(requests.map { $0.terms.count } == [2, 100, 2])
        #expect(requests.allSatisfy { $0.contextAppStoreID == metricsContextAppStoreID })
        #expect(try await metricCount(in: fixture.backgroundStore) == 104)
    }

    @Test
    func batchRejectsMoreThanFiveHundredUniqueKeywordGenerationsBeforeProviderWork() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 72))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let generations = (0...KeywordResearchMetricsWorkflow.maximumKeywordCount).map { _ in
            KeywordResearchKeywordGeneration(id: UUID(), incarnationID: UUID())
        }

        await #expect(throws: KeywordResearchMetricsWorkflowError.tooManyKeywords(
            maximum: KeywordResearchMetricsWorkflow.maximumKeywordCount
        )) {
            _ = try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGenerations: generations,
                policy: .requireNetwork
            )
        }

        #expect(await client.recordedRequests().isEmpty)
    }

    @Test
    func successfulRefreshRebuildsOnlyCanonicalDerivedRankingStats() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 84))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        try await seedRankingObservation(
            for: keyword,
            appStoreID: 777,
            rank: 5,
            in: fixture.backgroundStore
        )

        _ = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation,
            policy: .requireNetwork
        )

        let stats = try #require(try await storedRankingStats(
            queryKey: keyword.queryKey,
            in: fixture.backgroundStore
        ))
        #expect(stats.appStoreID == 777)
        #expect(stats.bestRank == 5)
        #expect(stats.latestRank == 5)
        #expect(stats.observationCount == 1)
        #expect(stats.popularityScore == 84)
        #expect(stats.difficultyScore == nil)
    }

    @Test
    func workflowDoesNotMutateExistingTrackedAppKeywordOrRefreshStatusGraph() async throws {
        let client = ScriptedMetricsHTTPClient(defaultReply: .scores(defaultScore: 84))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)
        try await seedTrackedGraph(queryKey: keyword.queryKey, in: fixture.backgroundStore)
        let before = try await trackedGraphState(in: fixture.backgroundStore)

        _ = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation,
            policy: .requireNetwork
        )

        let after = try await trackedGraphState(in: fixture.backgroundStore)
        #expect(after == before)
        #expect(try await metricCount(in: fixture.backgroundStore) == 1)
    }

    @Test
    func providerMessagesAndSessionSecretsNeverEscapeThroughWorkflowOutcomes() async throws {
        let providerSecret = "provider leaked \(metricsSession.cookieHeader) \(metricsSession.xsrfToken)"
        let client = ScriptedMetricsHTTPClient(defaultReply: .providerError(providerSecret))
        let fixture = try await makeFixture(httpClient: client, now: metricsTestDate)
        let keyword = try #require(fixture.keywords.first)

        let outcome = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: keyword.generation,
            policy: .requireNetwork
        )

        #expect(outcome.disposition == .unavailable)
        #expect(outcome.issue?.code == .providerFailure)
        let exposedText = [
            outcome.issue?.message ?? "",
            String(describing: outcome),
            String(reflecting: outcome),
        ].joined(separator: " ")
        #expect(!exposedText.contains(providerSecret))
        #expect(!exposedText.contains(metricsSession.cookieHeader))
        #expect(!exposedText.contains(metricsSession.xsrfToken))
        #expect(try await metricCount(in: fixture.backgroundStore) == 0)
    }
}

private extension KeywordResearchMetricsWorkflowTests {
    func makeFixture(
        httpClient: any HTTPClient,
        now: Date,
        configuration: MetricsTestConfiguration = .connected,
        keywordSpecs: [KeywordSpec] = [
            KeywordSpec(term: "launch planner", storefront: "gb", platform: .ipad)
        ]
    ) async throws -> MetricsWorkflowFixture {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let projectStore = KeywordResearchProjectStore(
            backgroundModelStore: backgroundStore,
            now: { metricsProjectCreatedAt }
        )
        var project = try await projectStore.createProject(
            name: "Metrics research",
            defaultStorefront: "gb",
            defaultPlatform: .ipad
        )
        var keywords: [KeywordResearchKeywordSnapshot] = []
        for spec in keywordSpecs {
            let addition = try await projectStore.addKeyword(
                to: project.revision,
                term: spec.term,
                storefront: spec.storefront,
                platform: spec.platform
            )
            project = addition.project
            keywords.append(addition.keyword)
        }

        let services = AppServices.mocked(httpClient: httpClient)
        switch configuration {
        case .connected:
            services.settingsStore.savePopularityContextAppStoreID(metricsContextAppStoreID)
            try services.appleAdsWebSessionStore.save(metricsSession)
        case .missingContext:
            try services.appleAdsWebSessionStore.save(metricsSession)
        case .missingSession:
            services.settingsStore.savePopularityContextAppStoreID(metricsContextAppStoreID)
        case .missingContextAndSession:
            break
        case .reconnectRequired:
            services.settingsStore.savePopularityContextAppStoreID(metricsContextAppStoreID)
            try services.appleAdsWebSessionStore.save(metricsSession)
            services.appleAdsWebSessionStore.markReconnectRequired(for: metricsSession)
        }

        let workflow = KeywordResearchMetricsWorkflow(
            backgroundModelStore: backgroundStore,
            metricsService: services.keywordMetricsService,
            rankingCoordinator: services.refreshCoordinator,
            configurationProvider: { [services] in
                let session = services.appleAdsWebSessionStore.session
                return KeywordResearchMetricsConfiguration(
                    contextAppStoreID: services.settingsStore.popularityContextAppStoreID,
                    webSession: session,
                    requiresReconnect: session.map {
                        services.appleAdsWebSessionStore.requiresReconnect(for: $0)
                    } ?? services.appleAdsWebSessionStore.requiresReconnect
                )
            },
            reconnectMarker: { [services] session in
                services.appleAdsWebSessionStore.markReconnectRequired(for: session)
            },
            now: { now }
        )

        return MetricsWorkflowFixture(
            container: container,
            backgroundStore: backgroundStore,
            projectStore: projectStore,
            services: services,
            workflow: workflow,
            project: project,
            keywords: keywords
        )
    }
}

private struct MetricsWorkflowFixture {
    let container: ModelContainer
    let backgroundStore: BackgroundModelStore
    let projectStore: KeywordResearchProjectStore
    let services: AppServices
    let workflow: KeywordResearchMetricsWorkflow
    let project: KeywordResearchProjectSnapshot
    let keywords: [KeywordResearchKeywordSnapshot]
}

private enum MetricsTestConfiguration {
    case connected
    case missingContext
    case missingSession
    case missingContextAndSession
    case reconnectRequired
}

private struct KeywordSpec: Sendable {
    let term: String
    let storefront: String
    let platform: AppPlatform
}

private struct SeededKeyword: Sendable {
    let generation: KeywordResearchKeywordGeneration
    let queryKey: String
    let term: String
    let storefront: String
    let platform: AppPlatform
}

private struct StoredMetric: Equatable, Sendable {
    let popularityScore: Int?
    let difficultyScore: Int?
    let source: KeywordMetricsSource
    let updatedAt: Date
    let notes: String?
}

private struct StoredRankingStats: Equatable, Sendable {
    let appStoreID: Int64
    let bestRank: Int?
    let latestRank: Int?
    let observationCount: Int
    let popularityScore: Int?
    let difficultyScore: Int?
}

private struct TrackedGraphState: Equatable, Sendable {
    let appCount: Int
    let trackCount: Int
    let statusCount: Int
    let appName: String
    let appPinned: Bool
    let trackNotes: String
    let trackStatusMessage: String?
    let rankingStatus: String?
    let popularityStatus: String?
}

private struct PopularityRequestBody: Decodable, Sendable {
    let storefronts: [String]
    let terms: [String]
}

private struct PopularityRequestRecord: Equatable, Sendable {
    let storefronts: [String]
    let terms: [String]
    let contextAppStoreID: Int64?
    let cookieHeader: String?
    let xsrfToken: String?
}

private enum PopularityReply: Sendable {
    case scores(defaultScore: Int?)
    case status(Int)
    case providerError(String)
}

private actor ScriptedMetricsHTTPClient: HTTPClient {
    private let defaultReply: PopularityReply
    private let repliesByStorefront: [String: PopularityReply]
    private var requests: [PopularityRequestRecord] = []

    init(
        defaultReply: PopularityReply,
        repliesByStorefront: [String: PopularityReply] = [:]
    ) {
        self.defaultReply = defaultReply
        self.repliesByStorefront = repliesByStorefront
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try decodePopularityRequest(request)
        requests.append(popularityRequestRecord(request, body: body))
        let storefront = body.storefronts.first ?? ""
        let reply = repliesByStorefront[storefront] ?? defaultReply
        return try popularityHTTPResponse(for: request, body: body, reply: reply)
    }

    func recordedRequests() -> [PopularityRequestRecord] {
        requests
    }
}

private actor GatedMetricsHTTPClient: HTTPClient {
    private let score: Int?
    private let statusCode: Int
    private var didStart = false
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests: [PopularityRequestRecord] = []

    init(score: Int?, statusCode: Int = 200) {
        self.score = score
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try decodePopularityRequest(request)
        requests.append(popularityRequestRecord(request, body: body))
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return try popularityHTTPResponse(
            for: request,
            body: body,
            reply: statusCode == 200 ? .scores(defaultScore: score) : .status(statusCode)
        )
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    func recordedRequests() -> [PopularityRequestRecord] {
        requests
    }
}

private func decodePopularityRequest(_ request: URLRequest) throws -> PopularityRequestBody {
    guard let body = request.httpBody else {
        throw OpenASOError.unexpectedResponse
    }
    return try JSONDecoder().decode(PopularityRequestBody.self, from: body)
}

private func popularityRequestRecord(
    _ request: URLRequest,
    body: PopularityRequestBody
) -> PopularityRequestRecord {
    let contextAppStoreID = request.url
        .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        .flatMap { components in
            components.queryItems?.first(where: { $0.name == "adamId" })?.value
        }
        .flatMap(Int64.init)
    return PopularityRequestRecord(
        storefronts: body.storefronts,
        terms: body.terms,
        contextAppStoreID: contextAppStoreID,
        cookieHeader: request.value(forHTTPHeaderField: "Cookie"),
        xsrfToken: request.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM")
    )
}

private func popularityHTTPResponse(
    for request: URLRequest,
    body: PopularityRequestBody,
    reply: PopularityReply
) throws -> (Data, URLResponse) {
    guard let url = request.url else {
        throw OpenASOError.unexpectedResponse
    }
    switch reply {
    case .scores(let defaultScore):
        let rows: [[String: Any]] = body.terms.compactMap { term in
            guard let defaultScore else { return nil }
            return ["name": term, "popularity": defaultScore]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "success",
            "data": rows,
        ])
        return (data, makeHTTPURLResponse(url: url, statusCode: 200))
    case .status(let statusCode):
        return (
            Data(#"{"error":"scripted status"}"#.utf8),
            makeHTTPURLResponse(url: url, statusCode: statusCode)
        )
    case .providerError(let message):
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "failure",
            "data": [],
            "error": ["errors": [["message": message]]],
        ])
        return (data, makeHTTPURLResponse(url: url, statusCode: 200))
    }
}

private func seedMetric(
    for keyword: KeywordResearchKeywordSnapshot,
    popularityScore: Int?,
    difficultyScore: Int? = nil,
    notes: String? = nil,
    updatedAt: Date,
    in store: BackgroundModelStore
) async throws {
    try await seedMetric(
        queryKey: keyword.queryKey,
        term: keyword.term,
        storefront: keyword.storefront,
        platform: keyword.platform,
        popularityScore: popularityScore,
        difficultyScore: difficultyScore,
        notes: notes,
        updatedAt: updatedAt,
        in: store
    )
}

private func seedMetric(
    queryKey: String,
    term: String,
    storefront: String,
    platform: AppPlatform,
    popularityScore: Int?,
    difficultyScore: Int? = nil,
    notes: String? = nil,
    updatedAt: Date,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        modelContext.insert(KeywordDailyMetric(
            queryKey: queryKey,
            keyword: term,
            storefront: storefront,
            platform: platform,
            popularityScore: popularityScore,
            difficultyScore: difficultyScore,
            source: .appleAdsPopularity,
            confidence: "seeded",
            updatedAt: updatedAt,
            notes: notes
        ))
    }
}

private func storedMetric(
    queryKey: String,
    in store: BackgroundModelStore
) async throws -> StoredMetric? {
    try await store.read { modelContext in
        let targetQueryKey = queryKey
        var descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metric in
                metric.queryKey == targetQueryKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map {
            StoredMetric(
                popularityScore: $0.popularityScore,
                difficultyScore: $0.difficultyScore,
                source: $0.source,
                updatedAt: $0.updatedAt,
                notes: $0.notes
            )
        }
    }
}

private func metricCount(in store: BackgroundModelStore) async throws -> Int {
    try await store.fetchCount(FetchDescriptor<KeywordDailyMetric>())
}

private func seedRankingObservation(
    for keyword: KeywordResearchKeywordSnapshot,
    appStoreID: Int64,
    rank: Int,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let targetQueryKey = keyword.queryKey
        var descriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == targetQueryKey
            }
        )
        descriptor.fetchLimit = 1
        guard let query = try modelContext.fetch(descriptor).first else {
            throw OpenASOError.unexpectedResponse
        }
        let observation = KeywordRankingCrawl(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: metricsProjectCreatedAt.addingTimeInterval(10),
            source: .appStoreWeb,
            resultCount: 1,
            query: query
        )
        let item = KeywordAppRanking(
            position: rank,
            appStoreID: appStoreID,
            bundleID: "example.derived.stats",
            name: "Derived stats sentinel",
            sellerName: "Sentinel seller",
            observation: observation
        )
        observation.items.append(item)
        query.observations.append(observation)
        modelContext.insert(observation)
        modelContext.insert(item)
    }
}

private func storedRankingStats(
    queryKey: String,
    in store: BackgroundModelStore
) async throws -> StoredRankingStats? {
    try await store.read { modelContext in
        let targetQueryKey = queryKey
        var descriptor = FetchDescriptor<AppKeywordStats>(
            predicate: #Predicate { stats in
                stats.queryKey == targetQueryKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map {
            StoredRankingStats(
                appStoreID: $0.appStoreID,
                bestRank: $0.bestRank,
                latestRank: $0.latestRank,
                observationCount: $0.observationCount,
                popularityScore: $0.popularityScore,
                difficultyScore: $0.difficultyScore
            )
        }
    }
}

private func seedResearchKeywords(
    _ specs: [KeywordSpec],
    projectGeneration: KeywordResearchProjectGeneration,
    in store: BackgroundModelStore
) async throws -> [SeededKeyword] {
    try await store.write { modelContext in
        let projectID = projectGeneration.id
        var descriptor = FetchDescriptor<KeywordResearchProject>(
            predicate: #Predicate { project in
                project.id == projectID
            }
        )
        descriptor.fetchLimit = 1
        guard let project = try modelContext.fetch(descriptor).first else {
            throw KeywordResearchProjectStoreError.projectNotFound(projectID)
        }
        guard project.incarnationID == projectGeneration.incarnationID else {
            throw KeywordResearchProjectStoreError.staleProjectRevision(projectID)
        }

        var seeded: [SeededKeyword] = []
        seeded.reserveCapacity(specs.count)
        for (index, spec) in specs.enumerated() {
            let query = try KeywordQuery.fetchOrInsert(
                term: spec.term,
                storefront: spec.storefront,
                platform: spec.platform,
                in: modelContext
            )
            let keyword = KeywordResearchKeyword(
                term: query.term,
                storefront: query.storefront,
                platform: query.platform,
                project: project,
                createdAt: metricsProjectCreatedAt.addingTimeInterval(Double(index + 1))
            )
            project.attachKeyword(keyword)
            modelContext.insert(keyword)
            seeded.append(SeededKeyword(
                generation: keyword.generation,
                queryKey: keyword.queryKey,
                term: keyword.term,
                storefront: keyword.storefront,
                platform: keyword.platform
            ))
        }
        return seeded
    }
}

private func seedTrackedGraph(
    queryKey: String,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let targetQueryKey = queryKey
        var descriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == targetQueryKey
            }
        )
        descriptor.fetchLimit = 1
        guard let query = try modelContext.fetch(descriptor).first else {
            throw OpenASOError.unexpectedResponse
        }
        let app = TrackedApp(
            appStoreID: 991,
            bundleID: "example.tracked.metrics",
            name: "Tracked graph sentinel",
            sellerName: "Sentinel seller",
            defaultPlatform: .ipad,
            createdAt: metricsProjectCreatedAt
        )
        app.isPinned = true
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: app,
            query: query,
            createdAt: metricsProjectCreatedAt.addingTimeInterval(1)
        )
        track.notes = "tracked notes must not change"
        track.statusMessage = "legacy scalar must not change"
        app.keywordTracks.append(track)
        modelContext.insert(app)
        modelContext.insert(track)
        try TrackedKeywordRefreshStatusStore.set(
            "ranking status must not change",
            domain: .ranking,
            for: track,
            updatedAt: metricsProjectCreatedAt.addingTimeInterval(2),
            in: modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            "popularity status must not change",
            domain: .popularity,
            for: track,
            updatedAt: metricsProjectCreatedAt.addingTimeInterval(3),
            in: modelContext
        )
    }
}

private func trackedGraphState(in store: BackgroundModelStore) async throws -> TrackedGraphState {
    try await store.read { modelContext in
        let apps = try modelContext.fetch(FetchDescriptor<TrackedApp>())
        let tracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
        let statuses = try modelContext.fetch(FetchDescriptor<TrackedKeywordRefreshStatus>())
        guard let app = apps.first, let track = tracks.first else {
            throw OpenASOError.unexpectedResponse
        }
        let status = try TrackedKeywordRefreshStatusStore.snapshot(for: track, in: modelContext)
        return TrackedGraphState(
            appCount: apps.count,
            trackCount: tracks.count,
            statusCount: statuses.count,
            appName: app.name,
            appPinned: app.isPinned,
            trackNotes: track.notes,
            trackStatusMessage: track.statusMessage,
            rankingStatus: status.rankingMessage,
            popularityStatus: status.popularityMessage
        )
    }
}

private let metricsDay: TimeInterval = 60 * 60 * 24
private let metricsTestDate = Date(timeIntervalSince1970: 1_800_000_000)
private let metricsProjectCreatedAt = Date(timeIntervalSince1970: 1_790_000_000)
private let metricsContextAppStoreID: Int64 = 6_608_976_383
private let metricsSession = AppleAdsWebSession(
    cookieHeader: "metrics-cookie=private-value; XSRF-TOKEN-CM=private-token",
    xsrfToken: "private-token",
    updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
    accountName: "Private test account"
)
private let replacementMetricsSession = AppleAdsWebSession(
    cookieHeader: "replacement-cookie=private-value; XSRF-TOKEN-CM=replacement-token",
    xsrfToken: "replacement-token",
    updatedAt: Date(timeIntervalSince1970: 1_780_000_001),
    accountName: "Replacement test account"
)
