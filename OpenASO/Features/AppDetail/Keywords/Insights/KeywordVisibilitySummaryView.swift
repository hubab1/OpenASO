import SwiftUI

struct KeywordVisibilitySummaryView: View {
    let summary: KeywordInsightsSummary

    var body: some View {
        HStack(spacing: 12) {
            KeywordSummaryCard(title: "Average Rank") {
                AverageRankSummaryCard(summary: summary)
            }

            KeywordSummaryCard(title: "Keyword Distribution") {
                KeywordDistributionCard(summary: summary)
            }

            KeywordSummaryCard(title: "Keyword Movement") {
                KeywordMovementSummaryCard(summary: summary)
            }
        }
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

private struct KeywordSummaryCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }
}

private struct AverageRankSummaryCard: View {
    let summary: KeywordInsightsSummary

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(formattedAverageRank)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                TrendPill(value: summary.averageRankDelta)
            }
            .frame(minWidth: 110, alignment: .leading)

            Divider()
                .frame(height: 42)

            MiniMetric(label: "High", value: summary.highRankCount.formatted())

            Divider()
                .frame(height: 42)

            MiniMetric(label: "Low", value: summary.lowRankCount.formatted())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formattedAverageRank: String {
        guard let averageRank = summary.averageRank else { return "-" }
        return averageRank.formatted(.number.precision(.fractionLength(0...1)))
    }
}

private struct KeywordDistributionCard: View {
    let summary: KeywordInsightsSummary

    private var maxCount: Int {
        [summary.top5Count, summary.top25Count, summary.top100Count, summary.outsideTop100Count, 1].max() ?? 1
    }

    var body: some View {
        if summary.seriesCount == 0 {
            KeywordChartEmptyState()
        } else {
            HStack(alignment: .bottom, spacing: 18) {
                DistributionBar(
                    label: "TOP 5",
                    value: summary.top5Count,
                    maxValue: maxCount,
                    color: .indigo
                )
                DistributionBar(
                    label: "TOP 25",
                    value: summary.top25Count,
                    maxValue: maxCount,
                    color: .indigo
                )
                DistributionBar(
                    label: "TOP 100",
                    value: summary.top100Count,
                    maxValue: maxCount,
                    color: .indigo
                )
                DistributionBar(
                    label: "> 100",
                    value: summary.outsideTop100Count,
                    maxValue: maxCount,
                    color: .secondary
                )
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .bottom)
        }
    }
}

private struct KeywordMovementSummaryCard: View {
    let summary: KeywordInsightsSummary

    var body: some View {
        if summary.seriesCount == 0 {
            KeywordChartEmptyState()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 20) {
                    MovementMetric(label: "Improved", value: summary.improvedCount, color: .green, systemImage: "arrow.up")
                    MovementMetric(label: "Declined", value: summary.declinedCount, color: .red, systemImage: "arrow.down")
                    MovementMetric(label: "Unchanged", value: summary.unchangedCount, color: .secondary, systemImage: nil)
                }

                MovementStackedBar(
                    improved: summary.improvedCount,
                    declined: summary.declinedCount,
                    unchanged: summary.unchangedCount
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MiniMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .center, spacing: 7) {
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 58, alignment: .leading)
    }
}

private struct TrendPill: View {
    let value: Double?

    var body: some View {
        if let value {
            HStack(spacing: 1) {
                Image(systemName: value < 0 ? "arrow.down" : "arrow.up")
                    .font(.caption2.weight(.bold))

                Text(abs(value).formatted(.number.precision(.fractionLength(0...1))))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            }
            .foregroundStyle(value < 0 ? .red : .green)
        }
    }
}

private struct DistributionBar: View {
    let label: String
    let value: Int
    let maxValue: Int
    let color: Color

    private var normalizedValue: CGFloat {
        guard maxValue > 0 else { return 0 }
        return CGFloat(value) / CGFloat(maxValue)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(value.formatted())
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(value == 0 ? 0.18 : 0.72))
                .frame(width: 44, height: Swift.max(1, 22 * normalizedValue))

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 58, alignment: .bottom)
    }
}

private struct MovementMetric: View {
    let label: String
    let value: Int
    let color: Color
    let systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                }

                Text(value.formatted())
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(color)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 74, alignment: .leading)
    }
}

private struct MovementStackedBar: View {
    let improved: Int
    let declined: Int
    let unchanged: Int

    private var total: Int {
        max(improved + declined + unchanged, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.green)
                    .frame(width: proxy.size.width * CGFloat(improved) / CGFloat(total))

                Rectangle()
                    .fill(.red)
                    .frame(width: proxy.size.width * CGFloat(declined) / CGFloat(total))

                Rectangle()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: proxy.size.width * CGFloat(unchanged) / CGFloat(total))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyword movement")
    }
}

