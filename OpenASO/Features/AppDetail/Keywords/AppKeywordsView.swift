import SwiftData
import SwiftUI

struct AppKeywordsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query private var tracks: [TrackedAppKeyword]

    let trackedApp: TrackedApp
    let searchText: String
    let selectedStorefrontFilter: StorefrontFilter
    let selectedDateRange: TrendDateRange
    let selectedPlatformFilter: PlatformFilter
    let popularityFilterRange: ClosedRange<Double>
    let difficultyFilterRange: ClosedRange<Double>
    let positionFilterRange: ClosedRange<Double>
    let changeFilterRange: ClosedRange<Double>
    let showsOnlyChangedKeywords: Bool
    let refreshToken: Int
    let reportError: (String) -> Void

    @State private var workspaceModel = KeywordWorkspaceModel()

    init(
        trackedApp: TrackedApp,
        searchText: String,
        selectedStorefrontFilter: StorefrontFilter,
        selectedDateRange: TrendDateRange,
        selectedPlatformFilter: PlatformFilter,
        popularityFilterRange: ClosedRange<Double>,
        difficultyFilterRange: ClosedRange<Double>,
        positionFilterRange: ClosedRange<Double>,
        changeFilterRange: ClosedRange<Double>,
        showsOnlyChangedKeywords: Bool,
        refreshToken: Int,
        reportError: @escaping (String) -> Void
    ) {
        self.trackedApp = trackedApp
        self.searchText = searchText
        self.selectedStorefrontFilter = selectedStorefrontFilter
        self.selectedDateRange = selectedDateRange
        self.selectedPlatformFilter = selectedPlatformFilter
        self.popularityFilterRange = popularityFilterRange
        self.difficultyFilterRange = difficultyFilterRange
        self.positionFilterRange = positionFilterRange
        self.changeFilterRange = changeFilterRange
        self.showsOnlyChangedKeywords = showsOnlyChangedKeywords
        self.refreshToken = refreshToken
        self.reportError = reportError

        let appStoreID = trackedApp.appStoreID
        let sortBy = [
            SortDescriptor(\TrackedAppKeyword.term, order: .forward),
            SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
            SortDescriptor(\TrackedAppKeyword.platformRaw, order: .forward)
        ]
        switch selectedStorefrontFilter {
        case .all:
            _tracks = Query(
                filter: #Predicate<TrackedAppKeyword> { track in
                    track.appStoreID == appStoreID
                },
                sort: sortBy
            )
        case .storefront(let code, _):
            let storefrontCode = code
            _tracks = Query(
                filter: #Predicate<TrackedAppKeyword> { track in
                    track.appStoreID == appStoreID && track.storefront == storefrontCode
                },
                sort: sortBy
            )
        }
    }

    private func materializationID(
        tracks: [TrackedAppKeyword]
    ) -> KeywordWorkspaceProjection.MaterializationID {
        return KeywordWorkspaceProjection.MaterializationID(
            refreshToken: refreshToken,
            backgroundStoreRevision: services.backgroundModelStoreRevision,
            appStoreID: trackedApp.appStoreID,
            storefrontFilterID: selectedStorefrontFilter.id,
            platformFilterID: selectedPlatformFilter.id,
            dateRangeID: selectedDateRange.id,
            tracks: tracks.map { track in
                KeywordWorkspaceProjection.MaterializationID.TrackIdentity(
                    identityKey: track.identityKey
                )
            }
        )
    }

    private var filters: KeywordWorkspaceProjection.Filters {
        KeywordWorkspaceProjection.Filters(
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            popularityRange: popularityFilterRange,
            difficultyRange: difficultyFilterRange,
            positionRange: positionFilterRange,
            changeRange: changeFilterRange,
            showsOnlyChangedKeywords: showsOnlyChangedKeywords
        )
    }

    private var storefrontDefinitions: [StorefrontDefinition] {
        ((try? services.storefrontCatalog.bundledStorefronts()) ?? []).map {
            StorefrontDefinition(
                code: $0.code.lowercased(),
                name: $0.name,
                flagEmoji: $0.flagEmoji,
                title: "\($0.flagEmoji) \($0.name)"
            )
        }
    }

    private func makeRows(
        from tracks: [TrackedAppKeyword],
        workspace: KeywordInsightsService.Workspace?,
        storefrontLookup: [String: StorefrontDefinition]
    ) -> [KeywordWorkspaceRow] {
        var rows: [KeywordWorkspaceRow] = []
        rows.reserveCapacity(tracks.count)

        for track in tracks {
            let loadedRow = workspace?.rowsByIdentityKey[track.identityKey]
            rows.append(
                KeywordWorkspaceRow(
                    track: track,
                    storefront: storefrontLookup[track.storefront],
                    metrics: loadedRow?.metrics,
                    refreshStatus: loadedRow?.refreshStatus ?? .empty,
                    latestSnapshot: loadedRow?.latestSnapshot,
                    trendSnapshots: loadedRow?.trendSnapshots ?? [],
                    rankingApps: loadedRow?.rankingApps ?? []
                )
            )
        }

        return KeywordWorkspaceProjection.orderedRows(rows)
    }

    var body: some View {
        let queriedTracks = tracks
        let targetMaterializationID = materializationID(tracks: queriedTracks)
        let storefronts = storefrontDefinitions
        KeywordWorkspaceContent(
            workspaceModel: workspaceModel,
            targetMaterializationID: targetMaterializationID,
            filters: filters,
            hasTrackedKeywords: !queriedTracks.isEmpty,
            trackedAppStoreID: trackedApp.appStoreID,
            chartSelectionScope: selectedStorefrontFilter.id,
            selectedDateRange: selectedDateRange,
            storefronts: storefronts,
            reportError: reportError
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: targetMaterializationID) {
            await materializeKeywordRows(
                for: targetMaterializationID,
                tracks: queriedTracks
            )
        }
    }

    private func materializeKeywordRows(
        for targetMaterializationID: KeywordWorkspaceProjection.MaterializationID,
        tracks: [TrackedAppKeyword]
    ) async {
        let platformTracks = tracks.filter { selectedPlatformFilter.matches($0.platform) }
        let storefrontLookup = Dictionary(
            uniqueKeysWithValues: storefrontDefinitions.map { ($0.code, $0) }
        )
        let primedWorkspace = services.keywordInsightsService.cachedWorkspace(
            for: targetMaterializationID
        )
        workspaceModel.prime(
            id: targetMaterializationID,
            rows: makeRows(
                from: platformTracks,
                workspace: primedWorkspace,
                storefrontLookup: storefrontLookup
            ),
            filters: filters
        )

        let errorMessage = await workspaceModel.materialize(
            id: targetMaterializationID,
            initialFilters: filters
        ) {
            try Task.checkCancellation()
            let workspace = try await services.keywordInsightsService.workspace(
                for: targetMaterializationID,
                tracks: platformTracks,
                appStoreID: trackedApp.appStoreID,
                dateRange: selectedDateRange,
                using: services.backgroundModelStore,
                fallbackModelContext: modelContext
            )
            return makeRows(
                from: platformTracks,
                workspace: workspace,
                storefrontLookup: storefrontLookup
            )
        }

        if let errorMessage {
            reportError(errorMessage)
        }
    }

}

