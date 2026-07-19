import Testing
@testable import OpenASO

struct KeywordMarketInsightsRefreshProjectionTests {
    @Test
    func intermediateProgressDoesNotReloadAndTerminalCompletionDoesOnce() {
        let events: [KeywordMarketInsightsRefreshProjection.Event] = [
            .progress,
            .progress,
            .progress,
            .completed(
                appStoreID: 42,
                refreshesRankings: true,
                keywordCount: 3
            )
        ]

        let reloadCount = events.reduce(0) { count, event in
            count + KeywordMarketInsightsRefreshProjection.tokenIncrement(
                for: event,
                viewedAppStoreID: 42
            )
        }

        #expect(reloadCount == 1)
    }

    @Test
    func unrelatedOrNonRankingCompletionDoesNotReload() {
        let events: [KeywordMarketInsightsRefreshProjection.Event] = [
            .completed(
                appStoreID: 7,
                refreshesRankings: true,
                keywordCount: 3
            ),
            .completed(
                appStoreID: 42,
                refreshesRankings: false,
                keywordCount: 3
            ),
            .completed(
                appStoreID: 42,
                refreshesRankings: true,
                keywordCount: 0
            )
        ]

        #expect(events.allSatisfy {
            KeywordMarketInsightsRefreshProjection.tokenIncrement(
                for: $0,
                viewedAppStoreID: 42
            ) == 0
        })
    }
}
