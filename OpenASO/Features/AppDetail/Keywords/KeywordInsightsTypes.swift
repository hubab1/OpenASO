import Foundation
import SwiftUI

enum KeywordInsightsSource {
    case local

    var title: String {
        switch self {
        case .local:
            return "Local"
        }
    }
}

struct KeywordInsightsDataset {
    let appStoreID: Int64
    let series: [KeywordInsightSeries]
    let source: KeywordInsightsSource

    init(appStoreID: Int64, series: [KeywordInsightSeries], source: KeywordInsightsSource) {
        self.appStoreID = appStoreID
        self.series = series
        self.source = source
    }

    init(rows: [KeywordWorkspaceRow]) {
        self.init(
            appStoreID: rows.first?.track.appStoreID ?? 0,
            series: rows.map { row in
                KeywordInsightSeries(
                    queryKey: row.track.queryKey,
                    keyword: row.track.term,
                    storefront: row.track.storefront,
                    platform: row.track.platform,
                    points: row.trendSnapshots.map { snapshot in
                        KeywordInsightPoint(
                            date: Calendar.current.startOfDay(for: snapshot.searchedAt),
                            observedAt: snapshot.searchedAt,
                            rank: snapshot.rank,
                            resultCount: snapshot.resultCount,
                            popularityScore: row.displayedPopularityScore,
                            confidence: nil
                        )
                    }
                )
            },
            source: .local
        )
    }
}

struct KeywordInsightSeries: Identifiable {
    let queryKey: String
    let keyword: String
    let storefront: String
    let platform: AppPlatform
    let points: [KeywordInsightPoint]

    var id: String { queryKey }
}

struct KeywordInsightPoint: Identifiable {
    let date: Date
    let observedAt: Date
    let rank: Int?
    let resultCount: Int
    let popularityScore: Int?
    let confidence: String?

    var id: String {
        "\(observedAt.timeIntervalSince1970)-\(rank ?? -1)-\(popularityScore ?? -1)"
    }
}

struct KeywordInsightsSummary {
    let source: KeywordInsightsSource
    let seriesCount: Int
    let rankedSeriesCount: Int
    let averageRank: Double?
    let highRankCount: Int
    let lowRankCount: Int
    let top5Count: Int
    let top25Count: Int
    let top100Count: Int
    let outsideTop100Count: Int
    let improvedCount: Int
    let declinedCount: Int
    let unchangedCount: Int
    let averageRankDelta: Double?
    let visibilityDelta: Double?
    let latestVisibility: Double
    let movementPoints: [KeywordMovementChartPoint]
    let visibilityPoints: [KeywordVisibilityChartPoint]
    let contributors: [KeywordVisibilityContributor]

    var hasHistory: Bool {
        !movementPoints.isEmpty || !visibilityPoints.isEmpty
    }

    static let empty = KeywordInsightsSummary(
        dataset: KeywordInsightsDataset(appStoreID: 0, series: [], source: .local)
    )

    init(dataset: KeywordInsightsDataset) {
        let movements = dataset.series.compactMap(Self.overallMovement)
        let movementPoints = Self.movementPoints(from: dataset.series)
        let visibilityPoints = Self.visibilityPoints(from: dataset.series)
        let latestVisibility = visibilityPoints.last?.visibility ?? 0
        let firstVisibility = visibilityPoints.first?.visibility
        let rankDeltas = movements.map(\.delta)
        let latestRanks = Self.latestNormalizedRanks(from: dataset.series)

        self.source = dataset.source
        self.seriesCount = dataset.series.count
        self.rankedSeriesCount = dataset.series.filter { series in
            series.points.contains { $0.rank != nil }
        }.count
        self.averageRank = latestRanks.isEmpty ? nil : Double(latestRanks.reduce(0, +)) / Double(latestRanks.count)
        self.highRankCount = latestRanks.filter { $0 <= 25 }.count
        self.lowRankCount = latestRanks.filter { $0 > 100 }.count
        self.top5Count = latestRanks.filter { $0 <= 5 }.count
        self.top25Count = latestRanks.filter { 6 ... 25 ~= $0 }.count
        self.top100Count = latestRanks.filter { 26 ... 100 ~= $0 }.count
        self.outsideTop100Count = latestRanks.filter { $0 > 100 }.count
        self.improvedCount = movements.filter { $0.delta > 0 }.count
        self.declinedCount = movements.filter { $0.delta < 0 }.count
        self.unchangedCount = movements.filter { $0.delta == 0 }.count
        self.averageRankDelta = rankDeltas.isEmpty ? nil : Double(rankDeltas.reduce(0, +)) / Double(rankDeltas.count)
        self.visibilityDelta = firstVisibility.map { latestVisibility - $0 }
        self.latestVisibility = latestVisibility
        self.movementPoints = movementPoints
        self.visibilityPoints = visibilityPoints
        self.contributors = Self.contributors(from: dataset.series)
    }

    private static func latestNormalizedRanks(from series: [KeywordInsightSeries]) -> [Int] {
        series.compactMap { keywordSeries in
            guard let latest = keywordSeries.points.max(by: { $0.observedAt < $1.observedAt }) else {
                return nil
            }

            return normalizedRank(latest.rank, resultCount: latest.resultCount)
        }
    }

    private static func overallMovement(from series: KeywordInsightSeries) -> KeywordMovement? {
        let ordered = series.points.sorted { $0.observedAt < $1.observedAt }
        guard let first = ordered.first, let last = ordered.last, ordered.count > 1 else {
            return nil
        }

        let firstRank = normalizedRank(first.rank, resultCount: first.resultCount)
        let lastRank = normalizedRank(last.rank, resultCount: last.resultCount)
        return KeywordMovement(
            queryKey: series.queryKey,
            keyword: series.keyword,
            date: last.date,
            delta: firstRank - lastRank
        )
    }

