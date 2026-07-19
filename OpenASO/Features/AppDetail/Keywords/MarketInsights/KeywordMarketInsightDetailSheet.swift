import SwiftUI

struct KeywordMarketInsightDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let row: KeywordMarketInsightsPresentation.KeywordRow

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.keyword)
                        .font(.title2.bold())
                    Text("Market ranking evidence · \(row.platform.displayName)")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    KeywordMarketInsightSummaryCard(row: row)

                    ForEach(row.markets) { market in
                        KeywordMarketInsightMarketCard(row: market)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 620, idealHeight: 780)
    }
}
