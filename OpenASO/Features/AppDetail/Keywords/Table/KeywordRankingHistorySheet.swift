import SwiftData
import SwiftUI

struct KeywordRankingHistorySheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let row: KeywordWorkspaceRow
    let modelContext: ModelContext

    @State private var timeframe: TrendDateRange = .last30Days
    @State private var historyModel = KeywordRankingHistoryModel()
    @State private var projectionReferenceDate = Date.now
    @State private var retryToken = 0

    private var historyLoadID: String {
        "\(row.track.identityKey)::\(retryToken)"
    }

    private var storefrontMetadataText: String {
        let code = row.track.storefront.uppercased()
        guard let storefront = row.storefront else {
            return code
        }

        if !storefront.flagEmoji.isEmpty {
            return "\(storefront.flagEmoji) \(storefront.name) (\(code))"
        }

        return "\(storefront.name) (\(code))"
    }

    var body: some View {
        let projection = KeywordRankingHistoryProjection(
            observations: historyModel.observations ?? [],
            timeframe: timeframe,
            now: projectionReferenceDate,
            calendar: .autoupdatingCurrent
        )

        VStack(spacing: 0) {
            header

            Divider()

            chartContent(projection: projection)
                .padding(24)

            Divider()

            footer(projection: projection)
        }
        .frame(minWidth: 760, minHeight: 440)
        .task(id: historyLoadID) {
            await loadHistory()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ranking History")
                .font(.title2)
                .bold()

            Spacer()

            Picker("Timeframe", selection: $timeframe) {
                ForEach(TrendDateRange.allCases) { range in
                    Text(range.compactTitle)
                        .accessibilityLabel(range.title)
                        .tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .accessibilityLabel("Ranking history timeframe")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func chartContent(projection: KeywordRankingHistoryProjection) -> some View {
        if let loadErrorMessage = historyModel.errorMessage {
            ContentUnavailableView {
                Label("Unable to Load Ranking History", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadErrorMessage)
            } actions: {
                Button("Try Again", action: retryLoading)
            }
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300)
        } else if historyModel.observations == nil {
            ProgressView("Loading ranking history…")
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300)
        } else {
            KeywordRankingHistoryChartView(
                projection: projection,
                height: 300
            )
        }
    }

    private func footer(projection: KeywordRankingHistoryProjection) -> some View {
        let observationStatusText = observationStatusText(projection: projection)

        return HStack(spacing: 16) {
            metadataText("Keyword", row.track.term)
            metadataText("Store", storefrontMetadataText)
            metadataText("Platform", row.track.platform.displayName)

            Spacer()

            Text(observationStatusText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(observationStatusText)

            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.defaultAction)
        }
        .font(.callout)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func observationStatusText(projection: KeywordRankingHistoryProjection) -> String {
        if historyModel.errorMessage != nil {
            return "History unavailable"
        }

        guard historyModel.observations != nil else {
            return "Loading observations"
        }

        return projection.observationSummaryText
    }

    private func metadataText(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(title):")
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func loadHistory() async {
        projectionReferenceDate = .now
        let dataSource = KeywordRankingHistoryDataSource.production(
            backgroundModelStore: services.backgroundModelStore,
            fallbackModelContext: modelContext
        )
        await historyModel.load(
            queryKey: row.track.queryKey,
            appStoreID: row.track.appStoreID,
            using: dataSource
        )
    }

    private func retryLoading() {
        retryToken += 1
    }
}
