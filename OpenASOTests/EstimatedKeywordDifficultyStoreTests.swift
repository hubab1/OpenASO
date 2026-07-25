import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct EstimatedKeywordDifficultyStoreTests {
    @Test
    func estimatedResultAndStructuredFallbackRoundTripAcrossReopen() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenASO-EstimatedDifficulty-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)
        let calculationID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let payload = makePayload(
            calculationID: calculationID,
            rankingSource: .iTunesFallback,
            fallback: EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .response,
                responseFailure: .pageShapeChanged
            )
        )

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(KeywordDailyMetric(
                queryKey: payload.queryKey,
                keyword: payload.keyword,
                storefront: payload.storefront,
                platform: payload.platform,
                popularityScore: nil,
                difficultyScore: 42,
                source: .appleAdsPopularity,
                updatedAt: payload.rankingFetchedAt
            ))
            #expect(try EstimatedKeywordDifficultyStore.upsert(payload, in: context) == .inserted)
            try context.save()
        }

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let context = ModelContext(container)
            let loadedSnapshot = try EstimatedKeywordDifficultyStore.snapshot(
                queryKey: payload.queryKey,
                in: context
            )
            let snapshot = try #require(loadedSnapshot)
            #expect(snapshot.queryKey == payload.queryKey)
            #expect(snapshot.calculationID == calculationID)
            #expect(snapshot.keyword == "focus timer")
            #expect(snapshot.storefront == "gb")
            #expect(snapshot.platform == .iphone)
            #expect(snapshot.state == .estimated)
            #expect(snapshot.score == 67)
            #expect(snapshot.confidenceScore == 83)
            #expect(snapshot.confidence == .medium)
            #expect(snapshot.unavailableReason == nil)
            #expect(snapshot.estimationSource == .topResultsHeuristic)
            #expect(snapshot.algorithmIdentifier == "top10-authority-saturation")
            #expect(snapshot.algorithmVersion == 1)
            #expect(snapshot.requestedResultLimit == 10)
            #expect(snapshot.providerResultCount == 8)
            #expect(snapshot.consideredResultCount == 3)
            #expect(snapshot.ratedResultCount == 3)
            #expect(snapshot.maximumRatingCount == 300)
            #expect(snapshot.medianRatingCount == 200)
            #expect(snapshot.rankingSource == .iTunesFallback)
            #expect(snapshot.fallbackProviderRaw == RankingSource.appStoreWeb.rawValue)
            #expect(snapshot.fallbackCategory == .response)
            #expect(snapshot.fallbackResponseFailure == .pageShapeChanged)
            #expect(snapshot.fallbackTransportCode == nil)
            #expect(snapshot.fallbackHTTPStatus == nil)
            #expect(snapshot.notes == payload.notes)
            #expect(snapshot.resultEvidence.count == 3)
            #expect(snapshot.resultEvidence.map(\.position) == [1, 2, 3])
            #expect(snapshot.resultEvidence[0].title == "focus timer result 1")
            #expect(snapshot.resultEvidence[0].subtitle == "Public subtitle 1")
            #expect(snapshot.resultEvidence[0].ratingCount == 100)
            #expect(snapshot.resultEvidence[0].ratingAuthorityScore == 41)
            #expect(snapshot.resultEvidence[0].titleTokenCoveragePercentage == 91)
            #expect(snapshot.resultEvidence[0].combinedTokenCoveragePercentage == 96)
            #expect(snapshot.resultEvidence[0].metadataMatchScore == 86)
            #expect(snapshot.resultEvidence[0].exactTitlePhraseMatch)
            #expect(!snapshot.resultEvidence[0].exactSubtitlePhraseMatch)

            let legacy = try #require(context.fetch(FetchDescriptor<KeywordDailyMetric>()).first)
            #expect(legacy.difficultyScore == 42)
            #expect(try context.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyMetric>()
            ).count == 1)
            #expect(try context.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
            ).count == 3)
        }
    }

    @Test
    func missingAndPersistedUnavailableAreDistinct() throws {
        let context = try makeContext()
        let queryKey = KeywordQuery.makeQueryKey(
            term: "new keyword",
            storefront: "us",
            platform: .ipad
        )
        #expect(try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: queryKey,
            in: context
        ) == nil)

        let payload = makePayload(
            keyword: "new keyword",
            storefront: "US",
            platform: .ipad,
            result: .unavailable(reason: .insufficientResults),
            evidenceCount: 0,
            providerResultCount: 0
        )
        #expect(try EstimatedKeywordDifficultyStore.upsert(payload, in: context) == .inserted)
        try context.save()

        let loadedSnapshot = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: payload.queryKey,
            in: context
        )
        let snapshot = try #require(loadedSnapshot)
        #expect(snapshot.state == .unavailable)
        #expect(snapshot.unavailableReason == .insufficientResults)
        #expect(snapshot.score == nil)
        #expect(snapshot.confidenceScore == nil)
        #expect(snapshot.confidenceRaw == nil)
        #expect(snapshot.resultEvidence.isEmpty)
    }

    @Test
    func replacementKeepsOnlyTheCurrentBoundedGenerationAndQueriesRemainIsolated() throws {
        let context = try makeContext()
        let first = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            evidenceCount: 10,
            providerResultCount: 10
        )
        let second = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            evidenceCount: 3,
            providerResultCount: 3,
            rankingFetchedAt: first.rankingFetchedAt.addingTimeInterval(60),
            computedAt: first.computedAt.addingTimeInterval(60)
        )
        let other = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            keyword: "sleep sounds",
            evidenceCount: 10,
            providerResultCount: 10
        )

        #expect(try EstimatedKeywordDifficultyStore.upsert(first, in: context) == .inserted)
        #expect(try EstimatedKeywordDifficultyStore.upsert(second, in: context) == .updated)
        #expect(try EstimatedKeywordDifficultyStore.upsert(other, in: context) == .inserted)
        try context.save()

        let snapshots = try EstimatedKeywordDifficultyStore.snapshots(
            queryKeys: [first.queryKey, other.queryKey, first.queryKey],
            in: context
        )
        #expect(snapshots[first.queryKey]?.calculationID == second.calculationID)
        #expect(snapshots[first.queryKey]?.resultEvidence.count == 3)
        #expect(snapshots[other.queryKey]?.resultEvidence.count == 10)
        #expect(try evidenceCount(queryKey: first.queryKey, in: context) == 3)
        #expect(try evidenceCount(queryKey: other.queryKey, in: context) == 10)

        try EstimatedKeywordDifficultyStore.delete(queryKeys: [first.queryKey], in: context)
        try context.save()
        #expect(try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: first.queryKey,
            in: context
        ) == nil)
        #expect(try evidenceCount(queryKey: first.queryKey, in: context) == 0)
        #expect(try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: other.queryKey,
            in: context
        )?.resultEvidence.count == 10)
    }

    @Test
    func revisionOrderingRejectsDelayedInputAndMakesExactRetriesIdempotent() throws {
        let context = try makeContext()
        let base = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        )
        #expect(try EstimatedKeywordDifficultyStore.upsert(base, in: context) == .inserted)

        let olderInput = makePayload(
            calculationID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            result: .estimated(score: 1, confidenceScore: 10, confidence: .low),
            rankingFetchedAt: base.rankingFetchedAt.addingTimeInterval(-60),
            computedAt: base.computedAt.addingTimeInterval(600)
        )
        #expect(try EstimatedKeywordDifficultyStore.upsert(olderInput, in: context) == .ignoredOlder)

        let newerCalculation = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            result: .estimated(score: 72, confidenceScore: 88, confidence: .high),
            rankingFetchedAt: base.rankingFetchedAt,
            computedAt: base.computedAt.addingTimeInterval(60)
        )
        #expect(try EstimatedKeywordDifficultyStore.upsert(newerCalculation, in: context) == .updated)
        #expect(try EstimatedKeywordDifficultyStore.upsert(newerCalculation, in: context) == .unchanged)
        try context.save()

        let loadedBeforeConflict = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: base.queryKey,
            in: context
        )
        let beforeConflict = try #require(loadedBeforeConflict)
        let conflictingRetry = makePayload(
            calculationID: newerCalculation.calculationID,
            result: .estimated(score: 73, confidenceScore: 88, confidence: .high),
            rankingFetchedAt: newerCalculation.rankingFetchedAt,
            computedAt: newerCalculation.computedAt
        )
        #expect(throws: EstimatedKeywordDifficultyStoreError.revisionConflict) {
            try EstimatedKeywordDifficultyStore.upsert(conflictingRetry, in: context)
        }
        #expect(try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: base.queryKey,
            in: context
        ) == beforeConflict)
        #expect(beforeConflict.score == 72)
    }

    @Test
    func reversedSavesFromTwoContextsCannotCommitAnOlderRevision() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let seedContext = ModelContext(container)
        let baseline = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(baseline, in: seedContext)
        try seedContext.save()

        let delayedContext = ModelContext(container)
        let newerContext = ModelContext(container)
        let delayed = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            result: .estimated(score: 11, confidenceScore: 60, confidence: .low),
            rankingFetchedAt: baseline.rankingFetchedAt.addingTimeInterval(60),
            computedAt: baseline.computedAt.addingTimeInterval(60)
        )
        let newer = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            result: .estimated(score: 77, confidenceScore: 90, confidence: .high),
            rankingFetchedAt: baseline.rankingFetchedAt.addingTimeInterval(120),
            computedAt: baseline.computedAt.addingTimeInterval(120)
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(delayed, in: delayedContext)
        _ = try EstimatedKeywordDifficultyStore.upsert(newer, in: newerContext)
        try newerContext.save()

        do {
            try delayedContext.save()
        } catch {
            delayedContext.rollback()
        }

        let verificationContext = ModelContext(container)
        let snapshot = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: baseline.queryKey,
            in: verificationContext
        )
        #expect(snapshot?.calculationID == newer.calculationID)
        #expect(snapshot?.score == 77)
        #expect(snapshot?.resultEvidence.count == 3)

        let reconciled = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
            result: .estimated(score: 80, confidenceScore: 88, confidence: .high),
            rankingFetchedAt: newer.rankingFetchedAt.addingTimeInterval(60),
            computedAt: newer.computedAt.addingTimeInterval(60)
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(reconciled, in: verificationContext)
        try verificationContext.save()

        let compactedContext = ModelContext(container)
        #expect(try compactedContext.fetch(
            FetchDescriptor<EstimatedKeywordDifficultyMetric>()
        ).count == 1)
        #expect(try evidenceCount(queryKey: baseline.queryKey, in: compactedContext) == 3)
    }

    @Test
    func concurrentFirstInsertsCannotCommitTwoQueryGenerations() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let delayedContext = ModelContext(container)
        let newerContext = ModelContext(container)
        let delayed = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!,
            result: .estimated(score: 12, confidenceScore: 60, confidence: .low)
        )
        let newer = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
            result: .estimated(score: 79, confidenceScore: 88, confidence: .high),
            rankingFetchedAt: delayed.rankingFetchedAt.addingTimeInterval(60),
            computedAt: delayed.computedAt.addingTimeInterval(60)
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(delayed, in: delayedContext)
        _ = try EstimatedKeywordDifficultyStore.upsert(newer, in: newerContext)
        try newerContext.save()

        do {
            try delayedContext.save()
        } catch {
            delayedContext.rollback()
        }

        let verificationContext = ModelContext(container)
        let snapshot = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: newer.queryKey,
            in: verificationContext
        )
        #expect(snapshot?.calculationID == newer.calculationID)
        #expect(snapshot?.score == 79)
        #expect(snapshot?.resultEvidence.count == 3)

        let reconciled = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000313")!,
            result: .estimated(score: 81, confidenceScore: 89, confidence: .high),
            rankingFetchedAt: newer.rankingFetchedAt.addingTimeInterval(60),
            computedAt: newer.computedAt.addingTimeInterval(60)
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(reconciled, in: verificationContext)
        try verificationContext.save()

        let compactedContext = ModelContext(container)
        #expect(try compactedContext.fetch(
            FetchDescriptor<EstimatedKeywordDifficultyMetric>()
        ).count == 1)
        #expect(try evidenceCount(queryKey: newer.queryKey, in: compactedContext) == 3)
    }

    @Test
    func differentAppsAtTheSameProviderPositionRemainExactAndDeterministic() throws {
        let context = try makeContext()
        var results = makeEvidence(count: 3, keyword: "focus timer").resultEvidence
        let second = results[1]
        results[1] = EstimatedKeywordDifficultyResultEvidence(
            position: results[0].position,
            appStoreID: second.appStoreID,
            title: second.title,
            subtitle: second.subtitle,
            ratingCount: second.ratingCount,
            ratingAuthorityScore: second.ratingAuthorityScore,
            titleTokenCoveragePercentage: second.titleTokenCoveragePercentage,
            combinedTokenCoveragePercentage: second.combinedTokenCoveragePercentage,
            metadataMatchScore: second.metadataMatchScore,
            exactTitlePhraseMatch: second.exactTitlePhraseMatch,
            exactSubtitlePhraseMatch: second.exactSubtitlePhraseMatch
        )
        let payload = makePayload(evidenceOverride: makeEvidence(from: results))

        #expect(try EstimatedKeywordDifficultyStore.upsert(payload, in: context) == .inserted)
        try context.save()
        let snapshot = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: payload.queryKey,
            in: context
        )
        #expect(snapshot?.resultEvidence.map(\.position) == [1, 1, 3])
        #expect(snapshot?.resultEvidence.map(\.appStoreID) == [10_001, 10_002, 10_003])
    }

    @Test
    func freshnessUsesRankingFetchTimeRatherThanRecomputationTime() throws {
        let context = try makeContext()
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let payload = makePayload(
            rankingFetchedAt: fetchedAt,
            computedAt: fetchedAt.addingTimeInterval(86_400)
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(payload, in: context)
        let loadedSnapshot = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: payload.queryKey,
            in: context
        )
        let snapshot = try #require(loadedSnapshot)

        #expect(!snapshot.isStale(
            asOf: fetchedAt.addingTimeInterval(3_599),
            maximumAge: 3_600
        ))
        #expect(snapshot.isStale(
            asOf: fetchedAt.addingTimeInterval(3_600),
            maximumAge: 3_600
        ))
        #expect(snapshot.isStale(
            asOf: payload.computedAt,
            maximumAge: 3_600
        ))
    }

    @Test
    func invalidPayloadsDoNotMutateTheExistingSnapshot() throws {
        let context = try makeContext()
        let baseline = makePayload()
        _ = try EstimatedKeywordDifficultyStore.upsert(baseline, in: context)
        try context.save()
        let loadedExpected = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: baseline.queryKey,
            in: context
        )
        let expected = try #require(loadedExpected)

        let invalidQuery = makePayload(queryKeyOverride: "wrong::query::key")
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidQueryScope) {
            try EstimatedKeywordDifficultyStore.upsert(invalidQuery, in: context)
        }

        let tooMany = makePayload(
            requestedResultLimit: 11,
            evidenceCount: 11,
            providerResultCount: 11
        )
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidEvidence("result count")) {
            try EstimatedKeywordDifficultyStore.upsert(tooMany, in: context)
        }

        var duplicateEvidence = makeEvidence(count: 3, keyword: baseline.keyword).resultEvidence
        duplicateEvidence[1] = EstimatedKeywordDifficultyResultEvidence(
            position: 2,
            appStoreID: duplicateEvidence[0].appStoreID,
            title: duplicateEvidence[1].title,
            subtitle: duplicateEvidence[1].subtitle,
            ratingCount: duplicateEvidence[1].ratingCount,
            ratingAuthorityScore: duplicateEvidence[1].ratingAuthorityScore,
            titleTokenCoveragePercentage: duplicateEvidence[1].titleTokenCoveragePercentage,
            combinedTokenCoveragePercentage: duplicateEvidence[1].combinedTokenCoveragePercentage,
            metadataMatchScore: duplicateEvidence[1].metadataMatchScore,
            exactTitlePhraseMatch: duplicateEvidence[1].exactTitlePhraseMatch,
            exactSubtitlePhraseMatch: duplicateEvidence[1].exactSubtitlePhraseMatch
        )
        let duplicate = makePayload(evidenceOverride: makeEvidence(
            from: duplicateEvidence
        ))
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidEvidence("duplicate result")) {
            try EstimatedKeywordDifficultyStore.upsert(duplicate, in: context)
        }

        let invalidScore = makePayload(
            result: .estimated(score: 101, confidenceScore: 83, confidence: .medium)
        )
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidResultState) {
            try EstimatedKeywordDifficultyStore.upsert(invalidScore, in: context)
        }

        let mismatchedConfidence = makePayload(
            result: .estimated(score: 50, confidenceScore: 0, confidence: .high)
        )
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidResultState) {
            try EstimatedKeywordDifficultyStore.upsert(mismatchedConfidence, in: context)
        }

        let impossibleEstimate = makePayload(
            result: .estimated(score: 50, confidenceScore: 50, confidence: .low),
            evidenceCount: 0,
            providerResultCount: 0
        )
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidResultState) {
            try EstimatedKeywordDifficultyStore.upsert(impossibleEstimate, in: context)
        }

        var incoherentResults = makeEvidence(
            count: 3,
            keyword: baseline.keyword
        ).resultEvidence
        let firstResult = incoherentResults[0]
        incoherentResults[0] = EstimatedKeywordDifficultyResultEvidence(
            position: firstResult.position,
            appStoreID: firstResult.appStoreID,
            title: firstResult.title,
            subtitle: firstResult.subtitle,
            ratingCount: nil,
            ratingAuthorityScore: firstResult.ratingAuthorityScore,
            titleTokenCoveragePercentage: firstResult.titleTokenCoveragePercentage,
            combinedTokenCoveragePercentage: firstResult.combinedTokenCoveragePercentage,
            metadataMatchScore: firstResult.metadataMatchScore,
            exactTitlePhraseMatch: firstResult.exactTitlePhraseMatch,
            exactSubtitlePhraseMatch: firstResult.exactSubtitlePhraseMatch
        )
        let incoherentEvidence = makePayload(
            result: .unavailable(reason: .insufficientRatingEvidence),
            evidenceOverride: makeEvidence(from: incoherentResults)
        )
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidEvidence("summary coherence")) {
            try EstimatedKeywordDifficultyStore.upsert(incoherentEvidence, in: context)
        }

        let unredactedShape = makePayload(
            rankingSource: .appStoreWeb,
            fallback: EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .httpStatus,
                httpStatus: 500
            )
        )
        #expect(throws: EstimatedKeywordDifficultyStoreError.invalidFallback) {
            try EstimatedKeywordDifficultyStore.upsert(unredactedShape, in: context)
        }

        #expect(try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: baseline.queryKey,
            in: context
        ) == expected)
        #expect(try evidenceCount(queryKey: baseline.queryKey, in: context) == 3)
    }

    @Test
    func backgroundWriteRollsBackMetricAndEvidenceTogether() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let store = BackgroundModelStore(modelContainer: container)
        let payload = makePayload()

        do {
            let _: Void = try await store.write { context -> Void in
                _ = try EstimatedKeywordDifficultyStore.upsert(payload, in: context)
                throw InjectedDifficultyStoreFailure.expected
            }
            Issue.record("Expected the injected transaction failure")
        } catch InjectedDifficultyStoreFailure.expected {
            // Expected.
        }

        let missing = try await store.read { context in
            try EstimatedKeywordDifficultyStore.snapshot(
                queryKey: payload.queryKey,
                in: context
            )
        }
        #expect(missing == nil)

        let outcome = try await EstimatedKeywordDifficultyStore.persist(
            payload,
            using: store
        )
        #expect(outcome == .inserted)
        let persisted = try await store.read { context in
            try EstimatedKeywordDifficultyStore.snapshot(
                queryKey: payload.queryKey,
                in: context
            )
        }
        #expect(persisted?.resultEvidence.count == 3)
    }

    @Test
    func unknownPersistedRawValuesNeverDefaultToKnownProvenance() throws {
        let context = try makeContext()
        let payload = makePayload()
        _ = try EstimatedKeywordDifficultyStore.upsert(payload, in: context)
        try context.save()

        let metric = try #require(context.fetch(
            FetchDescriptor<EstimatedKeywordDifficultyMetric>()
        ).first)
        metric.platformRaw = "future-platform"
        metric.stateRaw = "future-state"
        metric.confidenceRaw = "future-confidence"
        metric.unavailableReasonRaw = "future-reason"
        metric.estimationSourceRaw = "future-estimator"
        metric.rankingSourceRaw = "future-ranking-source"
        metric.fallbackCategoryRaw = "future-fallback"
        metric.fallbackResponseFailureRaw = "future-response"
        try context.save()

        let loadedSnapshot = try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: payload.queryKey,
            in: context
        )
        let snapshot = try #require(loadedSnapshot)
        #expect(snapshot.platformRaw == "future-platform")
        #expect(snapshot.platform == nil)
        #expect(snapshot.stateRaw == "future-state")
        #expect(snapshot.state == nil)
        #expect(snapshot.confidence == nil)
        #expect(snapshot.unavailableReason == nil)
        #expect(snapshot.estimationSource == nil)
        #expect(snapshot.rankingSourceRaw == "future-ranking-source")
        #expect(snapshot.rankingSource == nil)
        #expect(snapshot.fallbackCategory == nil)
        #expect(snapshot.fallbackResponseFailure == nil)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        return ModelContext(container)
    }

    private func evidenceCount(queryKey: String, in context: ModelContext) throws -> Int {
        let targetQueryKey = queryKey
        return try context.fetchCount(FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>(
            predicate: #Predicate { evidence in
                evidence.queryKey == targetQueryKey
            }
        ))
    }

    private func makePayload(
        queryKeyOverride: String? = nil,
        calculationID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        keyword: String = "focus timer",
        storefront: String = "gb",
        platform: AppPlatform = .iphone,
        result: EstimatedKeywordDifficultyPersistenceResult = .estimated(
            score: 67,
            confidenceScore: 83,
            confidence: .medium
        ),
        requestedResultLimit: Int = 10,
        evidenceCount: Int = 3,
        providerResultCount: Int = 8,
        evidenceOverride: EstimatedKeywordDifficultyEvidence? = nil,
        rankingSource: RankingSource = .appStoreWeb,
        rankingFetchedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        computedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_060),
        fallback: EstimatedKeywordDifficultyFallbackProvenance? = nil
    ) -> EstimatedKeywordDifficultyPersistencePayload {
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let queryKey = queryKeyOverride ?? KeywordQuery.makeQueryKey(
            term: keyword,
            storefront: normalizedStorefront,
            platform: platform
        )
        return EstimatedKeywordDifficultyPersistencePayload(
            queryKey: queryKey,
            calculationID: calculationID,
            keyword: keyword,
            storefront: storefront,
            platform: platform,
            result: result,
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: requestedResultLimit,
            providerResultCount: providerResultCount,
            evidence: evidenceOverride ?? makeEvidence(count: evidenceCount, keyword: keyword),
            rankingSource: rankingSource,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: computedAt,
            fallback: fallback,
            notes: [
                "Heuristic estimated competition from current top results.",
                "This is not Apple Ads difficulty or an Apple-provided metric."
            ]
        )
    }

    private func makeEvidence(
        count: Int,
        keyword: String
    ) -> EstimatedKeywordDifficultyEvidence {
        var results: [EstimatedKeywordDifficultyResultEvidence] = []
        if count > 0 {
            for position in 1 ... count {
                let result = EstimatedKeywordDifficultyResultEvidence(
                position: position,
                appStoreID: Int64(10_000 + position),
                title: "\(keyword) result \(position)",
                subtitle: "Public subtitle \(position)",
                ratingCount: position * 100,
                ratingAuthorityScore: min(100, 40 + position),
                titleTokenCoveragePercentage: min(100, 90 + position),
                combinedTokenCoveragePercentage: min(100, 95 + position),
                metadataMatchScore: min(100, 85 + position),
                exactTitlePhraseMatch: position.isMultiple(of: 2) == false,
                exactSubtitlePhraseMatch: position.isMultiple(of: 2)
                )
                results.append(result)
            }
        }
        return makeEvidence(from: results)
    }

    private func makeEvidence(
        from results: [EstimatedKeywordDifficultyResultEvidence]
    ) -> EstimatedKeywordDifficultyEvidence {
        let ratings = results.compactMap(\.ratingCount).sorted()
        return EstimatedKeywordDifficultyEvidence(
            consideredResultCount: results.count,
            ratedResultCount: ratings.count,
            weightedRatingCoveragePercentage: results.isEmpty ? 0 : 100,
            maximumRatingCount: ratings.last,
            medianRatingCount: median(ratings),
            ratingAuthorityScore: results.isEmpty ? nil : 62,
            metadataSaturationScore: results.isEmpty ? nil : 71,
            resultEvidence: results
        )
    }

    private func median(_ sortedValues: [Int]) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let middle = sortedValues.count / 2
        guard sortedValues.count.isMultiple(of: 2) else { return sortedValues[middle] }
        return sortedValues[middle - 1] + (sortedValues[middle] - sortedValues[middle - 1]) / 2
    }
}

private enum InjectedDifficultyStoreFailure: Error {
    case expected
}