private struct KeywordChartEmptyState: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(height: 1)

            Text("No history")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .background(.background)
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No chart history")
    }
}

#Preview("Keyword Charts - No Data") {
    KeywordVisibilitySummaryPreviewSurface(summary: .empty)
}

#Preview("Keyword Charts - One Day") {
    KeywordVisibilitySummaryPreviewSurface(summary: .oneDay)
}

#Preview("Keyword Charts - Little Data") {
    KeywordVisibilitySummaryPreviewSurface(summary: .littleData)
}

#Preview("Keyword Charts - Weeks") {
    KeywordVisibilitySummaryPreviewSurface(summary: .weeks)
}

#Preview("Keyword Charts - Months") {
    KeywordVisibilitySummaryPreviewSurface(summary: .months)
}

private struct KeywordVisibilitySummaryPreviewSurface: View {
    let summary: KeywordInsightsSummary

    var body: some View {
        KeywordVisibilitySummaryView(summary: summary)
            .padding(24)
            .frame(width: 940)
    }
}

extension KeywordInsightsSummary {
    static let oneDay = KeywordInsightsSummary(dataset: .preview(series: .previewSeries(days: 1, keywordCount: 6, cadence: .steadyGain)))
    static let littleData = KeywordInsightsSummary(dataset: .preview(series: .previewSeries(days: 3, keywordCount: 6, cadence: .mixed)))
    static let weeks = KeywordInsightsSummary(dataset: .preview(series: .previewSeries(days: 21, keywordCount: 10, cadence: .steadyGain)))
    static let months = KeywordInsightsSummary(dataset: .preview(series: .previewSeries(days: 90, keywordCount: 12, cadence: .mixed)))
}

private extension KeywordInsightsDataset {
    static func preview(series: [KeywordInsightSeries]) -> KeywordInsightsDataset {
        KeywordInsightsDataset(appStoreID: 123_456_789, series: series, source: .local)
    }
}

private extension Array where Element == KeywordInsightSeries {
    static func previewSeries(
        days: Int,
        keywordCount: Int,
        cadence: KeywordPreviewCadence
    ) -> [KeywordInsightSeries] {
        (0..<keywordCount).map { keywordIndex in
            KeywordInsightSeries(
                queryKey: "keyword-\(keywordIndex)",
                keyword: "Keyword \(keywordIndex + 1)",
                storefront: "us",
                platform: .iphone,
                points: .previewPoints(days: days, keywordIndex: keywordIndex, cadence: cadence)
            )
        }
    }
}

private extension Array where Element == KeywordInsightPoint {
    static func previewPoints(
        days: Int,
        keywordIndex: Int,
        cadence: KeywordPreviewCadence
    ) -> [KeywordInsightPoint] {
        guard days > 0 else { return [] }

        let calendar = Calendar(identifier: .gregorian)
        let endDate = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 795_052_800))
        let startDate = calendar.date(byAdding: .day, value: 1 - days, to: endDate) ?? endDate
        let popularity = Swift.max(18, Swift.min(96, 82 - (keywordIndex * 5)))

        return (0..<days).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: dayOffset, to: startDate) ?? startDate
            let rank = KeywordPreviewCadence.rank(
                dayOffset: dayOffset,
                keywordIndex: keywordIndex,
                days: days,
                cadence: cadence
            )

            return KeywordInsightPoint(
                date: date,
                observedAt: date.addingTimeInterval(TimeInterval(keywordIndex * 60)),
                rank: rank,
                resultCount: 80,
                popularityScore: popularity,
                confidence: "preview"
            )
        }
    }
}

private enum KeywordPreviewCadence {
    case steadyGain
    case mixed

    static func rank(
        dayOffset: Int,
        keywordIndex: Int,
        days: Int,
        cadence: KeywordPreviewCadence
    ) -> Int {
        let baseRank = 8 + (keywordIndex * 3)
        let progress = days > 1 ? Double(dayOffset) / Double(days - 1) : 0

        let movement = switch cadence {
        case .steadyGain:
            -Int((progress * Double(6 + keywordIndex % 4)).rounded())
        case .mixed:
            mixedMovement(dayOffset: dayOffset, keywordIndex: keywordIndex, progress: progress)
        }

        return Swift.max(1, Swift.min(60, baseRank + movement))
    }

    private static func mixedMovement(dayOffset: Int, keywordIndex: Int, progress: Double) -> Int {
        let direction = keywordIndex.isMultiple(of: 3) ? 1 : -1
        let drift = Int((progress * Double(5 + keywordIndex % 5)).rounded()) * direction
        let wave = ((dayOffset + keywordIndex) % 5) - 2
        return drift + wave
    }
}
