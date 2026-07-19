import SwiftUI

struct KeywordMarketInsightSummaryCard: View {
    let row: KeywordMarketInsightsPresentation.KeywordRow

    var body: some View {
        GroupBox("Cross-market summary") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    Text("Ranking evidence")
                        .foregroundStyle(.secondary)
                    Text(
                        KeywordMarketInsightsPresentation.coverageDescription(
                            available: row.availableEvidenceCount,
                            requested: row.requestedMarketCount
                        )
                    )
                }
                GridRow {
                    Text("Best market")
                        .foregroundStyle(.secondary)
                    RankSummaryValue(summary: row.bestMarket)
                }
                GridRow {
                    Text("Worst market")
                        .foregroundStyle(.secondary)
                    RankSummaryValue(summary: row.worstMarket)
                }
                GridRow {
                    Text("Average rank")
                        .foregroundStyle(.secondary)
                    if let averageRank = row.averageRank {
                        Text(averageRank, format: .number.precision(.fractionLength(1)))
                    } else {
                        Text("Unavailable")
                    }
                }
                GridRow {
                    Text("Rank spread")
                        .foregroundStyle(.secondary)
                    if let rankSpread = row.rankSpread {
                        Text(rankSpread, format: .number)
                    } else {
                        Text("Unavailable")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RankSummaryValue: View {
    let summary: KeywordMarketInsightRankSummary?

    var body: some View {
        if let summary {
            Text("#\(summary.rank) in \(summary.storefront.uppercased())")
        } else {
            Text("Unavailable")
        }
    }
}
