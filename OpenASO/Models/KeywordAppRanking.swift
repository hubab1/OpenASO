import Foundation
import SwiftData

extension OpenASOSchemaV1 {
@Model
final class KeywordAppRanking {
    #Index<KeywordAppRanking>(
        [\.crawlKey],
        [\.queryKey],
        [\.queryKey, \.appStoreID],
        [\.queryKey, \.appStoreID, \.observedAt],
        [\.queryKey, \.position],
        [\.appStoreID, \.queryKey, \.observedAt]
    )

    @Attribute(.unique) var itemKey: String
    var position: Int
    var appStoreID: Int64
    var bundleID: String?
    var name: String
    var subtitle: String?
    var sellerName: String?
    var crawlKey: String
    var queryKey: String
    var storefront: String
    var platformRaw: String
    var observedAt: Date

    var observation: KeywordRankingCrawl

    init(
        position: Int,
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String? = nil,
        sellerName: String?,
        observation: KeywordRankingCrawl
    ) {
        self.position = position
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.crawlKey = observation.observationKey
        self.queryKey = observation.queryKey
        self.storefront = observation.storefront
        self.platformRaw = observation.platformRaw
        self.observedAt = observation.observedAt
        self.itemKey = Self.makeItemKey(observationKey: observation.observationKey, appStoreID: appStoreID)
        self.observation = observation
    }

    static func makeItemKey(observationKey: String, appStoreID: Int64) -> String {
        [observationKey, String(appStoreID)].joined(separator: "::")
    }

    var platform: AppPlatform {
        get { AppPlatform(rawValue: platformRaw) ?? .iphone }
        set { platformRaw = newValue.rawValue }
    }
}
}

typealias KeywordAppRanking = OpenASOSchemaV1.KeywordAppRanking
typealias LegacyKeywordAppRanking = OpenASOSchemaV1.KeywordAppRanking
