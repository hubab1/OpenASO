import AppKit
import Observation
import SwiftData
import SwiftUI

struct KeywordTableView: View, Equatable {
    @CodableAppStorage(
        "keywordRankingChartSelectionByApp",
        defaultValue: [:],
        store: .openASOShared
    ) private var chartSelections: [String: [String]]
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings

    let rows: [KeywordWorkspaceRow]
    let isLoadingRows: Bool
    let contentRevision: Int
    let sortRevision: Int
    let trackedAppStoreID: Int64
    let chartSelectionScope: String
    let insightsSummary: KeywordInsightsSummary
    let storefronts: [StorefrontDefinition]
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore

    @State private var sortOrder = [
        KeyPathComparator(\KeywordTablePresentationRow.positionSortValue)
    ]
    @State private var presentationModel = KeywordTablePresentationModel()
    @State private var selection = Set<String>()
    @State private var presentedRankingRow: KeywordWorkspaceRow?
    @State private var presentedRankingHistoryRow: KeywordWorkspaceRow?
    @State private var presentedNotesRow: KeywordWorkspaceRow?
    @State private var actionErrorMessage: String?
    @State private var rowsPendingDeletion: [KeywordWorkspaceRow] = []

    nonisolated static func == (lhs: KeywordTableView, rhs: KeywordTableView) -> Bool {
        lhs.contentRevision == rhs.contentRevision
            && lhs.sortRevision == rhs.sortRevision
            && lhs.isLoadingRows == rhs.isLoadingRows
            && lhs.trackedAppStoreID == rhs.trackedAppStoreID
            && lhs.chartSelectionScope == rhs.chartSelectionScope
    }

    private var sortedRows: [KeywordWorkspaceRow] {
        presentationModel.rows.map(\.row)
    }

    private var showsPlatformColumn: Bool {
        Set(rows.map { $0.track.platform }).count > 1
    }

    private var selectedChartKeywordKeys: Set<String> {
        guard let savedSelection = chartSelections[chartSelectionAppKey] else {
            return Set(defaultChartKeywordKeys)
        }

        return Set(savedSelection)
    }

    private var defaultChartKeywordKeys: [String] {
        rows
            .filter(hasRankingHistory)
            .sorted(by: chartDefaultSort)
            .prefix(10)
            .map(\.track.identityKey)
    }

    private var chartSelectionAppKey: String {
        "\(trackedAppStoreID)::\(chartSelectionScope)"
    }