private struct KeywordWorkspaceContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    let workspaceModel: KeywordWorkspaceModel
    let targetMaterializationID: KeywordWorkspaceProjection.MaterializationID
    let filters: KeywordWorkspaceProjection.Filters
    let hasTrackedKeywords: Bool
    let trackedAppStoreID: Int64
    let chartSelectionScope: String
    let selectedDateRange: TrendDateRange
    let storefronts: [StorefrontDefinition]
    let reportError: (String) -> Void

    private var filterID: KeywordWorkspaceProjection.FilterID {
        KeywordWorkspaceProjection.FilterID(
            materializationGeneration: workspaceModel.materializationGeneration,
            filters: filters
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasTrackedKeywords {
                ContentUnavailableView(
                    "No Keywords Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Add one or more keywords and choose countries to start tracking this app.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                KeywordTableView(
                    rows: workspaceModel.rows,
                    isLoadingRows: workspaceModel.isLoading(for: targetMaterializationID),
                    contentRevision: workspaceModel.contentRevision,
                    sortRevision: workspaceModel.materializationGeneration,
                    trackedAppStoreID: trackedAppStoreID,
                    chartSelectionScope: chartSelectionScope,
                    insightsSummary: workspaceModel.insightsSummary,
                    storefronts: storefronts,
                    modelContext: modelContext,
                    appCatalogService: services.appCatalogService,
                    appIconStore: services.appIconStore
                )
                .equatable()
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                .layoutPriority(1)
            }
        }
        .background {
            KeywordDataUpdateListener(
                workspaceModel: workspaceModel,
                appStoreID: trackedAppStoreID,
                dateRange: selectedDateRange,
                reportError: reportError
            )
        }
        .task(id: filterID) {
            await workspaceModel.updateFilter(id: filterID) { rows, filters in
                try await KeywordWorkspaceProjection.debouncedRows(
                    rows,
                    filters: filters
                )
            }
        }
    }
}

