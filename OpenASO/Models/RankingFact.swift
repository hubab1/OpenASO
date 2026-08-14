import Foundation
import SwiftData

extension OpenASOSchemaV6 {
@Model
final class RankingFact {
    #Index<RankingFact>(
        [\.observation],
        [\.observation, \.position],
        [\.appStoreID, \.observation]
    )

    var position: Int
    var appStoreID: Int64
    var observation: RankingCrawlRecord
    var revision: RankingAppRevision

    init(
        position: Int,
        appStoreID: Int64,
        revision: RankingAppRevision,
        observation: RankingCrawlRecord
    ) {
        self.position = position
        self.appStoreID = appStoreID
        self.revision = revision
        self.observation = observation
    }

    static func makeItemKey(observationKey: String, appStoreID: Int64) -> String {
        [observationKey, String(appStoreID)].joined(separator: "::")
    }

    var itemKey: String {
        Self.makeItemKey(observationKey: observation.observationKey, appStoreID: appStoreID)
    }

    var bundleID: String? { revision.bundleID }
    var name: String { revision.name }
    var subtitle: String? { revision.subtitle }
    var sellerName: String? { revision.sellerName }
    var crawlKey: String { observation.observationKey }
    var queryKey: String { observation.queryKey }
    var storefront: String { observation.storefront }
    var platformRaw: String { observation.platformRaw }
    var observedAt: Date { observation.observedAt }
    var platform: AppPlatform { observation.platform }
}
}

typealias RankingFact = OpenASOSchemaV6.RankingFact
