import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct RankingRefreshCoordinatorTests {
    @Test
    func topRankingEnrichmentRequestsDeduplicateAndLimitToTopTwenty() {
        let items = (1...25).map { position in
            SearchRankingItem(
                position: position,
                appStoreID: position == 2 ? 1 : Int64(position),
                bundleID: nil,
                name: "App \(position)",
                sellerName: nil,
                platform: .iphone
            )
        }

        let requests = RankingRefreshCoordinator.topRankingEnrichmentRequests(
            items: items,
            storefront: " US ",
            platform: .iphone
        )

        #expect(requests.count == 19)
        #expect(requests.allSatisfy { $0.storefront == "us" })
        #expect(requests.allSatisfy { $0.platform == .iphone })
        let appStoreIDs = requests.map(\.appStoreID)
        let duplicateCount = appStoreIDs.filter { $0 == 1 }.count
        #expect(appStoreIDs.contains(21) == false)
        #expect(duplicateCount == 1)
    }

    @Test
    func refreshCreatesSnapshotAndPersistsCapturedResults() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)

        let trackedApp = TrackedApp(
            appStoreID: 842842640,
            bundleID: "com.google.Docs",
            name: "Google Docs",
            sellerName: "Google",
            defaultPlatform: .iphone
        )
        let track = try makeTrackedAppKeyword(term: "pages", trackedApp: trackedApp, in: modelContext)

        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        let provider = StubRankingProvider(
            page: SearchRankingPage(
                items: [
                    SearchRankingItem(
                        position: 1,
                        appStoreID: 361309726,
                        bundleID: "com.apple.Pages",
                        name: "Pages",
                        subtitle: "Documents that stand apart",
                        sellerName: "Apple",
                        iconURLString: "https://example.com/pages-100.png",
                        releaseDate: isoDate("2010-04-01T20:36:57Z"),
                        currentVersionReleaseDate: isoDate("2026-04-09T17:00:45Z"),
                        version: "15.3",
                        primaryGenreID: 6007,
                        primaryGenreName: "Productivity",
                        descriptionText: "Create beautiful documents.",
                        releaseNotes: "Improved collaboration.",
                        supportedLanguageCodes: ["EN", "FR"],
                        screenshotURLs: [
                            "https://example.com/pages-iphone-1.png",
                            "https://example.com/pages-iphone-2.png"
                        ],
                        ipadScreenshotURLs: [
                            "https://example.com/pages-ipad-1.png"
                        ],
                        ratingCount: 513_197,
                        averageRating: 4.65041,
                        platform: .iphone
                    ),
                    SearchRankingItem(
                        position: 2,
                        appStoreID: 842842640,
                        bundleID: "com.google.Docs",
                        name: "Google Docs",
                        sellerName: "Google",
                        iconURLString: "https://example.com/google-docs-100.png",
                        platform: .iphone
                    )
                ],
                source: .iTunesFallback
            )
        )
        let resolver = StubAppResolver()
        let catalogService = AppCatalogService(appResolver: resolver)
        let coordinator = RankingRefreshCoordinator(rankingProvider: provider, appCatalogService: catalogService)

        let result = await coordinator.refresh(track: track, in: modelContext, limit: 10)

        switch result {
        case .success(let snapshot):
            #expect(snapshot.rank == 2)
            #expect(snapshot.topResults.count == 2)
            #expect(track.rankingAppCount == 2)
            #expect(track.lastRefreshAt != nil)
        case .failure(let error):
            Issue.record("Expected refresh to succeed, got \(String(describing: error.localizedDescription))")
        }

        let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
        let rankedResults = try modelContext.fetch(FetchDescriptor<TrackedKeywordRankedResult>())
        let storeApps = try modelContext.fetch(FetchDescriptor<StoreApp>())
        let observations = try modelContext.fetch(FetchDescriptor<KeywordRankingCrawl>())
        let observationItems = try modelContext.fetch(FetchDescriptor<KeywordAppRanking>())
        let latestRatings = try modelContext.fetch(FetchDescriptor<LatestAppRating>())
        let ratingSnapshots = try modelContext.fetch(FetchDescriptor<AppDailyRating>())
        let storefrontMetadata = try modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>())
        let screenshots = try modelContext.fetch(FetchDescriptor<AppStoreScreenshot>())
        let appKeywordStats = try modelContext.fetch(FetchDescriptor<AppKeywordStats>())

        #expect(snapshots.count == 1)
        #expect(rankedResults.count == 2)
        #expect(storeApps.count == 2)
        #expect(observations.count == 1)
        #expect(observationItems.count == 2)
        #expect(rankedResults.first(where: { $0.appStoreID == 361309726 })?.subtitle == "Documents that stand apart")
        #expect(observationItems.first(where: { $0.appStoreID == 361309726 })?.subtitle == "Documents that stand apart")
        #expect(appKeywordStats.count == 2)
        #expect(appKeywordStats.first(where: { $0.appStoreID == 842842640 })?.bestRank == 2)
        let pagesStoreApp = storeApps.first(where: { $0.appStoreID == 361309726 })
        #expect(pagesStoreApp?.iconURLString == "https://example.com/pages-100.png")
        #expect(pagesStoreApp?.supportedLanguageCodes == ["EN", "FR"])
        #expect(pagesStoreApp?.releaseDate == isoDate("2010-04-01T20:36:57Z"))
        #expect(pagesStoreApp?.currentVersionReleaseDate == isoDate("2026-04-09T17:00:45Z"))
        let pagesMetadata = storefrontMetadata.first(where: { $0.appStoreID == 361309726 && $0.storefront == "us" })
        #expect(pagesMetadata?.name == "Pages")
        #expect(pagesMetadata?.subtitle == "Documents that stand apart")
        #expect(pagesMetadata?.descriptionText == "Create beautiful documents.")
        #expect(pagesMetadata?.releaseNotes == "Improved collaboration.")
        #expect(pagesMetadata?.version == "15.3")
        #expect(pagesMetadata?.primaryGenreID == 6007)
        #expect(pagesMetadata?.primaryGenreName == "Productivity")
        #expect(screenshots.filter { $0.appStoreID == 361309726 && $0.storefront == "us" }.count == 3)
        #expect(screenshots.first(where: { $0.urlString == "https://example.com/pages-iphone-1.png" })?.platformRaw == "iphone")
        #expect(screenshots.first(where: { $0.urlString == "https://example.com/pages-ipad-1.png" })?.platformRaw == "ipad")
        #expect(latestRatings.count == 1)
        #expect(latestRatings.first?.appStoreID == 361309726)
        #expect(latestRatings.first?.storefront == "us")
        #expect(latestRatings.first?.ratingCount == 513_197)
        #expect(latestRatings.first?.averageRating == 4.65041)
        #expect(ratingSnapshots.count == 1)
        #expect(ratingSnapshots.first?.appStoreID == 361309726)
        #expect(ratingSnapshots.first?.storefront == "us")
        #expect(ratingSnapshots.first?.ratingCount == 513_197)
        #expect(ratingSnapshots.first?.averageRating == 4.65041)
    }

    @Test
    func webEnrichmentBackfillsMissingSubtitleForRankingCatalogApp() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let catalogService = AppCatalogService(appResolver: StubAppResolver())

        let rankingItem = SearchRankingItem(
            position: 1,
            appStoreID: 1_358_823_008,
            bundleID: "com.flightyapp.flighty",
            name: "Flighty",
            subtitle: nil,
            sellerName: "Flighty LLC",
            platform: .iphone
        )
        let storeApp = try catalogService.upsertStoreApp(
            from: rankingItem,
            storefrontCode: "gb",
            in: modelContext
        )

        #expect(storeApp.defaultStorefront == "gb")
        #expect(storeApp.subtitle == nil)

        let webMetadata = AppStoreWebMetadata(
            appStoreID: 1_358_823_008,
            storefront: "gb",
            name: "Flighty - Live Flight Tracker",
            subtitle: "World's Fastest Delay Alerts",
            sellerName: "Flighty LLC",
            averageRating: nil,
            ratingCount: nil,
            screenshotGroups: [
                AppStoreWebScreenshotGroup(
                    platformRaw: "iphone",
                    displayTypeRaw: "phone",
                    screenshots: [
                        AppStoreWebScreenshot(
                            urlString: "https://example.com/flighty-iphone.png",
                            width: 1242,
                            height: 2688
                        )
                    ]
                )
            ]
        )

        try catalogService.upsertStoreApp(
            from: webMetadata,
            storefrontCode: "gb",
            in: modelContext
        )
        try modelContext.save()

        let storeApps = try modelContext.fetch(FetchDescriptor<StoreApp>())
        let storefrontMetadata = try modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>())
        let screenshots = try modelContext.fetch(FetchDescriptor<AppStoreScreenshot>())

        #expect(storeApps.first?.subtitle == "World's Fastest Delay Alerts")
        #expect(storefrontMetadata.first?.storefront == "gb")
        #expect(storefrontMetadata.first?.subtitle == "World's Fastest Delay Alerts")
        #expect(screenshots.first?.urlString == "https://example.com/flighty-iphone.png")
    }

    @Test
    func refreshUpdatesExistingDailyRankingPeriod() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)

        let trackedApp = TrackedApp(
            appStoreID: 842842640,
            bundleID: "com.google.Docs",
            name: "Google Docs",
            sellerName: "Google",
            defaultPlatform: .iphone
        )
        let track = try makeTrackedAppKeyword(term: "pages", trackedApp: trackedApp, in: modelContext)

        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        let provider = StubRankingProvider(
            page: SearchRankingPage(
                items: [
                    SearchRankingItem(
                        position: 1,
                        appStoreID: 361309726,
                        bundleID: "com.apple.Pages",
                        name: "Pages",
                        sellerName: "Apple",
                        iconURLString: "https://example.com/pages-100.png",
                        platform: .iphone
                    ),
                    SearchRankingItem(
                        position: 2,
                        appStoreID: 842842640,
                        bundleID: "com.google.Docs",
                        name: "Google Docs",
                        sellerName: "Google",
                        iconURLString: "https://example.com/google-docs-100.png",
                        platform: .iphone
                    )
                ],
                source: .iTunesFallback
            )
        )
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )

        _ = await coordinator.refresh(track: track, in: modelContext, limit: 10)

        provider.page = SearchRankingPage(
            items: [
                SearchRankingItem(
                    position: 1,
                    appStoreID: 842842640,
                    bundleID: "com.google.Docs",
                    name: "Google Docs",
                    sellerName: "Google",
                    iconURLString: "https://example.com/google-docs-100.png",
                    platform: .iphone
                )
            ],
            source: .iTunesFallback
        )

        let result = await coordinator.refresh(track: track, in: modelContext, limit: 10)

        guard case .success(let snapshot) = result else {
            Issue.record("Expected refresh to succeed")
            return
        }

        let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
        let rankedResults = try modelContext.fetch(FetchDescriptor<TrackedKeywordRankedResult>())
        let observations = try modelContext.fetch(FetchDescriptor<KeywordRankingCrawl>())
        let observationItems = try modelContext.fetch(FetchDescriptor<KeywordAppRanking>())
        let appKeywordStats = try modelContext.fetch(FetchDescriptor<AppKeywordStats>())

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.persistentModelID == snapshot.persistentModelID)
        #expect(snapshot.rank == 1)
        #expect(snapshot.topResults.count == 1)
        #expect(rankedResults.count == 1)
        #expect(rankedResults.first?.appStoreID == 842842640)
        #expect(observations.count == 1)
        #expect(observationItems.count == 1)
        #expect(observationItems.first?.appStoreID == 842842640)
        #expect(appKeywordStats.count == 1)
        #expect(appKeywordStats.first?.appStoreID == 842842640)
        #expect(appKeywordStats.first?.latestRank == 1)
        #expect(appKeywordStats.first?.observationCount == 1)
    }

    @Test
    func dailyRefreshSettingsDefaultToSevenAMAndOnlyTriggerOncePerDay() throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let beforeScheduledTime = date(year: 2026, month: 1, day: 2, hour: 6, minute: 59, calendar: calendar)
        let scheduledTime = date(year: 2026, month: 1, day: 2, hour: 7, minute: 0, calendar: calendar)
        let laterThatDay = date(year: 2026, month: 1, day: 2, hour: 12, minute: 0, calendar: calendar)

        #expect(settingsStore.isAutomaticRefreshEnabled)
        #expect(settingsStore.refreshHour == 7)
        #expect(settingsStore.refreshMinute == 0)
        #expect(!settingsStore.shouldTriggerRefresh(at: beforeScheduledTime, calendar: calendar))
        #expect(settingsStore.shouldTriggerRefresh(at: scheduledTime, calendar: calendar))

        settingsStore.markRefreshTriggered(on: scheduledTime)

        #expect(!settingsStore.shouldTriggerRefresh(at: laterThatDay, calendar: calendar))
        #expect(settingsStore.hasTriggeredRefresh(on: laterThatDay, calendar: calendar))
    }

    @Test
    func dailyRefreshSettingsTrackRatingsReviewsRefreshSeparately() throws {
        let defaults = makeDefaults()
        let calendar = utcCalendar()
        let refreshTime = date(year: 2026, month: 1, day: 2, hour: 10, minute: 0, calendar: calendar)
        let sameDay = date(year: 2026, month: 1, day: 2, hour: 18, minute: 0, calendar: calendar)
        let nextDay = date(year: 2026, month: 1, day: 3, hour: 8, minute: 0, calendar: calendar)

        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.markRatingsReviewsRefreshed(on: refreshTime)

        let reloadedSettingsStore = AppSettingsStore(defaults: defaults)
        #expect(reloadedSettingsStore.hasRefreshedRatingsReviews(on: sameDay, calendar: calendar))
        #expect(!reloadedSettingsStore.hasRefreshedRatingsReviews(on: nextDay, calendar: calendar))
        #expect(!reloadedSettingsStore.hasTriggeredRefresh(on: sameDay, calendar: calendar))
    }

    @Test
    func dailyRefreshSettingsCanDisableAutomaticRefresh() throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let scheduledTime = date(year: 2026, month: 1, day: 2, hour: 7, minute: 0, calendar: calendar)

        settingsStore.setAutomaticRefreshEnabled(false)

        #expect(!settingsStore.isAutomaticRefreshEnabled)
        #expect(!settingsStore.shouldTriggerRefresh(at: scheduledTime, calendar: calendar))
        #expect(settingsStore.scheduleConfiguration == DailyRefreshScheduleConfiguration(
            isAutomaticRefreshEnabled: false,
            refreshTimeMinutes: 7 * 60
        ))
    }

    @Test
    func dailyRefreshSchedulerRefreshesStaleTracksOncePerDay() async throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let triggerTime = date(year: 2026, month: 1, day: 2, hour: 7, minute: 1, calendar: calendar)
        let laterThatDay = date(year: 2026, month: 1, day: 2, hour: 10, minute: 0, calendar: calendar)

        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 842842640,
            bundleID: "com.google.Docs",
            name: "Google Docs",
            sellerName: "Google",
            defaultPlatform: .iphone
        )
        let track = try makeTrackedAppKeyword(term: "pages", trackedApp: trackedApp, in: modelContext)
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        let provider = StubRankingProvider(
            page: SearchRankingPage(
                items: [
                    SearchRankingItem(
                        position: 1,
                        appStoreID: 842842640,
                        bundleID: "com.google.Docs",
                        name: "Google Docs",
                        sellerName: "Google",
                        iconURLString: "https://example.com/google-docs-100.png",
                        platform: .iphone
                    )
                ],
                source: .iTunesFallback
            )
        )
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let scheduler = DailyRefreshScheduler(settingsStore: settingsStore, refreshCoordinator: coordinator)

        let didTrigger = await scheduler.triggerIfNeeded(in: modelContext, now: triggerTime, calendar: calendar)
        let didTriggerAgain = await scheduler.triggerIfNeeded(in: modelContext, now: laterThatDay, calendar: calendar)

        #expect(didTrigger)
        #expect(!didTriggerAgain)
        #expect(provider.searchCount == 1)
        #expect(scheduler.lastOutcome?.refreshedCount == 1)
        #expect(settingsStore.hasTriggeredRefresh(on: laterThatDay, calendar: calendar))
    }

    @Test
    func dailyRefreshSchedulerRunsAppDetailPipelineForTrackedApps() async throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let triggerTime = date(year: 2026, month: 1, day: 2, hour: 7, minute: 1, calendar: calendar)

        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let firstApp = TrackedApp(
            appStoreID: 842842640,
            bundleID: "com.google.Docs",
            name: "Google Docs",
            sellerName: "Google",
            defaultPlatform: .iphone
        )
        let firstTrack = try makeTrackedAppKeyword(term: "pages", trackedApp: firstApp, in: modelContext)
        firstApp.keywordTracks.append(firstTrack)
        let secondApp = TrackedApp(
            appStoreID: 361309726,
            bundleID: "com.apple.Pages",
            name: "Pages",
            sellerName: "Apple",
            defaultPlatform: .iphone
        )
        modelContext.insert(firstApp)
        modelContext.insert(firstTrack)
        modelContext.insert(secondApp)
        try modelContext.save()

        var requests: [AppDetailRefreshRequest] = []
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: StubRankingProvider(page: SearchRankingPage(items: [], source: .iTunesFallback)),
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let scheduler = DailyRefreshScheduler(
            settingsStore: settingsStore,
            refreshCoordinator: coordinator,
            appDetailRefresh: { request in
                requests.append(request)
                return AppDetailRefreshResult(keywordOutcomes: [], ratingOutcomes: [], reviewOutcomes: [], firstError: nil)
            },
            storefrontCodesProvider: { ["US", "gb"] }
        )

        let didTrigger = await scheduler.triggerIfNeeded(in: modelContext, now: triggerTime, calendar: calendar)

        #expect(didTrigger)
        #expect(requests.count == 2)
        #expect(scheduler.lastOutcome?.refreshedCount == 2)
        #expect(scheduler.lastOutcome?.failureCount == 0)
        #expect(settingsStore.hasTriggeredRefresh(on: triggerTime, calendar: calendar))
        #expect(settingsStore.hasRefreshedRatingsReviews(on: triggerTime, calendar: calendar))

        let requestsByAppID = Dictionary(uniqueKeysWithValues: requests.map { ($0.app.appStoreID, $0) })
        #expect(requestsByAppID[842842640]?.trackIdentityKeys == [firstTrack.identityKey])
        #expect(requestsByAppID[361309726]?.trackIdentityKeys == [])
        #expect(requests.allSatisfy { $0.trigger == "daily_refresh" })
        #expect(requests.allSatisfy { $0.refreshKeywords && $0.refreshMetrics })
        #expect(requests.allSatisfy { $0.refreshRatings && $0.refreshReviews })
        #expect(requests.allSatisfy { !$0.recordsRatingsReviewsRefresh })
        #expect(requests.allSatisfy {
            if case .all(let codes) = $0.storefrontSelection {
                return codes == ["gb", "us"]
            }
            return false
        })
    }

    @Test
    func dailyRefreshSchedulerSkipsRatingsReviewsWhenAlreadyRefreshedToday() async throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let ratingsRefreshTime = date(year: 2026, month: 1, day: 2, hour: 6, minute: 30, calendar: calendar)
        let triggerTime = date(year: 2026, month: 1, day: 2, hour: 7, minute: 1, calendar: calendar)
        settingsStore.markRatingsReviewsRefreshed(on: ratingsRefreshTime)

        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        modelContext.insert(TrackedApp(
            appStoreID: 842842640,
            bundleID: "com.google.Docs",
            name: "Google Docs",
            sellerName: "Google",
            defaultPlatform: .iphone
        ))
        try modelContext.save()

        var requests: [AppDetailRefreshRequest] = []
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: StubRankingProvider(page: SearchRankingPage(items: [], source: .iTunesFallback)),
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let scheduler = DailyRefreshScheduler(
            settingsStore: settingsStore,
            refreshCoordinator: coordinator,
            appDetailRefresh: { request in
                requests.append(request)
                return AppDetailRefreshResult(keywordOutcomes: [], ratingOutcomes: [], reviewOutcomes: [], firstError: nil)
            },
            storefrontCodesProvider: { ["us"] }
        )

        let didTrigger = await scheduler.triggerIfNeeded(in: modelContext, now: triggerTime, calendar: calendar)

        #expect(didTrigger)
        #expect(requests.count == 1)
        #expect(requests.first?.refreshKeywords == true)
        #expect(requests.first?.refreshMetrics == true)
        #expect(requests.first?.refreshRatings == false)
        #expect(requests.first?.refreshReviews == false)
    }

    @Test
    func dailyRefreshSchedulerDoesNotTriggerBeforeScheduledTime() async throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let beforeScheduledTime = date(year: 2026, month: 1, day: 2, hour: 6, minute: 59, calendar: calendar)

        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let provider = StubRankingProvider(page: SearchRankingPage(items: [], source: .iTunesFallback))
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let scheduler = DailyRefreshScheduler(settingsStore: settingsStore, refreshCoordinator: coordinator)

        let didTrigger = await scheduler.triggerIfNeeded(in: modelContext, now: beforeScheduledTime, calendar: calendar)

        #expect(!didTrigger)
        #expect(provider.searchCount == 0)
        #expect(scheduler.lastOutcome == nil)
        #expect(!settingsStore.hasTriggeredRefresh(on: beforeScheduledTime, calendar: calendar))
    }

    @Test
    func dailyRefreshSchedulerMarksDayTriggeredWhenNoTracksAreStale() async throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let triggerTime = date(year: 2026, month: 1, day: 2, hour: 7, minute: 1, calendar: calendar)

        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 842842640,
            bundleID: "com.google.Docs",
            name: "Google Docs",
            sellerName: "Google",
            defaultPlatform: .iphone
        )
        let track = try makeTrackedAppKeyword(term: "pages", trackedApp: trackedApp, in: modelContext)
        track.lastRefreshAt = Date.now
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        let provider = StubRankingProvider(page: SearchRankingPage(items: [], source: .iTunesFallback))
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let scheduler = DailyRefreshScheduler(settingsStore: settingsStore, refreshCoordinator: coordinator)

        let didTrigger = await scheduler.triggerIfNeeded(in: modelContext, now: triggerTime, calendar: calendar)

        #expect(didTrigger)
        #expect(provider.searchCount == 0)
        #expect(scheduler.lastOutcome?.refreshedCount == 0)
        #expect(scheduler.lastOutcome?.failureCount == 0)
        #expect(settingsStore.hasTriggeredRefresh(on: triggerTime, calendar: calendar))
    }

    @Test
    func dailyRefreshSchedulerRecomputesNextSleepFromCurrentSettings() throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = Calendar.current
        let referenceDate = date(year: 2026, month: 1, day: 2, hour: 6, minute: 0, calendar: calendar)
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: StubRankingProvider(page: SearchRankingPage(items: [], source: .iTunesFallback)),
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let scheduler = DailyRefreshScheduler(settingsStore: settingsStore, refreshCoordinator: coordinator)

        #expect(scheduler.nextCheckSleepNanoseconds(now: referenceDate) == 60 * 60 * 1_000_000_000)

        settingsStore.saveRefreshTime(hour: 8, minute: 30)

        #expect(scheduler.nextCheckSleepNanoseconds(now: referenceDate) == 150 * 60 * 1_000_000_000)
    }

    @Test
    func scheduledLoopExitsPromptlyWhenCancelledDuringSleep() async {
        let loop = ScheduledLoop()
        var operationCount = 0
        var sleepCount = 0

        let task = Task { @MainActor in
            await loop.run {
                operationCount += 1
            } sleepUntilNextRun: {
                sleepCount += 1
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }

        while sleepCount == 0 {
            await Task.yield()
        }
        task.cancel()
        await task.value

        #expect(operationCount == 1)
        #expect(sleepCount == 1)
    }

    @Test
    func storefrontCatalogAddsMissingBundledRegionsToExistingStores() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        modelContext.insert(Storefront(code: "us", name: "Old United States", flagEmoji: "US", languageCode: "en"))
        try modelContext.save()

        try StorefrontCatalog().seedIfNeeded(in: modelContext)

        let storefronts = try modelContext.fetch(FetchDescriptor<Storefront>())
        let codes = Set(storefronts.map(\.code))

        #expect(storefronts.count == StorefrontCatalog.seedCount)
        #expect(codes.count == storefronts.count)
        #expect(codes.contains("us"))
        #expect(codes.contains("zm"))
        #expect(storefronts.first(where: { $0.code == "us" })?.name == "United States")
        #expect(storefronts.first(where: { $0.code == "us" })?.flagEmoji == "🇺🇸")
    }
}

