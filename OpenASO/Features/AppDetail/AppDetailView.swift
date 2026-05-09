import SwiftData
import SwiftUI

struct AppDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query(sort: [
        SortDescriptor(\TrackedApp.sidebarSortOrder, order: .forward),
        SortDescriptor(\TrackedApp.appStoreID, order: .forward)
    ])
    private var trackedApps: [TrackedApp]

    let trackedApp: TrackedApp
    private let appStoreID: Int64
    private let bundleID: String?
    private let appName: String
    private let appSubtitle: String?
    private let appSellerName: String?
    private let defaultPlatform: AppPlatform

    @State private var isPresentingAddKeywords = false
    @State private var isRefreshingApp = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedWorkspaceView = AppDetailWorkspaceView.keywords
    @State private var selectedStorefrontFilter = StorefrontFilter.all
    @State private var keywordWorkspaceState = KeywordWorkspaceState()
    @State private var ratingsRefreshToken = 0
    @State private var isImportingCSV = false
    @State private var isProcessingCSVImport = false
    @State private var isExportingCSV = false
    @State private var exportDocument = CSVDocument(text: "")
    @State private var exportDefaultFilename = "keywords.csv"
    @State private var transferAlert: TrackedKeywordTransferAlert?
    @State private var keywordRefreshToken = 0
    @State private var queuedKeywordAdds: [KeywordAddRequest] = []
    @State private var isFlushingQueuedKeywordAdds = false
    @State private var isRefreshingQueuedKeywordAdds = false

    init(trackedApp: TrackedApp) {
        self.trackedApp = trackedApp
        self.appStoreID = trackedApp.appStoreID
        self.bundleID = trackedApp.bundleID
        self.appName = trackedApp.name
        self.appSubtitle = trackedApp.subtitle
        self.appSellerName = trackedApp.sellerName
        self.defaultPlatform = trackedApp.defaultPlatform
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding([.horizontal, .top], 24)
                    .padding(.bottom, 18)
            }

            if selectedWorkspaceView == .ratings {
                AppRatingsView(
                    appStoreID: appStoreID,
                    bundleID: bundleID,
                    selectedStorefrontFilter: selectedStorefrontFilter,
                    searchText: searchText,
                    refreshToken: ratingsRefreshToken
                )
            } else {
                AppKeywordsView(
                    trackedApp: trackedApp,
                    searchText: searchText,
                    selectedStorefrontFilter: selectedStorefrontFilter,
                    selectedDateRange: keywordWorkspaceState.selectedDateRange,
                    selectedPlatformFilter: keywordWorkspaceState.selectedPlatformFilter,
                    popularityFilterRange: keywordWorkspaceState.popularityFilterRange,
                    difficultyFilterRange: keywordWorkspaceState.difficultyFilterRange,
                    positionFilterRange: keywordWorkspaceState.positionFilterRange,
                    changeFilterRange: keywordWorkspaceState.changeFilterRange,
                    showsOnlyChangedKeywords: keywordWorkspaceState.showsOnlyChangedKeywords,
                    refreshToken: keywordRefreshToken,
                    reportError: setErrorMessage
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                AppDetailRefreshToolbarButton(
                    isRefreshing: isRefreshingApp,
                    isDisabled: isRefreshDisabled,
                    action: refreshApp,
                    refreshAllAction: refreshAllApps
                )
                AppDetailWorkspaceViewPicker(selectedWorkspaceView: $selectedWorkspaceView)
                AppDetailStorefrontPickerButton(
                    trackedAppStoreID: appStoreID,
                    selectedStorefrontFilter: $selectedStorefrontFilter
                )
            }

            ToolbarItemGroup {
                if selectedWorkspaceView == .keywords {
                    AppDetailFilterToolbarItems(
                        keywordWorkspaceState: $keywordWorkspaceState
                    )
                }
            }

            if selectedWorkspaceView == .keywords {
                ToolbarItem(placement: .principal) {
                    AppDetailAddKeywordsToolbarButton {
                        isPresentingAddKeywords = true
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if selectedWorkspaceView == .keywords {
                    AppDetailImportExportToolbarMenu(
                        exportAction: prepareCSVExport,
                        exportHistoryAction: prepareKeywordHistoryCSVExport,
                        importAction: showCSVImporter,
                        isImportDisabled: isProcessingCSVImport || isImportingCSV
                    )
                } else if selectedWorkspaceView == .ratings {
                    AppDetailExportToolbarButton(
                        title: "Export",
                        help: "Export Ratings CSV",
                        action: prepareRatingsCSVExport
                    )
                }

                AppDetailToolbarSearchField(
                    selectedWorkspaceView: selectedWorkspaceView,
                    searchText: $searchText
                )
            }
        }
        .sheet(isPresented: $isPresentingAddKeywords, onDismiss: {
            keywordRefreshToken += 1
        }) {
            AddKeywordsSheet(
                trackedApp: trackedApp,
                initialStorefrontCode: addKeywordsInitialStorefrontCode,
                isRefreshInProgress: isRefreshInProgress,
                queueKeywordAdd: queueKeywordAdd
            )
        }
        .onAppear {
            services.analyticsService.capture(.workspaceViewed(selectedWorkspaceView))
            flushQueuedKeywordAdds()
        }
        .onChange(of: selectedWorkspaceView) { _, newValue in
            services.analyticsService.capture(.workspaceViewed(newValue))
        }
        .onChange(of: isRefreshInProgress) { _, inProgress in
            guard !inProgress else { return }
            flushQueuedKeywordAdds()
        }
        .onChange(of: activeKeywordMetricsRefreshSignature) { _, signature in
            guard signature != nil else { return }
            keywordRefreshToken += 1
        }
        .fileExporter(
            isPresented: $isExportingCSV,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportDefaultFilename
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

    private var isRefreshDisabled: Bool {
        isRefreshingApp
    }

    private var addKeywordsInitialStorefrontCode: String? {
        switch selectedStorefrontFilter {
        case .all:
            return nil
        case .storefront(let code, _):
            return code
        }
    }

    private var isRefreshInProgress: Bool {
        if isRefreshingApp || isRefreshingQueuedKeywordAdds {
            return true
        }

        guard let refresh = services.refreshProgressStore.activeRefresh else {
            return false
        }

        switch refresh.phase {
        case .completed, .failed:
            return false
        case .preparing, .refreshingKeywords, .refreshingMetrics, .refreshingRatings, .refreshingReviews, .finishing:
            return true
        }
    }

    private var activeKeywordMetricsRefreshSignature: String? {
        guard let refresh = services.refreshProgressStore.activeRefresh,
              refresh.appStoreID == appStoreID,
              refresh.metricsProgress.total > 0,
              refresh.metricsProgress.completed > 0
        else {
            return nil
        }

        return [
            refresh.id.uuidString,
            String(refresh.metricsProgress.completed),
            String(refresh.metricsProgress.failureCount),
            String(describing: refresh.metricsProgress.status)
        ].joined(separator: "::")
    }

    private func refreshApp() {
        isRefreshingApp = true
        errorMessage = nil
        let activeWorkspaceView = selectedWorkspaceView
        let request: AppDetailRefreshRequest
        let refreshService: AppDetailRefreshService

        do {
            guard let service = services.appDetailRefreshService else {
                throw OpenASOError.providerUnavailable("The background model store is unavailable.")
            }
            request = try makeRefreshRequest(activeWorkspaceView: activeWorkspaceView)
            refreshService = service
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            isRefreshingApp = false
            return
        }

        OpenASOLog.appDetail.info(
            "Refresh tapped appStoreID=\(appStoreID, privacy: .public) appName=\(appName, privacy: .public) view=\(activeWorkspaceView.title, privacy: .public) selectedStorefront=\(selectedStorefrontFilter.title, privacy: .public) keywords=\(request.trackIdentityKeys.count, privacy: .public)"
        )

        Task(priority: .userInitiated) {
            let result = await refreshService.refresh(request)

            await MainActor.run {
                if let firstError = result.firstError {
                    errorMessage = firstError.localizedDescription
                }
                keywordRefreshToken += 1
                ratingsRefreshToken += 1

                OpenASOLog.appDetail.info(
                    "Refresh finished appStoreID=\(appStoreID, privacy: .public) ratingSuccesses=\(result.ratingOutcomes.filter { $0.error == nil }.count, privacy: .public) ratingFailures=\(result.ratingOutcomes.filter { $0.error != nil }.count, privacy: .public) reviewSuccesses=\(result.reviewOutcomes.filter { $0.error == nil }.count, privacy: .public) reviewFailures=\(result.reviewOutcomes.filter { $0.error != nil }.count, privacy: .public) keywordFailures=\(result.keywordOutcomes.filter { $0.error != nil }.count, privacy: .public)"
                )
                isRefreshingApp = false
                flushQueuedKeywordAdds()
            }
        }
    }

    private func refreshAllApps() {
        isRefreshingApp = true
        errorMessage = nil
        let activeWorkspaceView = selectedWorkspaceView
        let requests: [AppDetailRefreshRequest]
        let refreshService: AppDetailRefreshService

        do {
            guard let service = services.appDetailRefreshService else {
                throw OpenASOError.providerUnavailable("The background model store is unavailable.")
            }
            requests = try makeRefreshAllRequests(activeWorkspaceView: activeWorkspaceView)
            refreshService = service
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            isRefreshingApp = false
            return
        }

        OpenASOLog.appDetail.info(
            "Refresh all tapped startingAppStoreID=\(appStoreID, privacy: .public) view=\(activeWorkspaceView.title, privacy: .public) selectedStorefront=\(selectedStorefrontFilter.title, privacy: .public) appCount=\(requests.count, privacy: .public)"
        )

        Task(priority: .userInitiated) {
            var firstError: OpenASOError?
            var ratingSuccesses = 0
            var ratingFailures = 0
            var reviewSuccesses = 0
            var reviewFailures = 0
            var keywordFailures = 0

            for request in requests {
                let result = await refreshService.refresh(request)
                if firstError == nil {
                    firstError = result.firstError
                }
                ratingSuccesses += result.ratingOutcomes.filter { $0.error == nil }.count
                ratingFailures += result.ratingOutcomes.filter { $0.error != nil }.count
                reviewSuccesses += result.reviewOutcomes.filter { $0.error == nil }.count
                reviewFailures += result.reviewOutcomes.filter { $0.error != nil }.count
                keywordFailures += result.keywordOutcomes.filter { $0.error != nil }.count

                if request.app.appStoreID == appStoreID {
                    await MainActor.run {
                        keywordRefreshToken += 1
                        ratingsRefreshToken += 1
                    }
                }
            }

            await MainActor.run {
                if let firstError {
                    errorMessage = firstError.localizedDescription
                }
                keywordRefreshToken += 1
                ratingsRefreshToken += 1

                OpenASOLog.appDetail.info(
                    "Refresh all finished startingAppStoreID=\(appStoreID, privacy: .public) appCount=\(requests.count, privacy: .public) ratingSuccesses=\(ratingSuccesses, privacy: .public) ratingFailures=\(ratingFailures, privacy: .public) reviewSuccesses=\(reviewSuccesses, privacy: .public) reviewFailures=\(reviewFailures, privacy: .public) keywordFailures=\(keywordFailures, privacy: .public)"
                )
                isRefreshingApp = false
                flushQueuedKeywordAdds()
            }
        }
    }

    private func queueKeywordAdd(_ request: KeywordAddRequest) {
        queuedKeywordAdds.append(request)
        services.refreshProgressStore.queuePendingKeywordAddition(
            appStoreID: appStoreID,
            trackCount: request.keywords.count * request.storefrontCodes.count
        )
        flushQueuedKeywordAdds()
    }

    private func flushQueuedKeywordAdds() {
        guard !queuedKeywordAdds.isEmpty, !isRefreshInProgress, !isFlushingQueuedKeywordAdds else {
            return
        }

        isFlushingQueuedKeywordAdds = true
        let requests = queuedKeywordAdds
        queuedKeywordAdds.removeAll()
        services.refreshProgressStore.clearPendingKeywordAdditions(appStoreID: appStoreID)
        addQueuedKeywordTracks(requests)
        isFlushingQueuedKeywordAdds = false
    }

    private func addQueuedKeywordTracks(_ requests: [KeywordAddRequest]) {
        let existingKeys: Set<String>
        do {
            existingKeys = try existingKeywordDuplicateKeys()
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            return
        }

        var mutableExistingKeys = existingKeys
        var insertedTracks: [TrackedAppKeyword] = []
        var insertedStorefrontCodes = Set<String>()
        var requestedKeywordCount = 0
        var requestedStorefrontCodes = Set<String>()
        for request in requests {
            requestedKeywordCount += request.keywords.count
            requestedStorefrontCodes.formUnion(request.storefrontCodes)
            let platform = request.platform

            for storefrontCode in request.storefrontCodes.sorted() {
                for keyword in request.keywords {
                    let identityKey = keywordDuplicateKey(term: keyword, storefront: storefrontCode, platform: platform)
                    guard !mutableExistingKeys.contains(identityKey) else { continue }

                    let query: KeywordQuery
                    do {
                        query = try KeywordQuery.fetchOrInsert(
                            term: keyword,
                            storefront: storefrontCode,
                            platform: platform,
                            in: modelContext
                        )
                    } catch {
                        errorMessage = OpenASOError.map(error).localizedDescription
                        return
                    }

                    let track = TrackedAppKeyword(
                        term: keyword,
                        storefront: storefrontCode,
                        platform: platform,
                        trackedApp: trackedApp,
                        query: query
                    )

                    trackedApp.keywordTracks.append(track)
                    modelContext.insert(track)
                    mutableExistingKeys.insert(identityKey)
                    insertedStorefrontCodes.insert(storefrontCode)
                    insertedTracks.append(track)
                }
            }
        }

        guard !insertedTracks.isEmpty else {
            return
        }

        do {
            try modelContext.save()
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            return
        }

        keywordRefreshToken += 1
        services.analyticsService.capture(.keywordAdded(
            keywordCount: requestedKeywordCount,
            storefrontCount: requestedStorefrontCodes.count
        ))

        guard let refreshService = services.appDetailRefreshService else {
            return
        }

        let request = AppDetailRefreshRequest(
            app: appSnapshot,
            workspace: .keywords,
            storefrontSelection: .all(codes: insertedStorefrontCodes.sorted()),
            trackIdentityKeys: insertedTracks.map(\.identityKey),
            trigger: "after_add_keyword",
            refreshRatings: false,
            refreshReviews: false,
            recordsRatingsReviewsRefresh: false,
            popularityContextAppStoreID: services.settingsStore.popularityContextAppStoreID,
            appleAdsWebSession: services.appleAdsWebSessionStore.session,
            appStoreConnectCredentials: services.appStoreConnectCredentialStore.credentials
        )

        isRefreshingQueuedKeywordAdds = true
        Task(priority: .utility) {
            let result = await refreshService.refresh(request)
            await MainActor.run {
                if let firstError = result.firstError {
                    errorMessage = firstError.localizedDescription
                }
                keywordRefreshToken += 1
                isRefreshingQueuedKeywordAdds = false
                flushQueuedKeywordAdds()
            }
        }
    }

    private func makeRefreshRequest(activeWorkspaceView: AppDetailWorkspaceView) throws -> AppDetailRefreshRequest {
        try makeRefreshRequest(
            for: appSnapshot,
            trackIdentityKeys: fetchTrackedKeywords(for: appStoreID, platformFilter: keywordWorkspaceState.selectedPlatformFilter).map(\.identityKey),
            activeWorkspaceView: activeWorkspaceView,
            trigger: "manual"
        )
    }

    private func makeRefreshAllRequests(activeWorkspaceView: AppDetailWorkspaceView) throws -> [AppDetailRefreshRequest] {
        let orderedApps = trackedAppsForRefreshAll()
        let platformFilter = keywordWorkspaceState.selectedPlatformFilter
        let tracksByAppStoreID = Dictionary(
            grouping: try fetchAllTrackedKeywords().filter { platformFilter.matches($0.platform) },
            by: \.appStoreID
        )
        return try orderedApps.map { app in
            try makeRefreshRequest(
                for: AppDetailRefreshAppSnapshot(
                    appStoreID: app.appStoreID,
                    bundleID: app.bundleID,
                    name: app.name,
                    subtitle: app.subtitle,
                    sellerName: app.sellerName,
                    defaultPlatform: app.defaultPlatform
                ),
                trackIdentityKeys: (tracksByAppStoreID[app.appStoreID] ?? []).map(\.identityKey),
                activeWorkspaceView: activeWorkspaceView,
                trigger: "manual_all"
            )
        }
    }

    private func trackedAppsForRefreshAll() -> [TrackedApp] {
        let activeAppStoreID = appStoreID
        return trackedApps.sorted { lhs, rhs in
            if lhs.appStoreID == activeAppStoreID { return true }
            if rhs.appStoreID == activeAppStoreID { return false }
            if lhs.sidebarSortOrder != rhs.sidebarSortOrder {
                return lhs.sidebarSortOrder < rhs.sidebarSortOrder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var appSnapshot: AppDetailRefreshAppSnapshot {
        AppDetailRefreshAppSnapshot(
            appStoreID: appStoreID,
            bundleID: bundleID,
            name: appName,
            subtitle: appSubtitle,
            sellerName: appSellerName,
            defaultPlatform: defaultPlatform
        )
    }

    private func makeRefreshRequest(
        for app: AppDetailRefreshAppSnapshot,
        trackIdentityKeys: [String],
        activeWorkspaceView: AppDetailWorkspaceView,
        trigger: String
    ) throws -> AppDetailRefreshRequest {
        let storefrontSelection: AppDetailRefreshStorefrontSelection
        switch selectedStorefrontFilter {
        case .all:
            let codes = try services.storefrontCatalog.bundledStorefronts()
                .map { $0.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            storefrontSelection = .all(codes: Array(Set(codes)).sorted())
        case .storefront(let code, _):
            storefrontSelection = .storefront(code: code)
        }

        let workspace: AppDetailRefreshWorkspace
        switch activeWorkspaceView {
        case .keywords:
            workspace = .keywords
        case .ratings:
            workspace = .ratings
        }

        return AppDetailRefreshRequest(
            app: app,
            workspace: workspace,
            storefrontSelection: storefrontSelection,
            trackIdentityKeys: trackIdentityKeys,
            trigger: trigger,
            popularityContextAppStoreID: services.settingsStore.popularityContextAppStoreID,
            appleAdsWebSession: services.appleAdsWebSessionStore.session,
            appStoreConnectCredentials: services.appStoreConnectCredentialStore.credentials
        )
    }

    private func setErrorMessage(_ message: String) {
        errorMessage = message
    }

    private var keywordExportFilename: String {
        let sanitizedName = appName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        return sanitizedName.isEmpty ? "keywords.csv" : "\(sanitizedName)-keywords.csv"
    }

    private var keywordHistoryExportFilename: String {
        let sanitizedName = appName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
        let rangeSuffix = keywordWorkspaceState.selectedDateRange.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
        let baseName = sanitizedName.isEmpty ? "keywords" : sanitizedName

        return "\(baseName)-ranking-history-\(rangeSuffix).csv"
    }

    private var ratingsExportFilename: String {
        let sanitizedName = appName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        return sanitizedName.isEmpty ? "ratings.csv" : "\(sanitizedName)-ratings.csv"
    }

    private func makeExportDocument() throws -> CSVDocument {
        let tracks = try fetchTrackedKeywords()
        let metricsByQueryKey = try services.keywordMetricsService.metricsMap(
            for: tracks.map(\.queryKey),
            in: modelContext
        )
        let rows = tracks.map { track in
            let snapshot = track.latestSnapshot
            let metrics = metricsByQueryKey[track.queryKey]

            return TrackedKeywordCSVRow(
                appName: appName,
                appID: String(appStoreID),
                platform: track.platform.rawValue,
                keyword: track.term,
                storeDomain: track.storefront,
                store: storefrontTitle(for: track.storefront),
                note: track.notes,
                lastUpdate: TrackedKeywordCSVFormat.string(from: track.lastRefreshAt ?? snapshot?.searchedAt),
                ranking: snapshot?.rank.map(String.init) ?? "1000",
                change: changeText(for: track),
                popularity: metrics?.popularityScore.map(String.init) ?? "",
                difficulty: metrics?.difficultyScore.map(String.init) ?? "",
                appsInRanking: String(track.rankingAppCount ?? snapshot?.resultCount ?? 0),
                tags: ""
            )
        }

        return CSVDocument(text: TrackedKeywordCSVFormat.encode(rows: rows))
    }

    private func makeKeywordHistoryExportDocument() throws -> CSVDocument {
        let tracks = try fetchTrackedKeywords()
        let metricsByQueryKey = try services.keywordMetricsService.metricsMap(
            for: tracks.map(\.queryKey),
            in: modelContext
        )
        let rows = tracks
            .filter { matchesExportStorefront($0) }
            .filter { matchesExportPlatform($0) }
            .filter { matchesExportSearch($0) }
            .filter { matchesExportMetrics($0, metrics: metricsByQueryKey[$0.queryKey]) }
            .filter(matchesExportChangedOnly)
            .flatMap { track in
                historicalRankingRows(
                    for: track,
                    metrics: metricsByQueryKey[track.queryKey]
                )
            }

        return CSVDocument(text: KeywordRankingHistoryCSVFormat.encode(rows: rows))
    }

    private func makeRatingsExportDocument() async throws -> CSVDocument {
        try await AppDetailRatingsCSVExporter.makeDocument(
            appStoreID: appStoreID,
            appName: appName,
            selectedStorefrontFilter: selectedStorefrontFilter,
            searchText: searchText,
            backgroundModelStore: services.backgroundModelStore,
            storefrontCatalog: services.storefrontCatalog
        )
    }

    private func prepareCSVExport() {
        do {
            exportDocument = try makeExportDocument()
            exportDefaultFilename = keywordExportFilename
            isExportingCSV = true
            services.analyticsService.capture(.csvExported(type: "keywords"))
        } catch {
            transferAlert = TrackedKeywordTransferAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func prepareKeywordHistoryCSVExport() {
        do {
            exportDocument = try makeKeywordHistoryExportDocument()
            exportDefaultFilename = keywordHistoryExportFilename
            isExportingCSV = true
            services.analyticsService.capture(.csvExported(type: "keyword_history"))
        } catch {
            transferAlert = TrackedKeywordTransferAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func prepareRatingsCSVExport() {
        Task {
            do {
                exportDocument = try await makeRatingsExportDocument()
                exportDefaultFilename = ratingsExportFilename
                isExportingCSV = true
                services.analyticsService.capture(.csvExported(type: "ratings"))
            } catch {
                transferAlert = TrackedKeywordTransferAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
    }

    private func showCSVImporter() {
        guard !isProcessingCSVImport, !isImportingCSV else {
            return
        }
        isImportingCSV = true
    }

    private func changeText(for track: TrackedAppKeyword) -> String {
        guard
            let currentRank = track.latestSnapshot?.rank,
            let previousRank = track.previousSnapshot?.rank
        else {
            return "0"
        }

        return String(previousRank - currentRank)
    }

    private func historicalRankingRows(
        for track: TrackedAppKeyword,
        metrics: KeywordDailyMetric?
    ) -> [KeywordRankingHistoryCSVRow] {
        let snapshots = filteredSnapshots(for: track).sorted { $0.searchedAt < $1.searchedAt }
        guard
            snapshots.count > 1,
            let periodStartRank = snapshots.first?.rank,
            let periodEndRank = snapshots.last?.rank,
            matchesExportValue(periodStartRank - periodEndRank, in: keywordWorkspaceState.changeFilterRange, configuration: .change)
        else {
            return []
        }

        var previousRank: Int?
        return snapshots.map { snapshot in
            let snapshotChange = changeText(currentRank: snapshot.rank, previousRank: previousRank)
            let periodChange = changeText(currentRank: snapshot.rank, previousRank: periodStartRank)
            previousRank = snapshot.rank

            return KeywordRankingHistoryCSVRow(
                appName: appName,
                appID: String(appStoreID),
                platform: track.platform.rawValue,
                keyword: track.term,
                storeDomain: track.storefront,
                store: storefrontTitle(for: track.storefront),
                observedAt: KeywordRankingHistoryCSVFormat.string(from: snapshot.searchedAt),
                ranking: snapshot.rank.map(String.init) ?? "1000",
                change: snapshotChange,
                periodChange: periodChange,
                popularity: metrics?.popularityScore.map(String.init) ?? "",
                difficulty: metrics?.difficultyScore.map(String.init) ?? "",
                appsInRanking: String(snapshot.resultCount),
                source: snapshot.sourceRaw,
                error: snapshot.errorMessage ?? ""
            )
        }
    }

    private func filteredSnapshots(for track: TrackedAppKeyword) -> [TrackedKeywordDailyRanking] {
        track.sortedSnapshots.filter { snapshot in
            guard let cutoffDate = keywordWorkspaceState.selectedDateRange.cutoffDate else {
                return true
            }

            return snapshot.searchedAt >= cutoffDate
        }
    }

    private func matchesExportStorefront(_ track: TrackedAppKeyword) -> Bool {
        switch selectedStorefrontFilter {
        case .all:
            return true
        case .storefront(let code, _):
            return track.storefront == code
        }
    }

    private func matchesExportPlatform(_ track: TrackedAppKeyword) -> Bool {
        keywordWorkspaceState.selectedPlatformFilter.matches(track.platform)
    }

    private func matchesExportSearch(_ track: TrackedAppKeyword) -> Bool {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return true
        }

        return track.term.localizedCaseInsensitiveContains(trimmedSearch)
    }

    private func matchesExportMetrics(_ track: TrackedAppKeyword, metrics: KeywordDailyMetric?) -> Bool {
        guard matchesExportValue(metrics?.popularityScore, in: keywordWorkspaceState.popularityFilterRange, configuration: .popularity),
              matchesExportValue(metrics?.difficultyScore, in: keywordWorkspaceState.difficultyFilterRange, configuration: .difficulty)
        else {
            return false
        }

        let snapshots = filteredSnapshots(for: track)
        guard let latestRank = snapshots.last?.rank else {
            return MetricFilterRange.position.isDefault(keywordWorkspaceState.positionFilterRange)
        }

        return matchesExportValue(latestRank, in: keywordWorkspaceState.positionFilterRange, configuration: .position)
    }

    private func matchesExportChangedOnly(_ track: TrackedAppKeyword) -> Bool {
        guard keywordWorkspaceState.showsOnlyChangedKeywords else {
            return true
        }

        let rankedSnapshots = filteredSnapshots(for: track).compactMap(\.rank)
        guard let firstRank = rankedSnapshots.first, let latestRank = rankedSnapshots.last else {
            return false
        }

        return firstRank != latestRank
    }

    private func matchesExportValue(_ value: Int?, in range: ClosedRange<Double>, configuration: MetricFilterRange) -> Bool {
        if configuration.isDefault(range) {
            return true
        }

        guard let value else {
            return false
        }

        return range.contains(Double(value))
    }

    private func changeText(currentRank: Int?, previousRank: Int?) -> String {
        guard let currentRank, let previousRank else {
            return "0"
        }

        let change = previousRank - currentRank
        if change > 0 {
            return "+\(change)"
        }

        if change < 0 {
            return String(change)
        }

        return "0"
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
            services.analyticsService.capture(.csvImported(rowCount: summary.insertedCount, result: "success"))
            refreshImportedTracksInBackground(summary.importedTracks)

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
            services.analyticsService.capture(.csvImported(rowCount: 0, result: "failure"))
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
            setErrorMessage(OpenASOError.map(error).localizedDescription)
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
            guard let rowAppStoreID = importAppStoreID(from: row.appID, defaultAppStoreID: appStoreID) else {
                summary.skippedInvalidCount += 1
                continue
            }

            let platform = rowPlatform ?? defaultPlatform
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
                setErrorMessage(OpenASOError.map(error).localizedDescription)
                summary.failedRowCount += summary.insertedCount
                summary.importedTracks.removeAll()
                summary.importedAppIDs.removeAll()
                summary.insertedCount = 0
                summary.createdAppCount = 0
            }
        }
        return summary
    }

    private func refreshImportedTracksInBackground(_ importedTracks: [TrackedAppKeyword]) {
        guard !importedTracks.isEmpty else {
            return
        }
        guard let refreshService = services.appDetailRefreshService else {
            return
        }

        let storefrontSelection: AppDetailRefreshStorefrontSelection
        do {
            let codes = try services.storefrontCatalog.bundledStorefronts()
                .map { $0.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            storefrontSelection = .all(codes: Array(Set(codes)).sorted())
        } catch {
            setErrorMessage(OpenASOError.map(error).localizedDescription)
            return
        }

        let requests = importedKeywordRefreshRequests(
            importedTracks: importedTracks,
            storefrontSelection: storefrontSelection
        )
        guard !requests.isEmpty else {
            return
        }

        Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask {
                        _ = await refreshService.refresh(request)
                    }
                }
            }
            await MainActor.run {
                keywordRefreshToken += 1
                ratingsRefreshToken += 1
            }
        }
    }

    private func importedKeywordRefreshRequests(
        importedTracks: [TrackedAppKeyword],
        storefrontSelection: AppDetailRefreshStorefrontSelection
    ) -> [AppDetailRefreshRequest] {
        let tracksByAppStoreID = Dictionary(grouping: importedTracks, by: \.appStoreID)
        let orderedAppStoreIDs = tracksByAppStoreID.keys.sorted { lhs, rhs in
            let lhsIsCurrentApp = lhs == trackedApp.appStoreID
            let rhsIsCurrentApp = rhs == trackedApp.appStoreID
            if lhsIsCurrentApp != rhsIsCurrentApp {
                return lhsIsCurrentApp
            }
            return lhs < rhs
        }

        return orderedAppStoreIDs.compactMap { appStoreID in
            guard let tracks = tracksByAppStoreID[appStoreID], let trackedApp = tracks.first?.trackedApp else {
                return nil
            }

            return AppDetailRefreshRequest(
                app: AppDetailRefreshAppSnapshot(
                    appStoreID: trackedApp.appStoreID,
                    bundleID: trackedApp.bundleID,
                    name: trackedApp.name,
                    subtitle: trackedApp.subtitle,
                    sellerName: trackedApp.sellerName,
                    defaultPlatform: trackedApp.defaultPlatform
                ),
                workspace: .keywords,
                storefrontSelection: storefrontSelection,
                trackIdentityKeys: tracks.map(\.identityKey),
                trigger: "after_import_keywords",
                refreshRatings: false,
                refreshReviews: false,
                recordsRatingsReviewsRefresh: false,
                popularityContextAppStoreID: services.settingsStore.popularityContextAppStoreID,
                appleAdsWebSession: services.appleAdsWebSessionStore.session,
                appStoreConnectCredentials: services.appStoreConnectCredentialStore.credentials
            )
        }
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

    private func fetchTrackedKeywords() throws -> [TrackedAppKeyword] {
        try fetchTrackedKeywords(for: appStoreID, platformFilter: keywordWorkspaceState.selectedPlatformFilter)
    }

    private func fetchTrackedKeywords(for appStoreID: Int64, platformFilter: PlatformFilter = .all) throws -> [TrackedAppKeyword] {
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.appStoreID == appStoreID
            },
            sortBy: [
                SortDescriptor(\TrackedAppKeyword.term, order: .forward),
                SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
                SortDescriptor(\TrackedAppKeyword.platformRaw, order: .forward)
            ]
        )
        return try modelContext.fetch(descriptor)
            .filter { platformFilter.matches($0.platform) }
    }

    private func existingKeywordDuplicateKeys() throws -> Set<String> {
        Set(
            try fetchTrackedKeywords()
                .map { keywordDuplicateKey(term: $0.term, storefront: $0.storefront, platform: $0.platform) }
        )
    }

    private func keywordDuplicateKey(term: String, storefront: String, platform: AppPlatform) -> String {
        [
            term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform.rawValue
        ].joined(separator: "::")
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

    private func storefrontTitle(for code: String) -> String {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard
            let storefront = try? services.storefrontCatalog.bundledStorefronts()
                .first(where: { $0.code.lowercased() == normalizedCode })
        else {
            return code.uppercased()
        }

        return "\(storefront.flagEmoji) \(storefront.name)"
    }
}