private struct KeywordDataUpdateListener: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    let workspaceModel: KeywordWorkspaceModel
    let appStoreID: Int64
    let dateRange: TrendDateRange
    let reportError: (String) -> Void

    var body: some View {
        let update = services.refreshProgressStore.keywordDataUpdate(for: appStoreID)
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: update?.revision) {
                guard let update else { return }
                do {
                    let updatedRows = try await services.keywordInsightsService.updatedRows(
                        for: update.identityKeys,
                        appStoreID: appStoreID,
                        dateRange: dateRange,
                        using: services.backgroundModelStore,
                        fallbackModelContext: modelContext
                    )
                    workspaceModel.applyUpdatedRows(updatedRows)
                } catch is CancellationError {
                    return
                } catch {
                    reportError(OpenASOError.map(error).localizedDescription)
                }
            }
    }
}

#Preview("Keyword Workspace") {
    AppKeywordsPreviewHarness()
}

private struct AppKeywordsPreviewHarness: View {
    private let previewContainer: OpenASOPreviewContainer<TrackedApp>

    init() {
        self.previewContainer = OpenASOPreviewContainer(seed: Self.seed)
    }

    private var trackedApp: TrackedApp {
        previewContainer.seedData
    }

    var body: some View {
        AppKeywordsView(
            trackedApp: trackedApp,
            searchText: "",
            selectedStorefrontFilter: .all,
            selectedDateRange: .last30Days,
            selectedPlatformFilter: .all,
            popularityFilterRange: MetricFilterRange.popularity.defaultRange,
            difficultyFilterRange: MetricFilterRange.difficulty.defaultRange,
            positionFilterRange: MetricFilterRange.position.defaultRange,
            changeFilterRange: MetricFilterRange.change.defaultRange,
            showsOnlyChangedKeywords: false,
            refreshToken: 0,
            reportError: { _ in }
        )
        .openASOPreviewEnvironment(previewContainer)
        .frame(width: 1280, height: 760)
        .padding(24)
    }

