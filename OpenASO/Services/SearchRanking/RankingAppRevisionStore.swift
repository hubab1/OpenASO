import Foundation
import SwiftData

struct RankingAppRevisionPayload: Hashable, Sendable {
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let revisionKey: String

    init(_ item: SearchRankingItem) {
        self.init(
            appStoreID: item.appStoreID,
            bundleID: item.bundleID,
            name: item.name,
            subtitle: item.subtitle,
            sellerName: item.sellerName
        )
    }

    init(
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String?,
        sellerName: String?
    ) {
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.revisionKey = RankingAppRevision.makeRevisionKey(
            appStoreID: appStoreID,
            bundleID: bundleID,
            name: name,
            subtitle: subtitle,
            sellerName: sellerName
        )
    }
}

enum RankingAppRevisionStore {
    private static let fetchChunkSize = 250

    static func revisions(
        for payloads: some Sequence<RankingAppRevisionPayload>,
        in modelContext: ModelContext
    ) throws -> [String: RankingAppRevision] {
        let payloadsByKey = Dictionary(
            payloads.map { ($0.revisionKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        guard !payloadsByKey.isEmpty else { return [:] }

        var revisionsByKey: [String: RankingAppRevision] = [:]
        let revisionKeys = Array(payloadsByKey.keys)
        for chunkStart in stride(from: 0, to: revisionKeys.count, by: fetchChunkSize) {
            let chunkEnd = min(chunkStart + fetchChunkSize, revisionKeys.count)
            let chunk = Array(revisionKeys[chunkStart..<chunkEnd])
            let descriptor = FetchDescriptor<RankingAppRevision>(
                predicate: #Predicate { revision in
                    chunk.contains(revision.revisionKey)
                }
            )
            for revision in try modelContext.fetch(descriptor) {
                revisionsByKey[revision.revisionKey] = revision
            }
        }

        for (revisionKey, payload) in payloadsByKey {
            if let revision = revisionsByKey[revisionKey] {
                guard revision.matches(
                    appStoreID: payload.appStoreID,
                    bundleID: payload.bundleID,
                    name: payload.name,
                    subtitle: payload.subtitle,
                    sellerName: payload.sellerName
                ) else {
                    throw OpenASOError.providerUnavailable(
                        "A ranking app revision hash collision was detected."
                    )
                }
                continue
            }

            let revision = RankingAppRevision(
                appStoreID: payload.appStoreID,
                bundleID: payload.bundleID,
                name: payload.name,
                subtitle: payload.subtitle,
                sellerName: payload.sellerName
            )
            modelContext.insert(revision)
            revisionsByKey[revisionKey] = revision
        }
        return revisionsByKey
    }
}
