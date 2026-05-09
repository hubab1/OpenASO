import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TrackedKeywordDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    let trackedApp: TrackedApp
    let track: TrackedAppKeyword
    let storefront: Storefront?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var isImportingCSV = false
    @State private var isProcessingCSVImport = false
    @State private var isExportingCSV = false
    @State private var exportDocument = CSVDocument(text: "")
    @State private var transferAlert: TrackedKeywordTransferAlert?

    private var historyPoints: [RankHistoryPoint] {
        track.sortedSnapshots.compactMap { snapshot in
            guard let rank = snapshot.rank else { return nil }
            return RankHistoryPoint(date: snapshot.searchedAt, rank: rank)
        }
    }

    private var latestSnapshot: TrackedKeywordDailyRanking? {
        track.latestSnapshot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let latestSnapshot {
                    stats(for: latestSnapshot)
                    topRankingStrip(for: latestSnapshot)

                    if !historyPoints.isEmpty {
                        historyChart
                    }

                    competitorList(for: latestSnapshot)
                } else {
                    ContentUnavailableView(
                        "No Snapshot Yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Refresh this keyword to fetch the first ranked results page.")
                    )
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.leading, 16)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        exportDocument = makeExportDocument()
                        isExportingCSV = true
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        guard !isProcessingCSVImport, !isImportingCSV else {
                            return
                        }
                        isImportingCSV = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isProcessingCSVImport || isImportingCSV)
                } label: {
                    Label("Import/Export", systemImage: "arrow.up.arrow.down.document")
                }
                .help("Import or Export CSV")
            }
        }
        .fileExporter(
            isPresented: $isExportingCSV,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result {
                transferAlert = TrackedKeywordTransferAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isImportingCSV,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importCSV(from: result)
        }
        .alert(item: $transferAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(track.term)
                    .font(.title)
                    .bold()

                HStack(spacing: 8) {
                    Text(storefront?.title ?? track.storefront.uppercased())
                    Text("•")
                    Text(track.platform.displayName)
                    if let lastRefreshAt = track.lastRefreshAt {
                        Text("•")
                        Text(lastRefreshAt, style: .relative)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onRefresh()
            } label: {
                Label("Refresh Keyword", systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private func stats(for snapshot: TrackedKeywordDailyRanking) -> some View {
        HStack(spacing: 16) {
            statCard(title: "Current Rank", value: currentRankText(for: snapshot))
            statCard(title: "Change", value: rankChangeText)
            statCard(title: "Source", value: snapshot.source.displayName)
            statCard(title: "Ranking Apps", value: "\(track.rankingAppCount ?? snapshot.resultCount)")
        }
    }

    private var historyChart: some View {
        let maxRank = max(10, historyPoints.map(\.rank).max() ?? 10)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Rank History")
                .font(.headline)

            Chart(historyPoints) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Rank", point.rank)
                )
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Rank", point.rank)
                )
            }
            .chartYScale(domain: [maxRank, 1])
            .frame(height: 240)
        }
    }

    private func topRankingStrip(for snapshot: TrackedKeywordDailyRanking) -> some View {
        let topResults = Array(snapshot.sortedTopResults.prefix(5))

        return VStack(alignment: .leading, spacing: 12) {
            Text("Top 5 Apps")
                .font(.headline)

            if topResults.isEmpty {
                Text("No ranked apps captured yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(topResults) { result in
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomTrailing) {
                                    AppIconView(
                                        appStoreID: result.appStoreID,
                                        storefrontCode: track.storefront,
                                        size: 56,
                                        cornerRadius: 14
                                    )

                                    Text("#\(result.position)")
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }

                                Text(result.name)
                                    .font(.subheadline.weight(result.appStoreID == trackedApp.appStoreID ? .semibold : .regular))
                                    .lineLimit(2)
                                    .frame(width: 88, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func competitorList(for snapshot: TrackedKeywordDailyRanking) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Captured Search Results")
                .font(.headline)

            ForEach(snapshot.sortedTopResults) { result in
                HStack(spacing: 12) {
                    Text("#\(result.position)")
                        .font(.headline.monospacedDigit())
                        .frame(width: 48, alignment: .leading)

                    AppIconView(
                        appStoreID: result.appStoreID,
                        storefrontCode: track.storefront,
                        size: 44,
                        cornerRadius: 10
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.name)
                            .fontWeight(result.appStoreID == trackedApp.appStoreID ? .semibold : .regular)
                        HStack(spacing: 8) {
                            Text(result.sellerName ?? "Unknown Seller")
                            Text("•")
                            Text(verbatim: "App ID \(result.appStoreID)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if result.appStoreID == trackedApp.appStoreID {
                        Text("Tracked App")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .bold()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func currentRankText(for snapshot: TrackedKeywordDailyRanking) -> String {
        if let rank = snapshot.rank {
            return "#\(rank)"
        }

        if let errorMessage = snapshot.errorMessage {
            return errorMessage
        }

        return "Not in top \(snapshot.resultCount)"
    }

    private var rankChangeText: String {
        guard
            let currentRank = track.latestSnapshot?.rank,
            let previousRank = track.previousSnapshot?.rank
        else {
            return "—"
        }

        let delta = previousRank - currentRank
        if delta > 0 {
            return "+\(delta)"
        }
        if delta < 0 {
            return "\(delta)"
        }
        return "0"
    }

    private var exportFilename: String {
        let sanitizedKeyword = track.term
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        return sanitizedKeyword.isEmpty ? "keyword-track.csv" : "\(sanitizedKeyword)-keyword-track.csv"
    }

    private func makeExportDocument() -> CSVDocument {
        let snapshot = track.latestSnapshot
        let metrics = currentMetrics()
        let row = TrackedKeywordCSVRow(
            appName: trackedApp.name,
            appID: String(trackedApp.appStoreID),
            platform: track.platform.rawValue,
            keyword: track.term,
            storeDomain: track.storefront,
            store: storefront?.title ?? track.storefront.uppercased(),
            note: track.notes,
            lastUpdate: TrackedKeywordCSVFormat.string(from: track.lastRefreshAt ?? snapshot?.searchedAt),
            ranking: snapshot?.rank.map(String.init) ?? "1000",
            change: rankChangeText == "—" ? "0" : rankChangeText,
            popularity: metrics?.popularityScore.map(String.init) ?? "",
            difficulty: metrics?.difficultyScore.map(String.init) ?? "",
            appsInRanking: String(track.rankingAppCount ?? snapshot?.resultCount ?? 0),
            tags: ""
        )

        return CSVDocument(text: TrackedKeywordCSVFormat.encode(rows: [row]))
    }

    private func importCSV(from result: Result<[URL], Error>) {
        guard !isProcessingCSVImport else {
            return
        }
        isProcessingCSVImport = true
        defer {
            isProcessingCSVImport = false
        }

        do {
            guard let url = try result.get().first else {
                return
            }

            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let csv = String(decoding: data, as: UTF8.self)
            #if DEBUG
            print(TrackedKeywordCSVFormat.debugImportSummary(
                csv: csv,
                fileName: url.lastPathComponent,
                filePath: url.path,
                byteCount: data.count,
                didAccessSecurityScopedResource: didAccess
            ))
            #endif
            let rows = try TrackedKeywordCSVFormat.decode(csv)
            let summary = importRows(rows)
            #if DEBUG
            print("[CSVImportDebug] importResult inserted=\(summary.insertedCount) skippedExisting=\(summary.skippedExistingCount) skippedDuplicates=\(summary.skippedDuplicateCount) skippedInvalid=\(summary.skippedInvalidCount) createdApps=\(summary.createdAppCount) importedApps=\(summary.importedAppIDs.count)")
            #endif

            if summary.insertedCount == 0 {
                transferAlert = TrackedKeywordTransferAlert(
                    title: "Nothing Imported",
                    message: summary.nothingImportedMessage
                )
            } else {
                transferAlert = TrackedKeywordTransferAlert(
                    title: "Import Complete",
                    message: "Imported \(summary.insertedCount) keyword track\(summary.insertedCount == 1 ? "" : "s") across \(summary.importedAppIDs.count) app\(summary.importedAppIDs.count == 1 ? "" : "s"). Created \(summary.createdAppCount) app\(summary.createdAppCount == 1 ? "" : "s"). \(summary.skippedRowsMessage)"
                )
            }
        } catch {
            #if DEBUG
            print("[CSVImportDebug] importFailed error=\(error.localizedDescription)")
            #endif
            transferAlert = TrackedKeywordTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    private func importRows(_ rows: [TrackedKeywordCSVRow]) -> TrackedKeywordCSVImportSummary {
        var seenCSVKeys: Set<String> = []
        var existingKeys: Set<String>
        var trackedAppsByAppStoreID: [Int64: TrackedApp]
        do {
            existingKeys = Set(
                try fetchAllTrackedKeywords()
                    .map {
                        importDuplicateKey(
                            appStoreID: $0.appStoreID,
                            term: $0.term,
                            storefront: $0.storefront,
                            platform: $0.platform
                        )
                    }
            )
            trackedAppsByAppStoreID = Dictionary(uniqueKeysWithValues: try fetchTrackedApps().map { ($0.appStoreID, $0) })
        } catch {
            var summary = TrackedKeywordCSVImportSummary()
            summary.failedRowCount = rows.count
            return summary
        }
        var nextSidebarSortOrder = trackedAppsByAppStoreID.values
            .filter { $0.folder == nil }
            .map(\.sidebarSortOrder)
            .max()
            .map { $0 + 1 } ?? 0
        var queriesByKey: [String: KeywordQuery] = [:]
        var metricsByQueryKey: [String: KeywordDailyMetric] = [:]
        var summary = TrackedKeywordCSVImportSummary()

        for row in rows {
            let keyword = row.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let storefront = row.storeDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !keyword.isEmpty, !storefront.isEmpty else {
                summary.skippedInvalidCount += 1
                continue
            }

            let rowPlatform = AppPlatform(rawValue: row.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            guard let rowAppStoreID = importAppStoreID(from: row.appID, defaultAppStoreID: trackedApp.appStoreID) else {
                summary.skippedInvalidCount += 1
                continue
            }

            let platform = rowPlatform ?? trackedApp.defaultPlatform
            let existingApp = trackedAppsByAppStoreID[rowAppStoreID]
            let duplicateKey = importDuplicateKey(
                appStoreID: rowAppStoreID,
                term: keyword,
                storefront: storefront,
                platform: platform
            )
            guard seenCSVKeys.insert(duplicateKey).inserted else {
                summary.skippedDuplicateCount += 1
                continue
            }

            guard !existingKeys.contains(duplicateKey) else {
                summary.skippedExistingCount += 1
                continue
            }

            do {
                let queryKey = KeywordQuery.makeQueryKey(term: keyword, storefront: storefront, platform: platform)
                let query: KeywordQuery
                if let cachedQuery = queriesByKey[queryKey] {
                    query = cachedQuery
                } else {
                    query = try KeywordQuery.fetchOrInsert(
                        term: keyword,
                        storefront: storefront,
                        platform: platform,
                        in: modelContext
                    )
                    queriesByKey[queryKey] = query
                }

                let appForRow: TrackedApp
                if let existingApp {
                    appForRow = existingApp
                    updateTrackedApp(existingApp, from: row)
                } else {
                    let createdApp = try createTrackedApp(
                        from: row,
                        appStoreID: rowAppStoreID,
                        defaultPlatform: platform,
                        sidebarSortOrder: nextSidebarSortOrder
                    )
                    nextSidebarSortOrder += 1
                    trackedAppsByAppStoreID[createdApp.appStoreID] = createdApp
                    appForRow = createdApp
                    summary.createdAppCount += 1
                }

                let importedTrack = TrackedAppKeyword(
                    term: keyword,
                    storefront: storefront,
                    platform: platform,
                    trackedApp: appForRow,
                    query: query
                )
                importedTrack.notes = row.note

                appForRow.keywordTracks.append(importedTrack)
                modelContext.insert(importedTrack)
                applyImportedValues(from: row, to: importedTrack)
                insertMetrics(from: row, for: importedTrack, metricsByQueryKey: &metricsByQueryKey)

                existingKeys.insert(duplicateKey)
                summary.importedTracks.append(importedTrack)
                summary.importedAppIDs.insert(rowAppStoreID)
                summary.insertedCount += 1
            } catch {
                summary.failedRowCount += 1
            }
        }

        if summary.insertedCount > 0 || summary.createdAppCount > 0 {
            do {
                try modelContext.save()
            } catch {
                summary.failedRowCount += summary.insertedCount
                summary.importedTracks.removeAll()
                summary.importedAppIDs.removeAll()
                summary.insertedCount = 0
                summary.createdAppCount = 0
            }
        }
        return summary
    }

    private func importDuplicateKey(appStoreID: Int64, term: String, storefront: String, platform: AppPlatform) -> String {
        [
            String(appStoreID),
            term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform.rawValue
        ].joined(separator: "::")
    }

    private func importAppStoreID(from value: String, defaultAppStoreID: Int64) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultAppStoreID
        }
        return Int64(trimmed)
    }

    private func createTrackedApp(
        from row: TrackedKeywordCSVRow,
        appStoreID: Int64,
        defaultPlatform: AppPlatform,
        sidebarSortOrder: Int
    ) throws -> TrackedApp {
        let appName = row.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedApp = ResolvedApp(
            appStoreID: appStoreID,
            bundleID: nil,
            name: appName.isEmpty ? "App ID \(appStoreID)" : appName,
            sellerName: nil,
            defaultPlatform: defaultPlatform
        )
        let storeApp = try services.appCatalogService.upsertStoreApp(from: resolvedApp, in: modelContext)

        let trackedApp = TrackedApp(
            appStoreID: appStoreID,
            storeApp: storeApp,
            sidebarSortOrder: sidebarSortOrder
        )
        modelContext.insert(trackedApp)
        services.analyticsService.capture(.trackedAppAdded(platform: defaultPlatform, source: "csv_import"))
        return trackedApp
    }

    private func updateTrackedApp(_ trackedApp: TrackedApp, from row: TrackedKeywordCSVRow) {
        let appName = row.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appName.isEmpty {
            trackedApp.name = appName
        }
    }

    private func fetchAllTrackedKeywords() throws -> [TrackedAppKeyword] {
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            sortBy: [
                SortDescriptor(\TrackedAppKeyword.appStoreID, order: .forward),
                SortDescriptor(\TrackedAppKeyword.term, order: .forward),
                SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
                SortDescriptor(\TrackedAppKeyword.platformRaw, order: .forward)
            ]
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchTrackedApps() throws -> [TrackedApp] {
        let descriptor = FetchDescriptor<TrackedApp>(
            sortBy: [
                SortDescriptor(\TrackedApp.appStoreID, order: .forward)
            ]
        )
        return try modelContext.fetch(descriptor)
    }

    private func applyImportedValues(from row: TrackedKeywordCSVRow, to importedTrack: TrackedAppKeyword) {
        if let appsInRanking = Int(row.appsInRanking) {
            importedTrack.rankingAppCount = appsInRanking
        }

        guard let lastUpdate = TrackedKeywordCSVFormat.date(from: row.lastUpdate) else {
            return
        }

        importedTrack.lastRefreshAt = lastUpdate

        let rank = Int(row.ranking).flatMap { $0 >= 1000 ? nil : $0 }
        let resultCount = Int(row.appsInRanking) ?? importedTrack.rankingAppCount ?? rank ?? 0
        let snapshot = TrackedKeywordDailyRanking(
            rank: rank,
            searchedAt: lastUpdate,
            source: .iTunesFallback,
            resultCount: resultCount,
            keywordTrack: importedTrack
        )
        modelContext.insert(snapshot)
    }

    private func currentMetrics() -> KeywordDailyMetric? {
        let queryKey = track.queryKey
        let descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metrics in
                metrics.queryKey == queryKey
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func upsertMetrics(from row: TrackedKeywordCSVRow) {
        guard Int(row.popularity) != nil || Int(row.difficulty) != nil else {
            return
        }

        let existingMetrics = currentMetrics()
        let metrics = existingMetrics ?? KeywordDailyMetric(
            queryKey: track.queryKey,
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            popularityScore: nil,
            difficultyScore: nil,
            source: .appleAdsPopularity
        )

        metrics.keyword = track.term
        metrics.storefront = track.storefront
        metrics.platform = track.platform
        metrics.popularityScore = Int(row.popularity)
        metrics.difficultyScore = Int(row.difficulty)
        metrics.updatedAt = .distantPast
        metrics.notes = "Imported from CSV. Refresh to replace with current Apple Ads popularity."

        if existingMetrics == nil {
            modelContext.insert(metrics)
        }
    }

    private func insertMetrics(
        from row: TrackedKeywordCSVRow,
        for importedTrack: TrackedAppKeyword,
        metricsByQueryKey: inout [String: KeywordDailyMetric]
    ) {
        guard Int(row.popularity) != nil || Int(row.difficulty) != nil else {
            return
        }

        let queryKey = importedTrack.queryKey
        let metrics: KeywordDailyMetric
        if let cachedMetrics = metricsByQueryKey[queryKey] {
            metrics = cachedMetrics
        } else {
            metrics = existingMetrics(for: importedTrack) ?? KeywordDailyMetric(
                queryKey: queryKey,
                keyword: importedTrack.term,
                storefront: importedTrack.storefront,
                platform: importedTrack.platform,
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: .distantPast
            )
            metricsByQueryKey[queryKey] = metrics
        }

        metrics.keyword = importedTrack.term
        metrics.storefront = importedTrack.storefront
        metrics.platform = importedTrack.platform
        metrics.popularityScore = Int(row.popularity)
        metrics.difficultyScore = Int(row.difficulty)
        metrics.updatedAt = .distantPast
        metrics.notes = "Imported from CSV. Refresh to replace with current Apple Ads popularity."

        if metrics.modelContext == nil {
            modelContext.insert(metrics)
        }
    }

    private func existingMetrics(for track: TrackedAppKeyword) -> KeywordDailyMetric? {
        let queryKey = track.queryKey
        let descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metrics in
                metrics.queryKey == queryKey
            }
        )
        return try? modelContext.fetch(descriptor).first
    }
}

private struct RankHistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let rank: Int
}

struct TrackedKeywordTransferAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct TrackedKeywordCSVImportSummary {
    var insertedCount = 0
    var skippedDuplicateCount = 0
    var skippedExistingCount = 0
    var skippedInvalidCount = 0
    var failedRowCount = 0
    var createdAppCount = 0
    var importedAppIDs: Set<Int64> = []
    var importedTracks: [TrackedAppKeyword] = []

    var skippedRowsMessage: String {
        "Skipped \(skippedExistingCount) already tracked, \(skippedDuplicateCount) duplicate CSV, \(skippedInvalidCount) invalid row\(skippedInvalidCount == 1 ? "" : "s"), and \(failedRowCount) failed row\(failedRowCount == 1 ? "" : "s")."
    }

    var nothingImportedMessage: String {
        if skippedExistingCount == 0, skippedDuplicateCount == 0, skippedInvalidCount == 0, failedRowCount == 0 {
            return "No keyword rows were found in the CSV."
        }
        return "No new keyword tracks were imported. \(skippedRowsMessage)"
    }
}
