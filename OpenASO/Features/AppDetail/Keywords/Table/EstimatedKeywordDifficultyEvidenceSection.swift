import SwiftUI

struct EstimatedKeywordDifficultyEvidenceSection: View {
    let snapshot: EstimatedKeywordDifficultySnapshot

    var body: some View {
        GroupBox("Evidence") {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        LabeledContent("Results considered", value: snapshot.consideredResultCount.formatted())
                        LabeledContent("Results with ratings", value: snapshot.ratedResultCount.formatted())
                    }
                    GridRow {
                        LabeledContent(
                            "Weighted rating coverage",
                            value: "\(snapshot.weightedRatingCoveragePercentage)%"
                        )
                        LabeledContent(
                            "Rating authority",
                            value: scoreText(snapshot.ratingAuthorityScore)
                        )
                    }
                    GridRow {
                        LabeledContent(
                            "Metadata saturation",
                            value: scoreText(snapshot.metadataSaturationScore)
                        )
                        LabeledContent(
                            "Maximum rating count",
                            value: countText(snapshot.maximumRatingCount)
                        )
                    }
                    GridRow {
                        LabeledContent(
                            "Median rating count",
                            value: countText(snapshot.medianRatingCount)
                        )
                        LabeledContent(
                            "Exact phrase matches",
                            value: "\(snapshot.exactTitlePhraseMatchCount) title, \(snapshot.exactSubtitlePhraseMatchCount) subtitle"
                        )
                    }
                }

                Divider()

                if snapshot.resultEvidence.isEmpty {
                    Text("No individual ranking results were available for this calculation.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Ranking results used")
                        .font(.headline)

                    ForEach(snapshot.resultEvidence.indices, id: \.self) { index in
                        let evidence = snapshot.resultEvidence[index]
                        EstimatedKeywordDifficultyEvidenceRow(evidence: evidence)

                        if index < snapshot.resultEvidence.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private func scoreText(_ value: Int?) -> String {
        value.map { "\($0) / 100" } ?? "Not available"
    }

    private func countText(_ value: Int?) -> String {
        value?.formatted(.number) ?? "Not available"
    }
}

private struct EstimatedKeywordDifficultyEvidenceRow: View {
    let evidence: EstimatedKeywordDifficultyResultEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(evidence.position)")
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel("Rank \(evidence.position)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(evidence.title)
                        .font(.headline)
                    if let subtitle = evidence.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text("App ID \(evidence.appStoreID)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    evidenceLabels
                }

                VStack(alignment: .leading, spacing: 4) {
                    evidenceLabels
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var evidenceLabels: some View {
        Text("Ratings: \(countText(evidence.ratingCount))")
        Text("Authority: \(scoreText(evidence.ratingAuthorityScore))")
        Text("Title coverage: \(percentageText(evidence.titleTokenCoveragePercentage))")
        Text("Combined coverage: \(percentageText(evidence.combinedTokenCoveragePercentage))")
        Text("Metadata match: \(scoreText(evidence.metadataMatchScore))")
        if evidence.exactTitlePhraseMatch {
            Label("Exact title phrase", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        if evidence.exactSubtitlePhraseMatch {
            Label("Exact subtitle phrase", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func countText(_ value: Int?) -> String {
        value?.formatted(.number) ?? "Not available"
    }

    private func scoreText(_ value: Int?) -> String {
        value.map { "\($0) / 100" } ?? "Not available"
    }

    private func percentageText(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "Not available"
    }
}
