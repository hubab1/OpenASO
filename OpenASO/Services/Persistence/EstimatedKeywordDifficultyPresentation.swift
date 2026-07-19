import Foundation

/// Lightweight estimated-difficulty data for list and filter surfaces.
///
/// The persisted result evidence is deliberately omitted. Callers that need to
/// explain a calculation should load `EstimatedKeywordDifficultySnapshot`
/// explicitly instead of hydrating every row's evidence.
struct EstimatedKeywordDifficultySummary: Equatable, Sendable {
    let queryKey: String
    let calculationID: UUID
    let keyword: String
    let storefront: String
    let platformRaw: String
    let stateRaw: String
    let score: Int?
    let confidenceScore: Int?
    let confidenceRaw: String?
    let unavailableReasonRaw: String?
    let estimationSourceRaw: String
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let requestedResultLimit: Int
    let providerResultCount: Int
    let consideredResultCount: Int
    let ratedResultCount: Int
    let weightedRatingCoveragePercentage: Int
    let maximumRatingCount: Int?
    let medianRatingCount: Int?
    let ratingAuthorityScore: Int?
    let metadataSaturationScore: Int?
    let exactTitlePhraseMatchCount: Int
    let exactSubtitlePhraseMatchCount: Int
    let rankingSourceRaw: String
    let rankingFetchedAt: Date
    let computedAt: Date
    let fallbackProviderRaw: String?
    let fallbackCategoryRaw: String?
    let fallbackTransportCode: Int?
    let fallbackHTTPStatus: Int?
    let fallbackResponseFailureRaw: String?
    let notes: [String]

    var platform: AppPlatform? {
        AppPlatform(rawValue: platformRaw)
    }

    var state: EstimatedKeywordDifficultyState? {
        EstimatedKeywordDifficultyState(rawValue: stateRaw)
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

    var fallbackProvider: RankingSource? {
        fallbackProviderRaw.flatMap(RankingSource.init(rawValue:))
    }

    var fallbackCategory: EstimatedKeywordDifficultyFallbackCategory? {
        fallbackCategoryRaw.flatMap(EstimatedKeywordDifficultyFallbackCategory.init(rawValue:))
    }

    var fallbackResponseFailure: EstimatedKeywordDifficultyFallbackResponseFailure? {
        fallbackResponseFailureRaw.flatMap(
            EstimatedKeywordDifficultyFallbackResponseFailure.init(rawValue:)
        )
    }

    func isStale(asOf date: Date) -> Bool {
        EstimatedKeywordDifficultyFreshness.isStale(
            rankingFetchedAt: rankingFetchedAt,
            asOf: date
        )
    }
}

/// One freshness definition shared by row, detail, export, and MCP surfaces.
/// Freshness follows the ranking evidence rather than a later recomputation.
enum EstimatedKeywordDifficultyFreshness {
    static let maximumAge: TimeInterval = 24 * 60 * 60

    static func isStale(rankingFetchedAt: Date, asOf date: Date) -> Bool {
        date.timeIntervalSince(rankingFetchedAt) >= maximumAge
    }
}

/// A presentation-safe interpretation that keeps missing and persisted
/// unavailable values distinct while treating staleness as an orthogonal flag.
struct EstimatedKeywordDifficultyPresentation: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case missing
        case estimated(
            score: Int,
            confidenceScore: Int,
            confidence: EstimatedKeywordDifficultyConfidence
        )
        case unavailable(reason: EstimatedKeywordDifficultyUnavailableReason)
        case unsupported
    }

    let value: Value
    let isStale: Bool
    let rankingFetchedAt: Date?

    init(summary: EstimatedKeywordDifficultySummary?, asOf date: Date) {
        guard let summary else {
            value = .missing
            isStale = false
            rankingFetchedAt = nil
            return
        }

        rankingFetchedAt = summary.rankingFetchedAt
        isStale = summary.isStale(asOf: date)
        switch summary.state {
        case .estimated:
            if let score = summary.score,
               let confidenceScore = summary.confidenceScore,
               let confidence = summary.confidence {
                value = .estimated(
                    score: score,
                    confidenceScore: confidenceScore,
                    confidence: confidence
                )
            } else {
                value = .unsupported
            }
        case .unavailable:
            if let reason = summary.unavailableReason {
                value = .unavailable(reason: reason)
            } else {
                value = .unsupported
            }
        case nil:
            value = .unsupported
        }
    }
}

extension EstimatedKeywordDifficultySnapshot {
    func isStale(asOf date: Date) -> Bool {
        EstimatedKeywordDifficultyFreshness.isStale(
            rankingFetchedAt: rankingFetchedAt,
            asOf: date
        )
    }
}
