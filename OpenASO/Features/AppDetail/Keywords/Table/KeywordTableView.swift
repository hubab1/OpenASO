import AppKit
import SwiftData
import SwiftUI

struct KeywordTableView: View {
    @CodableAppStorage(
        "keywordRankingChartSelectionByApp",
        defaultValue: [:],
        store: .openASOShared
    ) private var chartSelections: [String: [String]]
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings

    let rows: [KeywordWorkspaceRow]
    let isLoadingRows: Bool
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
    @State private var selection = Set<PersistentIdentifier>()
    @State private var presentedRankingRow: KeywordWorkspaceRow?
    @State private var presentedNotesRow: KeywordWorkspaceRow?
    @State private var actionErrorMessage: String?
    @State private var rowsPendingDeletion: [KeywordWorkspaceRow] = []

    private var tableRows: [KeywordTablePresentationRow] {
        let selectedKeys = selectedChartKeywordKeys
        return rows.map { row in
            KeywordTablePresentationRow(
                row: row,
                isSelectedForChart: selectedKeys.contains(row.track.identityKey)
            )
        }
    }

    private var sortedTableRows: [KeywordTablePresentationRow] {
        tableRows.sorted(using: sortOrder)
    }

    private var sortedRows: [KeywordWorkspaceRow] {
        sortedTableRows.map(\.row)
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

    private var rankingChartSeries: [KeywordRankingChartSeries] {
        let selectedKeys = selectedChartKeywordKeys
        var series: [KeywordRankingChartSeries] = []
        series.reserveCapacity(rows.count)

        for row in rows {
            guard selectedKeys.contains(row.track.identityKey) else {
                continue
            }

            let snapshots = row.trendSnapshots.sorted { $0.searchedAt < $1.searchedAt }
            var points: [KeywordRankingChartSeries.Point] = []
            points.reserveCapacity(snapshots.count)
            var lastRank: Int?

            for snapshot in snapshots {
                if let rank = snapshot.rank {
                    lastRank = rank
                }

                if let lastRank {
                    points.append(
                        KeywordRankingChartSeries.Point(
                            date: snapshot.searchedAt,
                            rank: lastRank
                        )
                    )
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

    var body: some View {
        VStack(spacing: 0) {
            KeywordTableSummaryHeader(
                rankingSeries: rankingChartSeries,
                isLoading: isLoadingRows,
                insightsSummary: insightsSummary,
                screenshotDownloadProgressStore: services.screenshotDownloadProgressStore
            )

            if sortedTableRows.isEmpty {
                ContentUnavailableView(
                    "No Matching Keywords",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Adjust the search or filters to reveal tracked keywords.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(sortedTableRows, selection: $selection, sortOrder: $sortOrder) {
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
                        KeywordPopularityCell(row: tableRow.row) {
                            openAppleAdsSettings()
                        }
                    }
                    .width(min: 112, ideal: 124, max: 136)

                    TableColumn("Position", value: \.positionSortValue) { tableRow in
                        KeywordPositionCell(row: tableRow.row)
                    }
                    .width(min: 76, ideal: 88, max: 100)

                    TableColumn("Trend", value: \.trendSortValue) { tableRow in
                        KeywordTrendCell(row: tableRow.row)
                    }
                    .width(min: 104, ideal: 120, max: 132)

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
                            presentedNotesRow = tableRow.row
                        }
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Chart", value: \.chartSelectionSortValue) { tableRow in
                        ChartSelectionButton(
                            isSelected: tableRow.isSelectedForChart,
                            setSelection: { isSelected in
                                setChartSelection(isSelected, for: tableRow.row)
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .width(min: 56, ideal: 60, max: 68)
                }
                .tint(.accentColor)
                .contextMenu(forSelectionType: PersistentIdentifier.self) { selectedIDs in
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
        .onChange(of: sortedRows.map(\.id)) { _, rowIDs in
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
        .sheet(item: $presentedNotesRow) { row in
            KeywordNotesSheet(track: row.track)
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

    private func openAppleAdsSettings() {
        services.settingsStore.requestSettingsFocus(.webSession)
        openSettings()
    }

    private func selectedRows(for selectedIDs: Set<PersistentIdentifier>) -> [KeywordWorkspaceRow] {
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
        rows.forEach { row in
            chartKeys.remove(row.track.identityKey)
            modelContext.delete(row.track)
        }

        do {
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

        for row in rows {
            guard row.track.storefront != storefront.code else {
                continue
            }

            let trackedApp = row.track.trackedApp
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
            selection = Set(insertedTracks.map(\.persistentModelID))
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
        row.trendSnapshots.contains { $0.rank != nil }
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

private struct KeywordTablePresentationRow: Identifiable {
    let row: KeywordWorkspaceRow
    let isSelectedForChart: Bool

    var id: PersistentIdentifier { row.id }
    var keywordSortValue: String { row.keywordSortValue }
    var lastUpdatedSortValue: Date { row.lastUpdatedSortValue }
    var storefrontSortValue: String { row.storefrontSortValue }
    var platformSortValue: Int { row.track.platform.tableSortValue }
    var popularitySortValue: Int { row.popularitySortValue }
    var positionSortValue: Int { row.positionSortValue }
    var trendSortValue: Int { row.trendSortValue }
    var chartSelectionSortValue: Int { isSelectedForChart ? 0 : 1 }
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
            let points = series.points.sorted { $0.date < $1.date }
            guard let previous = points.dropLast().last,
                  let latest = points.last
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
