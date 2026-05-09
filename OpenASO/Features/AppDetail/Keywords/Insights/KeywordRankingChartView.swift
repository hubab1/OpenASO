import Charts
import SwiftUI

struct KeywordRankingChartView: View {
    let series: [KeywordRankingChartSeries]
    let chartHeight: CGFloat
    let legendWidth: CGFloat
    let isLoading: Bool
    private let horizontalPlotPadding: CGFloat = 3
    private let chartData: KeywordRankingChartData

    @State private var focusedSeriesID: String?

    init(
        series: [KeywordRankingChartSeries],
        chartHeight: CGFloat = 220,
        legendWidth: CGFloat = 156,
        isLoading: Bool = false
    ) {
        self.series = series
        self.chartHeight = chartHeight
        self.legendWidth = legendWidth
        self.isLoading = isLoading
        self.chartData = Self.makeChartData(for: series)
    }

    var body: some View {
        Group {
            if isLoading {
                KeywordRankingChartLoadingState(height: chartHeight)
            } else if chartData.chartPoints.isEmpty {
                KeywordRankingChartEmptyState(height: chartHeight)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    KeywordRankingChartLegend(
                        items: chartData.legendItems,
                        colors: chartData.keywordColors,
                        latestRankBySeriesID: chartData.latestRankBySeriesID,
                        focusedSeriesID: focusedSeriesID,
                        setFocusedSeriesID: setFocusedSeriesID
                    )
                    .frame(width: legendWidth, height: chartHeight, alignment: .topLeading)

                    Chart(chartData.chartPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Rank", point.rank)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: lineWidth(for: point.seriesID),
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .opacity(opacity(for: point.seriesID))
                        .foregroundStyle(by: .value("Keyword", point.seriesID))

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Rank", point.rank)
                        )
                        .symbolSize(pointSize(for: point.seriesID))
                        .opacity(opacity(for: point.seriesID))
                        .foregroundStyle(by: .value("Keyword", point.seriesID))

                        if shouldShowEndpointLabel(for: point) {
                            PointMark(
                                x: .value("Latest date", point.date),
                                y: .value("Latest rank", point.rank)
                            )
                            .symbolSize(pointSize(for: point.seriesID) + 18)
                            .foregroundStyle(by: .value("Keyword", point.seriesID))
                            .annotation(position: .leading, alignment: .center, spacing: 4) {
                                Text("#\(point.rank)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(chartData.colorBySeriesID[point.seriesID] ?? .secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.background.opacity(0.86), in: Capsule())
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: chartData.seriesIDs, range: chartData.keywordColors)
                    .chartXScale(domain: chartData.xScaleDomain, range: .plotDimension(padding: horizontalPlotPadding))
                    .chartYScale(domain: chartData.yScaleDomain)
                    .chartXAxis(.automatic)
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: chartData.yAxisValues) { value in
                            AxisGridLine()
                            AxisTick()
                            if let rank = value.as(Int.self), rank > 0 {
                                AxisValueLabel("#\(rank)")
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .chartPlotStyle { plotArea in
                        plotArea
                            .background(.secondary.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(height: chartHeight)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyword ranking chart")
    }

    private static func color(for index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    private static func makeChartData(for series: [KeywordRankingChartSeries]) -> KeywordRankingChartData {
        let validSeries = mergeDuplicateSeries(series.map { keywordSeries in
            let sortedPoints = keywordSeries.points
                .filter { $0.rank > 0 }
                .sorted { $0.date < $1.date }

            return KeywordRankingChartSeries(
                id: keywordSeries.id,
                keyword: keywordSeries.keyword,
                contextLabel: keywordSeries.contextLabel,
                platform: keywordSeries.platform,
                points: sortedPoints
            )
        })

        let latestDataDate = validSeries
            .flatMap(\.points)
            .map { normalizedChartDate(for: $0.date) }
            .max()
        let endDate = max(latestDataDate ?? normalizedChartDate(for: Date()), normalizedChartDate(for: Date()))

        let rankedSeries = validSeries
            .map { keywordSeries in
                KeywordRankingChartSeries(
                    id: keywordSeries.id,
                    keyword: keywordSeries.keyword,
                    contextLabel: keywordSeries.contextLabel,
                    platform: keywordSeries.platform,
                    points: pointsExtending(normalizedDailyPoints(keywordSeries.points), to: endDate)
                )
            }
            .filter { !$0.points.isEmpty }

        let chartPoints = rankedSeries.flatMap { keywordSeries in
            keywordSeries.points.map { point in
                KeywordRankingChartPoint(
                    seriesID: keywordSeries.id,
                    keyword: keywordSeries.keyword,
                    date: point.date,
                    rank: point.rank
                )
            }
        }

        let latestChartPoints: [KeywordRankingChartPoint] = rankedSeries.compactMap { keywordSeries in
            guard let point = keywordSeries.points.max(by: { $0.date < $1.date }) else {
                return nil
            }

            return KeywordRankingChartPoint(
                seriesID: keywordSeries.id,
                keyword: keywordSeries.keyword,
                date: point.date,
                rank: point.rank
            )
        }

        let seriesIDs = rankedSeries.map(\.id)
        let keywordColors = seriesIDs.indices.map { color(for: $0) }
        let showsPlatformIndicators = Set(rankedSeries.map(\.platform)).count > 1

        return KeywordRankingChartData(
            chartPoints: chartPoints,
            legendItems: rankedSeries.map { keywordSeries in
                KeywordRankingChartLegendItem(
                    id: keywordSeries.id,
                    keyword: keywordSeries.keyword,
                    contextLabel: keywordSeries.contextLabel,
                    platform: showsPlatformIndicators ? keywordSeries.platform : nil
                )
            },
            latestRankBySeriesID: Dictionary(latestChartPoints.map { ($0.seriesID, $0.rank) }, uniquingKeysWith: { _, latest in latest }),
            latestPointIDs: Set(latestChartPoints.map(\.id)),
            latestPointCount: latestChartPoints.count,
            seriesIDs: seriesIDs,
            keywordColors: keywordColors,
            colorBySeriesID: Dictionary(zip(seriesIDs, keywordColors), uniquingKeysWith: { first, _ in first }),
            yScaleDomain: yScaleDomain(for: chartPoints),
            xScaleDomain: xScaleDomain(for: chartPoints),
            yAxisValues: yAxisValues(for: chartPoints)
        )
    }

    private static func mergeDuplicateSeries(_ series: [KeywordRankingChartSeries]) -> [KeywordRankingChartSeries] {
        var mergedSeries: [KeywordRankingChartSeries] = []
        var indexBySeriesID: [String: Int] = [:]

        for keywordSeries in series {
            guard let existingIndex = indexBySeriesID[keywordSeries.id] else {
                indexBySeriesID[keywordSeries.id] = mergedSeries.count
                mergedSeries.append(keywordSeries)
                continue
            }

            let existingSeries = mergedSeries[existingIndex]
            mergedSeries[existingIndex] = KeywordRankingChartSeries(
                id: existingSeries.id,
                keyword: existingSeries.keyword,
                contextLabel: existingSeries.contextLabel,
                platform: existingSeries.platform,
                points: existingSeries.points + keywordSeries.points
            )
        }

        return mergedSeries
    }

    private static func pointsExtending(
        _ points: [KeywordRankingChartSeries.Point],
        to endDate: Date
    ) -> [KeywordRankingChartSeries.Point] {
        guard let latestPoint = points.last else {
            return []
        }

        guard latestPoint.date < endDate else {
            return points
        }

        return points + [
            KeywordRankingChartSeries.Point(
                date: endDate,
                rank: latestPoint.rank
            )
        ]
    }

    private static func normalizedDailyPoints(
        _ points: [KeywordRankingChartSeries.Point]
    ) -> [KeywordRankingChartSeries.Point] {
        var pointsByDay: [Date: KeywordRankingChartSeries.Point] = [:]

        for point in points {
            let normalizedDate = normalizedChartDate(for: point.date)
            pointsByDay[normalizedDate] = KeywordRankingChartSeries.Point(
                date: normalizedDate,
                rank: point.rank
            )
        }

        return pointsByDay.values.sorted { $0.date < $1.date }
    }

    private static func normalizedChartDate(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func setFocusedSeriesID(_ seriesID: String) {
        focusedSeriesID = focusedSeriesID == seriesID ? nil : seriesID
    }

    private func opacity(for seriesID: String) -> Double {
        guard let focusedSeriesID, focusedSeriesID != seriesID else {
            return 1
        }

        return 0.26
    }

    private func lineWidth(for seriesID: String) -> CGFloat {
        focusedSeriesID == seriesID ? 3 : 2
    }

    private func pointSize(for seriesID: String) -> CGFloat {
        focusedSeriesID == seriesID ? 24 : 12
    }

    private func shouldShowEndpointLabel(for point: KeywordRankingChartPoint) -> Bool {
        guard chartData.latestPointIDs.contains(point.id) else {
            return false
        }

        if let focusedSeriesID {
            return focusedSeriesID == point.seriesID
        }

        return chartData.latestPointCount <= 5
    }

    private static func xScaleDomain(for chartPoints: [KeywordRankingChartPoint]) -> ClosedRange<Date> {
        let dates = chartPoints.map(\.date)
        guard let minDate = dates.min(), let maxDate = dates.max() else {
            let today = Date()
            return today...today
        }

        if calendar.isDate(minDate, inSameDayAs: maxDate) {
            let startDate = calendar.startOfDay(for: minDate)
            let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? maxDate
            return startDate...endDate
        }

        return minDate...maxDate
    }

    private static func yScaleDomain(for chartPoints: [KeywordRankingChartPoint]) -> [Int] {
        let ranks = chartPoints.map(\.rank)
        let minRank = ranks.min() ?? 1
        let maxRank = ranks.max() ?? 10
        return [maxRank + 1, Swift.max(0, minRank - 1)]
    }

    private static func yAxisValues(for chartPoints: [KeywordRankingChartPoint]) -> [Int] {
        let ranks = chartPoints.map(\.rank)
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

        let firstTick = ((Swift.max(1, minRank) + step - 1) / step) * step
        let baseTicks = stride(from: firstTick, through: maxRank, by: step)
        return Array(Set([minRank, maxRank] + Array(baseTicks))).sorted()
    }

    private static let calendar = Calendar.autoupdatingCurrent

    private static let palette: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .pink,
        .teal,
        .red,
        .indigo,
        .mint,
        .cyan,
        Color(red: 0.58, green: 0.38, blue: 0.13),
        Color(red: 0.15, green: 0.55, blue: 0.42),
        Color(red: 0.62, green: 0.22, blue: 0.42),
        Color(red: 0.24, green: 0.42, blue: 0.78),
        Color(red: 0.74, green: 0.30, blue: 0.12),
        Color(red: 0.35, green: 0.55, blue: 0.18),
        Color(red: 0.48, green: 0.28, blue: 0.72),
        Color(red: 0.78, green: 0.48, blue: 0.08),
        Color(red: 0.12, green: 0.48, blue: 0.62),
        Color(red: 0.68, green: 0.18, blue: 0.22)
    ]
}

extension KeywordRankingChartView {
    init(insightSeries: [KeywordInsightSeries]) {
        self.init(
            series: insightSeries.map { keywordSeries in
                var lastRank: Int?
                let points = keywordSeries.points
                    .sorted { $0.date < $1.date }
                    .compactMap { point -> KeywordRankingChartSeries.Point? in
                        if let rank = point.rank {
                            lastRank = rank
                        }

                        guard let lastRank else {
                            return nil
                        }

                        return KeywordRankingChartSeries.Point(date: point.date, rank: lastRank)
                    }

                return KeywordRankingChartSeries(
                    id: keywordSeries.queryKey,
                    keyword: keywordSeries.keyword,
                    contextLabel: keywordSeries.storefront.uppercased(),
                    platform: keywordSeries.platform,
                    points: points
                )
            }
        )
    }
}

struct KeywordRankingChartSeries: Identifiable {
    struct Point: Identifiable {
        let date: Date
        let rank: Int

        var id: String {
            "\(date.timeIntervalSince1970)-\(rank)"
        }
    }

    let id: String
    let keyword: String
    let contextLabel: String?
    let platform: AppPlatform
    let points: [Point]

    init(
        id: String? = nil,
        keyword: String,
        contextLabel: String? = nil,
        platform: AppPlatform = .iphone,
        points: [Point]
    ) {
        self.id = id ?? keyword
        self.keyword = keyword
        self.contextLabel = contextLabel
        self.platform = platform
        self.points = points
    }
}

private struct KeywordRankingChartPoint: Identifiable {
    let seriesID: String
    let keyword: String
    let date: Date
    let rank: Int

    var id: String {
        "\(seriesID)-\(date.timeIntervalSince1970)-\(rank)"
    }
}

private struct KeywordRankingChartData {
    let chartPoints: [KeywordRankingChartPoint]
    let legendItems: [KeywordRankingChartLegendItem]
    let latestRankBySeriesID: [String: Int]
    let latestPointIDs: Set<String>
    let latestPointCount: Int
    let seriesIDs: [String]
    let keywordColors: [Color]
    let colorBySeriesID: [String: Color]
    let yScaleDomain: [Int]
    let xScaleDomain: ClosedRange<Date>
    let yAxisValues: [Int]
}

private struct KeywordRankingChartLegendItem: Identifiable {
    let id: String
    let keyword: String
    let contextLabel: String?
    let platform: AppPlatform?
}

private struct KeywordRankingChartLegend: View {
    let items: [KeywordRankingChartLegendItem]
    let colors: [Color]
    let latestRankBySeriesID: [String: Int]
    let focusedSeriesID: String?
    let setFocusedSeriesID: (String) -> Void

    @State private var hoveredSeriesID: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        setFocusedSeriesID(item.id)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(colors[index])
                                .frame(width: 8, height: 8)

                            Text(item.keyword)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if let contextLabel = item.contextLabel, !contextLabel.isEmpty {
                                Text(contextLabel)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            if let platform = item.platform {
                                Image(systemName: platform.keywordChartSystemImage)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .imageScale(.small)
                                    .accessibilityLabel(platform.displayName)
                            }

                            Spacer(minLength: 4)

                            if let rank = latestRankBySeriesID[item.id] {
                                Text("#\(rank)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(legendForegroundStyle(for: item.id))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(legendBackground(for: item.id), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovered in
                        hoveredSeriesID = isHovered ? item.id : nil
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: item, index: index))
                }
            }
            .padding(.vertical, 2)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.96),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func legendForegroundStyle(for seriesID: String) -> HierarchicalShapeStyle {
        guard let focusedSeriesID, focusedSeriesID != seriesID, hoveredSeriesID != seriesID else {
            return .primary
        }

        return .tertiary
    }

    private func legendBackground(for seriesID: String) -> Color {
        if focusedSeriesID == seriesID {
            return .secondary.opacity(0.12)
        }

        if hoveredSeriesID == seriesID {
            return .secondary.opacity(0.07)
        }

        return .clear
    }

    private func accessibilityLabel(for item: KeywordRankingChartLegendItem, index: Int) -> String {
        let name = [item.keyword, item.contextLabel, item.platform?.displayName].compactMap { $0 }.joined(separator: ", ")

        if let rank = latestRankBySeriesID[item.id] {
            return "\(name), rank \(rank), \(legendColorName(for: index))"
        }

        return "\(name), \(legendColorName(for: index))"
    }

    private func legendColorName(for index: Int) -> String {
        "series \(index + 1)"
    }
}

private extension AppPlatform {
    var keywordChartSystemImage: String {
        switch self {
        case .iphone:
            return "iphone"
        case .ipad:
            return "ipad"
        case .mac:
            return "macbook"
        }
    }
}

private struct KeywordRankingChartEmptyState: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(height: 1)

            Text("No ranking history")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .background(.background)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No keyword ranking history")
    }
}

private struct KeywordRankingChartLoadingState: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.045))

            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading keyword ranking chart")
    }
}

