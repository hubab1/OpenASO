import Foundation
import SwiftData

enum EstimatedKeywordDifficultyState: String, Codable, CaseIterable, Sendable {
    case estimated
    case unavailable
}

enum EstimatedKeywordDifficultyConfidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

enum EstimatedKeywordDifficultyUnavailableReason: String, Codable, CaseIterable, Sendable {
    case emptyKeyword
    case insufficientResults
    case insufficientRatingEvidence
}

enum EstimatedKeywordDifficultySource: String, Codable, CaseIterable, Sendable {
    /// A local heuristic derived from the selected top App Store ranking results.
    case topResultsHeuristic
}

/// One independently sourced estimated-difficulty calculation revision.
///
/// This model deliberately does not reuse `KeywordDailyMetric.difficultyScore`:
/// released stores may contain an ambiguous imported value there without the
/// source evidence needed to call it this heuristic. Multiple revisions may
/// temporarily coexist after concurrent context/process saves; readers choose
/// the deterministic newest revision and later writes compact visible losers.
@Model
final class EstimatedKeywordDifficultyMetric {
    #Index<EstimatedKeywordDifficultyMetric>(
        [\.queryKey],
        [\.rankingSourceRaw],
        [\.rankingFetchedAt],
        [\.computedAt]
    )

    @Attribute(.unique) var metricKey: String
    var queryKey: String
    var calculationID: UUID
    var keyword: String
    var storefront: String
    var platformRaw: String

    var stateRaw: String
    var score: Int?
    var confidenceScore: Int?
    var confidenceRaw: String?
    var unavailableReasonRaw: String?

    var estimationSourceRaw: String
    var algorithmIdentifier: String
    var algorithmVersion: Int
    var requestedResultLimit: Int
    var providerResultCount: Int

    var consideredResultCount: Int
    var ratedResultCount: Int
    var weightedRatingCoveragePercentage: Int
    var maximumRatingCount: Int?
    var medianRatingCount: Int?
    var ratingAuthorityScore: Int?
    var metadataSaturationScore: Int?
    var exactTitlePhraseMatchCount: Int
    var exactSubtitlePhraseMatchCount: Int

    var rankingSourceRaw: String
    var rankingFetchedAt: Date
    var computedAt: Date

    var fallbackProviderRaw: String?
    var fallbackCategoryRaw: String?
    var fallbackTransportCode: Int?
    var fallbackHTTPStatus: Int?
    var fallbackResponseFailureRaw: String?

    var notes: [String]

    init(
        queryKey: String,
        calculationID: UUID,
        keyword: String,
        storefront: String,
        platformRaw: String,
        stateRaw: String,
        score: Int?,
        confidenceScore: Int?,
        confidenceRaw: String?,
        unavailableReasonRaw: String?,
        estimationSourceRaw: String,
        algorithmIdentifier: String,
        algorithmVersion: Int,
        requestedResultLimit: Int,
        providerResultCount: Int,
        consideredResultCount: Int,
        ratedResultCount: Int,
        weightedRatingCoveragePercentage: Int,
        maximumRatingCount: Int?,
        medianRatingCount: Int?,
        ratingAuthorityScore: Int?,
        metadataSaturationScore: Int?,
        exactTitlePhraseMatchCount: Int,
        exactSubtitlePhraseMatchCount: Int,
        rankingSourceRaw: String,
        rankingFetchedAt: Date,
        computedAt: Date,
        fallbackProviderRaw: String?,
        fallbackCategoryRaw: String?,
        fallbackTransportCode: Int?,
        fallbackHTTPStatus: Int?,
        fallbackResponseFailureRaw: String?,
        notes: [String]
    ) {
        self.metricKey = Self.makeMetricKey(
            queryKey: queryKey,
            calculationID: calculationID
        )
        self.queryKey = queryKey
        self.calculationID = calculationID
        self.keyword = keyword
        self.storefront = storefront
        self.platformRaw = platformRaw
        self.stateRaw = stateRaw
        self.score = score
        self.confidenceScore = confidenceScore
        self.confidenceRaw = confidenceRaw
        self.unavailableReasonRaw = unavailableReasonRaw
        self.estimationSourceRaw = estimationSourceRaw
        self.algorithmIdentifier = algorithmIdentifier
        self.algorithmVersion = algorithmVersion
        self.requestedResultLimit = requestedResultLimit
        self.providerResultCount = providerResultCount
        self.consideredResultCount = consideredResultCount
        self.ratedResultCount = ratedResultCount
        self.weightedRatingCoveragePercentage = weightedRatingCoveragePercentage
        self.maximumRatingCount = maximumRatingCount
        self.medianRatingCount = medianRatingCount
        self.ratingAuthorityScore = ratingAuthorityScore
        self.metadataSaturationScore = metadataSaturationScore
        self.exactTitlePhraseMatchCount = exactTitlePhraseMatchCount
        self.exactSubtitlePhraseMatchCount = exactSubtitlePhraseMatchCount
        self.rankingSourceRaw = rankingSourceRaw
        self.rankingFetchedAt = rankingFetchedAt
        self.computedAt = computedAt
        self.fallbackProviderRaw = fallbackProviderRaw
        self.fallbackCategoryRaw = fallbackCategoryRaw
        self.fallbackTransportCode = fallbackTransportCode
        self.fallbackHTTPStatus = fallbackHTTPStatus
        self.fallbackResponseFailureRaw = fallbackResponseFailureRaw
        self.notes = notes
    }

    static func makeMetricKey(queryKey: String, calculationID: UUID) -> String {
        [
            queryKey,
            "estimated-difficulty",
            calculationID.uuidString.lowercased()
        ].joined(separator: "::")
    }

    var state: EstimatedKeywordDifficultyState? {
        EstimatedKeywordDifficultyState(rawValue: stateRaw)
    }

    var platform: AppPlatform? {
        AppPlatform(rawValue: platformRaw)
    }

    var confidence: EstimatedKeywordDifficultyConfidence? {
        confidenceRaw.flatMap(EstimatedKeywordDifficultyConfidence.init(rawValue:))
    }

    var unavailableReason: EstimatedKeywordDifficultyUnavailableReason? {
        unavailableReasonRaw.flatMap(EstimatedKeywordDifficultyUnavailableReason.init(rawValue:))
    }

    var estimationSource: EstimatedKeywordDifficultySource? {
        EstimatedKeywordDifficultySource(rawValue: estimationSourceRaw)
    }

    var rankingSource: RankingSource? {
        RankingSource(rawValue: rankingSourceRaw)
    }
}
