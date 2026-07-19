import Foundation

struct EstimatedKeywordDifficultyRowPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case missing
        case estimated(
            score: Int,
            confidenceScore: Int,
            confidence: EstimatedKeywordDifficultyConfidence,
            isStale: Bool
        )
        case unavailable(
            reason: EstimatedKeywordDifficultyUnavailableReason,
            isStale: Bool
        )
        case unsupported(isStale: Bool)
    }

    let state: State

    init(summary: EstimatedKeywordDifficultySummary?, asOf date: Date) {
        let presentation = EstimatedKeywordDifficultyPresentation(
            summary: summary,
            asOf: date
        )

        switch presentation.value {
        case .missing:
            state = .missing
        case .estimated(let score, let confidenceScore, let confidence):
            state = .estimated(
                score: score,
                confidenceScore: confidenceScore,
                confidence: confidence,
                isStale: presentation.isStale
            )
        case .unavailable(let reason):
            state = .unavailable(
                reason: reason,
                isStale: presentation.isStale
            )
        case .unsupported:
            state = .unsupported(isStale: presentation.isStale)
        }
    }

    var accessibilityValue: String {
        switch state {
        case .missing:
            "Not estimated."
        case .estimated(let score, let confidenceScore, let confidence, false):
            "\(score) out of 100. \(confidence.displayName) confidence, \(confidenceScore) out of 100. Current."
        case .estimated(let score, let confidenceScore, let confidence, true):
            "\(score) out of 100. \(confidence.displayName) confidence, \(confidenceScore) out of 100. Stale."
        case .unavailable(let reason, let isStale):
            "Unavailable: \(reason.displayName)." + staleAccessibilitySuffix(isStale)
        case .unsupported(let isStale):
            "Unavailable because the stored estimate is not supported."
                + staleAccessibilitySuffix(isStale)
        }
    }

    private func staleAccessibilitySuffix(_ isStale: Bool) -> String {
        isStale ? " The ranking evidence is stale." : ""
    }
}
