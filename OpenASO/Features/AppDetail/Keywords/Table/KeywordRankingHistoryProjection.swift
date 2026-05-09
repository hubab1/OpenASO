import Foundation

struct KeywordRankingHistoryProjection: Equatable, Sendable {
    static let maximumChartPointCount = 360
    static let maximumPointMarkCount = 120

    struct Point: Identifiable, Equatable, Sendable {
        let id: String
        let date: Date
        let rank: Int
    }

    struct Segment: Identifiable, Equatable, Sendable {
        let id: String
        let points: [Point]
    }

    let segments: [Segment]
    let chartSegments: [Segment]
    let chartPointCount: Int
    let showsPointMarks: Bool
    let totalObservationCount: Int
    let rankedObservationCount: Int
    let latestObservedRank: Int?
    let dateDomain: ClosedRange<Date>?
    let yScaleDomain: [Int]
    let yAxisValues: [Int]

    init(
        observations: [KeywordRankingCrawlSummary],
        timeframe: TrendDateRange,
        now: Date,
        calendar: Calendar
    ) {
        let cutoffDate = timeframe.cutoffDate(relativeTo: now, calendar: calendar)
        let filteredObservations = observations
            .filter { observation in
                guard let cutoffDate else { return true }
                return observation.searchedAt >= cutoffDate
            }
            .sorted { lhs, rhs in
                if lhs.searchedAt == rhs.searchedAt {
                    return lhs.id < rhs.id
                }
                return lhs.searchedAt < rhs.searchedAt
            }

        var segments: [Segment] = []
        var currentPoints: [Point] = []

        func finishCurrentSegment() {
            guard let firstPoint = currentPoints.first else { return }
            segments.append(
                Segment(
                    id: "segment-\(segments.count)-\(firstPoint.id)",
                    points: currentPoints
                )
            )
            currentPoints = []
        }

        for observation in filteredObservations {
            guard let rank = observation.rank, rank > 0 else {
                finishCurrentSegment()
                continue
            }

            currentPoints.append(
                Point(
                    id: observation.id,
                    date: observation.searchedAt,
                    rank: rank
                )
            )
        }
        finishCurrentSegment()

        let rankedPoints = segments.flatMap(\.points)
        let ranks = rankedPoints.map(\.rank)

        let chartSegments = Self.makeChartSegments(
            segments,
            maximumPointCount: Self.maximumChartPointCount
        )
        let chartPointCount = chartSegments.reduce(into: 0) { count, segment in
            count += segment.points.count
        }

        self.segments = segments
        self.chartSegments = chartSegments
        self.chartPointCount = chartPointCount
        self.showsPointMarks = chartPointCount <= Self.maximumPointMarkCount
        self.totalObservationCount = filteredObservations.count
        self.rankedObservationCount = rankedPoints.count
        self.latestObservedRank = filteredObservations.last?.rank.flatMap { $0 > 0 ? $0 : nil }
        self.dateDomain = Self.makeDateDomain(
            observations: filteredObservations,
            calendar: calendar
        )
        self.yScaleDomain = Self.makeYScaleDomain(ranks: ranks)
        self.yAxisValues = Self.makeYAxisValues(ranks: ranks)
    }

    var observationSummaryText: String {
        guard totalObservationCount > 0 else {
            return "No observations"
        }

        let observationLabel = totalObservationCount == 1 ? "observation" : "observations"
        return "Ranked in \(rankedObservationCount) of \(totalObservationCount) \(observationLabel)"
    }

    var accessibilitySummary: String {
        guard totalObservationCount > 0 else {
            return observationSummaryText
        }

        if let latestObservedRank {
            return "\(observationSummaryText). Latest observed rank \(latestObservedRank)."
        }

        return "\(observationSummaryText). Not ranked in the latest observation."
    }

    func showsPointMarks(for segment: Segment) -> Bool {
        showsPointMarks || segment.points.count == 1
    }

    private static func makeDateDomain(
        observations: [KeywordRankingCrawlSummary],
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        guard
            let firstDate = observations.first?.searchedAt,
            let lastDate = observations.last?.searchedAt
        else {
            return nil
        }

        guard firstDate == lastDate else {
            return firstDate...lastDate
        }

        let startDate = calendar.date(byAdding: .hour, value: -12, to: firstDate) ?? firstDate
        let endDate = calendar.date(byAdding: .hour, value: 12, to: firstDate) ?? firstDate
        return startDate...endDate
    }

