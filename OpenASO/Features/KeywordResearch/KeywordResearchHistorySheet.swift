import SwiftUI

struct KeywordResearchHistoryContext: Identifiable {
    struct ID: Hashable {
        let projectGeneration: KeywordResearchProjectGeneration
        let keywordGeneration: KeywordResearchKeywordGeneration
    }

    let projectGeneration: KeywordResearchProjectGeneration
    let keyword: KeywordResearchKeywordSnapshot

    var id: ID {
        ID(
            projectGeneration: projectGeneration,
            keywordGeneration: keyword.generation
        )
    }
}

struct KeywordResearchHistorySheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var model: KeywordResearchHistoryModel
    @State private var selectedObservationID: String?

    init(model: KeywordResearchHistoryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationSplitView {
            historySidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            observationDetail
        }
        .navigationTitle("Shared Search History")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Reload History", systemImage: "arrow.clockwise") {
                    Task { await reloadHistory() }
                }
                .labelStyle(.iconOnly)
                .help("Reload Shared Search History")
                .disabled(model.loadState.isLoading)

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .task(id: services.backgroundModelStoreRevision) {
            model.cancelLoading()
            await reloadHistory()
        }
        .onDisappear {
            model.cancelLoading()
        }
        .onChange(of: model.observations) {
            reconcileSelection()
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var selectedObservation: KeywordResearchRankingObservationSnapshot? {
        guard let selectedObservationID else { return nil }
        return model.observations.first { $0.id == selectedObservationID }
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyHeader
            Divider()

            if model.observations.isEmpty {
                emptyHistoryState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedObservationID) {
                    ForEach(model.observations) { observation in
                        KeywordResearchHistoryObservationRow(observation: observation)
                            .tag(observation.id)
                    }
                }

                historyFooter
            }
        }
        .background(.background)
    }

    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.keyword.term)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(2)
            Text(
                "\(model.keyword.storefront.uppercased()) · "
                    + model.keyword.platform.displayName
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(KeywordResearchHistoryPresentation.evidenceExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilitySummary)
        .accessibilityHint(
            "Positions describe returned apps in shared search result sets."
        )
    }

    @ViewBuilder
    private var emptyHistoryState: some View {
        switch model.loadState {
        case .idle, .loading, .loadingNextPage:
            ProgressView("Loading shared search history…")
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") {
                    Task { await retryFailedLoad() }
                }
            }
            .accessibilityLabel(error.accessibilityLabel)
        case .loaded:
            ContentUnavailableView {
                Label("No Shared Search History", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(
                    "Refresh Search Evidence for this keyword to capture its first shared "
                        + "App Store search observation."
                )
            }
        }
    }

    @ViewBuilder
    private var historyFooter: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    KeywordResearchHistoryPresentation.loadedObservationsDescription(
                        model.observations.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if case .failed(let error) = model.loadState {
                KeywordResearchStatusRow(
                    title: error.title,
                    message: error.message,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Try Again"
                ) {
                    Task { await retryFailedLoad() }
                }
                .accessibilityLabel(error.accessibilityLabel)
            } else if model.requiresReload {
                KeywordResearchStatusRow(
                    title: "History changed",
                    message: "Reload before loading more observations.",
                    systemImage: "arrow.clockwise",
                    actionTitle: "Reload"
                ) {
                    Task { await reloadHistory() }
                }
            } else if model.loadState == .loadingNextPage {
                ProgressView("Loading more observations…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            } else if model.loadState == .loading {
                ProgressView("Reloading shared search history…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            } else if model.hasMoreObservations {
                Button("Load More Observations") {
                    Task { await model.loadNextPage() }
                }
                .frame(maxWidth: .infinity)
                .padding(10)
            } else {
                Spacer().frame(height: 8)
            }
        }
    }

    @ViewBuilder
    private var observationDetail: some View {
        if let observation = selectedObservation {
            KeywordResearchHistoryObservationDetail(observation: observation)
        } else if model.observations.isEmpty {
            emptyHistoryState
        } else {
            ContentUnavailableView(
                "Select a Shared Observation",
                systemImage: "list.bullet.rectangle",
                description: Text(
                    "Choose a capture to inspect the App Store results and their positions."
                )
            )
        }
    }

    private func reloadHistory() async {
        await model.reload()
        reconcileSelection()
    }

    private func retryFailedLoad() async {
        await model.retryFailedLoad()
        reconcileSelection()
    }

    private func reconcileSelection() {
        selectedObservationID = KeywordResearchHistorySelection.reconciled(
            selectedObservationID,
            observations: model.observations
        )
    }
}

