import CryptoKit
import Foundation
import SwiftData

extension OpenASOSchemaV6 {
@Model
final class RankingAppRevision {
    #Index<RankingAppRevision>([\.appStoreID])

    @Attribute(.unique) var revisionKey: String
    var appStoreID: Int64
    var bundleID: String?
    var name: String
    var subtitle: String?
    var sellerName: String?

    init(
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String?,
        sellerName: String?
    ) {
        self.revisionKey = Self.makeRevisionKey(
            appStoreID: appStoreID,
            bundleID: bundleID,
            name: name,
            subtitle: subtitle,
            sellerName: sellerName
        )
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
    }

    static func makeRevisionKey(
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String?,
        sellerName: String?
    ) -> String {
        let payload = [
            String(appStoreID),
            encoded(bundleID),
            encoded(name),
            encoded(subtitle),
            encoded(sellerName)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func matches(
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String?,
        sellerName: String?
    ) -> Bool {
        self.appStoreID == appStoreID
            && self.bundleID == bundleID
            && self.name == name
            && self.subtitle == subtitle
            && self.sellerName == sellerName
    }

    private static func encoded(_ value: String?) -> String {
        guard let value else { return "nil" }
        return "some:\(value.utf8.count):\(value)"
    }
}
}

typealias RankingAppRevision = OpenASOSchemaV6.RankingAppRevision
