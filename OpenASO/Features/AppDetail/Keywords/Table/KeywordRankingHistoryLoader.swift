import Foundation
import SwiftData

enum KeywordRankingHistoryLoader {
    static func load(
        queryKey: String,
        appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> [KeywordRankingCrawlSummary] {
        let targetQueryKey = queryKey
        let targetAppStoreID = appStoreID
        let crawlDescriptor = FetchDescriptor<RankingCrawlRecord>(
            predicate: #Predicate { crawl in
                crawl.queryKey == targetQueryKey
            },
            sortBy: [
                SortDescriptor(\RankingCrawlRecord.observedAt, order: .forward),
                SortDescriptor(\RankingCrawlRecord.observationKey, order: .forward)
            ]
        )
        let crawls = try modelContext.fetch(crawlDescriptor)
            .filter { !$0.isTrackedRecovery }

        guard !crawls.isEmpty else {
            return []
        }

        let rankingDescriptor = FetchDescriptor<RankingFact>(
            predicate: #Predicate { ranking in
                ranking.observation.queryKey == targetQueryKey
                    && ranking.appStoreID == targetAppStoreID
            }
        )
        let rankings = try modelContext.fetch(rankingDescriptor)
        var rankByCrawlKey: [String: Int] = [:]
        rankByCrawlKey.reserveCapacity(rankings.count)

        for ranking in rankings {
            rankByCrawlKey[ranking.crawlKey] = ranking.position
        }

        return crawls.map { crawl in
            KeywordRankingCrawlSummary(
                crawl: crawl,
                rank: rankByCrawlKey[crawl.observationKey]
            )
        }
    }
}
