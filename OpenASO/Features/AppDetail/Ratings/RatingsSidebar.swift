import SwiftUI

struct RatingsSidebar: View {
    let rows: [RatingsStorefrontRow]
    let totalRatingCount: Int
    let totalRatingCountTrend: Int?
    let averageRating: Double?
    let averageRatingTrend: Double?
    let historyPoints: [RatingHistoryPoint]
    @Binding var metric: RatingsMetric

    @State private var timeFrame = RatingsTimeFrame.lastYear

    private var chartDateDomain: ClosedRange<Date>? {
        guard
            let earliestDate = historyPoints.map(\.date).min(),
            let latestDate = historyPoints.map(\.date).max()
        else {
            return nil
        }

        return max(earliestDate, timeFrame.cutoffDate(relativeTo: latestDate))...latestDate
    }

    private var filteredHistoryPoints: [RatingHistoryPoint] {
        guard let chartDateDomain else {
            return []
        }

        return historyPoints.filter { chartDateDomain.contains($0.date) }
    }

    var body: some View {
        VStack(spacing: 0) {
            RatingsSummaryMetrics(
                totalRatingCount: totalRatingCount,
                totalRatingCountTrend: totalRatingCountTrend,
                averageRating: averageRating,
                averageRatingTrend: averageRatingTrend
            )

            RatingsHistoryPanel(
                historyPoints: filteredHistoryPoints,
                metric: $metric,
                timeFrame: $timeFrame,
                dateDomain: chartDateDomain
            )

            Divider()

            RatingsStorefrontList(rows: rows)

            Divider()

            Text("\(rows.count.formatted()) Countries")
                .font(.caption.weight(.semibold))
                .padding(.vertical, 10)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

private struct RatingsHistoryPanel: View {
    let historyPoints: [RatingHistoryPoint]
    @Binding var metric: RatingsMetric
    @Binding var timeFrame: RatingsTimeFrame
    let dateDomain: ClosedRange<Date>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RatingsMetricPicker(metric: $metric)

                Spacer()

                Text("Time Frame")
                    .font(.callout.weight(.semibold))

                Picker("Time Frame", selection: $timeFrame) {
                    ForEach(RatingsTimeFrame.allCases) { option in
                        Text(option.title)
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
            }

            if let dateDomain, !historyPoints.isEmpty {
                RatingsHistoryChart(
                    historyPoints: historyPoints,
                    metric: metric,
                    timeFrame: timeFrame,
                    dateDomain: dateDomain
                )
                .frame(height: 300)
                .padding(.horizontal, 10)
            } else {
                ContentUnavailableView(
                    "No Rating History",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Historical rating snapshots will appear after refreshes.")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
                .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }
}

private struct RatingsMetricPicker: View {
    @Binding var metric: RatingsMetric

    var body: some View {
        CustomSegmentedPicker(
            segments: RatingsMetric.allCases.map { option in
                CustomSegmentedPicker<RatingsMetric>.Segment(option.title, value: option)
            },
            selection: $metric
        )
    }
}

private struct RatingsSummaryMetrics: View {
    let totalRatingCount: Int
    let totalRatingCountTrend: Int?
    let averageRating: Double?
    let averageRatingTrend: Double?

    var body: some View {
        HStack(spacing: 36) {
            RatingsSummaryMetric(
                value: totalRatingCount.formatted(),
                trend: totalRatingCountTrend.formattedCountTrend,
                label: "Ratings"
            )
            RatingsSummaryMetric(
                value: averageRating.formattedRating,
                trend: averageRatingTrend.formattedRatingTrend,
                label: "Average Rating"
            )
        }
        .padding(.top, 26)
        .padding(.bottom, 18)
    }
}

private struct RatingsSummaryMetric: View {
    private static let layoutPlaceholderTrend = RatingTrendValue(
        direction: .up,
        value: "0"
    )

    let value: String
    let trend: RatingTrendValue?
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            RatingTrendLabel(
                trend: trend ?? Self.layoutPlaceholderTrend,
                font: .callout.weight(.semibold)
            )
            .opacity(trend == nil ? 0 : 1)
            .accessibilityHidden(trend == nil)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.title.bold())
                    .monospacedDigit()
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RatingsStorefrontList: View {
    let rows: [RatingsStorefrontRow]
    @State private var sortOrder = [
        KeyPathComparator(\RatingsStorefrontRow.ratingCountSortValue, order: .reverse)
    ]

    private var sortedRows: [RatingsStorefrontRow] {
        rows.sorted(using: sortOrder)
    }

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No Ratings",
                systemImage: "star",
                description: Text("Refresh app ratings to populate this view.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(sortedRows, sortOrder: $sortOrder) {
                TableColumn("Country", value: \.titleSortValue) { row in
                    RatingsCountryCell(row: row)
                }
                .width(min: 130, ideal: 150)

                TableColumn("Ratings", value: \.ratingCountSortValue) { row in
                    RatingsCountCell(row: row)
                }
                .width(min: 116, ideal: 126, max: 150)

                TableColumn("Average Rating", value: \.averageRatingSortValue) { row in
                    RatingsAverageRatingCell(row: row)
                }
                .width(min: 136, ideal: 146, max: 170)
            }
        }
    }
}

private struct RatingsCountryCell: View {
    let row: RatingsStorefrontRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.flagEmoji ?? "🌐")
                .frame(width: 22)

            Text(row.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
    }
}

private struct RatingsCountCell: View {
    let row: RatingsStorefrontRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.ratingCount?.formatted() ?? "-")
                .frame(width: 80, alignment: .trailing)
                .monospacedDigit()

            TrendText(trend: row.ratingCountTrend.formattedCountTrend)
                .frame(width: 42, alignment: .leading)

            Spacer(minLength: 0)
        }
        .font(.body)
    }
}

private struct RatingsAverageRatingCell: View {
    let row: RatingsStorefrontRow

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(row.averageRating.formattedRating)
                    .monospacedDigit()
                Image(systemName: "star.fill")
                    .foregroundStyle(.green)
            }
            .frame(alignment: .leading)

            TrendText(trend: row.averageRatingTrend.formattedRatingTrend)
                .frame(width: 50, alignment: .leading)

            Spacer(minLength: 0)
        }
        .font(.body)
    }
}

private struct TrendText: View {
    let trend: RatingTrendValue?

    var body: some View {
        if let trend {
            RatingTrendLabel(trend: trend, font: .callout.weight(.semibold))
        } else {
            Text("-")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RatingTrendLabel: View {
    let trend: RatingTrendValue
    let font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: trend.systemImage)
                .font(font)
            Text(trend.value)
                .font(font)
                .monospacedDigit()
        }
        .foregroundStyle(trend.color)
    }
}
