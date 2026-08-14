import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordRankingListLoaderTests {
    @Test
    func productionDataSourceLoadsRealRankingAndEnrichmentJoins() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let appStoreID: Int64 = 10_001
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let query = KeywordQuery(term: "focus", storefront: "us", platform: .iphone)
        let crawl = RankingCrawlRecord(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: observedAt,
            source: .appStoreWeb,
            resultCount: 300,
            query: query
        )
        let ranking = makeRankingFact(
            position: 1,
            appStoreID: appStoreID,
            bundleID: "com.example.focus",
            name: "Ranking Name",
            subtitle: "Ranking Subtitle",
            sellerName: "Ranking Seller",
            observation: crawl,
            in: modelContext
        )
        let storeApp = StoreApp(
            appStoreID: appStoreID,
            bundleID: "com.example.focus",
            name: "Catalog Name",
            subtitle: "Catalog Subtitle",
            sellerName: "Catalog Seller",
            iconURLString: "https://example.com/icon.png",
            supportedLanguageCodes: ["en", "fr"],
            supportedLanguageCodesSource: .appStoreWeb,
            supportedLanguageCodesFetchedAt: observedAt,
            defaultPlatform: .iphone
        )
        let metadata = AppStorefrontMetadata(
            appStoreID: appStoreID,
            storefront: "us",
            defaultPlatform: .iphone,
            name: "Localized Name",
            subtitle: "Localized Subtitle",
            sellerName: "Localized Seller",
            iconURLString: "https://example.com/localized-icon.png",
            storefrontLanguageCode: "en-US",
            servedLanguageCode: "en-US",
            isLocalized: true,
            source: .appStoreWeb,
            lastFetchedAt: observedAt,
            storeApp: storeApp
        )
        let screenshot = AppStoreScreenshot(
            appStoreID: appStoreID,
            storefront: "us",
            platformRaw: "iphone",
            sortOrder: 0,
            urlString: "https://example.com/screenshot.png",
            width: 1_290,
            height: 2_796,
            source: .appStoreWeb,
            lastFetchedAt: observedAt,
            metadata: metadata
        )
        metadata.screenshots.append(screenshot)

        modelContext.insert(Storefront(
            code: "us",
            name: "United States",
            flagEmoji: "🇺🇸",
            languageCode: "en-US"
        ))
        modelContext.insert(query)
        modelContext.insert(crawl)
        modelContext.insert(ranking)
        modelContext.insert(storeApp)
        modelContext.insert(metadata)
        modelContext.insert(screenshot)
        modelContext.insert(LatestAppRating(
            appStoreID: appStoreID,
            storefront: "us",
            ratingCount: 1_250,
            averageRating: 4.8,
            observedAt: observedAt,
            storeApp: storeApp
        ))
        modelContext.insert(AppDailyRating(
            appStoreID: appStoreID,
            storefront: "us",
            ratingCount: 1_200,
            averageRating: 4.7,
            ratingDate: "2033-05-17",
            observedAt: observedAt.addingTimeInterval(-86_400),
            storeApp: storeApp
        ))
        modelContext.insert(AppDailyRating(
            appStoreID: appStoreID,
            storefront: "us",
            ratingCount: 1_250,
            averageRating: 4.8,
            ratingDate: "2033-05-18",
            observedAt: observedAt,
            storeApp: storeApp
        ))
        try modelContext.save()

        let dataSource = KeywordRankingListDataSource.production(
            backgroundModelStore: BackgroundModelStore(modelContainer: container),
            fallbackModelContext: modelContext
        )
        let snapshot = try await dataSource.load(
            crawlKey: crawl.observationKey,
            fallbackItems: [],
            storefrontCode: " US ",
            includesScreenshots: true
        )

        let row = try #require(snapshot.rows.first)
        #expect(snapshot.items.map(\.appStoreID) == [appStoreID])
        #expect(row.position == 1)
        #expect(row.appName == "Localized Name")
        #expect(row.subtitle == "Localized Subtitle")
        #expect(row.sellerName == "Localized Seller")
        #expect(row.ratingCount == 1_250)
        #expect(row.averageRating == 4.8)
        #expect(row.screenshots.map(\.urlString) == ["https://example.com/screenshot.png"])
        #expect(row.newRatingPoints.contains { $0.delta == 50 && $0.hasData })
        #expect(snapshot.storefrontLanguageCode == "en-US")
        #expect(snapshot.storefrontFlagEmoji == "🇺🇸")
        #expect(snapshot.includesScreenshots)
    }

    @Test
    func fallbackItemsLoadThroughMainContextAndPreserveFallbackValues() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let fallbackItem = KeywordRankingListItem(
            id: 42,
            position: 3,
            appStoreID: 42,
            name: "Fallback Name",
            subtitle: "Fallback Subtitle",
            sellerName: "Fallback Seller"
        )
        let dataSource = KeywordRankingListDataSource.production(
            backgroundModelStore: nil,
            fallbackModelContext: modelContext
        )

        let snapshot = try await dataSource.load(
            crawlKey: nil,
            fallbackItems: [fallbackItem],
            storefrontCode: "gb",
            includesScreenshots: false
        )

        let row = try #require(snapshot.rows.first)
        #expect(snapshot.items.map(\.appStoreID) == [42])
        #expect(row.appName == "Fallback Name")
        #expect(row.subtitle == "Fallback Subtitle")
        #expect(row.sellerName == "Fallback Seller")
        #expect(!snapshot.includesScreenshots)
    }

    @Test
    func metadataRevisionIDsIncludeBackgroundOnlyRankingRowsAndFallbacks() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let fallbackAppStoreID: Int64 = 101
        let backgroundAppStoreID: Int64 = 202
        let query = KeywordQuery(term: "focus", storefront: "us", platform: .iphone)
        let crawl = RankingCrawlRecord(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: Date(timeIntervalSince1970: 2_000_000_000),
            source: .appStoreWeb,
            resultCount: 1,
            query: query
        )
        modelContext.insert(query)
        modelContext.insert(crawl)
        modelContext.insert(makeRankingFact(
            position: 1,
            appStoreID: backgroundAppStoreID,
            bundleID: "com.example.background-only",
            name: "Background Only",
            subtitle: nil,
            sellerName: "Example",
            observation: crawl,
            in: modelContext
        ))
        try modelContext.save()

        let fallbackItem = KeywordRankingListItem(
            id: fallbackAppStoreID,
            position: 2,
            appStoreID: fallbackAppStoreID,
            name: "Fallback",
            subtitle: nil,
            sellerName: nil
        )
        let revisionStore = AppMetadataRefreshProgressStore { request, _ in
            AppMetadataRefreshResult(
                appStoreID: request.appStoreID,
                defaultStorefront: "us",
                storefronts: [
                    AppMetadataRefreshStorefrontOutcome(
                        storefront: "us",
                        iTunesLookup: .succeeded,
                        appStoreWeb: .succeeded
                    )
                ],
                iconInvalidated: false
            )
        }
        let model = KeywordRankingListModel()
        let initialAppStoreIDs = model.metadataRevisionAppStoreIDs(
            fallbackItems: [fallbackItem]
        )
        let initialRevisionSignature = revisionStore.revisionSignature(
            for: initialAppStoreIDs
        )
        await model.load(
            request: KeywordRankingListLoader.LoadID(
                crawlKey: crawl.observationKey,
                storefrontCode: "us",
                includesScreenshots: false
            ),
            fallbackItems: [fallbackItem],
            using: .production(
                backgroundModelStore: BackgroundModelStore(modelContainer: container),
                fallbackModelContext: modelContext
            )
        )

        #expect(model.snapshot?.rows.map(\.appStoreID) == [backgroundAppStoreID])
        #expect(
            model.metadataRevisionAppStoreIDs(fallbackItems: [fallbackItem])
                == [fallbackAppStoreID, backgroundAppStoreID]
        )
        let discoveredRevisionSignature = revisionStore.revisionSignature(
            for: model.metadataRevisionAppStoreIDs(fallbackItems: [fallbackItem])
        )
        #expect(discoveredRevisionSignature == initialRevisionSignature)

        #expect(revisionStore.start(AppMetadataRefreshRequest(appStoreID: backgroundAppStoreID)))
        await revisionStore.waitForCurrentBatch()
        #expect(
            revisionStore.revisionSignature(
                for: model.metadataRevisionAppStoreIDs(fallbackItems: [fallbackItem])
            ) == "\(backgroundAppStoreID):1"
        )
    }

    @Test
    func loaderChecksCancellationBetweenFetchStages() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let fallbackItem = KeywordRankingListItem(
            id: 42,
            position: 1,
            appStoreID: 42,
            name: "Fallback",
            subtitle: nil,
            sellerName: nil
        )
        var checkpointCount = 0

        #expect(throws: CancellationError.self) {
            _ = try KeywordRankingListLoader.load(
                crawlKey: nil,
                fallbackItems: [fallbackItem],
                storefrontCode: "us",
                includesScreenshots: false,
                in: modelContext,
                checkCancellation: {
                    checkpointCount += 1
                    if checkpointCount == 3 {
                        throw CancellationError()
                    }
                }
            )
        }

        #expect(checkpointCount == 3)
    }

    @Test
    func repeatedBackgroundReadSeesExternalContextUpdate() async throws {
        let container = try makeInMemoryContainer()
        let setupContext = ModelContext(container)
        let appStoreID: Int64 = 77
        setupContext.insert(StoreApp(
            appStoreID: appStoreID,
            bundleID: "com.example.freshness",
            name: "Before",
            sellerName: "Example",
            iconURLString: nil,
            defaultPlatform: .iphone
        ))
        try setupContext.save()

        let fallbackItem = KeywordRankingListItem(
            id: appStoreID,
            position: 1,
            appStoreID: appStoreID,
            name: "Fallback",
            subtitle: nil,
            sellerName: nil
        )
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let dataSource = KeywordRankingListDataSource.production(
            backgroundModelStore: backgroundStore,
            fallbackModelContext: setupContext
        )
        let first = try await dataSource.load(
            crawlKey: nil,
            fallbackItems: [fallbackItem],
            storefrontCode: "us",
            includesScreenshots: false
        )
        #expect(first.rows.first?.appName == "Before")

        let writerContext = ModelContext(container)
        let targetAppStoreID = appStoreID
        let descriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { app in
                app.appStoreID == targetAppStoreID
            }
        )
        let writerApp = try #require(try writerContext.fetch(descriptor).first)
        writerApp.name = "After"
        try writerContext.save()

        let second = try await dataSource.load(
            crawlKey: nil,
            fallbackItems: [fallbackItem],
            storefrontCode: "us",
            includesScreenshots: false
        )
        #expect(second.rows.first?.appName == "After")
    }

    @Test
    func ratingHistoryFetchIsBoundedToLatestSnapshotsPerApp() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let baseDate = Date(timeIntervalSince1970: 1_900_000_000)

        for index in 0..<45 {
            let observedAt = baseDate.addingTimeInterval(TimeInterval(index * 86_400))
            modelContext.insert(AppDailyRating(
                appStoreID: 1,
                storefront: "us",
                ratingCount: index,
                averageRating: 4.0,
                ratingDate: LatestAppRating.ratingDateString(for: observedAt),
                observedAt: observedAt
            ))
            modelContext.insert(AppDailyRating(
                appStoreID: 1,
                storefront: "gb",
                ratingCount: 1_000 + index,
                averageRating: 4.0,
                ratingDate: LatestAppRating.ratingDateString(for: observedAt),
                observedAt: observedAt
            ))
        }
        for index in 45..<50 {
            let observedAt = baseDate.addingTimeInterval(TimeInterval(index * 86_400))
            modelContext.insert(AppDailyRating(
                appStoreID: 1,
                storefront: "us",
                ratingCount: nil,
                averageRating: nil,
                ratingDate: LatestAppRating.ratingDateString(for: observedAt),
                observedAt: observedAt
            ))
        }
        for index in 0..<8 {
            let observedAt = baseDate.addingTimeInterval(TimeInterval(index * 86_400))
            modelContext.insert(AppDailyRating(
                appStoreID: 2,
                storefront: "us",
                ratingCount: 100 + index,
                averageRating: 4.0,
                ratingDate: LatestAppRating.ratingDateString(for: observedAt),
                observedAt: observedAt
            ))
        }
        try modelContext.save()

        let snapshotsByID = try KeywordRankingListLoader.ratingSnapshotsByID(
            storefront: "us",
            appStoreIDs: [2, 1, 1],
            in: modelContext
        )

        let firstAppSnapshots = try #require(snapshotsByID[1])
        #expect(firstAppSnapshots.count == KeywordRankingListLoader.ratingSnapshotLimit)
        #expect(firstAppSnapshots.first?.ratingCount == 14)
        #expect(firstAppSnapshots.last?.ratingCount == 44)
        let secondAppSnapshots = try #require(snapshotsByID[2])
        #expect(secondAppSnapshots.compactMap(\.ratingCount) == Array(100..<108))
    }

    @Test
    func modelTransitionsThroughLoadingFailureAndRetryWhileRetainingScreenshots() async {
        let controlled = ControlledRankingListDataSource()
        let model = KeywordRankingListModel()
        let dataSource = makeDataSource(controlledBy: controlled)
        let request = loadID(includesScreenshots: true)
        let retainedScreenshotURL = "https://example.com/retained.png"
        let screenshotSnapshot = snapshot(
            name: "With Screenshots",
            screenshotURL: retainedScreenshotURL
        )
        let recoveredSnapshot = snapshot(
            name: "Recovered",
            screenshotURL: "https://example.com/recovered.png"
        )

        let initialTask = Task { @MainActor in
            await model.load(request: request, fallbackItems: [], using: dataSource)
        }
        await controlled.waitForRequestCount(1)
        #expect(model.isLoading)
        #expect(model.snapshot?.items.count == nil)
        controlled.succeedRequest(at: 0, with: screenshotSnapshot)
        await initialTask.value
        #expect(model.snapshot?.items.first?.name == "With Screenshots")
        #expect(model.snapshot?.rows.first?.screenshots.map(\.urlString) == [retainedScreenshotURL])
        #expect(model.includesScreenshots)

        let failingTask = Task { @MainActor in
            await model.load(request: request, fallbackItems: [], using: dataSource)
        }
        await controlled.waitForRequestCount(2)
        #expect(model.isLoading)
        #expect(model.snapshot?.items.first?.name == "With Screenshots")
        controlled.failRequest(at: 1)
        await failingTask.value
        #expect(model.errorMessage != nil)
        #expect(model.snapshot?.items.first?.name == "With Screenshots")
        #expect(model.snapshot?.rows.first?.screenshots.map(\.urlString) == [retainedScreenshotURL])
        #expect(model.includesScreenshots)

        let retryTask = Task { @MainActor in
            await model.load(request: request, fallbackItems: [], using: dataSource)
        }
        await controlled.waitForRequestCount(3)
        #expect(model.isLoading)
        #expect(model.errorMessage == nil)
        #expect(model.snapshot?.items.first?.name == "With Screenshots")
        #expect(model.snapshot?.rows.first?.screenshots.map(\.urlString) == [retainedScreenshotURL])
        controlled.succeedRequest(at: 2, with: recoveredSnapshot)
        await retryTask.value
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        #expect(model.snapshot?.items.first?.name == "Recovered")
        #expect(model.includesScreenshots)
    }

    @Test
    func canceledStaleFailureCannotReplaceFreshLoadedState() async {
        let controlled = ControlledRankingListDataSource()
        let model = KeywordRankingListModel()
        let dataSource = makeDataSource(controlledBy: controlled)
        let staleRequest = loadID(crawlKey: "stale")
        let freshRequest = loadID(crawlKey: "fresh")
        let freshSnapshot = snapshot(name: "Fresh")

        let staleTask = Task { @MainActor in
            await model.load(request: staleRequest, fallbackItems: [], using: dataSource)
        }
        await controlled.waitForRequestCount(1)
        staleTask.cancel()

        let freshTask = Task { @MainActor in
            await model.load(request: freshRequest, fallbackItems: [], using: dataSource)
        }
        await controlled.waitForRequestCount(2)
        controlled.succeedRequest(at: 1, with: freshSnapshot)
        await freshTask.value
        #expect(model.snapshot?.items.first?.name == "Fresh")
        #expect(model.errorMessage == nil)

        controlled.failRequest(at: 0)
        await staleTask.value
        #expect(model.snapshot?.items.first?.name == "Fresh")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test
    func preCancelledStaleLoadCannotInvalidateFreshPendingRequest() async {
        let controlled = ControlledRankingListDataSource()
        let model = KeywordRankingListModel()
        let freshDataSource = makeDataSource(controlledBy: controlled)
        let freshRequest = loadID(crawlKey: "fresh")
        let staleRequest = loadID(crawlKey: "stale")
        let freshSnapshot = snapshot(name: "Fresh")
        let staleSnapshot = snapshot(name: "Stale")
        let staleDataSource = KeywordRankingListDataSource { _, _, _, _ in
            staleSnapshot
        }

        let freshTask = Task { @MainActor in
            await model.load(request: freshRequest, fallbackItems: [], using: freshDataSource)
        }
        await controlled.waitForRequestCount(1)
        #expect(model.isLoading)

        let startGate = ControlledStartGate()
        let staleTask = Task { @MainActor in
            await startGate.wait()
            await model.load(
                request: staleRequest,
                fallbackItems: [],
                using: staleDataSource
            )
        }
        await startGate.waitUntilWaiting()
        staleTask.cancel()
        startGate.open()
        await staleTask.value

        #expect(model.isLoading)
        #expect(model.snapshot == nil)

        controlled.succeedRequest(at: 0, with: freshSnapshot)
        await freshTask.value
        #expect(model.snapshot?.items.first?.name == "Fresh")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    private func makeDataSource(
        controlledBy controlled: ControlledRankingListDataSource
    ) -> KeywordRankingListDataSource {
        KeywordRankingListDataSource { crawlKey, fallbackItems, storefrontCode, includesScreenshots in
            try await controlled.load(
                crawlKey: crawlKey,
                fallbackItems: fallbackItems,
                storefrontCode: storefrontCode,
                includesScreenshots: includesScreenshots
            )
        }
    }

    private func loadID(
        crawlKey: String? = nil,
        includesScreenshots: Bool = false
    ) -> KeywordRankingListLoader.LoadID {
        KeywordRankingListLoader.LoadID(
            crawlKey: crawlKey,
            storefrontCode: "us",
            includesScreenshots: includesScreenshots
        )
    }

    private func snapshot(
        name: String,
        screenshotURL: String? = nil
    ) -> KeywordRankingListLoader.Snapshot {
        let item = KeywordRankingListItem(
            id: 1,
            position: 1,
            appStoreID: 1,
            name: name,
            subtitle: nil,
            sellerName: nil
        )
        let storeApp = StoreApp(
            appStoreID: 1,
            bundleID: "com.example.snapshot",
            name: name,
            sellerName: "Example",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        let metadata = AppStorefrontMetadata(
            appStoreID: 1,
            storefront: "us",
            defaultPlatform: .iphone,
            name: name,
            source: .appStoreWeb,
            storeApp: storeApp
        )
        if let screenshotURL {
            metadata.screenshots.append(AppStoreScreenshot(
                appStoreID: 1,
                storefront: "us",
                platformRaw: "iphone",
                sortOrder: 0,
                urlString: screenshotURL,
                source: .appStoreWeb,
                metadata: metadata
            ))
        }

        let row = KeywordRankingCatalogRow(
            item: item,
            storeApp: StoreAppDisplayValue(storeApp),
            storefrontMetadata: AppStorefrontMetadataDisplayValue(
                metadata,
                includeScreenshots: screenshotURL != nil
            ),
            usMetadata: nil,
            latestRating: nil,
            ratingSnapshots: []
        )
        return KeywordRankingListLoader.Snapshot(
            items: [item],
            rows: [row],
            storefrontLanguageCode: "en-US",
            storefrontFlagEmoji: "🇺🇸",
            includesScreenshots: screenshotURL != nil
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
    }
}

@MainActor
private final class ControlledStartGate {
    private var isWaiting = false
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        let observers = waitingObservers
        waitingObservers.removeAll()
        for observer in observers {
            observer.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { continuation in
            waitingObservers.append(continuation)
        }
    }

    func open() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class ControlledRankingListDataSource {
    private struct Request {
        let crawlKey: String?
        let fallbackItems: [KeywordRankingListItem]
        let storefrontCode: String
        let includesScreenshots: Bool
        var continuation: CheckedContinuation<KeywordRankingListLoader.Snapshot, any Error>?
    }

    private var requests: [Request] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load(
        crawlKey: String?,
        fallbackItems: [KeywordRankingListItem],
        storefrontCode: String,
        includesScreenshots: Bool
    ) async throws -> KeywordRankingListLoader.Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(
                crawlKey: crawlKey,
                fallbackItems: fallbackItems,
                storefrontCode: storefrontCode,
                includesScreenshots: includesScreenshots,
                continuation: continuation
            ))
            resumeSatisfiedWaiters()
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func succeedRequest(at index: Int, with snapshot: KeywordRankingListLoader.Snapshot) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil
        continuation?.resume(returning: snapshot)
    }

    func failRequest(at index: Int) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil
        continuation?.resume(throwing: ControlledRankingListError.expected)
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

private enum ControlledRankingListError: Error {
    case expected
}