@MainActor
struct AppDetailRefreshServiceQueueTests {
    @Test
    func refreshSerializesConcurrentAppRefreshRequests() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        modelContext.insert(StoreApp(
            appStoreID: 1,
            bundleID: nil,
            name: "First App",
            sellerName: nil,
            iconURLString: nil,
            defaultPlatform: .iphone
        ))
        modelContext.insert(StoreApp(
            appStoreID: 2,
            bundleID: nil,
            name: "Second App",
            sellerName: nil,
            iconURLString: nil,
            defaultPlatform: .iphone
        ))
        try modelContext.save()

        let httpClient = ControlledRatingsHTTPClient()
        let progressStore = AppRefreshProgressStore()
        let service = AppDetailRefreshService(
            backgroundModelStore: BackgroundModelStore(modelContainer: container),
            refreshCoordinator: RankingRefreshCoordinator(
                rankingProvider: StubRankingProvider(page: SearchRankingPage(items: [], source: .iTunesFallback)),
                appCatalogService: AppCatalogService(appResolver: StubAppResolver())
            ),
            keywordMetricsService: KeywordMetricsService(
                httpClient: httpClient,
                credentialStore: AppleAdsCredentialStore(
                    defaults: makeDefaults(),
                    keychain: InMemoryKeychainService(),
                    loadsEnvironmentCredentials: false
                ),
                settingsStore: AppSettingsStore(defaults: makeDefaults()),
                webSessionStore: AppleAdsWebSessionStore(defaults: makeDefaults(), keychain: InMemoryKeychainService())
            ),
            appStorefrontRatingService: AppStorefrontRatingService(
                httpClient: httpClient,
                retryPolicy: AppStorefrontRatingRetryPolicy(maxAttempts: 1, baseDelaySeconds: 0, maxDelaySeconds: 0)
            ),
            appStorefrontReviewService: AppStorefrontReviewService(httpClient: httpClient),
            appStoreConnectReviewService: AppStoreConnectReviewService(
                httpClient: httpClient,
                credentialStore: AppStoreConnectCredentialStore(defaults: makeDefaults(), keychain: InMemoryKeychainService())
            ),
            progressStore: progressStore
        )

