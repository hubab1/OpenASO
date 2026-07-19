import SwiftUI

struct KeywordMarketInsightLiveDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: KeywordMarketInsightsModel
    let rowID: String

    var body: some View {
        if let row = model.snapshot?.rows.first(where: { $0.id == rowID }) {
            KeywordMarketInsightDetailSheet(row: row)
        } else {
            ContentUnavailableView {
                Label("Keyword Not in Current Page", systemImage: "arrow.clockwise.circle")
            } description: {
                Text(
                    "The refreshed first page does not contain this keyword. Return to the list and load additional pages to find its current saved evidence."
                )
            } actions: {
                Button("Done", action: dismiss.callAsFunction)
            }
            .frame(minWidth: 720, minHeight: 620)
        }
    }
}
