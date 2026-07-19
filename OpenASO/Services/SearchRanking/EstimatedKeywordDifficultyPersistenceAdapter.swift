import Foundation
import SwiftData

/// Converts the pure estimator output and redacted ranking provenance into the
/// append-only V4 persistence contract. Invalid or incomplete provider
/// provenance returns `nil` so an otherwise valid ranking refresh still lands.
enum EstimatedKeywordDifficultyPersistenceAdapter {
    /// Revalidates the track generation inside the estimate transaction. This
    /// prevents a provider result from restoring orphaned query-level data
    /// after its originating track was deleted or replaced.
    @discardableResult
    static func upsertIfCurrent(
        for pageResult: RankingRefreshPageResult,
        in modelContext: ModelContext
    ) throws -> EstimatedKeywordDifficultyUpsertOutcome? {
        guard let payload = pageResult.estimatedDifficultyPayload else { return nil }
        let identityKey = pageResult.request.identityKey
        var descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.identityKey == identityKey
            }
        )
        descriptor.fetchLimit = 1
        guard let track = try modelContext.fetch(descriptor).first,
              pageResult.request.matchesGeneration(of: track),
              payload.queryKey == track.queryKey
        else {
            return nil
        }
        return try EstimatedKeywordDifficultyStore.upsert(payload, in: modelContext)
    }

    static func payload(
        request: RankingRefreshRequest,
        page: SearchRankingPage,
        requestedResultLimit: Int,
        rankingFetchedAt: Date,
        calculationID: UUID = UUID(),
        now: () -> Date = { Date() }
    ) -> EstimatedKeywordDifficultyPersistencePayload? {
        guard (1 ... EstimatedKeywordDifficultyStore.maximumRequestedResultCount)
            .contains(requestedResultLimit),
            page.resultCount <= requestedResultLimit,
            request.queryKey == KeywordQuery.makeQueryKey(
                term: request.term,
                storefront: request.storefront,
                platform: request.platform
            ),
            let fallback = fallbackProvenance(for: page)
        else {
            return nil
        }

        let estimation = KeywordDifficultyEstimator.estimate(
            keyword: request.term,
            searchResults: page.items
        )
        // Provenance records when calculation finished, not when it began.
        // Clamp non-monotonic injected clocks so the persistence invariant
        // still holds relative to the ranking evidence timestamp.
        let computedAt = max(now(), rankingFetchedAt)
        let fields = persistenceFields(for: estimation)

        return EstimatedKeywordDifficultyPersistencePayload(
            queryKey: request.queryKey,
            calculationID: calculationID,
            keyword: request.term,
            storefront: request.storefront,
            platform: request.platform,
            result: fields.result,
            algorithmIdentifier: fields.algorithmIdentifier,
            algorithmVersion: fields.algorithmVersion,
            requestedResultLimit: requestedResultLimit,
            providerResultCount: page.resultCount,
            evidence: evidence(fields.evidence),
            rankingSource: page.source,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: computedAt,
            fallback: fallback.value,
            notes: fields.notes
        )
    }

    private static func persistenceFields(
        for estimation: KeywordDifficultyEstimation
    ) -> (
        result: EstimatedKeywordDifficultyPersistenceResult,
        algorithmIdentifier: String,
        algorithmVersion: Int,
        evidence: KeywordDifficultyEvidence,
        notes: [String]
    ) {
        switch estimation {
        case .estimated(let estimate):
            return (
                .estimated(
                    score: estimate.score,
                    confidenceScore: estimate.confidenceScore,
                    confidence: confidence(estimate.confidence)
                ),
                estimate.algorithmIdentifier,
                estimate.algorithmVersion,
                estimate.evidence,
                estimate.notes
            )
        case .unavailable(let unavailable):
            return (
                .unavailable(reason: unavailableReason(unavailable.reason)),
                unavailable.algorithmIdentifier,
                unavailable.algorithmVersion,
                unavailable.evidence,
                unavailable.notes
            )
        }
    }

    private static func evidence(
        _ evidence: KeywordDifficultyEvidence
    ) -> EstimatedKeywordDifficultyEvidence {
        EstimatedKeywordDifficultyEvidence(
            consideredResultCount: evidence.consideredResultCount,
            ratedResultCount: evidence.ratedResultCount,
            weightedRatingCoveragePercentage: evidence.weightedRatingCoveragePercentage,
            maximumRatingCount: evidence.maximumRatingCount,
            medianRatingCount: evidence.medianRatingCount,
            ratingAuthorityScore: evidence.ratingAuthorityScore,
            metadataSaturationScore: evidence.metadataSaturationScore,
            resultEvidence: evidence.resultEvidence.map { result in
                EstimatedKeywordDifficultyResultEvidence(
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
        )
    }

    private static func confidence(
        _ confidence: EstimatedKeywordDifficulty.Confidence
    ) -> EstimatedKeywordDifficultyConfidence {
        switch confidence {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    private static func unavailableReason(
        _ reason: KeywordDifficultyUnavailable.Reason
    ) -> EstimatedKeywordDifficultyUnavailableReason {
        switch reason {
        case .emptyKeyword: .emptyKeyword
        case .insufficientResults: .insufficientResults
        case .insufficientRatingEvidence: .insufficientRatingEvidence
        }
    }

    private struct OptionalFallback {
        let value: EstimatedKeywordDifficultyFallbackProvenance?
    }

    /// A wrapper distinguishes valid primary provenance (`nil`) from invalid
    /// fallback provenance (outer `nil`).
    private static func fallbackProvenance(
        for page: SearchRankingPage
    ) -> OptionalFallback? {
        switch page.source {
        case .appStoreWeb:
            guard page.fallbackContext == nil else { return nil }
            return OptionalFallback(value: nil)
        case .iTunesFallback:
            guard let context = page.fallbackContext else {
                return OptionalFallback(value: nil)
            }
            guard context.provider == .appStoreWeb else { return nil }
            return OptionalFallback(value: EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: fallbackCategory(context.category),
                transportCode: transportCode(context.category),
                httpStatus: httpStatus(context.category),
                responseFailure: responseFailure(context.category)
            ))
        }
    }

    private static func fallbackCategory(
        _ category: SearchRankingFailureCategory
    ) -> EstimatedKeywordDifficultyFallbackCategory {
        switch category {
        case .transport: .transport
        case .httpStatus: .httpStatus
        case .response: .response
        case .provider: .provider
        case .other: .other
        }
    }

    private static func transportCode(_ category: SearchRankingFailureCategory) -> Int? {
        guard case .transport(let code) = category else { return nil }
        return code
    }

    private static func httpStatus(_ category: SearchRankingFailureCategory) -> Int? {
        guard case .httpStatus(let status) = category else { return nil }
        return status
    }

    private static func responseFailure(
        _ category: SearchRankingFailureCategory
    ) -> EstimatedKeywordDifficultyFallbackResponseFailure? {
        guard case .response(let failure) = category else { return nil }
        switch failure {
        case .serializedServerDataMissing:
            return .serializedServerDataMissing
        case .decodingFailed:
            return .decodingFailed
        case .nonHTTPResponse:
            return .nonHTTPResponse
        case .requestIntentMissing:
            return .requestIntentMissing
        case .requestIntentAmbiguous:
            return .requestIntentAmbiguous
        case .pageShapeChanged:
            return .pageShapeChanged
        case .authoritativeShelfMissing:
            return .authoritativeShelfMissing
        case .authoritativeShelfAmbiguous:
            return .authoritativeShelfAmbiguous
        case .malformedSearchResult:
            return .malformedSearchResult
        case .truncatedResults:
            return .truncatedResults
        case .lookupHydrationIncomplete:
            return .lookupHydrationIncomplete
        }
    }
}
