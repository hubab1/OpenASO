import SwiftData
import SwiftUI

struct EstimatedKeywordDifficultyDetailSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let keyword: String
    let queryKey: String
    let summary: EstimatedKeywordDifficultySummary?
    let fallbackStorefront: String
    let fallbackPlatform: AppPlatform
    let modelContext: ModelContext

    @State private var detailModel = EstimatedKeywordDifficultyDetailModel()
    @State private var retryToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated Difficulty")
                        .font(.title2.bold())
                    Text(keyword)
                        .font(.headline)
                    Text(scopeDescription)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            switch detailModel.state {
            case .idle, .loading:
                ProgressView("Loading estimated difficulty…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                ContentUnavailableView {
                    Label("No Estimated Difficulty Yet", systemImage: "gauge.with.dots.needle.0percent")
                } description: {
                    Text("Refresh this keyword to calculate a local estimate from its App Store ranking evidence.")
                } actions: {
                    Button("Try Again", action: retryLoading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let snapshot):
                EstimatedKeywordDifficultyDetailContent(snapshot: snapshot)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to Load Estimated Difficulty", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", action: retryLoading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: retryToken) {
            let dataSource = EstimatedKeywordDifficultyDetailDataSource.production(
                backgroundModelStore: services.backgroundModelStore,
                fallbackModelContext: modelContext
            )
            await detailModel.load(queryKey: queryKey, using: dataSource)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 620, idealHeight: 780)
    }

    var scopeDescription: String {
        let storefront = detailModel.snapshot?.storefront.uppercased()
            ?? summary?.storefront.uppercased()
            ?? fallbackStorefront
        let platform = detailModel.snapshot?.platform?.displayName
            ?? summary?.platform?.displayName
            ?? fallbackPlatform.displayName
        return "\(storefront) · \(platform)"
    }

    private func retryLoading() {
        retryToken &+= 1
    }
}
