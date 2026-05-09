import Foundation
import SwiftData

enum TrendDateRange: CaseIterable, Identifiable {
    case last7Days
    case last30Days
    case last90Days
    case allTime

    var id: String { title }

    var title: String {
        switch self {
        case .last7Days:
            return "Last 7 Days"
        case .last30Days:
            return "Last 30 Days"
        case .last90Days:
            return "Last 90 Days"
        case .allTime:
            return "All Time"
        }
    }

    var cutoffDate: Date? {
        switch self {
        case .last7Days:
            return Calendar.current.date(byAdding: .day, value: -7, to: .now)
        case .last30Days:
            return Calendar.current.date(byAdding: .day, value: -30, to: .now)
        case .last90Days:
            return Calendar.current.date(byAdding: .day, value: -90, to: .now)
        case .allTime:
            return nil
        }
    }
}

enum AppDetailWorkspaceView: String, CaseIterable, Identifiable {
    case keywords
    case ratings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keywords:
            return "Keywords"
        case .ratings:
            return "Ratings"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .keywords:
            return "Search keywords"
        case .ratings:
            return "Search"
        }
    }
}

struct KeywordWorkspaceState {
    var selectedDateRange = TrendDateRange.last7Days
    var selectedPlatformFilter = PlatformFilter.all
    var popularityFilterRange = MetricFilterRange.popularity.defaultRange
    var difficultyFilterRange = MetricFilterRange.difficulty.defaultRange
    var positionFilterRange = MetricFilterRange.position.defaultRange
    var changeFilterRange = MetricFilterRange.change.defaultRange
    var showsOnlyChangedKeywords = false

    mutating func resetFilters() {
        selectedPlatformFilter = .all
        popularityFilterRange = MetricFilterRange.popularity.defaultRange
        difficultyFilterRange = MetricFilterRange.difficulty.defaultRange
        positionFilterRange = MetricFilterRange.position.defaultRange
        changeFilterRange = MetricFilterRange.change.defaultRange
        showsOnlyChangedKeywords = false
    }
}

enum PlatformFilter: Identifiable, Equatable, Hashable, CaseIterable {
    case all
    case platform(AppPlatform)

    static var allCases: [PlatformFilter] {
        [.all] + AppPlatform.allCases.map(PlatformFilter.platform)
    }

    var id: String {
        switch self {
        case .all:
            return "all"
        case .platform(let platform):
            return platform.rawValue
        }
    }

    var title: String {
        switch self {
        case .all:
            return "All Devices"
        case .platform(let platform):
            return platform.displayName
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "rectangle.stack"
        case .platform(.iphone):
            return "iphone"
        case .platform(.ipad):
            return "ipad"
        case .platform(.mac):
            return "macbook"
        }
    }

    func matches(_ platform: AppPlatform) -> Bool {
        switch self {
        case .all:
            return true
        case .platform(let selectedPlatform):
            return selectedPlatform == platform
        }
    }
}

enum RatingsMetric: String, CaseIterable, Identifiable {
    case ratingCount
    case averageRating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ratingCount:
            return "Ratings Count"
        case .averageRating:
            return "Average Rating"
        }
    }

    func value(from snapshot: AppDailyRating) -> Double? {
        switch self {
        case .ratingCount:
            return snapshot.ratingCount.map(Double.init)
        case .averageRating:
            return snapshot.averageRating
        }
    }

    func aggregateValue(from snapshots: [AppDailyRating]) -> Double? {
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

    func formatted(_ value: Double?) -> String {
        guard let value else { return "-" }
        switch self {
        case .ratingCount:
            return Int(value.rounded()).formatted()
        case .averageRating:
            return value.formatted(.number.precision(.fractionLength(2)))
        }
    }
}

struct StorefrontPickerOption: Identifiable {
    let filter: StorefrontFilter
    let code: String
    let icon: String
    let title: String
    let keywordCount: Int

    var id: String { filter.id }
}

struct StorefrontDefinition: Identifiable, Hashable {
    let code: String
    let name: String
    let flagEmoji: String
    let title: String

    var id: String { code }
}

struct RatingsStorefrontRow: Identifiable {
    let storefront: String
    let title: String
    let flagEmoji: String?
    let ratingCount: Int?
    let ratingCountTrend: Int?
    let averageRating: Double?
    let averageRatingTrend: Double?
    let observedAt: Date?

    var id: String { storefront }
    var titleSortValue: String { title }
    var ratingCountSortValue: Int { ratingCount ?? -1 }
    var averageRatingSortValue: Double { averageRating ?? -1 }
}

struct RatingHistoryPoint: Identifiable {
    let date: Date
    let value: Double
    let storefront: String

    var id: String {
        "\(storefront)-\(date.timeIntervalSince1970)-\(value)"
    }
}

enum MetricFilterRange {
    case popularity
    case difficulty
    case position
    case change

    var title: String {
        switch self {
        case .popularity:
            return "Popularity"
        case .difficulty:
            return "Difficulty"
        case .position:
            return "Position"
        case .change:
            return "Change"
        }
    }

    var bounds: ClosedRange<Double> {
        switch self {
        case .popularity, .difficulty:
            return 0...100
        case .position:
            return 1...300
        case .change:
            return -100...100
        }
    }

    var defaultRange: ClosedRange<Double> {
        bounds
    }

    var step: Double {
        1
    }

    func isDefault(_ range: ClosedRange<Double>) -> Bool {
        range.lowerBound <= defaultRange.lowerBound && range.upperBound >= defaultRange.upperBound
    }
}

enum StorefrontFilter: Identifiable, Equatable {
    case all
    case storefront(code: String, title: String)

    var id: String {
        switch self {
        case .all:
            return "all"
        case .storefront(let code, _):
            return code
        }
    }

    var title: String {
        switch self {
        case .all:
            return "All Countries"
        case .storefront(_, let title):
            return title
        }
    }

    var shortTitle: String {
        switch self {
        case .all:
            return "All Countries"
        case .storefront(let code, let title):
            return title
                .replacingOccurrences(of: icon, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? code.uppercased()
        }
    }

    var icon: String {
        switch self {
        case .all:
            return "🌎"
        case .storefront(_, let title):
            return title.split(separator: " ").first.map(String.init) ?? "🌐"
        }
    }

    static func options(from storefronts: [Storefront]) -> [StorefrontFilter] {
        [.all] + storefronts.map { .storefront(code: $0.code, title: $0.title) }
    }
}

extension Optional where Wrapped == Double {
    var formattedRating: String {
        guard let self else { return "-" }
        return self.formatted(.number.precision(.fractionLength(2)))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