    private static func historicalMovements(from series: KeywordInsightSeries) -> [KeywordMovement] {
        let ordered = series.points.sorted { $0.observedAt < $1.observedAt }
        guard ordered.count > 1 else {
            return []
        }

        return zip(ordered, ordered.dropFirst()).map { previous, current in
            KeywordMovement(
                queryKey: series.queryKey,
                keyword: series.keyword,
                date: current.date,
                delta: normalizedRank(previous.rank, resultCount: previous.resultCount) - normalizedRank(current.rank, resultCount: current.resultCount)
            )
        }
    }

    private static func movementPoints(from series: [KeywordInsightSeries]) -> [KeywordMovementChartPoint] {
        let movements = series.flatMap(Self.historicalMovements)
        let groupedMovements = Dictionary(grouping: movements) { movement in
            movement.date
        }
        var points: [KeywordMovementChartPoint] = []

        for (date, values) in groupedMovements {
            var improved = 0
            var declined = 0
            var unchanged = 0
            var deltaTotal = 0

            for value in values {
                deltaTotal += value.delta
                if value.delta > 0 {
                    improved += 1
                } else if value.delta < 0 {
                    declined += 1
                } else {
                    unchanged += 1
                }
            }

            points.append(
                KeywordMovementChartPoint(
                    date: date,
                    improved: improved,
                    declined: declined,
                    unchanged: unchanged,
                    averageDelta: Double(deltaTotal) / Double(values.count)
                )
            )
        }

        return points.sorted { $0.date < $1.date }
    }

    private static func visibilityPoints(from series: [KeywordInsightSeries]) -> [KeywordVisibilityChartPoint] {
        let grouped = Dictionary(grouping: series.flatMap { keywordSeries in
            keywordSeries.points.map { point in
                KeywordVisibilityContribution(date: point.date, score: visibilityScore(for: point))
            }
        }, by: \.date)

        return grouped.map { date, values in
            KeywordVisibilityChartPoint(date: date, visibility: values.map(\.score).reduce(0, +))
        }
        .sorted { $0.date < $1.date }
    }

    private static func contributors(from series: [KeywordInsightSeries]) -> [KeywordVisibilityContributor] {
        series.compactMap { keywordSeries in
            let ordered = keywordSeries.points.sorted { $0.observedAt < $1.observedAt }
            guard let first = ordered.first, let last = ordered.last, ordered.count > 1 else {
                return nil
            }

            let delta = visibilityScore(for: last) - visibilityScore(for: first)
            return KeywordVisibilityContributor(
                queryKey: keywordSeries.queryKey,
                keyword: keywordSeries.keyword,
                storefront: keywordSeries.storefront,
                rankDelta: normalizedRank(first.rank, resultCount: first.resultCount) - normalizedRank(last.rank, resultCount: last.resultCount),
                visibilityDelta: delta,
                latestRank: last.rank,
                popularityScore: last.popularityScore
            )
        }
        .sorted { abs($0.visibilityDelta) > abs($1.visibilityDelta) }
    }

    private static func visibilityScore(for point: KeywordInsightPoint) -> Double {
        guard let popularityScore = point.popularityScore else {
            return 0
        }

        guard let rank = point.rank, rank > 0 else {
            return 0
        }

        let popularityWeight = Double(popularityScore) / 100
        return popularityWeight * clickThroughRateWeight(forRank: rank) * 100
    }

    private static func clickThroughRateWeight(forRank rank: Int) -> Double {
        // Visibility is a relative opportunity score, not an impression estimate.
        // It combines Apple Ads popularity (0...100) with App Store search CTR
        // midpoint assumptions from common ASO benchmark ranges:
        // #1: 25%...40% -> 32.5%, #2: 15%...25% -> 20%,
        // #3: 10%...15% -> 12.5%, #4+: below 10% with a steep tail.
        switch rank {
        case 1:
            return 0.325
        case 2:
            return 0.20
        case 3:
            return 0.125
        case 4:
            return 0.08
        case 5:
            return 0.06
        case 6...10:
            return 0.04
        case 11...20:
            return 0.02
        case 21...50:
            return 0.01
        default:
            return 0.005
        }
    }

    private static func normalizedRank(_ rank: Int?, resultCount: Int) -> Int {
        rank ?? min(SearchRankingCrawl.fullKeywordRankingLimit + 1, resultCount + 1)
    }
}

struct KeywordMovementChartPoint: Identifiable {
    let date: Date
    let improved: Int
    let declined: Int
    let unchanged: Int
    let averageDelta: Double

    var id: Date { date }
}

struct KeywordVisibilityChartPoint: Identifiable {
    let date: Date
    let visibility: Double

    var id: Date { date }
}

struct KeywordVisibilityContributor: Identifiable {
    let queryKey: String
    let keyword: String
    let storefront: String
    let rankDelta: Int
    let visibilityDelta: Double
    let latestRank: Int?
    let popularityScore: Int?

    var id: String { queryKey }

    var color: Color {
        if visibilityDelta > 0 { return .green }
        if visibilityDelta < 0 { return .red }
        return .secondary
    }
}

private struct KeywordMovement {
    let queryKey: String
    let keyword: String
    let date: Date
    let delta: Int
}

private struct KeywordVisibilityContribution {
    let date: Date
    let score: Double
}
