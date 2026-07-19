import SwiftUI

struct KeywordMarketInsightsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services

    let context: KeywordMarketInsightsSheetContext
    let refreshToken: Int
    let dataSource: KeywordMarketInsightsDataSource

    @State private var model = KeywordMarketInsightsModel()
    @State private var retryToken = 0
    @State private var paginationToken = 0
    @State private var selectedRow: KeywordMarketInsightSelection?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: loadID) {
            guard let scope = context.scope else { return }
            await model.load(scope: scope, using: dataSource)
        }
        .task(id: paginationToken) {
            guard paginationToken > 0 else { return }
            await model.loadNextPage(using: dataSource)
        }
        .sheet(item: $selectedRow) { selection in
            KeywordMarketInsightLiveDetailSheet(
                model: model,
                rowID: selection.id
            )
        }
        .frame(minWidth: 980, idealWidth: 1_180, minHeight: 660, idealHeight: 820)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Market Insights")
                    .font(.title2.bold())
                Text(context.appName)
                    .font(.headline)
                Text("Saved cross-country ranking evidence; no network requests are made.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Reload", systemImage: "arrow.clockwise", action: retryLoading)
                .disabled(context.scope == nil)

            Button("Done", action: dismiss.callAsFunction)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if let scope = context.scope {
            VStack(alignment: .leading, spacing: 14) {
                KeywordMarketInsightsScopeBar(
                    appStoreID: scope.appStoreID,
                    platform: scope.platform,
                    storefronts: scope.storefronts
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)

                loadedContent
            }
        } else {
            VStack(spacing: 14) {
                KeywordMarketInsightsScopeBar(
                    appStoreID: context.appStoreID,
                    platform: context.platform,
                    storefronts: []
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)

                ContentUnavailableView {
                    Label("No Countries in This Scope", systemImage: "globe.badge.chevron.backward")
                } description: {
                    Text(
                        context.scopeIssue
                            ?? "No tracked countries are available for \(context.platform.displayName)."
                    )
                } actions: {
                    Button("Done", action: dismiss.callAsFunction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let snapshot = model.snapshot {
            if !snapshot.partialReasons.isEmpty {
                KeywordMarketInsightsStatusBanner(
                    partialReasons: snapshot.partialReasons,
                    staleMarketCount: snapshot.staleMarketCount
                )
                .padding(.horizontal, 20)
            }

            if let errorMessage = model.errorMessage {
                loadErrorBanner(
                    title: "Unable to refresh market insights",
                    message: errorMessage,
                    retry: retryLoading
                )
                .padding(.horizontal, 20)
            }

            if snapshot.rows.isEmpty {
                ContentUnavailableView {
                    Label("No Market Insights", systemImage: "globe")
                } description: {
                    Text("No tracked keywords were found in this concrete platform and country scope.")
                } actions: {
                    Button("Reload", systemImage: "arrow.clockwise", action: retryLoading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                KeywordMarketInsightsTable(
                    rows: snapshot.rows,
                    showDetails: showDetails
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                paginationFooter(snapshot: snapshot)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label("Unable to Load Market Insights", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again", systemImage: "arrow.clockwise", action: retryLoading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Loading saved market evidence…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadErrorBanner(
        title: String,
        message: String,
        retry: @escaping () -> Void
    ) -> some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(title, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Try Again", systemImage: "arrow.clockwise", action: retry)
            }
        }
    }

    private func paginationFooter(
        snapshot: KeywordMarketInsightsModel.Snapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let paginationErrorMessage = model.paginationErrorMessage {
                loadErrorBanner(
                    title: "Unable to load the next page",
                    message: paginationErrorMessage,
                    retry: retryLoading
                )
            }

            HStack {
                Text(
                    [
                        KeywordMarketInsightsPresentation.keywordCountDescription(
                            snapshot.rows.count
                        ),
                        KeywordMarketInsightsPresentation.countryRowCountDescription(
                            snapshot.returnedMarketEvidenceCount
                        )
                    ].joined(separator: " · ")
                )
                .foregroundStyle(.secondary)

                Spacer()

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing…")
                        .foregroundStyle(.secondary)
                } else if model.isLoadingNextPage {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more…")
                        .foregroundStyle(.secondary)
                } else if snapshot.nextCursor != nil {
                    Button("Load More", systemImage: "arrow.down.circle", action: requestNextPage)
                        .disabled(!model.canLoadNextPage)
                } else {
                    Text("All available keywords loaded")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var loadID: String {
        [
            context.id.uuidString,
            context.scope?.id ?? "empty-scope",
            "refresh-\(refreshToken)",
            "background-store-\(services.backgroundModelStoreRevision)",
            "daily-refresh-\(dailyRefreshCompletionID)",
            "retry-\(retryToken)"
        ].joined(separator: "::")
    }

    private var dailyRefreshCompletionID: String {
        guard let outcome = services.dailyRefreshScheduler.lastOutcome else {
            return "none"
        }
        return [
            String(outcome.triggeredAt.timeIntervalSinceReferenceDate.bitPattern),
            String(outcome.refreshedCount),
            String(outcome.failureCount)
        ].joined(separator: "-")
    }

    private func retryLoading() {
        retryToken &+= 1
    }

    private func requestNextPage() {
        guard model.canLoadNextPage else { return }
        paginationToken &+= 1
    }

    private func showDetails(
        _ row: KeywordMarketInsightsPresentation.KeywordRow
    ) {
        selectedRow = KeywordMarketInsightSelection(id: row.id)
    }
}

private struct KeywordMarketInsightSelection: Identifiable {
    let id: String
}
