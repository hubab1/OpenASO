import Foundation

enum KeywordMetricsSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleAdsPopularity
    case rankingDifficulty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleAdsPopularity:
            return "Apple Ads"
        case .rankingDifficulty:
            return "Ranking difficulty"
        }
    }
}