#Preview("Keyword Rankings - 10 Keywords") {
    KeywordRankingChartPreviewSurface(
        title: "10 Keywords",
        series: .previewKeywordRankings(keywordCount: 10, days: 28, scenario: .clustered)
    )
}

#Preview("Keyword Rankings - 20 Keywords") {
    KeywordRankingChartPreviewSurface(
        title: "20 Keywords",
        series: .previewKeywordRankings(keywordCount: 20, days: 28, scenario: .clustered)
    )
}

#Preview("Keyword Rankings - Wide Split") {
    KeywordRankingChartPreviewSurface(
        title: "Wide Rank Split",
        series: .previewKeywordRankings(keywordCount: 12, days: 35, scenario: .wideSplit)
    )
}

private struct KeywordRankingChartPreviewSurface: View {
    let title: String
    let series: [KeywordRankingChartSeries]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            KeywordRankingChartView(series: series)
        }
        .padding(24)
        .frame(width: 980)
    }
}

private extension Array where Element == KeywordRankingChartSeries {
    static func previewKeywordRankings(
        keywordCount: Int,
        days: Int,
        scenario: KeywordRankingChartPreviewScenario
    ) -> [KeywordRankingChartSeries] {
        var rankings: [KeywordRankingChartSeries] = []
        rankings.reserveCapacity(keywordCount)

        for index in 0..<keywordCount {
            let keyword = KeywordRankingChartPreviewKeyword.name(for: index)
            let points: [KeywordRankingChartSeries.Point] = .previewPoints(
                days: days,
                keywordIndex: index,
                scenario: scenario
            )
            rankings.append(KeywordRankingChartSeries(keyword: keyword, points: points))
        }

        return rankings
    }
}

