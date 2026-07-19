import SwiftUI

struct KeywordMarketInsightDifficultySection: View {
    let difficulty: KeywordMarketInsightsPresentation.Difficulty

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated difficulty")
                    .font(.headline)
                Spacer()
                Text(difficulty.summary)
            }

            if let confidenceScore = difficulty.confidenceScore {
                LabeledContent("Confidence score") {
                    Text("\(confidenceScore) out of 100")
                }
            }

            LabeledContent("Estimation source") {
                Text(difficulty.estimationSourceDisplayName)
            }
            LabeledContent("Algorithm") {
                Text("\(difficulty.algorithmIdentifier) · version \(difficulty.algorithmVersion)")
                    .textSelection(.enabled)
            }
            LabeledContent("Ranking source") {
                Text(difficulty.rankingSourceDisplayName)
            }
            LabeledContent("Ranking evidence fetched") {
                Text(
                    difficulty.rankingFetchedAt,
                    format: .dateTime.year().month().day().hour().minute()
                )
            }
            LabeledContent("Estimate computed") {
                Text(
                    difficulty.computedAt,
                    format: .dateTime.year().month().day().hour().minute()
                )
            }

            if difficulty.isStale {
                Label(
                    "The estimate is based on stale ranking evidence.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .foregroundStyle(.orange)
            }

            Text("This is a local heuristic, not an Apple-provided difficulty metric.")
                .foregroundStyle(.secondary)
        }
    }
}
