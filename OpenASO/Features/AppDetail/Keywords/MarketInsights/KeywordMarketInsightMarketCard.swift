import SwiftUI

struct KeywordMarketInsightMarketCard: View {
    let row: KeywordMarketInsightsPresentation.MarketRow

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.storefront)
                        .font(.headline)
                    Spacer()
                    KeywordMarketInsightsStatusLabel(status: row.status)
                }

                if let searchedAt = row.rankingSearchedAt,
                   let source = row.rankingSource,
                   let resultCount = row.resultCount {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            Text("Saved rank")
                                .foregroundStyle(.secondary)
                            if let rank = row.rank {
                                Text("#\(rank)")
                            } else {
                                Text("Not ranked")
                            }
                        }
                        GridRow {
                            Text("Ranking source")
                                .foregroundStyle(.secondary)
                            Text(source.displayName)
                        }
                        GridRow {
                            Text("Searched")
                                .foregroundStyle(.secondary)
                            Text(
                                searchedAt,
                                format: .dateTime.year().month().day().hour().minute()
                            )
                        }
                        GridRow {
                            Text("Results sampled")
                                .foregroundStyle(.secondary)
                            Text(resultCount, format: .number)
                        }
                    }
                } else {
                    Text(noEvidenceDescription)
                        .foregroundStyle(.secondary)
                }

                if row.isStale {
                    Label(
                        "Saved ranking evidence is at least 24 hours old.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }

                if row.requiresUnconfirmedEvidenceNotice {
                    Label(
                        "Bounded reads could not prove the current state. Any rank shown above is saved, unconfirmed evidence.",
                        systemImage: "questionmark.circle"
                    )
                    .foregroundStyle(.red)
                }

                if row.market.isPartial
                    && !row.isStale
                    && !row.requiresUnconfirmedEvidenceNotice {
                    Label("This country has partial evidence.", systemImage: "circle.lefthalf.filled")
                        .foregroundStyle(.secondary)
                }

                if let failure = row.failure {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Latest ranking refresh failed", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(failure.updatedAt, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                        Text(failure.message)
                            .textSelection(.enabled)
                        if row.hasCachedEvidenceAfterFailure {
                            Text("The rank above is cached evidence from the last successful refresh.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let difficulty = row.difficulty {
                    Divider()
                    KeywordMarketInsightDifficultySection(difficulty: difficulty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noEvidenceDescription: String {
        switch row.market.state {
        case .notTracked:
            "This keyword is not tracked in this country."
        case .neverRefreshed:
            "This tracked keyword has no saved ranking refresh yet."
        case .failedWithoutEvidence:
            "The refresh failed before any ranking evidence was saved."
        case .unavailable:
            "Bounded reads could not prove the current ranking state."
        case .ranked, .notRanked, .failedWithCachedEvidence:
            "No saved ranking evidence is available."
        }
    }
}