enum KeywordResearchHistorySelection {
    static func reconciled(
        _ selection: String?,
        observations: [KeywordResearchRankingObservationSnapshot]
    ) -> String? {
        guard let selection else { return observations.first?.id }
        return observations.contains { $0.id == selection } ? selection : nil
    }
}

enum KeywordResearchHistoryPresentation {
    static let evidenceExplanation =
        "Each entry is shared search-result evidence for this exact keyword, storefront, "
        + "and platform. Positions belong to returned apps; no rank is assigned to the "
        + "research project."

    static func reportedResultsDescription(_ count: Int) -> String {
        count == 1 ? "1 reported result" : "\(count) reported results"
    }

    static func retainedRowsDescription(_ count: Int) -> String {
        count == 1 ? "1 retained result row" : "\(count) retained result rows"
    }

    static func loadedObservationsDescription(_ count: Int) -> String {
        count == 1 ? "1 shared observation loaded" : "\(count) shared observations loaded"
    }

    static func accessibilityLabel(
        for observation: KeywordResearchRankingObservationSnapshot
    ) -> String {
        [
            "Shared search observation for \(observation.term)",
            observation.observedAt.formatted(date: .abbreviated, time: .shortened),
            reportedResultsDescription(observation.resultCount),
            retainedRowsDescription(observation.items.count),
            "source \(observation.source.displayName)",
        ].joined(separator: ", ")
    }
}

private struct KeywordResearchHistoryObservationRow: View {
    let observation: KeywordResearchRankingObservationSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(observation.observedAt.formatted(date: .abbreviated, time: .shortened))
                .fontWeight(.medium)
            Text(
                KeywordResearchHistoryPresentation.reportedResultsDescription(
                    observation.resultCount
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(observation.source.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            KeywordResearchHistoryPresentation.accessibilityLabel(for: observation)
        )
    }
}

private struct KeywordResearchHistoryObservationDetail: View {
    let observation: KeywordResearchRankingObservationSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            observationHeader
            Divider()

            if observation.items.isEmpty {
                emptyResultState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultTable
            }
        }
    }

    private var observationHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(observation.observedAt.formatted(date: .long, time: .shortened))
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                Label(
                    KeywordResearchHistoryPresentation.reportedResultsDescription(
                        observation.resultCount
                    ),
                    systemImage: "magnifyingglass"
                )
                Label(
                    KeywordResearchHistoryPresentation.retainedRowsDescription(
                        observation.items.count
                    ),
                    systemImage: "list.number"
                )
                Label(observation.source.displayName, systemImage: "network")
            }
            .font(.callout)

            Text(
                "The positions below belong to returned App Store apps. They are not a "
                    + "position for this pre-live research project."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            KeywordResearchHistoryPresentation.accessibilityLabel(for: observation)
        )
        .accessibilityHint(
            "Positions belong to returned App Store apps, not to the research project."
        )
    }

    private var emptyResultState: some View {
        ContentUnavailableView {
            Label("No Retained Result Rows", systemImage: "list.number")
        } description: {
            if observation.resultCount == 0 {
                Text("This shared App Store search observation reported no results.")
            } else {
                Text(
                    "This observation reports results but has no retained app rows to display."
                )
            }
        }
    }

    private var resultTable: some View {
        Table(observation.items) {
            TableColumn("Position") { item in
                Text(item.position.formatted())
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80, max: 90)

            TableColumn("App") { item in
                KeywordResearchHistoryAppCell(item: item)
            }
            .width(min: 260, ideal: 340)

            TableColumn("Seller") { item in
                Text(KeywordResearchHistoryAppCell.sellerName(for: item))
                    .lineLimit(2)
            }
            .width(min: 180, ideal: 240)

            TableColumn("App Store ID") { item in
                Text(String(item.appStoreID))
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            .width(min: 110, ideal: 130, max: 150)
        }
    }
}

private struct KeywordResearchHistoryAppCell: View {
    let item: KeywordResearchRankingItemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .fontWeight(.medium)
                .lineLimit(2)
            if let detail = Self.secondaryDetail(for: item) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [
            "Returned app position \(item.position)",
            item.name,
        ]
        if let detail = Self.secondaryDetail(for: item) {
            parts.append(detail)
        }
        parts.append("by \(Self.sellerName(for: item))")
        return parts.joined(separator: ", ")
    }

    static func sellerName(for item: KeywordResearchRankingItemSnapshot) -> String {
        normalized(item.sellerName) ?? "Unknown seller"
    }

    private static func secondaryDetail(
        for item: KeywordResearchRankingItemSnapshot
    ) -> String? {
        normalized(item.subtitle) ?? normalized(item.bundleID)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
