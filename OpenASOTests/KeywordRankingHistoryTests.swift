import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordRankingHistoryTests {
    @Test
    func projectionFiltersRangesAgainstNowAndIncludesCutoffBoundary() throws {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sevenDayCutoff = try #require(calendar.date(byAdding: .day, value: -7, to: now))
        let thirtyDayCutoff = try #require(calendar.date(byAdding: .day, value: -30, to: now))
        let olderThanThirtyDays = thirtyDayCutoff.addingTimeInterval(-1)
        let observations = [
            makeSummary(id: "now", rank: 3, date: now),
            makeSummary(id: "older", rank: 12, date: olderThanThirtyDays),
            makeSummary(id: "thirty-day-boundary", rank: 9, date: thirtyDayCutoff),
            makeSummary(id: "seven-day-boundary", rank: 5, date: sevenDayCutoff)
        ]

        let sevenDays = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .last7Days,
            now: now,
            calendar: calendar
        )
        let thirtyDays = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .last30Days,
            now: now,
            calendar: calendar
        )
        let ninetyDays = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .last90Days,
            now: now,
            calendar: calendar
        )
        let allTime = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .allTime,
            now: now,
            calendar: calendar
        )

        #expect(sevenDays.totalObservationCount == 2)
        #expect(sevenDays.segments.flatMap(\.points).map(\.id) == ["seven-day-boundary", "now"])
        #expect(thirtyDays.totalObservationCount == 3)
        #expect(
            thirtyDays.segments.flatMap(\.points).map(\.id)
                == ["thirty-day-boundary", "seven-day-boundary", "now"]
        )
        #expect(ninetyDays.totalObservationCount == 4)
        #expect(allTime.totalObservationCount == 4)
    }

    @Test
    func projectionExcludesStaleHistoryFromRecentTimeframes() throws {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let staleDate = try #require(calendar.date(byAdding: .day, value: -40, to: now))
        let observations = [makeSummary(id: "stale", rank: 11, date: staleDate)]

        let recentProjection = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .last7Days,
            now: now,
            calendar: calendar
        )
        let allTimeProjection = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .allTime,
            now: now,
            calendar: calendar
        )

        #expect(recentProjection.totalObservationCount == 0)
        #expect(recentProjection.segments.isEmpty)
        #expect(allTimeProjection.totalObservationCount == 1)
        #expect(allTimeProjection.rankedObservationCount == 1)
    }

    @Test
    func projectionBreaksLinesAtUnrankedObservationsWithoutExtendingToNow() throws {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstDate = try #require(calendar.date(byAdding: .day, value: -4, to: now))
        let gapDate = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let resumedDate = try #require(calendar.date(byAdding: .day, value: -2, to: now))
        let latestDate = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let observations = [
            makeSummary(id: "first", rank: 12, date: firstDate),
            makeSummary(id: "gap", rank: nil, date: gapDate),
            makeSummary(id: "resumed", rank: 8, date: resumedDate),
            makeSummary(id: "latest-gap", rank: nil, date: latestDate)
        ]

        let projection = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .last30Days,
            now: now,
            calendar: calendar
        )

        #expect(projection.segments.map { $0.points.map(\.id) } == [["first"], ["resumed"]])
        #expect(projection.totalObservationCount == 4)
        #expect(projection.rankedObservationCount == 2)
        #expect(projection.latestObservedRank == nil)
        #expect(projection.dateDomain?.lowerBound == firstDate)
        #expect(projection.dateDomain?.upperBound == latestDate)
        #expect(projection.dateDomain?.upperBound != now)
        #expect(projection.observationSummaryText == "Ranked in 2 of 4 observations")
        #expect(projection.accessibilitySummary.hasSuffix("Not ranked in the latest observation."))
    }

    @Test
    func projectionUsesSingularObservationWording() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let projection = KeywordRankingHistoryProjection(
            observations: [makeSummary(id: "only", rank: 4, date: now)],
            timeframe: .allTime,
            now: now,
            calendar: utcCalendar()
        )

        #expect(projection.observationSummaryText == "Ranked in 1 of 1 observation")
        #expect(projection.accessibilitySummary.hasSuffix("Latest observed rank 4."))
        #expect(projection.showsPointMarks)
    }

    @Test
    func projectionBoundsDenseUnsortedHistoryWhilePreservingGapsEndpointsAndExtrema() {
        let startDate = Date(timeIntervalSince1970: 1_900_000_000)
        let gapIndices: Set<Int> = [400, 800]
        let observations = (0..<1_200).reversed().map { index in
            let rank: Int?
            if gapIndices.contains(index) {
                rank = nil
            } else if index == 123 {
                rank = 1
            } else if index == 678 {
                rank = 250
            } else {
                rank = 20 + index % 50
            }

            return makeSummary(
                id: "observation-\(index)",
                rank: rank,
                date: startDate.addingTimeInterval(TimeInterval(index * 3_600))
            )
        }

        let projection = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .allTime,
            now: startDate.addingTimeInterval(TimeInterval(1_300 * 3_600)),
            calendar: utcCalendar()
        )

        #expect(projection.totalObservationCount == 1_200)
        #expect(projection.rankedObservationCount == 1_198)
        #expect(projection.segments.count == 3)
        #expect(projection.chartSegments.count == 3)
        #expect(projection.chartPointCount <= KeywordRankingHistoryProjection.maximumChartPointCount)
        #expect(!projection.showsPointMarks)
        let chartPointIDs = Set(projection.chartSegments.flatMap(\.points).map(\.id))
        #expect(!chartPointIDs.contains("observation-400"))
        #expect(!chartPointIDs.contains("observation-800"))

        for (fullSegment, chartSegment) in zip(projection.segments, projection.chartSegments) {
            let chartPointIDs = Set(chartSegment.points.map(\.id))
            #expect(chartPointIDs.contains(fullSegment.points.first?.id ?? ""))
            #expect(chartPointIDs.contains(fullSegment.points.last?.id ?? ""))
            #expect(chartSegment.points.map(\.rank).contains(fullSegment.points.map(\.rank).min() ?? -1))
            #expect(chartSegment.points.map(\.rank).contains(fullSegment.points.map(\.rank).max() ?? -1))
        }

        let fragmentedObservations = (0..<1_000).reversed().map { index in
            makeSummary(
                id: "fragmented-\(index)",
                rank: index.isMultiple(of: 2) ? index % 100 + 1 : nil,
                date: startDate.addingTimeInterval(TimeInterval(index * 3_600))
            )
        }
        let fragmentedProjection = KeywordRankingHistoryProjection(
            observations: fragmentedObservations,
            timeframe: .allTime,
            now: startDate.addingTimeInterval(TimeInterval(1_300 * 3_600)),
            calendar: utcCalendar()
        )

        #expect(fragmentedProjection.segments.count == 500)
        #expect(fragmentedProjection.chartPointCount <= KeywordRankingHistoryProjection.maximumChartPointCount)
        #expect(fragmentedProjection.chartSegments.allSatisfy { $0.points.count == 1 })
        let fragmentedChartRanks = fragmentedProjection.chartSegments.flatMap(\.points).map(\.rank)
        #expect(fragmentedChartRanks.contains(1))
        #expect(fragmentedChartRanks.contains(99))
    }

    @Test
    func denseProjectionKeepsIsolatedRankedObservationsVisibleAsPoints() {
        let startDate = Date(timeIntervalSince1970: 1_900_000_000)
        let observations = (0..<500).reversed().map { index in
            makeSummary(
                id: "observation-\(index)",
                rank: index == 200 || index == 202 ? nil : index % 100 + 1,
                date: startDate.addingTimeInterval(TimeInterval(index * 3_600))
            )
        }
        let projection = KeywordRankingHistoryProjection(
            observations: observations,
            timeframe: .allTime,
            now: startDate.addingTimeInterval(TimeInterval(600 * 3_600)),
            calendar: utcCalendar()
        )

        #expect(!projection.showsPointMarks)
        let isolatedSegment = projection.chartSegments.first { segment in
            segment.points.map(\.id) == ["observation-201"]
        }
        #expect(isolatedSegment != nil)
        if let isolatedSegment {
            #expect(projection.showsPointMarks(for: isolatedSegment))
        }
    }

    @Test
    func loaderReturnsCompleteHistoryOnlyForRequestedQueryAndApp() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = try #require(calendar.date(byAdding: .day, value: -120, to: now))
        let recentDate = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let otherQueryDate = try #require(calendar.date(byAdding: .hour, value: -12, to: now))
        let targetAppStoreID: Int64 = 100
        let otherAppStoreID: Int64 = 200

        let targetQuery = KeywordQuery(term: "weather", storefront: "us", platform: .iphone)
        let otherQuery = KeywordQuery(term: "weather", storefront: "gb", platform: .iphone)
        modelContext.insert(targetQuery)
        modelContext.insert(otherQuery)

        let recentTargetCrawl = makeCrawl(query: targetQuery, date: recentDate)
        let oldTargetCrawl = makeCrawl(query: targetQuery, date: oldDate)
        let otherQueryCrawl = makeCrawl(query: otherQuery, date: otherQueryDate)
        modelContext.insert(recentTargetCrawl)
        modelContext.insert(oldTargetCrawl)
        modelContext.insert(otherQueryCrawl)

        modelContext.insert(
            makeRanking(
                position: 4,
                appStoreID: targetAppStoreID,
                observation: oldTargetCrawl
            )
        )
        modelContext.insert(
            makeRanking(
                position: 1,
                appStoreID: otherAppStoreID,
                observation: recentTargetCrawl
            )
        )
        modelContext.insert(
            makeRanking(
                position: 2,
                appStoreID: targetAppStoreID,
                observation: otherQueryCrawl
            )
        )
        try modelContext.save()

        let history = try KeywordRankingHistoryLoader.load(
            queryKey: targetQuery.queryKey,
            appStoreID: targetAppStoreID,
            in: modelContext
        )

        #expect(history.map(\.id) == [oldTargetCrawl.observationKey, recentTargetCrawl.observationKey])
        #expect(history.map(\.rank) == [4, nil])
        #expect(history.map(\.searchedAt) == [oldDate, recentDate])
    }

    @Test
    func productionDataSourceReadsThroughBackgroundModelStore() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let query = KeywordQuery(term: "forecast", storefront: "us", platform: .iphone)
        let crawl = makeCrawl(
            query: query,
            date: Date(timeIntervalSince1970: 2_000_000_000)
        )
        modelContext.insert(query)
        modelContext.insert(crawl)
        modelContext.insert(
            makeRanking(
                position: 7,
                appStoreID: 100,
                observation: crawl
            )
        )
        try modelContext.save()

        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let dataSource = KeywordRankingHistoryDataSource.production(
            backgroundModelStore: backgroundModelStore,
            fallbackModelContext: modelContext
        )
        let observations = try await dataSource.load(
            queryKey: query.queryKey,
            appStoreID: 100
        )

        #expect(observations.map(\.id) == [crawl.observationKey])
        #expect(observations.map(\.rank) == [7])
    }

    @Test
    func historyModelTransitionsFromLoadingToSuccess() async {
        let controlledDataSource = ControlledHistoryDataSource()
        let model = KeywordRankingHistoryModel()
        let dataSource = makeDataSource(controlledBy: controlledDataSource)
        let expectedObservations = [
            makeSummary(
                id: "loaded",
                rank: 3,
                date: Date(timeIntervalSince1970: 2_000_000_000)
            )
        ]

        let loadTask = Task {
            await model.load(queryKey: "query", appStoreID: 100, using: dataSource)
        }
        await controlledDataSource.waitForRequestCount(1)

        #expect(model.state == .loading)
        await controlledDataSource.succeedRequest(at: 0, with: expectedObservations)
        await loadTask.value
        #expect(model.state == .loaded(expectedObservations))
    }

    @Test
    func historyModelRecoversFromErrorWhenRetried() async {
        let controlledDataSource = ControlledHistoryDataSource()
        let model = KeywordRankingHistoryModel()
        let dataSource = makeDataSource(controlledBy: controlledDataSource)
        let recoveredObservations = [
            makeSummary(
                id: "recovered",
                rank: 9,
                date: Date(timeIntervalSince1970: 2_000_000_000)
            )
        ]

        let failingTask = Task {
            await model.load(queryKey: "query", appStoreID: 100, using: dataSource)
        }
        await controlledDataSource.waitForRequestCount(1)
        await controlledDataSource.failRequest(at: 0)
        await failingTask.value
        guard case let .failed(message) = model.state else {
            Issue.record("Expected the first load to fail")
            return
        }
        #expect(!message.isEmpty)

        let retryTask = Task {
            await model.load(queryKey: "query", appStoreID: 100, using: dataSource)
        }
        await controlledDataSource.waitForRequestCount(2)
        #expect(model.state == .loading)
        await controlledDataSource.succeedRequest(at: 1, with: recoveredObservations)
        await retryTask.value
        #expect(model.state == .loaded(recoveredObservations))
    }

    @Test
    func historyModelIgnoresCanceledStaleCompletion() async {
        let controlledDataSource = ControlledHistoryDataSource()
        let model = KeywordRankingHistoryModel()
        let dataSource = makeDataSource(controlledBy: controlledDataSource)
        let staleObservations = [
            makeSummary(
                id: "stale",
                rank: 20,
                date: Date(timeIntervalSince1970: 1_900_000_000)
            )
        ]
        let freshObservations = [
            makeSummary(
                id: "fresh",
                rank: 2,
                date: Date(timeIntervalSince1970: 2_000_000_000)
            )
        ]

        let staleTask = Task {
            await model.load(queryKey: "query", appStoreID: 100, using: dataSource)
        }
        await controlledDataSource.waitForRequestCount(1)
        staleTask.cancel()

        let freshTask = Task {
            await model.load(queryKey: "query", appStoreID: 100, using: dataSource)
        }
        await controlledDataSource.waitForRequestCount(2)
        await controlledDataSource.succeedRequest(at: 1, with: freshObservations)
        await freshTask.value
        #expect(model.state == .loaded(freshObservations))

        await controlledDataSource.succeedRequest(at: 0, with: staleObservations)
        await staleTask.value
        #expect(model.state == .loaded(freshObservations))
    }

    @Test
    func trendAccessibilityDescribesEachDirection() {
        #expect(makeWorkspaceRow(ranks: [10]).trendAccessibilityText == "Not enough history to determine a ranking trend.")
        #expect(makeWorkspaceRow(ranks: [10, 5]).trendAccessibilityText == "Up 5 positions.")
        #expect(makeWorkspaceRow(ranks: [5, 6]).trendAccessibilityText == "Down 1 position.")
        #expect(makeWorkspaceRow(ranks: [5, 5]).trendAccessibilityText == "Ranking unchanged.")
    }

    @Test
    func unknownLegacyRankingSourcesDefaultToConservativeFallback() {
        let trackedApp = TrackedApp(
            appStoreID: 100,
            bundleID: "com.example.app",
            name: "Example",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(term: "weather", storefront: "us", platform: .iphone)
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query
        )
        let snapshot = TrackedKeywordDailyRanking(
            rank: 3,
            searchedAt: .now,
            source: .appStoreWeb,
            resultCount: 10,
            keywordTrack: track
        )
        let crawl = KeywordRankingCrawl(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: .now,
            source: .appStoreWeb,
            resultCount: 10,
            query: query
        )

        snapshot.sourceRaw = "legacy-unknown-source"
        crawl.sourceRaw = "legacy-unknown-source"

        #expect(snapshot.source == .iTunesFallback)
        #expect(crawl.source == .iTunesFallback)
    }

    private func makeDataSource(
        controlledBy controlledDataSource: ControlledHistoryDataSource
    ) -> KeywordRankingHistoryDataSource {
        KeywordRankingHistoryDataSource { queryKey, appStoreID in
            try await controlledDataSource.load(
                queryKey: queryKey,
                appStoreID: appStoreID
            )
        }
    }

    private func makeWorkspaceRow(ranks: [Int?]) -> KeywordWorkspaceRow {
        let trackedApp = TrackedApp(
            appStoreID: 100,
            bundleID: "com.example.app",
            name: "Example",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(term: "weather", storefront: "us", platform: .iphone)
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query
        )
        let snapshots = ranks.enumerated().map { index, rank in
            makeSummary(
                id: "trend-\(index)",
                rank: rank,
                date: Date(timeIntervalSince1970: TimeInterval(1_900_000_000 + index))
            )
        }
        return KeywordWorkspaceRow(
            track: track,
            storefront: nil,
            metrics: Optional<KeywordDailyMetric>.none,
            latestSnapshot: snapshots.last,
            trendSnapshots: snapshots,
            rankingApps: []
        )
    }
}