private enum KeywordRankingChartPreviewKeyword {
    static func name(for index: Int) -> String {
        let number = (index % 20) + 1
        return "Keyword \(number)"
    }
}

private extension Array where Element == KeywordRankingChartSeries.Point {
    static func previewPoints(
        days: Int,
        keywordIndex: Int,
        scenario: KeywordRankingChartPreviewScenario
    ) -> [KeywordRankingChartSeries.Point] {
        let calendar = Calendar(identifier: .gregorian)
        let endDate = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 795_052_800))
        let startDate = calendar.date(byAdding: .day, value: 1 - days, to: endDate) ?? endDate

        return (0..<days).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: dayOffset, to: startDate) ?? startDate
            return KeywordRankingChartSeries.Point(
                date: date,
                rank: scenario.rank(dayOffset: dayOffset, keywordIndex: keywordIndex, days: days)
            )
        }
    }
}

private enum KeywordRankingChartPreviewScenario {
    case clustered
    case wideSplit

    func rank(dayOffset: Int, keywordIndex: Int, days: Int) -> Int {
        let progress = days > 1 ? Double(dayOffset) / Double(days - 1) : 0
        let wave = Double(((dayOffset + keywordIndex) % 7) - 3)

        switch self {
        case .clustered:
            let baseRank = 8 + (keywordIndex * 4)
            let direction = keywordIndex.isMultiple(of: 4) ? 1.0 : -1.0
            let movement = direction * progress * Double(5 + keywordIndex % 6)
            return clippedRank(Double(baseRank) + movement + wave, upperBound: 95)

        case .wideSplit:
            let highRankBase = 2 + keywordIndex
            let lowRankBase = 110 + (keywordIndex * 12)
            let baseRank = keywordIndex.isMultiple(of: 2) ? highRankBase : lowRankBase
            let direction = keywordIndex.isMultiple(of: 3) ? 1.0 : -1.0
            let movement = direction * progress * Double(10 + keywordIndex)
            return clippedRank(Double(baseRank) + movement + (wave * 1.8), upperBound: 260)
        }
    }

    private func clippedRank(_ value: Double, upperBound: Int) -> Int {
        Swift.max(1, Swift.min(upperBound, Int(value.rounded())))
    }
}
