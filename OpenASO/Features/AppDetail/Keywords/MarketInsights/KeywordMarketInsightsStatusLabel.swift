import SwiftUI

struct KeywordMarketInsightsStatusLabel: View {
    let status: KeywordMarketInsightsPresentation.Status

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .foregroundStyle(foregroundStyle)
            .accessibilityElement(children: .combine)
    }

    private var foregroundStyle: Color {
        switch status.kind {
        case .current:
            .green
        case .incomplete:
            .secondary
        case .failed:
            .orange
        case .unavailable:
            .red
        }
    }
}
