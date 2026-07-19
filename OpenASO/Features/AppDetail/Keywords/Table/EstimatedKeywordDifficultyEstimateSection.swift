import SwiftUI

struct EstimatedKeywordDifficultyEstimateSection: View {
    let snapshot: EstimatedKeywordDifficultySnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(isStale: snapshot.isStale(asOf: timeline.date))
        }
    }

    private func content(isStale: Bool) -> some View {
        GroupBox("Estimate") {
            VStack(alignment: .leading, spacing: 10) {
                switch snapshot.state {
                case .estimated:
                    if let score = snapshot.score,
                       let confidenceScore = snapshot.confidenceScore,
                       let confidence = snapshot.confidence {
                        LabeledContent("Estimated difficulty") {
                            Text(score, format: .number)
                                .monospacedDigit()
                            Text(" / 100")
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Confidence") {
                            Text(confidence.displayName)
                            Text("(\(confidenceScore) / 100)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        LabeledContent("Status", value: "Stored estimate is unavailable")
                    }
                case .unavailable:
                    if let unavailableReason = snapshot.unavailableReason {
                        LabeledContent("Status", value: "Unavailable")
                        LabeledContent("Reason", value: unavailableReason.displayName)
                        Text(unavailableReason.guidance)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LabeledContent("Status", value: "Stored estimate is unavailable")
                    }
                case nil:
                    LabeledContent("Status", value: "Stored estimate is unavailable")
                }

                Divider()

                LabeledContent("Evidence freshness") {
                    Label(
                        isStale ? "Stale" : "Current",
                        systemImage: isStale
                            ? "clock.badge.exclamationmark"
                            : "checkmark.circle.fill"
                    )
                    .foregroundStyle(isStale ? .orange : .green)
                }

                if isStale {
                    Text("Refresh this keyword to calculate a new estimate from current ranking evidence.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}