    private static func makeChartSegments(
        _ segments: [Segment],
        maximumPointCount: Int
    ) -> [Segment] {
        let pointCount = segments.reduce(into: 0) { count, segment in
            count += segment.points.count
        }
        guard pointCount > maximumPointCount else {
            return segments
        }

        let mandatoryIndices = segments.map { mandatoryPointIndices(in: $0.points) }
        let mandatoryPointCount = mandatoryIndices.reduce(into: 0) { count, indices in
            count += indices.count
        }
        guard mandatoryPointCount <= maximumPointCount else {
            let maximumSegmentCount = max(1, maximumPointCount / 4)
            let selectedSegmentCount = min(segments.count, maximumSegmentCount)
            let selectedSegmentIndices = representativeSegmentIndices(
                in: segments,
                maximumCount: selectedSegmentCount
            )
            return makeChartSegments(
                selectedSegmentIndices.map { segments[$0] },
                maximumPointCount: maximumPointCount
            )
        }

        let optionalPointCounts = zip(segments, mandatoryIndices).map { segment, indices in
            segment.points.count - indices.count
        }
        let totalOptionalPointCount = optionalPointCounts.reduce(0, +)
        var remainingBudget = maximumPointCount - mandatoryPointCount
        var optionalAllocations = Array(repeating: 0, count: segments.count)

        if totalOptionalPointCount > 0, remainingBudget > 0 {
            let availableOptionalBudget = remainingBudget
            for index in segments.indices {
                let allocation = min(
                    optionalPointCounts[index],
                    availableOptionalBudget * optionalPointCounts[index] / totalOptionalPointCount
                )
                optionalAllocations[index] = allocation
            }

            remainingBudget -= optionalAllocations.reduce(0, +)
            while remainingBudget > 0 {
                var madeAllocation = false
                for index in segments.indices where remainingBudget > 0 {
                    guard optionalAllocations[index] < optionalPointCounts[index] else {
                        continue
                    }
                    optionalAllocations[index] += 1
                    remainingBudget -= 1
                    madeAllocation = true
                }
                guard madeAllocation else { break }
            }
        }

        return segments.indices.map { index in
            let retainedIndices = retainingEvenlyDistributedPoints(
                in: segments[index].points,
                mandatoryIndices: mandatoryIndices[index],
                optionalPointCount: optionalAllocations[index]
            )
            return Segment(
                id: segments[index].id,
                points: retainedIndices.map { segments[index].points[$0] }
            )
        }
    }

    private static func representativeSegmentIndices(
        in segments: [Segment],
        maximumCount: Int
    ) -> [Int] {
        guard maximumCount > 1 else {
            return [max(0, (segments.count - 1) / 2)]
        }

        var selectedIndices: Set<Int> = [0, segments.count - 1]
        if let minimumRankSegmentIndex = segments.indices.min(by: {
            (segments[$0].points.map(\.rank).min() ?? Int.max)
                < (segments[$1].points.map(\.rank).min() ?? Int.max)
        }) {
            selectedIndices.insert(minimumRankSegmentIndex)
        }
        if let maximumRankSegmentIndex = segments.indices.max(by: {
            (segments[$0].points.map(\.rank).max() ?? Int.min)
                < (segments[$1].points.map(\.rank).max() ?? Int.min)
        }) {
            selectedIndices.insert(maximumRankSegmentIndex)
        }

        for index in evenlyDistributedIndices(count: maximumCount, upperBound: segments.count)
            where selectedIndices.count < maximumCount {
            selectedIndices.insert(index)
        }
        for index in segments.indices where selectedIndices.count < maximumCount {
            selectedIndices.insert(index)
        }
        return selectedIndices.sorted()
    }

    private static func evenlyDistributedIndices(
        count: Int,
        upperBound: Int
    ) -> [Int] {
        guard count > 1 else {
            return [max(0, (upperBound - 1) / 2)]
        }

        return (0..<count).map { index in
            index * (upperBound - 1) / (count - 1)
        }
    }

    private static func mandatoryPointIndices(in points: [Point]) -> Set<Int> {
        guard !points.isEmpty else { return [] }

        var indices: Set<Int> = [0, points.count - 1]
        if let minimumRankIndex = points.indices.min(by: { points[$0].rank < points[$1].rank }) {
            indices.insert(minimumRankIndex)
        }
        if let maximumRankIndex = points.indices.max(by: { points[$0].rank < points[$1].rank }) {
            indices.insert(maximumRankIndex)
        }
        return indices
    }

    private static func retainingEvenlyDistributedPoints(
        in points: [Point],
        mandatoryIndices: Set<Int>,
        optionalPointCount: Int
    ) -> [Int] {
        let optionalIndices = points.indices.filter { !mandatoryIndices.contains($0) }
        guard optionalPointCount < optionalIndices.count else {
            return points.indices.map(\.self)
        }

        var retainedIndices = mandatoryIndices
        for slot in 0..<optionalPointCount {
            let position = slot * optionalIndices.count / optionalPointCount
            retainedIndices.insert(optionalIndices[position])
        }
        return retainedIndices.sorted()
    }

    private static func makeYScaleDomain(ranks: [Int]) -> [Int] {
        guard let minRank = ranks.min(), let maxRank = ranks.max() else {
            return [10, 0]
        }

        return [maxRank + 1, max(0, minRank - 1)]
    }

    private static func makeYAxisValues(ranks: [Int]) -> [Int] {
        guard let minRank = ranks.min(), let maxRank = ranks.max() else {
            return [1, 5, 10]
        }

        let span = maxRank - minRank
        let step: Int
        switch span {
        case 0...12:
            step = 2
        case 13...50:
            step = 5
        case 51...120:
            step = 10
        default:
            step = 25
        }

        let firstTick = ((max(1, minRank) + step - 1) / step) * step
        let baseTicks = stride(from: firstTick, through: maxRank, by: step)
        return Array(Set([minRank, maxRank] + Array(baseTicks))).sorted()
    }
}