        let firstTask = Task {
            await service.refresh(Self.request(appStoreID: 1, appName: "First App"))
        }
        await httpClient.waitForRequestCount(1)
        #expect(progressStore.pendingAppRefreshCount == 0)

        let secondTask = Task {
            await service.refresh(Self.request(appStoreID: 2, appName: "Second App"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await httpClient.requestedAppStoreIDs() == [1])
        #expect(progressStore.pendingAppRefreshCount == 1)

        await httpClient.complete(appStoreID: 1)
        let firstResult = await firstTask.value
        #expect(firstResult.firstError == nil)
        #expect(firstResult.ratingOutcomes.map { $0.storefront } == ["us"])

        await httpClient.waitForRequestCount(2)
        #expect(await httpClient.requestedAppStoreIDs() == [1, 2])
        #expect(progressStore.pendingAppRefreshCount == 0)

        await httpClient.complete(appStoreID: 2)
        let secondResult = await secondTask.value
        #expect(secondResult.firstError == nil)
        #expect(secondResult.ratingOutcomes.map { $0.storefront } == ["us"])
    }

    private static func request(appStoreID: Int64, appName: String) -> AppDetailRefreshRequest {
        AppDetailRefreshRequest(
            app: AppDetailRefreshAppSnapshot(
                appStoreID: appStoreID,
                bundleID: nil,
                name: appName,
                subtitle: nil,
                sellerName: nil,
                defaultPlatform: .iphone
            ),
            workspace: .ratings,
            storefrontSelection: .storefront(code: "us"),
            trackIdentityKeys: [],
            trigger: "after_add_app",
            refreshKeywords: false,
            refreshMetrics: false,
            refreshRatings: true,
            refreshReviews: false,
            recordsRatingsReviewsRefresh: false,
            popularityContextAppStoreID: nil,
            appleAdsWebSession: nil,
            appStoreConnectCredentials: AppStoreConnectCredentials(issuerID: "", keyID: "", privateKey: "")
        )
    }
}

@MainActor
private final class StubRankingProvider: SearchRankingProvider {
    var page: SearchRankingPage
    private(set) var searchCount = 0

