import Foundation

extension EstimatedKeywordDifficultyConfidence {
    var displayName: String {
        switch self {
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        }
    }
}

extension EstimatedKeywordDifficultyUnavailableReason {
    var displayName: String {
        switch self {
        case .emptyKeyword:
            "Empty keyword"
        case .insufficientResults:
            "Not enough ranking results"
        case .insufficientRatingEvidence:
            "Not enough rating evidence"
        }
    }

    var guidance: String {
        switch self {
        case .emptyKeyword:
            "Enter a keyword before requesting a ranking refresh."
        case .insufficientResults:
            "Refresh again when the App Store returns at least three unique ranking results."
        case .insufficientRatingEvidence:
            "The sampled ranking needs rating counts for at least three results before OpenASO can estimate difficulty."
        }
    }
}

extension EstimatedKeywordDifficultySource {
    var displayName: String {
        switch self {
        case .topResultsHeuristic:
            "Top-results heuristic"
        }
    }
}

extension EstimatedKeywordDifficultyFallbackCategory {
    var displayName: String {
        switch self {
        case .transport:
            "Connection"
        case .httpStatus:
            "HTTP response"
        case .response:
            "Response validation"
        case .provider:
            "Provider"
        case .other:
            "Other"
        }
    }
}

extension EstimatedKeywordDifficultyFallbackResponseFailure {
    var displayName: String {
        switch self {
        case .serializedServerDataMissing:
            "Server data was missing"
        case .decodingFailed:
            "Response could not be decoded"
        case .nonHTTPResponse:
            "Response was not HTTP"
        case .requestIntentMissing:
            "Search request could not be identified"
        case .requestIntentAmbiguous:
            "Search request was ambiguous"
        case .pageShapeChanged:
            "Search page format changed"
        case .authoritativeShelfMissing:
            "Primary result shelf was missing"
        case .authoritativeShelfAmbiguous:
            "Primary result shelf was ambiguous"
        case .malformedSearchResult:
            "A search result was malformed"
        case .truncatedResults:
            "Search results were incomplete"
        }
    }
}

extension EstimatedKeywordDifficultySnapshot {
    var fallbackProvider: RankingSource? {
        fallbackProviderRaw.flatMap(RankingSource.init(rawValue:))
    }
}
