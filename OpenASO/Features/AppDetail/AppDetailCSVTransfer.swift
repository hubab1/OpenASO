import Foundation
import SwiftData

struct AppDetailRatingsExportData: Sendable {
    let latestRatings: [AppDetailRatingLatestValue]
    let ratingSnapshots: [AppDetailRatingSnapshotValue]
}

struct AppDetailRatingLatestValue: Sendable {
    let appStoreID: Int64
    let storefront: String
    let ratingCount: Int?
    let averageRating: Double?
    let oneStarRatingCount: Int?
    let twoStarRatingCount: Int?
    let threeStarRatingCount: Int?
    let fourStarRatingCount: Int?
    let fiveStarRatingCount: Int?
    let ratingDate: String
    let observedAt: Date
    let sourceRaw: String

    init(_ latest: LatestAppRating) {
        self.appStoreID = latest.appStoreID
        self.storefront = latest.storefront
        self.ratingCount = latest.ratingCount
        self.averageRating = latest.averageRating
        self.oneStarRatingCount = latest.oneStarRatingCount
        self.twoStarRatingCount = latest.twoStarRatingCount
        self.threeStarRatingCount = latest.threeStarRatingCount
        self.fourStarRatingCount = latest.fourStarRatingCount
        self.fiveStarRatingCount = latest.fiveStarRatingCount
        self.ratingDate = latest.ratingDate
        self.observedAt = latest.observedAt
        self.sourceRaw = latest.sourceRaw
    }
}

struct AppDetailRatingSnapshotValue: Sendable {
    let appStoreID: Int64
    let storefront: String
    let ratingDate: String
    let ratingCount: Int?
    let averageRating: Double?
    let oneStarRatingCount: Int?
    let twoStarRatingCount: Int?
    let threeStarRatingCount: Int?
    let fourStarRatingCount: Int?
    let fiveStarRatingCount: Int?
    let observedAt: Date

    init(_ snapshot: AppDailyRating) {
        self.init(RatingHistoryRecord(snapshot))
    }

    init(_ snapshot: RatingHistoryRecord) {
        self.appStoreID = snapshot.appStoreID
        self.storefront = snapshot.storefront
        self.ratingDate = snapshot.ratingDate
        self.ratingCount = snapshot.ratingCount
        self.averageRating = snapshot.averageRating
        self.oneStarRatingCount = snapshot.oneStarRatingCount
        self.twoStarRatingCount = snapshot.twoStarRatingCount
        self.threeStarRatingCount = snapshot.threeStarRatingCount
        self.fourStarRatingCount = snapshot.fourStarRatingCount
        self.fiveStarRatingCount = snapshot.fiveStarRatingCount
        self.observedAt = snapshot.observedAt
    }
}

@MainActor
struct AppDetailRatingsCSVExporter {
    static func makeDocument(
        appStoreID: Int64,
        appName: String,
        selectedStorefrontFilter: StorefrontFilter,
        searchText: String,
        backgroundModelStore: BackgroundModelStore?,
        storefrontCatalog: StorefrontCatalog
    ) async throws -> CSVDocument {
        let rows = try await ratingsExportRows(
            appStoreID: appStoreID,
            appName: appName,
            selectedStorefrontFilter: selectedStorefrontFilter,
            searchText: searchText,
            backgroundModelStore: backgroundModelStore,
            storefrontCatalog: storefrontCatalog
        )
        return CSVDocument(text: RatingsCSVFormat.encode(rows: rows))
    }

