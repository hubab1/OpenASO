import SwiftUI

struct KeywordRankingListLoadStatusView: View {
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        if isLoading {
            ProgressView("Updating ranking apps…")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
                .padding(16)
        } else if let errorMessage {
            HStack(spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)

                Button("Try Again", action: retry)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .padding(16)
        }
    }
}
