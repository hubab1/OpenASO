import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct EstimatedKeywordDifficultySummaryTests {
    @Test
    func bulkReadersChooseTheSameLatestRevisionWithoutLeakingOlderEvidence() throws {
        let context = try makeContext()
        let earlier = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            score: 41
        )
        let laterTieBreaker = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            score: 81
        )
        context.insert(makeMetric(from: earlier))
        context.insert(makeMetric(from: laterTieBreaker))
        for result in earlier.evidence.resultEvidence {
            context.insert(makeEvidenceRecord(result, payload: earlier))
        }
        for result in laterTieBreaker.evidence.resultEvidence {
            context.insert(makeEvidenceRecord(result, payload: laterTieBreaker))
        }
        try context.save()

        let missingQueryKey = KeywordQuery.makeQueryKey(
            term: "not persisted",
            storefront: "gb",
            platform: .iphone
        )
        let summaries = try EstimatedKeywordDifficultyStore.summaries(
            queryKeys: [earlier.queryKey, missingQueryKey, earlier.queryKey],
            in: context
        )
        let snapshots = try EstimatedKeywordDifficultyStore.snapshots(
            queryKeys: [earlier.queryKey, missingQueryKey, earlier.queryKey],
            in: context
        )

        let summary = try #require(summaries[earlier.queryKey])
        let snapshot = try #require(snapshots[earlier.queryKey])
        #expect(summaries.count == 1)
        #expect(snapshots.count == 1)
        #expect(summary.calculationID == laterTieBreaker.calculationID)
        #expect(snapshot.calculationID == summary.calculationID)
        #expect(summary.score == 81)
        #expect(snapshot.resultEvidence.map(\.appStoreID) == [20_001, 20_002, 20_003])
        #expect(try EstimatedKeywordDifficultyStore.summary(
            queryKey: missingQueryKey,
            in: context
        ) == nil)
    }

    @Test
    func presentationKeepsMissingUnavailableAndEstimatedDistinct() throws {
        let context = try makeContext()
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let estimated = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            rankingFetchedAt: fetchedAt,
            computedAt: fetchedAt.addingTimeInterval(60)
        )
        let unavailable = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            keyword: "rare phrase",
            result: .unavailable(reason: .insufficientResults),
            evidenceCount: 0,
            providerResultCount: 0,
            rankingFetchedAt: fetchedAt,
            computedAt: fetchedAt.addingTimeInterval(86_399)
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(estimated, in: context)
        _ = try EstimatedKeywordDifficultyStore.upsert(unavailable, in: context)

        let summaries = try EstimatedKeywordDifficultyStore.summaries(
            queryKeys: [estimated.queryKey, unavailable.queryKey],
            in: context
        )
        let beforeBoundary = EstimatedKeywordDifficultyPresentation(
            summary: summaries[estimated.queryKey],
            asOf: fetchedAt.addingTimeInterval(
                EstimatedKeywordDifficultyFreshness.maximumAge - 0.001
            )
        )
        let atBoundary = EstimatedKeywordDifficultyPresentation(
            summary: summaries[estimated.queryKey],
            asOf: fetchedAt.addingTimeInterval(
                EstimatedKeywordDifficultyFreshness.maximumAge
            )
        )
        let unavailablePresentation = EstimatedKeywordDifficultyPresentation(
            summary: summaries[unavailable.queryKey],
            asOf: unavailable.computedAt
        )
        let missingPresentation = EstimatedKeywordDifficultyPresentation(
            summary: nil,
            asOf: fetchedAt
        )

        #expect(beforeBoundary.value == .estimated(
            score: 67,
            confidenceScore: 83,
            confidence: .medium
        ))
        #expect(!beforeBoundary.isStale)
        #expect(atBoundary.isStale)
        #expect(unavailablePresentation.value == .unavailable(reason: .insufficientResults))
        #expect(!unavailablePresentation.isStale)
        #expect(missingPresentation.value == .missing)
        #expect(!missingPresentation.isStale)
        #expect(missingPresentation.rankingFetchedAt == nil)
    }

    @Test
    func directITunesResultRoundTripsWithoutFabricatedFallbackContext() throws {
        let context = try makeContext()
        let payload = makePayload(
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            rankingSource: .iTunesFallback,
            fallback: nil
        )

        #expect(try EstimatedKeywordDifficultyStore.upsert(payload, in: context) == .inserted)
        try context.save()

        let summary = try #require(try EstimatedKeywordDifficultyStore.summary(
            queryKey: payload.queryKey,
            in: context
        ))
        let snapshot = try #require(try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: payload.queryKey,
            in: context
        ))
        #expect(summary.rankingSource == .iTunesFallback)
        #expect(summary.fallbackProvider == nil)
        #expect(summary.fallbackCategory == nil)
        #expect(snapshot.rankingSource == .iTunesFallback)
        #expect(snapshot.fallbackProviderRaw == nil)
        #expect(snapshot.fallbackCategoryRaw == nil)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        return ModelContext(container)
    }

    private func makePayload(
        calculationID: UUID,
        keyword: String = "focus timer",
        score: Int = 67,
        result: EstimatedKeywordDifficultyPersistenceResult? = nil,
        evidenceCount: Int = 3,
        providerResultCount: Int = 3,
        rankingSource: RankingSource = .appStoreWeb,
        rankingFetchedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        computedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_060),
        fallback: EstimatedKeywordDifficultyFallbackProvenance? = nil
    ) -> EstimatedKeywordDifficultyPersistencePayload {
        let storefront = "gb"
        let platform = AppPlatform.iphone
        return EstimatedKeywordDifficultyPersistencePayload(
            queryKey: KeywordQuery.makeQueryKey(
                term: keyword,
                storefront: storefront,
                platform: platform
            ),
            calculationID: calculationID,
            keyword: keyword,
            storefront: storefront,
            platform: platform,
            result: result ?? .estimated(
                score: score,
                confidenceScore: 83,
                confidence: .medium
            ),
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: 10,
            providerResultCount: providerResultCount,
            evidence: makeEvidence(
                count: evidenceCount,
                keyword: keyword,
                appStoreIDBase: calculationID.uuidString.hasSuffix("10") ? 10_000 : 20_000
            ),
            rankingSource: rankingSource,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: computedAt,
            fallback: fallback,
            notes: ["Estimated locally from public ranking evidence."]
        )
    }

    private func makeEvidence(
        count: Int,
        keyword: String,
        appStoreIDBase: Int64
    ) -> EstimatedKeywordDifficultyEvidence {
        let positions = count > 0 ? Array(1 ... count) : []
        let results = positions.map { position in
            EstimatedKeywordDifficultyResultEvidence(
                position: position,
                appStoreID: appStoreIDBase + Int64(position),
                title: "\(keyword) result \(position)",
                subtitle: "Subtitle \(position)",
                ratingCount: position * 100,
                ratingAuthorityScore: 40 + position,
                titleTokenCoveragePercentage: 80 + position,
                combinedTokenCoveragePercentage: 85 + position,
                metadataMatchScore: 70 + position,
                exactTitlePhraseMatch: position == 1,
                exactSubtitlePhraseMatch: position == 2
            )
        }
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

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        guard values.count.isMultiple(of: 2) else { return values[middle] }
        return values[middle - 1] + (values[middle] - values[middle - 1]) / 2
    }

    private func makeMetric(
        from payload: EstimatedKeywordDifficultyPersistencePayload
    ) -> EstimatedKeywordDifficultyMetric {
        let stateRaw: String
        let score: Int?
        let confidenceScore: Int?
        let confidenceRaw: String?
        let unavailableReasonRaw: String?
        switch payload.result {
        case .estimated(let value, let confidenceValue, let confidence):
            stateRaw = EstimatedKeywordDifficultyState.estimated.rawValue
            score = value
            confidenceScore = confidenceValue
            confidenceRaw = confidence.rawValue
            unavailableReasonRaw = nil
        case .unavailable(let reason):
            stateRaw = EstimatedKeywordDifficultyState.unavailable.rawValue
            score = nil
            confidenceScore = nil
            confidenceRaw = nil
            unavailableReasonRaw = reason.rawValue
        }
        return EstimatedKeywordDifficultyMetric(
            queryKey: payload.queryKey,
            calculationID: payload.calculationID,
            keyword: payload.keyword,
            storefront: payload.storefront,
            platformRaw: payload.platform.rawValue,
            stateRaw: stateRaw,
            score: score,
            confidenceScore: confidenceScore,
            confidenceRaw: confidenceRaw,
            unavailableReasonRaw: unavailableReasonRaw,
            estimationSourceRaw: payload.estimationSource.rawValue,
            algorithmIdentifier: payload.algorithmIdentifier,
            algorithmVersion: payload.algorithmVersion,
            requestedResultLimit: payload.requestedResultLimit,
            providerResultCount: payload.providerResultCount,
            consideredResultCount: payload.evidence.consideredResultCount,
            ratedResultCount: payload.evidence.ratedResultCount,
            weightedRatingCoveragePercentage: payload.evidence.weightedRatingCoveragePercentage,
            maximumRatingCount: payload.evidence.maximumRatingCount,
            medianRatingCount: payload.evidence.medianRatingCount,
            ratingAuthorityScore: payload.evidence.ratingAuthorityScore,
            metadataSaturationScore: payload.evidence.metadataSaturationScore,
            exactTitlePhraseMatchCount: payload.evidence.resultEvidence.count(
                where: \.exactTitlePhraseMatch
            ),
            exactSubtitlePhraseMatchCount: payload.evidence.resultEvidence.count(
                where: \.exactSubtitlePhraseMatch
            ),
            rankingSourceRaw: payload.rankingSource.rawValue,
            rankingFetchedAt: payload.rankingFetchedAt,
            computedAt: payload.computedAt,
            fallbackProviderRaw: payload.fallback?.provider.rawValue,
            fallbackCategoryRaw: payload.fallback?.category.rawValue,
            fallbackTransportCode: payload.fallback?.transportCode,
            fallbackHTTPStatus: payload.fallback?.httpStatus,
            fallbackResponseFailureRaw: payload.fallback?.responseFailure?.rawValue,
            notes: payload.notes
        )
    }

    private func makeEvidenceRecord(
        _ result: EstimatedKeywordDifficultyResultEvidence,
        payload: EstimatedKeywordDifficultyPersistencePayload
    ) -> EstimatedKeywordDifficultyResultEvidenceRecord {
        EstimatedKeywordDifficultyResultEvidenceRecord(
            queryKey: payload.queryKey,
            calculationID: payload.calculationID,
            position: result.position,
            appStoreID: result.appStoreID,
            title: result.title,
            subtitle: result.subtitle,
            ratingCount: result.ratingCount,
            ratingAuthorityScore: result.ratingAuthorityScore,
            titleTokenCoveragePercentage: result.titleTokenCoveragePercentage,
            combinedTokenCoveragePercentage: result.combinedTokenCoveragePercentage,
            metadataMatchScore: result.metadataMatchScore,
            exactTitlePhraseMatch: result.exactTitlePhraseMatch,
            exactSubtitlePhraseMatch: result.exactSubtitlePhraseMatch
        )
    }
}