private actor ControlledHistoryDataSource {
    private struct PendingRequest {
        let queryKey: String
        let appStoreID: Int64
        var continuation: CheckedContinuation<[KeywordRankingCrawlSummary], any Error>?
    }

    private var requests: [PendingRequest] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load(
        queryKey: String,
        appStoreID: Int64
    ) async throws -> [KeywordRankingCrawlSummary] {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(
                PendingRequest(
                    queryKey: queryKey,
                    appStoreID: appStoreID,
                    continuation: continuation
                )
            )
            resumeSatisfiedWaiters()
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func succeedRequest(
        at index: Int,
        with observations: [KeywordRankingCrawlSummary]
    ) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil
        continuation?.resume(returning: observations)
    }

    func failRequest(at index: Int) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil
        continuation?.resume(throwing: ControlledHistoryDataSourceError.expected)
    }

    private func resumeSatisfiedWaiters() {
        var remainingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in requestWaiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        requestWaiters = remainingWaiters
    }
}

private enum ControlledHistoryDataSourceError: Error {
    case expected
}

private func makeSummary(id: String, rank: Int?, date: Date) -> KeywordRankingCrawlSummary {
    KeywordRankingCrawlSummary(
        id: id,
        rank: rank,
        searchedAt: date,
        source: .appStoreWeb,
        resultCount: 100
    )
}

private func makeCrawl(query: KeywordQuery, date: Date) -> KeywordRankingCrawl {
    KeywordRankingCrawl(
        keyword: query.term,
        storefront: query.storefront,
        platform: query.platform,
        observedAt: date,
        source: .appStoreWeb,
        resultCount: 100,
        query: query
    )
}

private func makeRanking(
    position: Int,
    appStoreID: Int64,
    observation: KeywordRankingCrawl
) -> KeywordAppRanking {
    KeywordAppRanking(
        position: position,
        appStoreID: appStoreID,
        bundleID: "com.example.\(appStoreID)",
        name: "App \(appStoreID)",
        sellerName: "Example",
        observation: observation
    )
}

private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema(OpenASOSchemaV1.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
}