    init(page: SearchRankingPage) {
        self.page = page
    }

    func search(keyword: String, storefrontCode: String, platform: AppPlatform, limit: Int) async throws -> SearchRankingPage {
        searchCount += 1
        return page
    }
}

@MainActor
private final class StubAppResolver: AppResolver {
    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        ResolvedApp(
            appStoreID: appStoreID,
            bundleID: "stub.bundle.\(appStoreID)",
            name: "Stub",
            sellerName: "Stub Seller",
            iconURLString: "https://example.com/\(appStoreID).png",
            defaultPlatform: .iphone
        )
    }

    func searchApps(named query: String, storefrontCode: String, limit: Int) async throws -> [ResolvedApp] {
        []
    }
}

private actor ControlledRatingsHTTPClient: HTTPClient {
    private var requestedIDs: [Int64] = []
    private var pendingResponses: [Int64: CheckedContinuation<(Data, URLResponse), any Error>] = [:]
    private var requestCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let appStoreID = Self.appStoreID(from: request)
        requestedIDs.append(appStoreID)
        resumeSatisfiedWaiters()

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[appStoreID] = continuation
        }
    }

    func requestedAppStoreIDs() -> [Int64] {
        requestedIDs
    }

    func waitForRequestCount(_ count: Int) async {
        guard requestedIDs.count < count else { return }

        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func complete(appStoreID: Int64) {
        guard let continuation = pendingResponses.removeValue(forKey: appStoreID) else { return }
        let url = URL(string: "https://itunes.apple.com/lookup?id=\(appStoreID)&country=us")!
        let data = Data(#"{"results":[{"trackId":\#(appStoreID),"userRatingCount":42,"averageUserRating":4.5}]}"#.utf8)
        continuation.resume(returning: (
            data,
            makeHTTPURLResponse(url: url, statusCode: 200)
        ))
    }

    private func resumeSatisfiedWaiters() {
        let readyWaiters = requestCountWaiters.filter { requestedIDs.count >= $0.count }
        requestCountWaiters.removeAll { requestedIDs.count >= $0.count }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    private static func appStoreID(from request: URLRequest) -> Int64 {
        guard
            let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
            let appStoreID = Int64(id)
        else {
            return 0
        }
        return appStoreID
    }
}

private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([
        AppFolder.self,
        AppKeywordStats.self,
        LatestAppRating.self,
        AppDailyRating.self,
        AppStorefrontReview.self,
        StoreApp.self,
        AppStorefrontMetadata.self,
        AppStoreScreenshot.self,
        KeywordQuery.self,
        KeywordDailyMetric.self,
        KeywordRankingCrawl.self,
        KeywordAppRanking.self,
        TrackedApp.self,
        TrackedAppKeyword.self,
        TrackedKeywordDailyRanking.self,
        TrackedKeywordRankedResult.self,
        Storefront.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

private func makeTrackedAppKeyword(
    term: String,
    trackedApp: TrackedApp,
    in modelContext: ModelContext
) throws -> TrackedAppKeyword {
    let query = try KeywordQuery.fetchOrInsert(
        term: term,
        storefront: "us",
        platform: .iphone,
        in: modelContext
    )
    return TrackedAppKeyword(
        term: term,
        storefront: "us",
        platform: .iphone,
        trackedApp: trackedApp,
        query: query
    )
}

private func makeDefaults() -> UserDefaults {
    let suiteName = "daily.refresh.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    )) ?? Date(timeIntervalSince1970: 0)
}

private func isoDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
}

private extension StorefrontCatalog {
    static var seedCount: Int {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenASO")
            .appendingPathComponent("Resources")
            .appendingPathComponent("storefronts.json")
        guard
              let data = try? Data(contentsOf: url),
              let seeds = try? JSONDecoder().decode([Seed].self, from: data) else {
            return 0
        }
        return seeds.count
    }

    struct Seed: Decodable {
        let code: String
        let name: String
        let flagEmoji: String
        let languageCode: String
    }
}