    private static func seed(in modelContext: ModelContext) -> TrackedApp {
        let trackedApp = TrackedApp(
            appStoreID: 6448311069,
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            subtitle: "AI chatbot for writing and learning",
            sellerName: "OpenAI",
            defaultPlatform: .iphone
        )
        let storefronts = [
            Storefront(code: "us", name: "United States", flagEmoji: "US", languageCode: "en"),
            Storefront(code: "gb", name: "United Kingdom", flagEmoji: "GB", languageCode: "en"),
            Storefront(code: "ca", name: "Canada", flagEmoji: "CA", languageCode: "en")
        ]
        let competitors = [
            PreviewRankedApp(appStoreID: trackedApp.appStoreID, name: trackedApp.name, subtitle: trackedApp.subtitle, sellerName: trackedApp.sellerName ?? "OpenAI"),
            PreviewRankedApp(appStoreID: 310633997, name: "Google", subtitle: "Search, images and AI chatbot help", sellerName: "Google LLC"),
            PreviewRankedApp(appStoreID: 1444383602, name: "Perplexity", subtitle: "Ask anything with AI search", sellerName: "Perplexity AI, Inc."),
            PreviewRankedApp(appStoreID: 1668000334, name: "Microsoft Copilot", subtitle: "Your everyday AI companion", sellerName: "Microsoft Corporation"),
            PreviewRankedApp(appStoreID: 6479726147, name: "Claude", subtitle: "AI assistant for deep work", sellerName: "Anthropic PBC")
        ]
        let fixtures = [
            PreviewKeywordFixture(
                term: "ai chatbot",
                storefrontCode: "us",
                popularity: 92,
                difficulty: 64,
                ranks: [19, 12, 8, 5, 3, 2, 1],
                topApps: [0, 2, 3, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "essay writer",
                storefrontCode: "us",
                popularity: 88,
                difficulty: 83,
                ranks: [7, 7, 8, 8, 9, 11, 12],
                topApps: [2, 3, 0, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "homework help",
                storefrontCode: "gb",
                popularity: 76,
                difficulty: 71,
                ranks: [34, 31, 30, 28, 25, 21, 16],
                topApps: [3, 0, 2, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "ai image generator",
                storefrontCode: "ca",
                popularity: 84,
                difficulty: 91,
                ranks: [42, 39, 44, 36, 38, 29, 24],
                topApps: [1, 2, 4, 0, 3]
            ),
            PreviewKeywordFixture(
                term: "productivity ai",
                storefrontCode: "us",
                popularity: 58,
                difficulty: 46,
                ranks: [nil],
                errorMessage: "Lookup failed",
                topApps: []
            )
        ]

        modelContext.insert(trackedApp)
        storefronts.forEach(modelContext.insert)

        for fixture in fixtures {
            let query = try! KeywordQuery.fetchOrInsert(
                term: fixture.term,
                storefront: fixture.storefrontCode,
                platform: .iphone,
                in: modelContext
            )
            let track = TrackedAppKeyword(
                term: fixture.term,
                storefront: fixture.storefrontCode,
                platform: .iphone,
                trackedApp: trackedApp,
                query: query
            )
            track.statusMessage = fixture.errorMessage.map { "Ranking failed to refresh. \($0)" }

            let metrics = KeywordDailyMetric(
                queryKey: track.queryKey,
                keyword: track.term,
                storefront: track.storefront,
                platform: track.platform,
                popularityScore: fixture.popularity,
                difficultyScore: fixture.difficulty,
                source: .appleAdsPopularity
            )
            let snapshots = fixture.ranks.enumerated().map { offset, rank in
                TrackedKeywordDailyRanking(
                    rank: rank,
                    searchedAt: Calendar.current.date(
                        byAdding: .day,
                        value: offset - max(fixture.ranks.count - 1, 0),
                        to: .now
                    ) ?? .now,
                    source: .appStoreWeb,
                    resultCount: fixture.resultCount,
                    errorMessage: rank == nil ? fixture.errorMessage : nil,
                    keywordTrack: track
                )
            }

            trackedApp.keywordTracks.append(track)
            modelContext.insert(track)
            modelContext.insert(metrics)
            snapshots.forEach {
                track.snapshots.append($0)
                modelContext.insert($0)
            }

            if let latestSnapshot = snapshots.last {
                fixture.topApps.enumerated().forEach { position, competitorIndex in
                    let app = competitors[competitorIndex]
                    let result = TrackedKeywordRankedResult(
                        position: position + 1,
                        appStoreID: app.appStoreID,
                        bundleID: nil,
                        name: app.name,
                        subtitle: app.subtitle,
                        sellerName: app.sellerName,
                        snapshot: latestSnapshot
                    )
                    latestSnapshot.topResults.append(result)
                    modelContext.insert(result)
                }
            }
        }

        try? modelContext.save()
        return trackedApp
    }

    private struct PreviewKeywordFixture {
        let term: String
        let storefrontCode: String
        let popularity: Int?
        let difficulty: Int?
        let ranks: [Int?]
        let errorMessage: String?
        let resultCount: Int
        let topApps: [Int]

        init(
            term: String,
            storefrontCode: String,
            popularity: Int?,
            difficulty: Int?,
            ranks: [Int?],
            errorMessage: String? = nil,
            resultCount: Int = 50,
            topApps: [Int]
        ) {
            self.term = term
            self.storefrontCode = storefrontCode
            self.popularity = popularity
            self.difficulty = difficulty
            self.ranks = ranks
            self.errorMessage = errorMessage
            self.resultCount = resultCount
            self.topApps = topApps
        }
    }

    private struct PreviewRankedApp {
        let appStoreID: Int64
        let name: String
        let subtitle: String?
        let sellerName: String
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
