import SwiftUI

struct EstimatedKeywordDifficultyCell: View {
    let keyword: String
    let summary: EstimatedKeywordDifficultySummary?
    let asOf: Date
    let showDetails: () -> Void

    private var presentation: EstimatedKeywordDifficultyRowPresentation {
        EstimatedKeywordDifficultyRowPresentation(summary: summary, asOf: asOf)
    }

    var body: some View {
        Button(action: showDetails) {
            HStack(spacing: 6) {
                switch presentation.state {
                case .missing:
                    Label("Not estimated", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                case .estimated(let score, _, let confidence, let isStale):
                    MetricBarView(
                        value: score,
                        maxValue: 100,
                        colorScale: .lowGreenHighRed,
                        placeholder: "-"
                    )

                    Text(confidence.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                case .unavailable(_, let isStale):
                    Label("Unavailable", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)

                    if isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                case .unsupported(let isStale):
                    Label("Unavailable", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)

                    if isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show estimated difficulty details")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated difficulty for \(keyword)")
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint("Opens the local estimate, provenance, and ranking evidence.")
    }
}
