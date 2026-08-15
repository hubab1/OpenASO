import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordWorkspaceProjectionTests {
    @Test
    func precomputesLongHistoryAndPreservesFilterSemantics() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let longHistory = (0..<10_000).reversed().map { index in
            KeywordRankingCrawlSummary(
                id: "history-\(index)",
                rank: index == 4_000 ? nil : 10 + index % 100,
                searchedAt: start.addingTimeInterval(TimeInterval(index * 60)),
                source: .appStoreWeb,
                resultCount: 300
            )
        }
        let focusRow = makeRow(
            term: "Focus Timer",
            appStoreID: 1,
            currentRank: 5,
            popularity: 80,
            difficulty: 40,
            trendSnapshots: longHistory
        )
        let habitRow = makeRow(
            term: "Habit Tracker",
            appStoreID: 2,
            currentRank: 2,
            popularity: 20,
            difficulty: 70,
            trendSnapshots: [
                summary(id: "habit-old", rank: 2, date: start),
                summary(id: "habit-new", rank: 2, date: start.addingTimeInterval(60))
            ]
        )
        let unrankedRow = makeRow(
            term: "Pomodoro",
            appStoreID: 3,
            currentRank: nil,
            popularity: nil,
            difficulty: nil,
            trendSnapshots: []
        )

        #expect(focusRow.trendSnapshots.first?.id == "history-0")
        #expect(focusRow.trendSnapshots.last?.id == "history-9999")
        #expect(focusRow.trendPoints.count == 9_999)
        #expect(focusRow.trendDelta == -99)

        let ordered = KeywordWorkspaceProjection.orderedRows([focusRow, unrankedRow, habitRow])
        #expect(ordered.map { $0.track.term } == ["Habit Tracker", "Focus Timer", "Pomodoro"])

        let filtered = KeywordWorkspaceProjection.filteredRows(
            ordered,
            filters: filters(searchText: "FOCUS", popularityRange: 50...100, changedOnly: true)
        )
        #expect(filtered.map { $0.track.term } == ["Focus Timer"])
    }

    @Test
    func initialMaterializationPublishesLatestFiltersAndLoadingCompletionTogether() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let id = materializationID(refreshToken: 1)
        let focusRow = makeRow(term: "Focus Timer", appStoreID: 1)
        let habitRow = makeRow(term: "Habit Tracker", appStoreID: 2)

        let loadTask = Task { @MainActor in
            await model.materialize(
                id: id,
                initialFilters: filters(searchText: "focus"),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)
        #expect(model.isLoading(for: id))
        #expect(model.rows.isEmpty)

        let latestFilters = filters(searchText: "habit")
        var didRunDebouncedFilter = false
        await model.updateFilter(
            id: KeywordWorkspaceProjection.FilterID(
                materializationGeneration: model.materializationGeneration,
                filters: latestFilters
            )
        ) { rows, filters in
            didRunDebouncedFilter = true
            return KeywordWorkspaceProjection.filteredRows(rows, filters: filters)
        }
        #expect(!didRunDebouncedFilter)

        materializer.succeedRequest(at: 0, with: [focusRow, habitRow])
        let errorMessage = await loadTask.value

        #expect(errorMessage == nil)
        #expect(!model.isLoading(for: id))
        #expect(model.rows.map { $0.track.term } == ["Habit Tracker"])
    }

    @Test
    func primedRowsRemainVisibleWhileHistoryMaterializes() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let id = materializationID(refreshToken: 1)
        let shellRow = makeRow(term: "Focus Timer", appStoreID: 1)
        let hydratedRow = makeRow(term: "Focus Timer", appStoreID: 1, currentRank: 4)

        model.prime(id: id, rows: [shellRow], filters: filters())
        #expect(model.rows.map(\.track.term) == ["Focus Timer"])
        #expect(model.rows.first?.currentRank == nil)
        #expect(!model.isLoading(for: id))

        let loadTask = Task { @MainActor in
            await model.materialize(
                id: id,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)

        #expect(model.rows.map(\.track.term) == ["Focus Timer"])
        #expect(model.rows.first?.currentRank == nil)

        materializer.succeedRequest(at: 0, with: [hydratedRow])
        let errorMessage = await loadTask.value

        #expect(errorMessage == nil)
        #expect(model.rows.first?.currentRank == 4)
    }

    @Test
    func popularityRevisionKeepsCompleteHistoryVisibleWhileReplacementMaterializes() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let initialID = materializationID(refreshToken: 1, backgroundStoreRevision: 0)
        let refreshedID = materializationID(refreshToken: 1, backgroundStoreRevision: 1)
        let history = [
            summary(
                id: "focus-old",
                rank: 9,
                date: Date(timeIntervalSince1970: 1_999_913_600)
            ),
            summary(
                id: "focus-latest",
                rank: 4,
                date: Date(timeIntervalSince1970: 2_000_000_000)
            )
        ]
        let hydratedRow = makeRow(
            term: "Focus Timer",
            appStoreID: 1,
            currentRank: 4,
            popularity: 60,
            trendSnapshots: history
        )
        let initialError = await model.materialize(
            id: initialID,
            initialFilters: filters()
        ) {
            [hydratedRow]
        }
        #expect(initialError == nil)

        let shellRow = makeRow(term: "Focus Timer", appStoreID: 1)
        model.prime(id: refreshedID, rows: [shellRow], filters: filters())

        #expect(model.isLoading(for: refreshedID))
        #expect(model.rows.first?.currentRank == 4)
        #expect(model.rows.first?.trendSnapshots.map(\.rank) == [9, 4])
        #expect(model.rows.first?.trendPoints.count == 2)

        let loadTask = Task { @MainActor in
            await model.materialize(
                id: refreshedID,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)

        #expect(model.rows.first?.currentRank == 4)
        #expect(model.rows.first?.trendSnapshots.map(\.rank) == [9, 4])

        materializer.succeedRequest(at: 0, with: [hydratedRow])
        let refreshedError = await loadTask.value

        #expect(refreshedError == nil)
        #expect(!model.isLoading(for: refreshedID))
        #expect(model.rows.first?.currentRank == 4)
        #expect(model.rows.first?.trendSnapshots.map(\.rank) == [9, 4])
    }

    @Test
    func failedPopularityRevisionKeepsPreviouslyLoadedHistory() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let initialID = materializationID(refreshToken: 1, backgroundStoreRevision: 0)
        let refreshedID = materializationID(refreshToken: 1, backgroundStoreRevision: 1)
        let history = [
            summary(
                id: "focus-old",
                rank: 9,
                date: Date(timeIntervalSince1970: 1_999_913_600)
            ),
            summary(
                id: "focus-latest",
                rank: 4,
                date: Date(timeIntervalSince1970: 2_000_000_000)
            )
        ]
        let hydratedRow = makeRow(
            term: "Focus Timer",
            appStoreID: 1,
            currentRank: 4,
            popularity: 60,
            trendSnapshots: history
        )
        _ = await model.materialize(id: initialID, initialFilters: filters()) {
            [hydratedRow]
        }

        model.prime(
            id: refreshedID,
            rows: [makeRow(term: "Focus Timer", appStoreID: 1)],
            filters: filters()
        )
        let loadTask = Task { @MainActor in
            await model.materialize(
                id: refreshedID,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)
        materializer.failRequest(at: 0)
        let errorMessage = await loadTask.value

        #expect(errorMessage != nil)
        #expect(!model.isLoading(for: refreshedID))
        #expect(model.rows.first?.currentRank == 4)
        #expect(model.rows.first?.trendSnapshots.map(\.rank) == [9, 4])
    }

    @Test
    func failedHydrationDoesNotDiscardPrimedRows() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let id = materializationID(refreshToken: 1)
        let shellRow = makeRow(term: "Focus Timer", appStoreID: 1)

        model.prime(id: id, rows: [shellRow], filters: filters())
        let loadTask = Task { @MainActor in
            await model.materialize(
                id: id,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)
        materializer.failRequest(at: 0)

        let errorMessage = await loadTask.value
        #expect(errorMessage != nil)
        #expect(model.rows.map(\.track.term) == ["Focus Timer"])
    }

    @Test
    func insightsWorkspaceLoadsOnceInBackgroundAndIsCached() async throws {
        let container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let modelContext = ModelContext(container)
        let appStoreID: Int64 = 101
        let trackedApp = TrackedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.focus",
            name: "Focus",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(term: "focus timer", storefront: "us", platform: .iphone)
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query
        )
        let oldCrawl = RankingCrawlRecord(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: Date(timeIntervalSince1970: 1_900_000_000),
            source: .appStoreWeb,
            resultCount: 100,
            query: query
        )
        let latestCrawl = RankingCrawlRecord(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: Date(timeIntervalSince1970: 1_900_086_400),
            source: .appStoreWeb,
            resultCount: 100,
            query: query
        )
        let metric = KeywordDailyMetric(
            queryKey: query.queryKey,
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            popularityScore: 73,
            difficultyScore: 41,
            source: .appleAdsPopularity
        )
        let rankings = [
            makeRankingFact(
                position: 8,
                appStoreID: appStoreID,
                bundleID: trackedApp.bundleID,
                name: trackedApp.name,
                sellerName: trackedApp.sellerName,
                observation: oldCrawl,
                in: modelContext
            ),
            makeRankingFact(
                position: 3,
                appStoreID: appStoreID,
                bundleID: trackedApp.bundleID,
                name: trackedApp.name,
                sellerName: trackedApp.sellerName,
                observation: latestCrawl,
                in: modelContext
            ),
            makeRankingFact(
                position: 1,
                appStoreID: 202,
                bundleID: "com.example.competitor",
                name: "Competitor",
                sellerName: "Example",
                observation: latestCrawl,
                in: modelContext
            )
        ]

        modelContext.insert(trackedApp)
        modelContext.insert(query)
        modelContext.insert(track)
        modelContext.insert(oldCrawl)
        modelContext.insert(latestCrawl)
        modelContext.insert(metric)
        rankings.forEach(modelContext.insert)
        try modelContext.save()

        let materializationID = KeywordWorkspaceProjection.MaterializationID(
            refreshToken: 0,
            backgroundStoreRevision: 0,
            appStoreID: appStoreID,
            storefrontFilterID: "all",
            platformFilterID: "all",
            dateRangeID: TrendDateRange.allTime.id,
            tracks: [
                .init(
                    identityKey: track.identityKey
                )
            ]
        )
        let service = KeywordInsightsService()
        let workspace = try await service.workspace(
            for: materializationID,
            tracks: [track],
            appStoreID: appStoreID,
            dateRange: .allTime,
            using: BackgroundModelStore(modelContainer: container),
            fallbackModelContext: modelContext
        )
        let row = try #require(workspace.rowsByIdentityKey[track.identityKey])

        #expect(row.metrics?.popularityScore == 73)
        #expect(row.metrics?.difficultyScore == 41)
        #expect(row.latestSnapshot?.rank == 3)
        #expect(row.trendSnapshots.map(\.rank) == [8, 3])
        #expect(row.rankingApps.map(\.position) == [1, 3])
        #expect(service.cachedWorkspace(for: materializationID) != nil)
    }

    @Test
    func boundedWorkspaceKeepsLatestSnapshotOutsideTrendWindow() async throws {
        let container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let modelContext = ModelContext(container)
        let appStoreID: Int64 = 303
        let trackedApp = TrackedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.archive",
            name: "Archive",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(term: "archived keyword", storefront: "us", platform: .iphone)
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query
        )
        let oldDate = Date.now.addingTimeInterval(-30 * 86_400)
        let oldCrawl = RankingCrawlRecord(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: oldDate,
            source: .appStoreWeb,
            resultCount: 100,
            query: query
        )
        let ranking = makeRankingFact(
            position: 3,
            appStoreID: appStoreID,
            bundleID: trackedApp.bundleID,
            name: trackedApp.name,
            sellerName: trackedApp.sellerName,
            observation: oldCrawl,
            in: modelContext
        )

        modelContext.insert(trackedApp)
        modelContext.insert(query)
        modelContext.insert(track)
        modelContext.insert(oldCrawl)
        modelContext.insert(ranking)
        try modelContext.save()

        let materializationID = KeywordWorkspaceProjection.MaterializationID(
            refreshToken: 0,
            backgroundStoreRevision: 0,
            appStoreID: appStoreID,
            storefrontFilterID: "all",
            platformFilterID: "all",
            dateRangeID: TrendDateRange.last7Days.id,
            tracks: [.init(identityKey: track.identityKey)]
        )
        let workspace = try await KeywordInsightsService().workspace(
            for: materializationID,
            tracks: [track],
            appStoreID: appStoreID,
            dateRange: .last7Days,
            using: BackgroundModelStore(modelContainer: container),
            fallbackModelContext: modelContext
        )
        let row = try #require(workspace.rowsByIdentityKey[track.identityKey])

        #expect(row.latestSnapshot?.rank == 3)
        #expect(row.latestSnapshot?.searchedAt == oldDate)
        #expect(row.trendSnapshots.isEmpty)
        #expect(row.rankingApps.map(\.position) == [3])
    }

    @Test
    func canceledSupersededErrorCannotClearFreshPublicationOrReportAnError() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let staleID = materializationID(refreshToken: 1)
        let freshID = materializationID(refreshToken: 2)
        let freshRow = makeRow(term: "Fresh Keyword", appStoreID: 2)

        let staleTask = Task { @MainActor in
            await model.materialize(
                id: staleID,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)
        staleTask.cancel()

        let freshTask = Task { @MainActor in
            await model.materialize(
                id: freshID,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(2)
        materializer.succeedRequest(at: 1, with: [freshRow])
        let freshError = await freshTask.value
        #expect(freshError == nil)
        #expect(model.rows.map { $0.track.term } == ["Fresh Keyword"])
        #expect(!model.isLoading(for: freshID))

        materializer.failRequest(at: 0)
        let staleError = await staleTask.value
        #expect(staleError == nil)
        #expect(model.rows.map { $0.track.term } == ["Fresh Keyword"])
        #expect(!model.isLoading(for: freshID))
    }

    @Test
    func supersededSuccessCannotReplaceFreshPublication() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let staleID = materializationID(refreshToken: 1)
        let freshID = materializationID(refreshToken: 2)

        let staleTask = Task { @MainActor in
            await model.materialize(
                id: staleID,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)

        let freshTask = Task { @MainActor in
            await model.materialize(
                id: freshID,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(2)

        materializer.succeedRequest(
            at: 1,
            with: [makeRow(term: "Fresh Keyword", appStoreID: 2)]
        )
        let freshError = await freshTask.value
        #expect(freshError == nil)
        #expect(model.rows.map { $0.track.term } == ["Fresh Keyword"])

        materializer.succeedRequest(
            at: 0,
            with: [makeRow(term: "Stale Keyword", appStoreID: 1)]
        )
        let staleError = await staleTask.value
        #expect(staleError == nil)
        #expect(model.rows.map { $0.track.term } == ["Fresh Keyword"])
        #expect(!model.isLoading(for: freshID))
    }

    @Test
    func preCancelledStaleMaterializationCannotInvalidateFreshRequest() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let staleID = materializationID(refreshToken: 1)
        let freshID = materializationID(refreshToken: 2)
        let freshRow = makeRow(term: "Fresh Keyword", appStoreID: 2)

        let freshTask = Task { @MainActor in
            await model.materialize(
                id: freshID,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)

        let staleTask = Task { @MainActor in
            await model.materialize(
                id: staleID,
                initialFilters: filters()
            ) {
                try Task.checkCancellation()
                return []
            }
        }
        staleTask.cancel()
        let staleError = await staleTask.value
        #expect(staleError == nil)

        materializer.succeedRequest(at: 0, with: [freshRow])
        let freshError = await freshTask.value

        #expect(freshError == nil)
        #expect(model.rows.map { $0.track.term } == ["Fresh Keyword"])
        #expect(!model.isLoading(for: freshID))
    }

    @Test
    func currentFailureCompletesLoadingAndReportsError() async {
        let model = KeywordWorkspaceModel()
        let materializer = ControlledWorkspaceMaterializer()
        let id = materializationID(refreshToken: 1)

        let loadTask = Task { @MainActor in
            await model.materialize(
                id: id,
                initialFilters: filters(),
                using: materializer.load
            )
        }
        await materializer.waitForRequestCount(1)
        materializer.failRequest(at: 0)

        let errorMessage = await loadTask.value
        #expect(errorMessage != nil)
        #expect(!model.isLoading(for: id))
        #expect(model.rows.isEmpty)
    }

    @Test
    func staleFilterCompletionCannotReplaceNewerFilteredRows() async {
        let model = KeywordWorkspaceModel()
        let id = materializationID(refreshToken: 1)
        let focusRow = makeRow(term: "Focus Timer", appStoreID: 1)
        let habitRow = makeRow(term: "Habit Tracker", appStoreID: 2)
        let loadError = await model.materialize(
            id: id,
            initialFilters: filters()
        ) {
            [focusRow, habitRow]
        }
        #expect(loadError == nil)

        let filterer = ControlledWorkspaceFilterer()
        let generation = model.materializationGeneration
        let staleTask = Task { @MainActor in
            await model.updateFilter(
                id: KeywordWorkspaceProjection.FilterID(
                    materializationGeneration: generation,
                    filters: filters(searchText: "focus")
                ),
                using: filterer.filter
            )
        }
        await filterer.waitForRequestCount(1)

        let freshTask = Task { @MainActor in
            await model.updateFilter(
                id: KeywordWorkspaceProjection.FilterID(
                    materializationGeneration: generation,
                    filters: filters(searchText: "habit")
                ),
                using: filterer.filter
            )
        }
        await filterer.waitForRequestCount(2)
        filterer.succeedRequest(at: 1)
        await freshTask.value
        #expect(model.rows.map { $0.track.term } == ["Habit Tracker"])

        filterer.succeedRequest(at: 0)
        await staleTask.value
        #expect(model.rows.map { $0.track.term } == ["Habit Tracker"])
    }

    @Test
    func completedFilterPublishesANewTableContentRevision() async {
        let model = KeywordWorkspaceModel()
        let id = materializationID(refreshToken: 1)
        let focusRow = makeRow(term: "Focus Timer", appStoreID: 1)
        let habitRow = makeRow(term: "Habit Tracker", appStoreID: 2)
        let loadError = await model.materialize(
            id: id,
            initialFilters: filters()
        ) {
            [focusRow, habitRow]
        }
        #expect(loadError == nil)
        let revisionBeforeFilter = model.contentRevision

        await model.updateFilter(
            id: KeywordWorkspaceProjection.FilterID(
                materializationGeneration: model.materializationGeneration,
                filters: filters(searchText: "habit")
            )
        ) { rows, filters in
            KeywordWorkspaceProjection.filteredRows(rows, filters: filters)
        }

        #expect(model.rows.map { $0.track.term } == ["Habit Tracker"])
        #expect(model.contentRevision == revisionBeforeFilter + 1)
    }

    @Test
    func coalescedRowDeltaPatchesOnlyChangedKeywordWithoutRematerializingWorkspace() async throws {
        let model = KeywordWorkspaceModel()
        let id = materializationID(refreshToken: 1)
        let focusRow = makeRow(term: "Focus Timer", appStoreID: 1, currentRank: 9, popularity: 40)
        let habitRow = makeRow(term: "Habit Tracker", appStoreID: 2, currentRank: 3, popularity: 70)
        let loadError = await model.materialize(id: id, initialFilters: filters()) {
            [focusRow, habitRow]
        }
        #expect(loadError == nil)
        let generationBeforeUpdate = model.materializationGeneration
        let revisionBeforeUpdate = model.contentRevision
        let updatedAt = Date(timeIntervalSince1970: 2_100_000_000)

        model.applyUpdatedRows([
            focusRow.id: KeywordInsightsService.Workspace.Row(
                metrics: KeywordMetricsSnapshot(
                    popularityScore: 99,
                    difficultyScore: 12,
                    updatedAt: updatedAt,
                    notes: nil
                ),
                refreshStatus: .empty,
                latestSnapshot: summary(id: "focus-updated", rank: 1, date: updatedAt),
                trendSnapshots: [summary(id: "focus-updated", rank: 1, date: updatedAt)],
                rankingApps: []
            )
        ])

        let updatedFocus = try #require(model.rows.first { $0.id == focusRow.id })
        let unchangedHabit = try #require(model.rows.first { $0.id == habitRow.id })
        #expect(updatedFocus.currentRank == 1)
        #expect(updatedFocus.metrics?.popularityScore == 99)
        #expect(unchangedHabit == habitRow)
        #expect(model.materializationGeneration == generationBeforeUpdate)
        #expect(model.contentRevision == revisionBeforeUpdate + 1)
    }

    @Test
    func refreshDeltasMaintainSelectedSortWithoutRebuildingTable() throws {
        let sourceRows = (0..<338).map { index in
            makeRow(
                term: "Keyword \(index.formatted(.number.precision(.integerLength(3))))",
                appStoreID: Int64(index + 1),
                popularity: index
            )
        }
        let model = KeywordTablePresentationModel()
        let sortOrder = [
            KeyPathComparator(\KeywordTablePresentationRow.popularitySortValue, order: .reverse)
        ]

        model.update(
            sourceRows: sourceRows,
            selectedChartKeywordKeys: [],
            sortOrder: sortOrder,
            forceSort: true
        )
        let initialIDs = model.rowIDs
        #expect(model.rows.count == 338)
        #expect(model.sortCount == 1)
        #expect(model.tableIdentity == 1)

        let firstSourceRow = try #require(sourceRows.first)
        let updatedFirstRow = firstSourceRow.updating(
            metrics: KeywordMetricsSnapshot(
                popularityScore: 1_000,
                difficultyScore: nil,
                updatedAt: Date(timeIntervalSince1970: 2_100_000_000),
                notes: nil
            ),
            refreshStatus: .empty,
            latestSnapshot: firstSourceRow.latestSnapshot,
            trendSnapshots: firstSourceRow.trendSnapshots,
            rankingApps: firstSourceRow.rankingApps
        )
        var updatedSourceRows = sourceRows
        updatedSourceRows[0] = updatedFirstRow

        for _ in 0..<25 {
            model.update(
                sourceRows: updatedSourceRows,
                selectedChartKeywordKeys: [],
                sortOrder: sortOrder,
                forceSort: false
            )
        }

        #expect(model.rowIDs != initialIDs)
        #expect(model.sortCount == 26)
        #expect(model.tableIdentity == 1)
        #expect(model.rows.first?.id == updatedFirstRow.id)
        #expect(model.rows.first?.popularitySortValue == 1_000)

        model.update(
            sourceRows: updatedSourceRows,
            selectedChartKeywordKeys: [],
            sortOrder: sortOrder,
            forceSort: true
        )

        #expect(model.sortCount == 27)
        #expect(model.tableIdentity == 2)
        #expect(model.rows.first?.id == updatedFirstRow.id)
    }

    @Test
    func preCancelledStaleFilterCannotInvalidateFreshRequest() async {
        let model = KeywordWorkspaceModel()
        let id = materializationID(refreshToken: 1)
        let focusRow = makeRow(term: "Focus Timer", appStoreID: 1)
        let habitRow = makeRow(term: "Habit Tracker", appStoreID: 2)
        let loadError = await model.materialize(
            id: id,
            initialFilters: filters()
        ) {
            [focusRow, habitRow]
        }
        #expect(loadError == nil)

        let filterer = ControlledWorkspaceFilterer()
        let generation = model.materializationGeneration
        let freshTask = Task { @MainActor in
            await model.updateFilter(
                id: KeywordWorkspaceProjection.FilterID(
                    materializationGeneration: generation,
                    filters: filters(searchText: "habit")
                ),
                using: filterer.filter
            )
        }
        await filterer.waitForRequestCount(1)

        let staleTask = Task { @MainActor in
            await model.updateFilter(
                id: KeywordWorkspaceProjection.FilterID(
                    materializationGeneration: generation,
                    filters: filters(searchText: "focus")
                )
            ) { _, _ in
                try Task.checkCancellation()
                return []
            }
        }
        staleTask.cancel()
        await staleTask.value

        filterer.succeedRequest(at: 0)
        await freshTask.value

        #expect(model.rows.map { $0.track.term } == ["Habit Tracker"])
    }

    private func materializationID(
        refreshToken: Int,
        backgroundStoreRevision: Int = 0
    ) -> KeywordWorkspaceProjection.MaterializationID {
        KeywordWorkspaceProjection.MaterializationID(
            refreshToken: refreshToken,
            backgroundStoreRevision: backgroundStoreRevision,
            appStoreID: 1,
            storefrontFilterID: "all",
            platformFilterID: "all",
            dateRangeID: "30d",
            tracks: []
        )
    }

    private func filters(
        searchText: String = "",
        popularityRange: ClosedRange<Double> = MetricFilterRange.popularity.defaultRange,
        changedOnly: Bool = false
    ) -> KeywordWorkspaceProjection.Filters {
        KeywordWorkspaceProjection.Filters(
            searchText: searchText,
            popularityRange: popularityRange,
            difficultyRange: MetricFilterRange.difficulty.defaultRange,
            positionRange: MetricFilterRange.position.defaultRange,
            changeRange: MetricFilterRange.change.defaultRange,
            showsOnlyChangedKeywords: changedOnly
        )
    }

    private func makeRow(
        term: String,
        appStoreID: Int64,
        currentRank: Int? = nil,
        popularity: Int? = nil,
        difficulty: Int? = nil,
        trendSnapshots: [KeywordRankingCrawlSummary] = []
    ) -> KeywordWorkspaceRow {
        let trackedApp = TrackedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.\(appStoreID)",
            name: "App \(appStoreID)",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(term: term, storefront: "us", platform: .iphone)
        let track = TrackedAppKeyword(
            term: term,
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query
        )
        let latestSnapshot = currentRank.map { rank in
            summary(
                id: "latest-\(appStoreID)",
                rank: rank,
                date: Date(timeIntervalSince1970: 2_000_000_000)
            )
        }
        let metrics = KeywordMetricsSnapshot(
            popularityScore: popularity,
            difficultyScore: difficulty,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            notes: nil
        )

        return KeywordWorkspaceRow(
            track: track,
            storefront: StorefrontDefinition(
                code: "us",
                name: "United States",
                flagEmoji: "🇺🇸",
                title: "🇺🇸 United States"
            ),
            metrics: metrics,
            latestSnapshot: latestSnapshot,
            trendSnapshots: trendSnapshots,
            rankingApps: []
        )
    }

    private func summary(id: String, rank: Int?, date: Date) -> KeywordRankingCrawlSummary {
        KeywordRankingCrawlSummary(
            id: id,
            rank: rank,
            searchedAt: date,
            source: .appStoreWeb,
            resultCount: 300
        )
    }
}

@MainActor
private final class ControlledWorkspaceMaterializer {
    private struct Request {
        var rows: [KeywordWorkspaceRow]?
        var didFail = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private var requests: [Request] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load() async throws -> [KeywordWorkspaceRow] {
        let index = requests.count
        await withCheckedContinuation { continuation in
            requests.append(Request(continuation: continuation))
            resumeSatisfiedWaiters()
        }

        if requests[index].didFail {
            throw ControlledWorkspaceError.expected
        }
        return requests[index].rows ?? []
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func succeedRequest(at index: Int, with rows: [KeywordWorkspaceRow]) {
        let continuation = requests[index].continuation
        requests[index].rows = rows
        requests[index].continuation = nil
        continuation?.resume()
    }

    func failRequest(at index: Int) {
        let continuation = requests[index].continuation
        requests[index].didFail = true
        requests[index].continuation = nil
        continuation?.resume()
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

@MainActor
private final class ControlledWorkspaceFilterer {
    private struct Request {
        let rows: [KeywordWorkspaceRow]
        let filters: KeywordWorkspaceProjection.Filters
        var continuation: CheckedContinuation<Void, Never>?
    }

    private var requests: [Request] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func filter(
        rows: [KeywordWorkspaceRow],
        filters: KeywordWorkspaceProjection.Filters
    ) async throws -> [KeywordWorkspaceRow] {
        let index = requests.count
        await withCheckedContinuation { continuation in
            requests.append(Request(rows: rows, filters: filters, continuation: continuation))
            resumeSatisfiedWaiters()
        }

        return KeywordWorkspaceProjection.filteredRows(
            requests[index].rows,
            filters: requests[index].filters
        )
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func succeedRequest(at index: Int) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil
        continuation?.resume()
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

private enum ControlledWorkspaceError: Error {
    case expected
}
