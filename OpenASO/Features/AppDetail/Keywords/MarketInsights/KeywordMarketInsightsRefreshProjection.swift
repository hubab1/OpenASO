enum KeywordMarketInsightsRefreshProjection {
    enum Event: Equatable, Sendable {
        case progress
        case completed(
            appStoreID: Int64,
            refreshesRankings: Bool,
            keywordCount: Int
        )
    }

    static func tokenIncrement(
        for event: Event,
        viewedAppStoreID: Int64
    ) -> Int {
        switch event {
        case .progress:
            0
        case .completed(let appStoreID, let refreshesRankings, let keywordCount):
            appStoreID == viewedAppStoreID
                && refreshesRankings
                && keywordCount > 0
                ? 1
                : 0
        }
    }
}