    var body: some View {
        VStack(spacing: 0) {
            KeywordTableSummaryHeader(
                rankingSeries: presentationModel.rankingChartSeries,
                isLoading: isLoadingRows,
                insightsSummary: insightsSummary,
                screenshotDownloadProgressStore: services.screenshotDownloadProgressStore
            )

            if presentationModel.rows.isEmpty {
                ContentUnavailableView(
                    "No Matching Keywords",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Adjust the search or filters to reveal tracked keywords.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                KeywordRowsTable(
                    rows: presentationModel.rows,
                    selection: $selection,
                    sortOrder: $sortOrder,
                    showsPlatformColumn: showsPlatformColumn,
                    trackedAppStoreID: trackedAppStoreID,
                    modelContext: modelContext,
                    appCatalogService: appCatalogService,
                    appIconStore: appIconStore,
                    requiresAppleAdsReconnect: services.appleAdsWebSessionStore.requiresReconnect,
                    presentRanking: presentRanking,
                    presentRankingHistory: { presentedRankingHistoryRow = $0 },
                    presentNotes: { presentedNotesRow = $0 },
                    setChartSelection: setChartSelection,
                    openAppleAdsSettings: openAppleAdsSettings
                )
                // Rebuilding the virtualized table is substantially cheaper than
                // asking NSTableView to diff hundreds of moved rows after a sort.
                // Refresh deltas keep this identity stable and still update cells
                // in place.
                .id(presentationModel.tableIdentity)
                .contextMenu(forSelectionType: String.self) { selectedIDs in
                    let contextRows = selectedRows(for: selectedIDs)
                    if contextRows.isEmpty {
                        Button("No Keywords Selected") {}
                            .disabled(true)
                    } else {
                        Menu("Copy to Country") {
                            ForEach(storefronts) { storefront in
                                Button(storefront.title) {
                                    copyRows(contextRows, to: storefront)
                                }
                                .disabled(!canCopyRows(contextRows, to: storefront))
                            }
                        }
                        Divider()
                        Button(deleteTitle(for: contextRows), role: .destructive) {
                            rowsPendingDeletion = contextRows
                        }
                    }
                }
            }
        }
        .onAppear {
            updatePresentationRows(forceSort: true)
        }
        .onChange(of: contentRevision) {
            updatePresentationRows(forceSort: false)
        }
        .onChange(of: sortRevision) {
            updatePresentationRows(forceSort: true)
        }
        .onChange(of: sortOrder) {
            // Keep the header selection responsive while a refresh is emitting
            // row deltas. The final workspace materialization increments
            // sortRevision and applies this selected order once, instead of
            // rebuilding the ten-column table in the middle of the refresh.
            guard !isTrackedAppRefreshRunning else { return }
            updatePresentationRows(forceSort: true)
        }
        .onChange(of: chartSelections) {
            updatePresentationRows(forceSort: true)
        }
        .onChange(of: presentationModel.rowIDs) { _, rowIDs in
            selection.formIntersection(Set(rowIDs))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(.quaternary)
        }
        .sheet(item: $presentedRankingRow) { row in
            KeywordRankingListSheet(
                row: row,
                trackedAppStoreID: trackedAppStoreID,
                modelContext: modelContext,
                appCatalogService: appCatalogService,
                appIconStore: appIconStore
            )
        }
        .sheet(item: $presentedRankingHistoryRow) { row in
            KeywordRankingHistorySheet(
                row: row,
                modelContext: modelContext
            )
        }
        .sheet(item: $presentedNotesRow) { row in
            if let track = try? trackedKeyword(identityKey: row.track.identityKey) {
                KeywordNotesSheet(track: track)
            } else {
                ContentUnavailableView(
                    "Keyword Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The keyword was removed before its notes could be opened.")
                )
                .frame(width: 420, height: 220)
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { !rowsPendingDeletion.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        rowsPendingDeletion = []
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(deleteTitle(for: rowsPendingDeletion), role: .destructive) {
                let rows = rowsPendingDeletion
                rowsPendingDeletion = []
                deleteRows(rows)
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(
            "Keyword Action Failed",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        actionErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private func presentRanking(_ row: KeywordWorkspaceRow) {
        presentedRankingRow = row
    }

    private func updatePresentationRows(forceSort: Bool) {
        presentationModel.update(
            sourceRows: rows,
            selectedChartKeywordKeys: selectedChartKeywordKeys,
            sortOrder: sortOrder,
            forceSort: forceSort
        )
    }

    private var isTrackedAppRefreshRunning: Bool {
        guard let refresh = services.refreshProgressStore.activeRefresh,
              refresh.appStoreID == trackedAppStoreID else {
            return false
        }

        switch refresh.phase {
        case .completed, .failed:
            return false
        case .preparing,
             .refreshingKeywords,
             .refreshingMetrics,
             .refreshingRatings,
             .refreshingReviews,
             .finishing:
            return true
        }
    }

    private func openAppleAdsSettings() {
        services.settingsStore.requestSettingsFocus(.webSession)
        openSettings()
    }

    private func selectedRows(for selectedIDs: Set<String>) -> [KeywordWorkspaceRow] {
        let ids = selectedIDs.isEmpty ? selection : selectedIDs
        guard !ids.isEmpty else { return [] }

        return sortedRows.filter { ids.contains($0.id) }
    }

    private func deleteTitle(for rows: [KeywordWorkspaceRow]) -> String {
        rows.count == 1 ? "Delete Keyword" : "Delete \(rows.count) Keywords"
    }

    private var deleteConfirmationTitle: String {
        rowsPendingDeletion.count == 1 ? "Delete Keyword?" : "Delete Keywords?"
    }

    private var deleteConfirmationMessage: String {
        guard rowsPendingDeletion.count == 1 else {
            return "Delete \(rowsPendingDeletion.count) selected keyword tracks from OpenASO."
        }

        guard let row = rowsPendingDeletion.first else {
            return ""
        }

        return "Delete \"\(row.track.term)\" for \(row.storefront?.name ?? row.track.storefront.uppercased()) from OpenASO."
    }

    private func deleteRows(_ rows: [KeywordWorkspaceRow]) {
        guard !rows.isEmpty else { return }

        var chartKeys = selectedChartKeywordKeys

        do {
            let trackedKeywords = try trackedKeywords(
                identityKeys: rows.map(\.track.identityKey)
            )
            try TrackedKeywordRefreshStatusStore.deleteStatuses(
                for: rows.map(\.track.identityKey),
                in: modelContext
            )
            rows.forEach { row in
                chartKeys.remove(row.track.identityKey)
            }
            trackedKeywords.forEach(modelContext.delete)
            try modelContext.save()
            saveChartSelection(chartKeys)
            selection.subtract(rows.map(\.id))
            services.analyticsService.capture(.keywordDeleted(deleteCount: rows.count))
        } catch {
            actionErrorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func canCopyRows(_ rows: [KeywordWorkspaceRow], to storefront: StorefrontDefinition) -> Bool {
        guard let existingKeys = try? existingKeywordKeys() else {
            return false
        }

        return rows.contains { row in
            row.track.storefront != storefront.code && !existingKeys.contains(
                TrackedAppKeyword.makeIdentityKey(
                    appStoreID: trackedAppStoreID,
                    term: row.track.term,
                    storefront: storefront.code,
                    platform: row.track.platform
                )
            )
        }
    }

    private func copyRows(_ rows: [KeywordWorkspaceRow], to storefront: StorefrontDefinition) {
        guard !rows.isEmpty else { return }

        let existingKeys: Set<String>
        do {
            existingKeys = try existingKeywordKeys()
        } catch {
            actionErrorMessage = OpenASOError.map(error).localizedDescription
            return
        }

        var mutableExistingKeys = existingKeys
        var insertedTracks: [TrackedAppKeyword] = []
        let trackedApp: TrackedApp
        do {
            trackedApp = try fetchTrackedApp()
        } catch {
            actionErrorMessage = OpenASOError.map(error).localizedDescription
            return
        }

        for row in rows {
            guard row.track.storefront != storefront.code else {
                continue
            }

            let identityKey = TrackedAppKeyword.makeIdentityKey(
                appStoreID: trackedApp.appStoreID,
                term: row.track.term,
                storefront: storefront.code,
                platform: row.track.platform
            )
            guard !mutableExistingKeys.contains(identityKey) else {
                continue
            }

            let query: KeywordQuery
            do {
                query = try KeywordQuery.fetchOrInsert(
                    term: row.track.term,
                    storefront: storefront.code,
                    platform: row.track.platform,
                    in: modelContext
                )
            } catch {
                actionErrorMessage = OpenASOError.map(error).localizedDescription
                return
            }
            let copiedTrack = TrackedAppKeyword(
                term: row.track.term,
                storefront: storefront.code,
                platform: row.track.platform,
                trackedApp: trackedApp,
                query: query
            )
            copiedTrack.notes = row.track.notes
            trackedApp.keywordTracks.append(copiedTrack)
            modelContext.insert(copiedTrack)
            mutableExistingKeys.insert(identityKey)
            insertedTracks.append(copiedTrack)
        }

        guard !insertedTracks.isEmpty else { return }

        do {
            try modelContext.save()
            selection = Set(insertedTracks.map(\.identityKey))
        } catch {
            actionErrorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func existingKeywordKeys() throws -> Set<String> {
        let appStoreID = trackedAppStoreID
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.appStoreID == appStoreID
            }
        )
        return Set(try modelContext.fetch(descriptor).map(\.identityKey))
    }

    private func trackedKeyword(identityKey: String) throws -> TrackedAppKeyword? {
        let targetIdentityKey = identityKey
        var descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.identityKey == targetIdentityKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func trackedKeywords(identityKeys: [String]) throws -> [TrackedAppKeyword] {
        let targetIdentityKeys = Array(Set(identityKeys))
        guard !targetIdentityKeys.isEmpty else { return [] }
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                targetIdentityKeys.contains(track.identityKey)
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchTrackedApp() throws -> TrackedApp {
        let appStoreID = trackedAppStoreID
        var descriptor = FetchDescriptor<TrackedApp>(
            predicate: #Predicate { app in
                app.appStoreID == appStoreID
            }
        )
        descriptor.fetchLimit = 1
        guard let trackedApp = try modelContext.fetch(descriptor).first else {
            throw OpenASOError.appNotFound
        }
        return trackedApp
    }

    private func setChartSelection(_ isSelected: Bool, for row: KeywordWorkspaceRow) {
        var selectedKeys = selectedChartKeywordKeys
        if isSelected {
            selectedKeys.insert(row.track.identityKey)
        } else {
            selectedKeys.remove(row.track.identityKey)
        }

        saveChartSelection(selectedKeys)
    }

    private func saveChartSelection(_ selectedKeys: Set<String>) {
        var selections = chartSelections
        selections[chartSelectionAppKey] = Array(selectedKeys).sorted()
        chartSelections = selections
    }

    private func hasRankingHistory(_ row: KeywordWorkspaceRow) -> Bool {
        !row.trendPoints.isEmpty
    }

    private func chartDefaultSort(_ lhs: KeywordWorkspaceRow, _ rhs: KeywordWorkspaceRow) -> Bool {
        switch (lhs.currentRank, rhs.currentRank) {
        case let (lhsRank?, rhsRank?):
            if lhsRank == rhsRank {
                if lhs.popularitySortValue != rhs.popularitySortValue {
                    return lhs.popularitySortValue > rhs.popularitySortValue
                }

                return lhs.track.term.localizedCaseInsensitiveCompare(rhs.track.term) == .orderedAscending
            }

            return lhsRank < rhsRank
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if lhs.popularitySortValue != rhs.popularitySortValue {
                return lhs.popularitySortValue > rhs.popularitySortValue
            }

            return lhs.track.term.localizedCaseInsensitiveCompare(rhs.track.term) == .orderedAscending
        }
    }
}

private struct KeywordRowsTable: View {
    let rows: [KeywordTablePresentationRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<KeywordTablePresentationRow>]
    let showsPlatformColumn: Bool
    let trackedAppStoreID: Int64
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore
    let requiresAppleAdsReconnect: Bool
    let presentRanking: (KeywordWorkspaceRow) -> Void
    let presentRankingHistory: (KeywordWorkspaceRow) -> Void
    let presentNotes: (KeywordWorkspaceRow) -> Void
    let setChartSelection: (Bool, KeywordWorkspaceRow) -> Void
    let openAppleAdsSettings: () -> Void

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Keyword", value: \.keywordSortValue) { tableRow in
                KeywordCell(row: tableRow.row)
            }
            .width(min: 160, ideal: 230)

            TableColumn("Last updated", value: \.lastUpdatedSortValue) { tableRow in
                KeywordLastUpdatedCell(row: tableRow.row)
            }
            .width(min: 92, ideal: 112, max: 132)

            TableColumn("Country", value: \.storefrontSortValue) { tableRow in
                KeywordStoreCell(row: tableRow.row)
            }
            .width(min: 100, ideal: 148)

            if showsPlatformColumn {
                TableColumn("Platform", value: \.platformSortValue) { tableRow in
                    KeywordPlatformCell(platform: tableRow.row.track.platform)
                }
                .width(min: 92, ideal: 104, max: 116)
            }

            TableColumn("Popularity", value: \.popularitySortValue) { tableRow in
                KeywordPopularityCell(
                    row: tableRow.row,
                    requiresAppleAdsReconnect: requiresAppleAdsReconnect,
                    openAppleAdsSettings: openAppleAdsSettings
                )
            }
            .width(min: 112, ideal: 124, max: 136)

            TableColumn("Position", value: \.positionSortValue) { tableRow in
                KeywordPositionCell(row: tableRow.row)
            }
            .width(min: 76, ideal: 88, max: 100)

            TableColumn("Trend", value: \.trendSortValue) { tableRow in
                KeywordTrendButton(row: tableRow.row) {
                    presentRankingHistory(tableRow.row)
                }
            }
            .width(min: 120, ideal: 132, max: 152)

            TableColumn("Apps in Ranking") { tableRow in
                AppsInRankingButton(
                    row: tableRow.row,
                    trackedAppStoreID: trackedAppStoreID,
                    modelContext: modelContext,
                    appCatalogService: appCatalogService,
                    appIconStore: appIconStore,
                    presentRanking: presentRanking
                )
            }
            .width(min: 132, ideal: 220)

            TableColumn("Notes") { tableRow in
                KeywordNotesCell(row: tableRow.row) {
                    presentNotes(tableRow.row)
                }
            }
            .width(min: 120, ideal: 180)

            TableColumn("Chart", value: \.chartSelectionSortValue) { tableRow in
                ChartSelectionButton(
                    isSelected: tableRow.isSelectedForChart,
                    setSelection: { isSelected in
                        setChartSelection(isSelected, tableRow.row)
                    }
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(min: 56, ideal: 60, max: 68)
        }
        .tint(.accentColor)
    }
}

struct KeywordTablePresentationRow: Identifiable, Equatable {
    let row: KeywordWorkspaceRow
    let isSelectedForChart: Bool

    var id: String { row.id }
    var keywordSortValue: String { row.keywordSortValue }
    var lastUpdatedSortValue: Date { row.lastUpdatedSortValue }
    var storefrontSortValue: String { row.storefrontSortValue }
    var platformSortValue: Int { row.track.platform.tableSortValue }
    var popularitySortValue: Int { row.popularitySortValue }
    var positionSortValue: Int { row.positionSortValue }
    var trendSortValue: Int { row.trendSortValue }
    var chartSelectionSortValue: Int { isSelectedForChart ? 0 : 1 }
}

@Observable
@MainActor
final class KeywordTablePresentationModel {
    private(set) var rows: [KeywordTablePresentationRow] = []
    private(set) var rowIDs: [String] = []
    private(set) var rankingChartSeries: [KeywordRankingChartSeries] = []
    private(set) var tableIdentity = 0
    @ObservationIgnored private(set) var sortCount = 0

    func update(
        sourceRows: [KeywordWorkspaceRow],
        selectedChartKeywordKeys: Set<String>,
        sortOrder: [KeyPathComparator<KeywordTablePresentationRow>],
        forceSort: Bool
    ) {
        let incomingRows = sourceRows.map { row in
            KeywordTablePresentationRow(
                row: row,
                isSelectedForChart: selectedChartKeywordKeys.contains(row.track.identityKey)
            )
        }
        let incomingRowsByID = Dictionary(
            uniqueKeysWithValues: incomingRows.map { ($0.id, $0) }
        )
        rankingChartSeries = Self.makeRankingChartSeries(
            sourceRows,
            selectedChartKeywordKeys: selectedChartKeywordKeys
        )
        let membershipChanged = Set(rowIDs) != Set(incomingRowsByID.keys)

        if forceSort || membershipChanged || rows.isEmpty {
            rows = incomingRows.sorted(using: sortOrder)
            sortCount &+= 1
            tableIdentity &+= 1
        } else {
            // Preserve the current visual order while refresh deltas arrive.
            // This lets SwiftUI diff stable row IDs and update only changed cells.
            rows = rowIDs.compactMap { incomingRowsByID[$0] }
        }
        rowIDs = rows.map(\.id)
    }

    private static func makeRankingChartSeries(
        _ sourceRows: [KeywordWorkspaceRow],
        selectedChartKeywordKeys: Set<String>
    ) -> [KeywordRankingChartSeries] {
        var series: [KeywordRankingChartSeries] = []
        series.reserveCapacity(min(selectedChartKeywordKeys.count, sourceRows.count))

        for row in sourceRows where selectedChartKeywordKeys.contains(row.track.identityKey) {
            var points: [KeywordRankingChartSeries.Point] = []
            points.reserveCapacity(row.trendSnapshots.count)
            var lastRank: Int?

            for snapshot in row.trendSnapshots {
                if let rank = snapshot.rank {
                    lastRank = rank
                }
                if let lastRank {
                    points.append(.init(date: snapshot.searchedAt, rank: lastRank))
                }
            }

            if !points.isEmpty {
                series.append(
                    KeywordRankingChartSeries(
                        id: row.track.identityKey,
                        keyword: row.track.term,
                        contextLabel: row.storefront?.flagEmoji ?? row.track.storefront.uppercased(),
                        platform: row.track.platform,
                        points: points
                    )
                )
            }
        }
        return series
    }
}

private struct KeywordPlatformCell: View {
    let platform: AppPlatform

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: platform.keywordTableSystemImage)
                .frame(width: 16, alignment: .center)

            Text(platform.displayName)
        }
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct KeywordTrendButton: View {
    let row: KeywordWorkspaceRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KeywordTrendCell(row: row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show ranking history")
        .accessibilityLabel("Ranking trend for \(row.track.term)")
        .accessibilityValue(row.trendCellAccessibilityValue)
        .accessibilityHint("Opens ranking history.")
    }
}

private extension AppPlatform {
    var keywordTableSystemImage: String {
        switch self {
        case .iphone:
            return "iphone"
        case .ipad:
            return "ipad"
        case .mac:
            return "macbook"
        }
    }

    var tableSortValue: Int {
        switch self {
        case .iphone:
            return 0
        case .ipad:
            return 1
        case .mac:
            return 2
        }
    }
}

private struct KeywordTableSummaryHeader: View {
    let rankingSeries: [KeywordRankingChartSeries]
    let isLoading: Bool
    let insightsSummary: KeywordInsightsSummary
    let screenshotDownloadProgressStore: ScreenshotDownloadProgressStore

    private var showsChartLoadingState: Bool {
        isLoading && rankingSeries.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    KeywordRankingChartView(series: rankingSeries, chartHeight: 220, legendWidth: 156, isLoading: showsChartLoadingState)
                        .frame(minWidth: 560, maxWidth: .infinity, alignment: .leading)

                    KeywordTableInsightsSidebar(
                        rankingSeries: rankingSeries,
                        summary: insightsSummary,
                        screenshotDownloadProgressStore: screenshotDownloadProgressStore
                    )
                    .frame(minWidth: 320, idealWidth: 410, maxWidth: 410)
                }

                VStack(alignment: .leading, spacing: 16) {
                    KeywordRankingChartView(series: rankingSeries, chartHeight: 220, legendWidth: 156, isLoading: showsChartLoadingState)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    KeywordTableInsightsSidebar(
                        rankingSeries: rankingSeries,
                        summary: insightsSummary,
                        screenshotDownloadProgressStore: screenshotDownloadProgressStore
                    )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }
}

private struct KeywordTableInsightsSidebar: View {
    let rankingSeries: [KeywordRankingChartSeries]
    let summary: KeywordInsightsSummary
    let screenshotDownloadProgressStore: ScreenshotDownloadProgressStore

    var body: some View {
        VStack(spacing: 10) {
            if screenshotDownloadProgressStore.activeDownload != nil {
                ScreenshotDownloadStatusView(progressStore: screenshotDownloadProgressStore, placement: .sidebar)
            }

            HStack(spacing: 10) {
                compactMetric(
                    title: "Best Rank",
                    value: formattedBestRank,
                    detail: bestRankKeyword
                )

                compactMetric(
                    title: "Median Rank",
                    value: formattedMedianRank,
                    detail: "selected"
                )

                compactMetric(
                    title: "Changed",
                    value: "\(changedCount) / \(currentRanks.count)",
                    detail: "moved"
                )
            }

            KeywordDistributionStrip(summary: summary)

            KeywordMovementStrip(summary: summary)
        }
    }

    private var currentRanks: [(keyword: String, rank: Int)] {
        rankingSeries.compactMap { series in
            guard let point = series.points.max(by: { $0.date < $1.date }) else {
                return nil
            }

            return (series.keyword, point.rank)
        }
    }

    private var formattedBestRank: String {
        guard let bestRank = currentRanks.map(\.rank).min() else {
            return "-"
        }

        return "#\(bestRank)"
    }

    private var bestRankKeyword: String {
        currentRanks
            .min { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.keyword.localizedCaseInsensitiveCompare(rhs.keyword) == .orderedAscending
                }

                return lhs.rank < rhs.rank
            }?
            .keyword ?? "No data"
    }

    private var formattedMedianRank: String {
        let ranks = currentRanks.map(\.rank).sorted()
        guard !ranks.isEmpty else {
            return "-"
        }

        let middleIndex = ranks.count / 2
        if ranks.count.isMultiple(of: 2) {
            let median = Double(ranks[middleIndex - 1] + ranks[middleIndex]) / 2
            return "#\(median.formatted(.number.precision(.fractionLength(0...1))))"
        }

        return "#\(ranks[middleIndex])"
    }

    private var changedCount: Int {
        rankingSeries.reduce(0) { count, series in
            guard let previous = series.points.dropLast().last,
                  let latest = series.points.last
            else {
                return count
            }

            return previous.rank == latest.rank ? count : count + 1
        }
    }

    private func compactMetric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary)
        }
    }
}

private struct KeywordDistributionStrip: View {
    let summary: KeywordInsightsSummary

    private var maxCount: Int {
        [summary.top5Count, summary.top25Count, summary.top100Count, summary.outsideTop100Count, 1].max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Distribution")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                compactBar(label: "Top 5", value: summary.top5Count, color: .indigo)
                compactBar(label: "Top 25", value: summary.top25Count, color: .indigo)
                compactBar(label: "Top 100", value: summary.top100Count, color: .indigo)
                compactBar(label: "> 100", value: summary.outsideTop100Count, color: .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary)
        }
    }

    private func compactBar(label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(value.formatted())
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()

                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(value == 0 ? 0.16 : 0.68))
                    .frame(width: proxy.size.width * CGFloat(value) / CGFloat(maxCount))
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeywordMovementStrip: View {
    let summary: KeywordInsightsSummary

    private var total: Int {
        max(summary.improvedCount + summary.declinedCount + summary.unchangedCount, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Movement")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                MovementCount(value: summary.improvedCount, label: "went up", systemImage: "arrow.up", color: .green)

                MovementCount(value: summary.declinedCount, label: "went down", systemImage: "arrow.down", color: .red)

                Text("\(summary.unchangedCount) unchanged")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(.green)
                        .frame(width: proxy.size.width * CGFloat(summary.improvedCount) / CGFloat(total))

                    Rectangle()
                        .fill(.red)
                        .frame(width: proxy.size.width * CGFloat(summary.declinedCount) / CGFloat(total))

                    Rectangle()
                        .fill(.secondary.opacity(0.28))
                        .frame(width: proxy.size.width * CGFloat(summary.unchangedCount) / CGFloat(total))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary)
        }
    }
}

private struct MovementCount: View {
    let value: Int
    let label: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))

                Text(value.formatted())
            }
            .foregroundStyle(color)

            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChartSelectionButton: View {
    let isSelected: Bool
    let setSelection: (Bool) -> Void

    var body: some View {
        Button {
            setSelection(!isSelected)
        } label: {
            Image(systemName: isSelected ? "checkmark.square" : "square")
                .font(.body)
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .frame(width: 18, height: 18)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Hide from chart" : "Show in chart")
        .accessibilityLabel(isSelected ? "Hide from chart" : "Show in chart")
    }
}

#Preview("Keyword Table") {
    KeywordTablePreview()
}
