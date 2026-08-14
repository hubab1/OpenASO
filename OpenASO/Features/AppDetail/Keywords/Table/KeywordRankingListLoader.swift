import Foundation
import SwiftData

enum KeywordRankingListLoader {
    static let ratingSnapshotLimit = 31

    struct LoadID: Hashable, Sendable {
        let crawlKey: String?
        let storefrontCode: String
        let includesScreenshots: Bool
    }

    struct Snapshot: Sendable {
        let items: [KeywordRankingListItem]
        let rows: [KeywordRankingCatalogRow]
        let storefrontLanguageCode: String?
        let storefrontFlagEmoji: String?
        let includesScreenshots: Bool
    }

    static func load(
        crawlKey: String?,
        fallbackItems: [KeywordRankingListItem],
        storefrontCode: String,
        includesScreenshots: Bool,
        in modelContext: ModelContext,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Snapshot {
        try checkCancellation()
        let items = try rankingItems(
            crawlKey: crawlKey,
            fallbackItems: fallbackItems,
            in: modelContext,
            checkCancellation: checkCancellation
        )
        try checkCancellation()

        guard !items.isEmpty else {
            return Snapshot(
                items: [],
                rows: [],
                storefrontLanguageCode: nil,
                storefrontFlagEmoji: nil,
                includesScreenshots: includesScreenshots
            )
        }

        let normalizedStorefront = normalized(storefrontCode)
        let appStoreIDs = items.map(\.appStoreID)
        let appStoreIDSet = Set(appStoreIDs)
        let storefront = try storefrontDisplay(
            for: normalizedStorefront,
            in: modelContext,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        let storeAppsByID = try storeAppsByID(
            appStoreIDs: appStoreIDs,
            in: modelContext,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        let storefrontMetadataByID = try metadataByAppStoreID(
            storefront: normalizedStorefront,
            appStoreIDSet: appStoreIDSet,
            includesScreenshots: includesScreenshots,
            in: modelContext,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        let usMetadataByID: [Int64: AppStorefrontMetadataDisplayValue]
        if normalizedStorefront == "us" {
            usMetadataByID = storefrontMetadataByID
        } else {
            usMetadataByID = try metadataByAppStoreID(
                storefront: "us",
                appStoreIDSet: appStoreIDSet,
                includesScreenshots: includesScreenshots,
                in: modelContext,
                checkCancellation: checkCancellation
            )
        }
        try checkCancellation()
        let latestRatingsByID = try latestRatingsByID(
            storefront: normalizedStorefront,
            appStoreIDs: appStoreIDs,
            in: modelContext,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        let ratingSnapshotsByID = try ratingSnapshotsByID(
            storefront: normalizedStorefront,
            appStoreIDs: appStoreIDs,
            in: modelContext,
            checkCancellation: checkCancellation
        )
        try checkCancellation()

        let rows = items.map { item in
            KeywordRankingCatalogRow(
                item: item,
                storeApp: storeAppsByID[item.appStoreID],
                storefrontMetadata: storefrontMetadataByID[item.appStoreID],
                usMetadata: usMetadataByID[item.appStoreID],
                latestRating: latestRatingsByID[item.appStoreID],
                ratingSnapshots: ratingSnapshotsByID[item.appStoreID] ?? []
            )
        }
        try checkCancellation()

        return Snapshot(
            items: items,
            rows: rows,
            storefrontLanguageCode: storefront?.languageCode,
            storefrontFlagEmoji: storefront?.flagEmoji,
            includesScreenshots: includesScreenshots
        )
    }

    private static func rankingItems(
        crawlKey: String?,
        fallbackItems: [KeywordRankingListItem],
        in modelContext: ModelContext,
        checkCancellation: () throws -> Void
    ) throws -> [KeywordRankingListItem] {
        guard let crawlKey else {
            return fallbackItems
        }

        let targetCrawlKey = crawlKey
        let descriptor = FetchDescriptor<RankingFact>(
            predicate: #Predicate { ranking in
                ranking.observation.observationKey == targetCrawlKey
            },
            sortBy: [SortDescriptor(\RankingFact.position, order: .forward)]
        )

        let rankings = try modelContext.fetch(descriptor)
        try checkCancellation()
        return rankings
            .map(KeywordRankingAppSummary.init)
            .map(KeywordRankingListItem.init)
    }

    private static func storefrontDisplay(
        for storefront: String,
        in modelContext: ModelContext,
        checkCancellation: () throws -> Void
    ) throws -> StorefrontDisplayValue? {
        let targetStorefront = storefront
        let descriptor = FetchDescriptor<Storefront>(
            predicate: #Predicate { storefront in
                storefront.code == targetStorefront
            }
        )
        let storefronts = try modelContext.fetch(descriptor)
        try checkCancellation()
        return storefronts.first.map(StorefrontDisplayValue.init)
    }

    private static func storeAppsByID(
        appStoreIDs: [Int64],
        in modelContext: ModelContext,
        checkCancellation: () throws -> Void
    ) throws -> [Int64: StoreAppDisplayValue] {
        let descriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { app in
                appStoreIDs.contains(app.appStoreID)
            }
        )
        let storeApps = try modelContext.fetch(descriptor)
        try checkCancellation()
        return Dictionary(
            uniqueKeysWithValues: storeApps
                .map { ($0.appStoreID, StoreAppDisplayValue($0)) }
        )
    }

    private static func metadataByAppStoreID(
        storefront: String,
        appStoreIDSet: Set<Int64>,
        includesScreenshots: Bool,
        in modelContext: ModelContext,
        checkCancellation: () throws -> Void
    ) throws -> [Int64: AppStorefrontMetadataDisplayValue] {
        let targetStorefront = normalized(storefront)
        let descriptor = FetchDescriptor<AppStorefrontMetadata>(
            predicate: #Predicate { metadata in
                metadata.storefront == targetStorefront && appStoreIDSet.contains(metadata.appStoreID)
            },
            sortBy: [SortDescriptor(\.appStoreID, order: .forward)]
        )
        let metadataItems = try modelContext.fetch(descriptor)
        try checkCancellation()
        return Dictionary(
            uniqueKeysWithValues: metadataItems
                .map { metadata in
                    (
                        metadata.appStoreID,
                        AppStorefrontMetadataDisplayValue(
                            metadata,
                            includeScreenshots: includesScreenshots
                        )
                    )
                }
        )
    }

    private static func latestRatingsByID(
        storefront: String,
        appStoreIDs: [Int64],
        in modelContext: ModelContext,
        checkCancellation: () throws -> Void
    ) throws -> [Int64: RatingLatestDisplayValue] {
        let targetStorefront = storefront
        let descriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                latest.storefront == targetStorefront && appStoreIDs.contains(latest.appStoreID)
            },
            sortBy: [SortDescriptor(\.appStoreID, order: .forward)]
        )
        let ratings = try modelContext.fetch(descriptor)
        try checkCancellation()
        return Dictionary(
            uniqueKeysWithValues: ratings
                .map { ($0.appStoreID, RatingLatestDisplayValue($0)) }
        )
    }

    static func ratingSnapshotsByID(
        storefront: String,
        appStoreIDs: [Int64],
        in modelContext: ModelContext,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [Int64: [RatingSnapshotDisplayValue]] {
        let targetStorefront = storefront
        var snapshotsByID: [Int64: [RatingSnapshotDisplayValue]] = [:]
        let uniqueAppStoreIDs = Array(Set(appStoreIDs)).sorted()
        snapshotsByID.reserveCapacity(uniqueAppStoreIDs.count)

        guard !uniqueAppStoreIDs.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { snapshot in
                snapshot.storefront == targetStorefront
                    && uniqueAppStoreIDs.contains(snapshot.appStoreID)
                    && snapshot.ratingCount != nil
            },
            sortBy: [
                SortDescriptor(\.appStoreID, order: .forward),
                SortDescriptor(\.ratingDate, order: .reverse),
                SortDescriptor(\.observedAt, order: .reverse)
            ]
        )
        for (index, snapshot) in try modelContext.fetch(descriptor).enumerated() {
            if snapshotsByID[snapshot.appStoreID, default: []].count < ratingSnapshotLimit {
                snapshotsByID[snapshot.appStoreID, default: []].append(
                    RatingSnapshotDisplayValue(snapshot)
                )
            }
            if index.isMultiple(of: 256) {
                try checkCancellation()
            }
        }
        for appStoreID in snapshotsByID.keys {
            snapshotsByID[appStoreID]?.reverse()
        }

        return snapshotsByID
    }

    private static func normalized(_ storefrontCode: String) -> String {
        storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
