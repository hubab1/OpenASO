import Charts
import SwiftUI

struct KeywordRankingHistoryChartView: View {
    let projection: KeywordRankingHistoryProjection
    let height: Double

    var body: some View {
        Group {
            if projection.totalObservationCount == 0 {
                ContentUnavailableView(
                    "No Ranking History",
                    systemImage: "chart.xyaxis.line",
                    description: Text("No ranking observations were captured in this timeframe.")
                )
            } else if projection.rankedObservationCount == 0 {
                ContentUnavailableView(
                    "Not Ranked in This Timeframe",
                    systemImage: "chart.line.downtrend.xyaxis",
                    description: Text(notRankedDescription)
                )
            } else if let dateDomain = projection.dateDomain {
                Chart {
                    ForEach(projection.chartSegments) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Rank", point.rank),
                                series: .value("Ranked segment", segment.id)
                            )
                            .interpolationMethod(.linear)
                            .lineStyle(
                                StrokeStyle(
                                    lineWidth: 2,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                            .foregroundStyle(Color.accentColor)

                            if projection.showsPointMarks(for: segment) {
                                PointMark(
                                    x: .value("Date", point.date),
                                    y: .value("Rank", point.rank)
                                )
                                .symbolSize(18)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .chartXScale(domain: dateDomain)
                .chartYScale(domain: projection.yScaleDomain)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: projection.yAxisValues) { value in
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
                        .clipShape(.rect(cornerRadius: 6))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Keyword ranking history chart")
                .accessibilityValue(projection.accessibilitySummary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }

    private var notRankedDescription: String {
        let count = projection.totalObservationCount
        let observationLabel = count == 1 ? "observation" : "observations"
        return "OpenASO checked \(count) \(observationLabel) but did not find this app in the captured results."
    }
}
