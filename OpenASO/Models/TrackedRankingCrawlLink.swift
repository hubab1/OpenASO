import Foundation
import SwiftData

extension OpenASOSchemaV6 {
@Model
final class TrackedRankingCrawlLink {
    #Index<TrackedRankingCrawlLink>([\.crawl])

    @Attribute(.unique) var snapshotKey: String
    var crawl: RankingCrawlRecord

    init(snapshotKey: String, crawl: RankingCrawlRecord) {
        self.snapshotKey = snapshotKey
        self.crawl = crawl
    }
}
}

typealias TrackedRankingCrawlLink = OpenASOSchemaV6.TrackedRankingCrawlLink