    private static func ratingsExportRows(
        appStoreID: Int64,
        appName: String,
        selectedStorefrontFilter: StorefrontFilter,
        searchText: String,
        backgroundModelStore: BackgroundModelStore?,
        storefrontCatalog: StorefrontCatalog
    ) async throws -> [RatingsCSVRow] {
        guard let backgroundModelStore else {
            throw OpenASOError.providerUnavailable("Ratings export is unavailable until the model store is ready.")
        }

        let ratingsData = try await backgroundModelStore.read { modelContext in
            try fetchRatingsExportData(appStoreID: appStoreID, in: modelContext)
        }
        let storefrontDefinitions = try storefrontCatalog.bundledStorefronts().map {
            StorefrontDefinition(
                code: $0.code.lowercased(),
                name: $0.name,
                flagEmoji: $0.flagEmoji,
                title: "\($0.flagEmoji) \($0.name)"
            )
        }
        let storefrontLookup = Dictionary(uniqueKeysWithValues: storefrontDefinitions.map { ($0.code, $0) })
        let selectedDefinitions = selectedRatingStorefrontDefinitions(
            selectedStorefrontFilter: selectedStorefrontFilter,
            from: storefrontDefinitions,
            storefrontLookup: storefrontLookup
        )
        let latestByStorefront = ratingsData.latestRatings.reduce(into: [String: AppDetailRatingLatestValue]()) { partial, latest in
            guard latest.appStoreID == appStoreID else { return }
            partial[latest.storefront] = latest
        }
        let previousSnapshotsByStorefront = previousRatingSnapshotsByStorefront(
            appStoreID: appStoreID,
            latestByStorefront: latestByStorefront,
            ratingSnapshots: ratingsData.ratingSnapshots
        )
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return selectedDefinitions
            .compactMap { definition -> RatingsCSVRow? in
                guard
                    let latest = latestByStorefront[definition.code],
                    latest.ratingCount != nil || latest.averageRating != nil
                else {
                    return nil
                }

                guard normalizedSearch.isEmpty
                    || definition.name.localizedCaseInsensitiveContains(normalizedSearch)
                    || definition.code.localizedCaseInsensitiveContains(normalizedSearch)
                else {
                    return nil
                }

                let previousSnapshot = previousSnapshotsByStorefront[definition.code]
                return RatingsCSVRow(
                    appName: appName,
                    appID: String(appStoreID),
                    storefront: definition.code,
                    store: definition.name,
                    ratingCount: latest.ratingCount.map(String.init) ?? "",
                    ratingCountChange: ratingCountChangeText(latest: latest, previousSnapshot: previousSnapshot),
                    averageRating: latest.averageRating.map(ratingDecimalString) ?? "",
                    averageRatingChange: averageRatingChangeText(latest: latest, previousSnapshot: previousSnapshot),
                    oneStarRatingCount: latest.oneStarRatingCount.map(String.init) ?? "",
                    oneStarRatingCountChange: starRatingCountChangeText(current: latest.oneStarRatingCount, previous: previousSnapshot?.oneStarRatingCount),
                    twoStarRatingCount: latest.twoStarRatingCount.map(String.init) ?? "",
                    twoStarRatingCountChange: starRatingCountChangeText(current: latest.twoStarRatingCount, previous: previousSnapshot?.twoStarRatingCount),
                    threeStarRatingCount: latest.threeStarRatingCount.map(String.init) ?? "",
                    threeStarRatingCountChange: starRatingCountChangeText(current: latest.threeStarRatingCount, previous: previousSnapshot?.threeStarRatingCount),
                    fourStarRatingCount: latest.fourStarRatingCount.map(String.init) ?? "",
                    fourStarRatingCountChange: starRatingCountChangeText(current: latest.fourStarRatingCount, previous: previousSnapshot?.fourStarRatingCount),
                    fiveStarRatingCount: latest.fiveStarRatingCount.map(String.init) ?? "",
                    fiveStarRatingCountChange: starRatingCountChangeText(current: latest.fiveStarRatingCount, previous: previousSnapshot?.fiveStarRatingCount),
                    ratingDate: latest.ratingDate,
                    observedAt: RatingsCSVFormat.string(from: latest.observedAt),
                    source: latest.sourceRaw
                )
            }
            .sorted {
                let leftCount = Int($0.ratingCount) ?? 0
                let rightCount = Int($1.ratingCount) ?? 0
                if leftCount == rightCount {
                    return $0.store.localizedCaseInsensitiveCompare($1.store) == .orderedAscending
                }
                return leftCount > rightCount
            }
    }

    nonisolated private static func fetchRatingsExportData(
        appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> AppDetailRatingsExportData {
        let targetAppStoreID = appStoreID
        let latestDescriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                latest.appStoreID == targetAppStoreID
            },
            sortBy: [SortDescriptor(\.storefront, order: .forward)]
        )
        let snapshots = try RatingHistoryStore.recent(appStoreIDs: [appStoreID], limitPerApp: 1_000, in: modelContext)

        return AppDetailRatingsExportData(
            latestRatings: try modelContext.fetch(latestDescriptor).map(AppDetailRatingLatestValue.init),
            ratingSnapshots: snapshots.map(AppDetailRatingSnapshotValue.init)
        )
    }

    private static func selectedRatingStorefrontDefinitions(
        selectedStorefrontFilter: StorefrontFilter,
        from storefrontDefinitions: [StorefrontDefinition],
        storefrontLookup: [String: StorefrontDefinition]
    ) -> [StorefrontDefinition] {
        switch selectedStorefrontFilter {
        case .all:
            return storefrontDefinitions
        case .storefront(let code, let title):
            let normalizedCode = code.lowercased()
            return [
                storefrontLookup[normalizedCode] ?? StorefrontDefinition(
                    code: normalizedCode,
                    name: StorefrontFilter.storefront(code: code, title: title).shortTitle,
                    flagEmoji: StorefrontFilter.storefront(code: code, title: title).icon,
                    title: title
                )
            ]
        }
    }

    private static func previousRatingSnapshotsByStorefront(
        appStoreID: Int64,
        latestByStorefront: [String: AppDetailRatingLatestValue],
        ratingSnapshots: [AppDetailRatingSnapshotValue]
    ) -> [String: AppDetailRatingSnapshotValue] {
        Dictionary(uniqueKeysWithValues: latestByStorefront.compactMap { storefront, latest in
            let previousSnapshot = ratingSnapshots
                .filter { snapshot in
                    snapshot.appStoreID == appStoreID
                        && snapshot.storefront == storefront
                        && (snapshot.ratingDate != latest.ratingDate || snapshot.observedAt < latest.observedAt)
                }
                .sorted {
                    if $0.ratingDate == $1.ratingDate {
                        return $0.observedAt > $1.observedAt
                    }
                    return $0.ratingDate > $1.ratingDate
                }
                .first

            guard let previousSnapshot else { return nil }
            return (storefront, previousSnapshot)
        })
    }

    private static func ratingCountChangeText(
        latest: AppDetailRatingLatestValue,
        previousSnapshot: AppDetailRatingSnapshotValue?
    ) -> String {
        guard
            let latestCount = latest.ratingCount,
            let previousCount = previousSnapshot?.ratingCount
        else {
            return ""
        }

        return String(latestCount - previousCount)
    }

    private static func averageRatingChangeText(
        latest: AppDetailRatingLatestValue,
        previousSnapshot: AppDetailRatingSnapshotValue?
    ) -> String {
        guard
            let latestRating = latest.averageRating,
            let previousRating = previousSnapshot?.averageRating
        else {
            return ""
        }

        return ratingDecimalString(latestRating - previousRating)
    }

    private static func starRatingCountChangeText(current: Int?, previous: Int?) -> String {
        guard let current, let previous else { return "" }
        let delta = current - previous
        guard delta != 0 else { return "0" }
        return delta > 0 ? "+\(delta)" : String(delta)
    }

    private static func ratingDecimalString(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}
