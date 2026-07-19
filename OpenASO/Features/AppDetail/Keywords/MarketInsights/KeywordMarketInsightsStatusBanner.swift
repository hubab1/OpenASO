import SwiftUI

struct KeywordMarketInsightsStatusBanner: View {
    let partialReasons: [KeywordMarketInsightsPartialReason]
    let staleMarketCount: Int

    var body: some View {
        if !partialReasons.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Partial market evidence", systemImage: "exclamationmark.circle")
                        .font(.headline)

                    ForEach(partialReasons, id: \.rawValue) { reason in
                        Label(
                            KeywordMarketInsightsPresentation.partialReasonTitle(reason),
                            systemImage: "circle.fill"
                        )
                        .labelStyle(PartialReasonLabelStyle())
                    }

                    if staleMarketCount > 0 {
                        Text(
                            KeywordMarketInsightsPresentation.staleResultDescription(
                                staleMarketCount
                            )
                        )
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PartialReasonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(.body, design: .default, weight: .black))
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            configuration.title
                .foregroundStyle(.secondary)
        }
    }
}
