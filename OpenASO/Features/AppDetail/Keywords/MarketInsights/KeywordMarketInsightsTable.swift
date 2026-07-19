import SwiftUI

struct KeywordMarketInsightsTable: View {
    let rows: [KeywordMarketInsightsPresentation.KeywordRow]
    let showDetails: (KeywordMarketInsightsPresentation.KeywordRow) -> Void

    var body: some View {
        Table(rows) {
            TableColumn("Keyword") { row in
                Button(row.keyword) {
                    showDetails(row)
                }
                .buttonStyle(.plain)
                .help("View country evidence for \(row.keyword)")
            }
            .width(min: 150, ideal: 220)

            TableColumn("Coverage") { row in
                Text(
                    KeywordMarketInsightsPresentation.coverageDescription(
                        available: row.availableEvidenceCount,
                        requested: row.requestedMarketCount
                    )
                )
                    .accessibilityLabel(
                        KeywordMarketInsightsPresentation.coverageAccessibilityDescription(
                            available: row.availableEvidenceCount,
                            requested: row.requestedMarketCount
                        )
                    )
            }
            .width(min: 80, ideal: 100)

            TableColumn("Best") { row in
                RankSummaryText(summary: row.bestMarket)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Worst") { row in
                RankSummaryText(summary: row.worstMarket)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Average") { row in
                if let averageRank = row.averageRank {
                    Text(averageRank, format: .number.precision(.fractionLength(1)))
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unavailable")
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Spread") { row in
                if let rankSpread = row.rankSpread {
                    Text(rankSpread, format: .number)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unavailable")
                }
            }
            .width(min: 60, ideal: 75)

            TableColumn("Fresh ranks") { row in
                Text(row.freshRankedMarketCount, format: .number)
            }
            .width(min: 75, ideal: 90)

            TableColumn("Status") { row in
                KeywordMarketInsightsStatusLabel(status: row.status)
            }
            .width(min: 120, ideal: 150)

            TableColumn("") { row in
                Button("View Details", systemImage: "info.circle") {
                    showDetails(row)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("View Details")
            }
            .width(36)
        }
    }
}

private struct RankSummaryText: View {
    let summary: KeywordMarketInsightRankSummary?

    var body: some View {
        if let summary {
            Text("#\(summary.rank) · \(summary.storefront.uppercased())")
                .accessibilityLabel(
                    "Rank \(summary.rank) in \(summary.storefront.uppercased())"
                )
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Unavailable")
        }
    }
}
