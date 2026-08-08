import SwiftUI

struct RatingsDashboardData: Sendable {
    let latestRatings: [RatingLatestValue]
    let ratingSnapshots: [RatingSnapshotValue]
}

enum RatingsAppStoreConnectStatus: Equatable, Sendable {
    case notConnected
    case owned
    case publicOnly(String)
    case error(String)

    var usesAppStoreConnectReviews: Bool {
        if case .owned = self {
            return true
        }
        return false
    }
}

struct RatingLatestValue: Identifiable, Hashable, Sendable {
    let identityKey: String
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

    var id: String { identityKey }

    init(_ latest: LatestAppRating) {
        self.identityKey = latest.identityKey
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

struct RatingSnapshotValue: Identifiable, Hashable, Sendable {
    let identityKey: String
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

    var id: String { identityKey }

    init(_ snapshot: AppDailyRating) {
        self.identityKey = snapshot.identityKey
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

struct AppStoreReviewValue: Identifiable, Hashable, Sendable {
    let reviewKey: String
    let appStoreID: Int64
    let storefront: String
    let reviewID: String
    let reviewerName: String
    let title: String
    let content: String
    let rating: Int
    let reviewedAt: Date
    let version: String?
    let sourceRaw: String
    let ascReviewID: String?
    let developerResponseID: String?
    let developerResponseBody: String?
    let developerResponseState: String?
    let developerResponseModifiedAt: Date?
    let translatedTitle: String?
    let translatedContent: String?
    let translationLanguage: String?
    let translatedAt: Date?
    let translationProviderRaw: String?
    let translationModelID: String?
    let assumedLanguageCode: String?
    let assumedLanguageConfidence: Double?

    var id: String { reviewKey }

    init(_ review: AppStorefrontReview) {
        self.reviewKey = review.reviewKey
        self.appStoreID = review.appStoreID
        self.storefront = StorefrontCatalog.normalizedStorefrontCode(review.storefront)
        self.reviewID = review.reviewID
        self.reviewerName = review.reviewerName
        self.title = review.title
        self.content = review.content
        self.rating = review.rating
        self.reviewedAt = review.reviewedAt
        self.version = review.version
        self.sourceRaw = review.sourceRaw
        self.ascReviewID = review.ascReviewID
        self.developerResponseID = review.developerResponseID
        self.developerResponseBody = review.developerResponseBody
        self.developerResponseState = review.developerResponseState
        self.developerResponseModifiedAt = review.developerResponseModifiedAt
        self.translatedTitle = review.translatedTitle
        self.translatedContent = review.translatedContent
        self.translationLanguage = review.translationLanguage
        self.translatedAt = review.translatedAt
        self.translationProviderRaw = review.translationProviderRaw
        self.translationModelID = review.translationModelID
        self.assumedLanguageCode = review.assumedLanguageCode
        self.assumedLanguageConfidence = review.assumedLanguageConfidence
    }

    var source: AppStorefrontReviewSource {
        AppStorefrontReviewSource(rawValue: sourceRaw) ?? .iTunesCustomerReviewsRSS
    }

}

extension RatingsMetric {
    func value(from snapshot: RatingSnapshotValue) -> Double? {
        switch self {
        case .ratingCount:
            return snapshot.ratingCount.map(Double.init)
        case .averageRating:
            return snapshot.averageRating
        }
    }

    func aggregateValue(from snapshots: [RatingSnapshotValue]) -> Double? {
        switch self {
        case .ratingCount:
            let values = snapshots.compactMap(\.ratingCount)
            guard !values.isEmpty else { return nil }
            return Double(values.reduce(0, +))
        case .averageRating:
            let weightedValues = snapshots.reduce((sum: 0.0, count: 0)) { partial, snapshot in
                guard let ratingCount = snapshot.ratingCount, let averageRating = snapshot.averageRating else {
                    return partial
                }
                return (partial.sum + Double(ratingCount) * averageRating, partial.count + ratingCount)
            }
            guard weightedValues.count > 0 else { return nil }
            return weightedValues.sum / Double(weightedValues.count)
        }
    }
}

struct RatingsDashboardModel {
    let rows: [RatingsStorefrontRow]
    let totalRatingCount: Int
    let totalRatingCountTrend: Int?
    let averageRating: Double?
    let averageRatingTrend: Double?
    let historyPoints: [RatingHistoryPoint]

    init(
        appStoreID: Int64,
        selectedStorefrontFilter: StorefrontFilter,
        searchText: String,
        metric: RatingsMetric,
        latestRatings: [RatingLatestValue],
        ratingSnapshots: [RatingSnapshotValue],
        storefrontDefinitions: [StorefrontDefinition]
    ) {
        let storefrontLookup = Dictionary(uniqueKeysWithValues: storefrontDefinitions.map { ($0.code, $0) })
        let selectedDefinitions = Self.selectedDefinitions(
            for: selectedStorefrontFilter,
            storefrontDefinitions: storefrontDefinitions,
            storefrontLookup: storefrontLookup
        )
        let latestByStorefront = latestRatings.reduce(into: [String: RatingLatestValue]()) { partial, latest in
            guard latest.appStoreID == appStoreID else { return }
            partial[latest.storefront] = latest
        }
        let previousSnapshotsByStorefront = Self.previousSnapshotsByStorefront(
            appStoreID: appStoreID,
            latestByStorefront: latestByStorefront,
            ratingSnapshots: ratingSnapshots
        )
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        self.rows = selectedDefinitions
            .map { definition in
                let latest = latestByStorefront[definition.code]
                let previousSnapshot = previousSnapshotsByStorefront[definition.code]
                return RatingsStorefrontRow(
                    storefront: definition.code,
                    title: definition.name,
                    flagEmoji: definition.flagEmoji,
                    ratingCount: latest?.ratingCount,
                    ratingCountTrend: Self.ratingCountTrend(latest: latest, previousSnapshot: previousSnapshot),
                    averageRating: latest?.averageRating,
                    averageRatingTrend: Self.averageRatingTrend(latest: latest, previousSnapshot: previousSnapshot),
                    observedAt: latest?.observedAt
                )
            }
            .filter { row in
                if let ratingCount = row.ratingCount {
                    return ratingCount > 0
                }
                return row.averageRating != nil
            }
            .filter { row in
                Self.matchesRatingSearch(row, normalizedSearch: normalizedSearch)
            }
            .sorted {
                let leftCount = $0.ratingCount ?? 0
                let rightCount = $1.ratingCount ?? 0
                if leftCount == rightCount {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return leftCount > rightCount
            }

        let weightedRating = rows.reduce((sum: 0.0, count: 0)) { partial, row in
            guard let ratingCount = row.ratingCount, let averageRating = row.averageRating else {
                return partial
            }
            return (partial.sum + Double(ratingCount) * averageRating, partial.count + ratingCount)
        }
        self.totalRatingCount = weightedRating.count
        self.averageRating = weightedRating.count > 0 ? weightedRating.sum / Double(weightedRating.count) : nil
        self.totalRatingCountTrend = Self.totalRatingCountTrend(rows: rows, previousSnapshotsByStorefront: previousSnapshotsByStorefront)
        self.averageRatingTrend = Self.averageRatingTrend(rows: rows, previousSnapshotsByStorefront: previousSnapshotsByStorefront)
        self.historyPoints = Self.historyPoints(
            appStoreID: appStoreID,
            selectedStorefrontFilter: selectedStorefrontFilter,
            metric: metric,
            ratingSnapshots: ratingSnapshots
        )
    }

    private static func previousSnapshotsByStorefront(
        appStoreID: Int64,
        latestByStorefront: [String: RatingLatestValue],
        ratingSnapshots: [RatingSnapshotValue]
    ) -> [String: RatingSnapshotValue] {
        var previousSnapshots: [String: RatingSnapshotValue] = [:]
        previousSnapshots.reserveCapacity(latestByStorefront.count)

        for snapshot in ratingSnapshots where snapshot.appStoreID == appStoreID {
            guard let latest = latestByStorefront[snapshot.storefront],
                  snapshot.ratingDate != latest.ratingDate || snapshot.observedAt < latest.observedAt
            else {
                continue
            }

            guard let existing = previousSnapshots[snapshot.storefront] else {
                previousSnapshots[snapshot.storefront] = snapshot
                continue
            }

            if snapshot.ratingDate > existing.ratingDate
                || (snapshot.ratingDate == existing.ratingDate && snapshot.observedAt > existing.observedAt) {
                previousSnapshots[snapshot.storefront] = snapshot
            }
        }

        return previousSnapshots
    }

    private static func ratingCountTrend(latest: RatingLatestValue?, previousSnapshot: RatingSnapshotValue?) -> Int? {
        guard
            let latestCount = latest?.ratingCount,
            let previousCount = previousSnapshot?.ratingCount
        else {
            return nil
        }

        return latestCount - previousCount
    }

    private static func averageRatingTrend(latest: RatingLatestValue?, previousSnapshot: RatingSnapshotValue?) -> Double? {
        guard
            let latestRating = latest?.averageRating,
            let previousRating = previousSnapshot?.averageRating
        else {
            return nil
        }

        return latestRating - previousRating
    }

    private static func totalRatingCountTrend(
        rows: [RatingsStorefrontRow],
        previousSnapshotsByStorefront: [String: RatingSnapshotValue]
    ) -> Int? {
        let pairedRows = rows.compactMap { row -> (current: Int, previous: Int)? in
            guard
                let current = row.ratingCount,
                let previous = previousSnapshotsByStorefront[row.storefront]?.ratingCount
            else {
                return nil
            }

            return (current, previous)
        }

        guard !pairedRows.isEmpty else { return nil }
        return pairedRows.reduce(0) { $0 + $1.current } - pairedRows.reduce(0) { $0 + $1.previous }
    }

    private static func averageRatingTrend(
        rows: [RatingsStorefrontRow],
        previousSnapshotsByStorefront: [String: RatingSnapshotValue]
    ) -> Double? {
        let previousWeightedRating = rows.reduce((sum: 0.0, count: 0)) { partial, row in
            guard
                let previousSnapshot = previousSnapshotsByStorefront[row.storefront],
                let previousCount = previousSnapshot.ratingCount,
                let previousRating = previousSnapshot.averageRating
            else {
                return partial
            }

            return (partial.sum + Double(previousCount) * previousRating, partial.count + previousCount)
        }
        let currentWeightedRating = rows.reduce((sum: 0.0, count: 0)) { partial, row in
            guard
                previousSnapshotsByStorefront[row.storefront] != nil,
                let currentCount = row.ratingCount,
                let currentRating = row.averageRating
            else {
                return partial
            }

            return (partial.sum + Double(currentCount) * currentRating, partial.count + currentCount)
        }

        guard previousWeightedRating.count > 0, currentWeightedRating.count > 0 else { return nil }
        return (currentWeightedRating.sum / Double(currentWeightedRating.count))
            - (previousWeightedRating.sum / Double(previousWeightedRating.count))
    }

    private static func selectedDefinitions(
        for selectedStorefrontFilter: StorefrontFilter,
        storefrontDefinitions: [StorefrontDefinition],
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

    private static func matchesRatingSearch(_ row: RatingsStorefrontRow, normalizedSearch: String) -> Bool {
        guard !normalizedSearch.isEmpty else { return true }
        return row.title.localizedCaseInsensitiveContains(normalizedSearch)
            || row.storefront.localizedCaseInsensitiveContains(normalizedSearch)
    }

    private static func historyPoints(
        appStoreID: Int64,
        selectedStorefrontFilter: StorefrontFilter,
        metric: RatingsMetric,
        ratingSnapshots: [RatingSnapshotValue]
    ) -> [RatingHistoryPoint] {
        let snapshots = ratingSnapshots
            .filter { $0.appStoreID == appStoreID }
            .filter { snapshot in
                switch selectedStorefrontFilter {
                case .all:
                    return true
                case .storefront(let code, _):
                    return snapshot.storefront == code
                }
            }
            .filter {
                switch metric {
                case .ratingCount:
                    return $0.ratingCount != nil
                case .averageRating:
                    return $0.averageRating != nil
                }
            }

        guard selectedStorefrontFilter == .all else {
            return Self.latestSnapshotPerRatingDate(from: snapshots).compactMap {
                guard let value = metric.value(from: $0) else {
                    return nil
                }
                return RatingHistoryPoint(date: Self.displayDate(for: $0.ratingDate), value: value, storefront: $0.storefront)
            }
        }

        let groupedByDay = Dictionary(grouping: snapshots) {
            $0.ratingDate
        }

        return groupedByDay.map { ratingDate, snapshots in
            let latestSnapshots = Self.latestSnapshotPerStorefront(from: snapshots)
            return RatingHistoryPoint(
                date: Self.displayDate(for: ratingDate),
                value: metric.aggregateValue(from: latestSnapshots) ?? 0,
                storefront: "all"
            )
        }
        .filter { $0.value > 0 }
        .sorted { $0.date < $1.date }
    }

    private static func latestSnapshotPerStorefront(
        from snapshots: [RatingSnapshotValue]
    ) -> [RatingSnapshotValue] {
        Dictionary(grouping: snapshots, by: \.storefront).compactMap { _, snapshots in
            snapshots.max { left, right in
                if left.ratingDate == right.ratingDate {
                    return left.observedAt < right.observedAt
                }
                return left.ratingDate < right.ratingDate
            }
        }
    }

    private static func latestSnapshotPerRatingDate(
        from snapshots: [RatingSnapshotValue]
    ) -> [RatingSnapshotValue] {
        Dictionary(grouping: snapshots, by: \.ratingDate).compactMap { _, snapshots in
            snapshots.max { $0.observedAt < $1.observedAt }
        }
        .sorted { $0.observedAt < $1.observedAt }
    }

    private static func displayDate(for ratingDate: String) -> Date {
        let parts = ratingDate.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return .distantPast }

        return Calendar.current.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: 12
        )) ?? .distantPast
    }
}

struct RatingTrendValue {
    enum Direction {
        case up
        case down
    }

    let direction: Direction
    let value: String

    var systemImage: String {
        switch direction {
        case .up:
            return "arrow.up"
        case .down:
            return "arrow.down"
        }
    }

    var color: Color {
        switch direction {
        case .up:
            return .green
        case .down:
            return .red
        }
    }
}

extension Optional where Wrapped == Int {
    var formattedCountTrend: RatingTrendValue? {
        guard let self else { return nil }
        if self > 0 {
            return RatingTrendValue(direction: .up, value: self.formatted())
        }
        if self < 0 {
            return RatingTrendValue(direction: .down, value: abs(self).formatted())
        }
        return nil
    }
}

extension Optional where Wrapped == Double {
    var formattedRatingTrend: RatingTrendValue? {
        guard let self else { return nil }
        let displayedMagnitude = ((abs(self) * 100) + 0.000000001).rounded() / 100
        guard displayedMagnitude > 0 else { return nil }

        if self > 0 {
            return RatingTrendValue(
                direction: .up,
                value: displayedMagnitude.formatted(.number.precision(.fractionLength(2)))
            )
        }
        if self < 0 {
            return RatingTrendValue(
                direction: .down,
                value: displayedMagnitude.formatted(.number.precision(.fractionLength(2)))
            )
        }
        return nil
    }
}
