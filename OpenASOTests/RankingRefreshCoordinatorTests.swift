import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct RankingRefreshCoordinatorTests {
    @Test
    func rankingRequestGroupsNormalizeEquivalentQueriesAndPreserveFanOutMetadata() throws {
        let requests = [
            RankingRefreshRequest(
                identityKey: "101::pages::us::iphone",
                queryKey: "legacy-query-a",
                term: " Pages ",
                storefront: " US ",
                platform: .iphone
            ),
            RankingRefreshRequest(
                identityKey: "202::pages::us::iphone",
                queryKey: "legacy-query-b",
                term: "pages",
                storefront: "us",
                platform: .iphone
            ),
            RankingRefreshRequest(
                identityKey: "303::pages::us::ipad",
                queryKey: "pages::us::ipad",
                term: "pages",
                storefront: "US",
                platform: .ipad
            ),
            RankingRefreshRequest(
                identityKey: "404::numbers::us::iphone",
                queryKey: "numbers::us::iphone",
                term: "Numbers",
                storefront: "us",
                platform: .iphone
            ),
        ]

        let groups = RankingRequestGroup.normalizedGroups(for: requests)

        #expect(groups.count == 3)
        let pagesGroup = try #require(groups.first)
        #expect(pagesGroup.providerRequest.identityKey == requests[0].identityKey)
        #expect(pagesGroup.providerRequest.queryKey == "pages::us::iphone")
        #expect(pagesGroup.providerRequest.term == "Pages")
        #expect(pagesGroup.providerRequest.storefront == "us")
        #expect(pagesGroup.providerRequest.platform == .iphone)
        #expect(pagesGroup.targetRequests.map(\.identityKey) == [
            requests[0].identityKey,
            requests[1].identityKey,
        ])
        #expect(groups[1].providerRequest.platform == .ipad)
        #expect(groups[2].providerRequest.term == "Numbers")

        let searchedAt = Date(timeIntervalSince1970: 1_234)
        let providerResult = RankingRefreshPageResult(
            request: pagesGroup.providerRequest,
            page: SearchRankingPage(items: [], source: .iTunesFallback),
            searchedAt: searchedAt,
            observedHour: 42,
            submissionCount: 3,
            winningCount: 2,
            confidence: "fixture-confidence"
        )
        let fannedResults = pagesGroup.pageResults(fanningOut: providerResult)

        #expect(fannedResults.map(\.request.identityKey) == pagesGroup.targetRequests.map(\.identityKey))
        #expect(fannedResults.allSatisfy { $0.searchedAt == searchedAt })
        #expect(fannedResults.allSatisfy { $0.observedHour == 42 })
        #expect(fannedResults.allSatisfy { $0.submissionCount == 3 })
        #expect(fannedResults.allSatisfy { $0.winningCount == 2 })
        #expect(fannedResults.allSatisfy { $0.confidence == "fixture-confidence" })
        #expect(fannedResults.allSatisfy { $0.page.source == .iTunesFallback })
    }

    @Test
    func refreshTracksDeduplicatesNormalizedQueriesAndPersistsPerAppResults() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let fixture = try makeDeduplicatedRefreshFixture(in: modelContext)
        fixture.firstTrack.term = " Pages "
        try modelContext.save()

        let provider = QueryRankingProvider(responses: [
            QueryRankingProvider.key(term: "pages", storefront: "us", platform: .iphone): .page(
                SearchRankingPage(
                    items: [
                        rankingItem(position: 1, appStoreID: fixture.firstApp.appStoreID, platform: .iphone),
                        rankingItem(position: 2, appStoreID: 999, platform: .iphone),
                        rankingItem(position: 3, appStoreID: fixture.secondApp.appStoreID, platform: .iphone),
                    ],
                    source: .iTunesFallback
                )
            ),
            QueryRankingProvider.key(term: "pages", storefront: "gb", platform: .iphone): .page(
                SearchRankingPage(
                    items: [
                        rankingItem(position: 1, appStoreID: 998, platform: .iphone),
                        rankingItem(position: 2, appStoreID: fixture.thirdApp.appStoreID, platform: .iphone),
                    ],
                    source: .iTunesFallback
                )
            ),
        ])
        let progressRecorder = RankingRefreshProgressRecorder()
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )

        let outcomes = await coordinator.refresh(
            tracks: fixture.tracks,
            in: modelContext,
            progress: { completed, total, failureCount in
                await progressRecorder.record(
                    completed: completed,
                    total: total,
                    failureCount: failureCount
                )
            }
        )

        #expect(await provider.callCounts() == [
            "pages::us::iphone": 1,
            "pages::gb::iphone": 1,
        ])
        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy { $0.error == nil })
        #expect(outcomes.first(where: { $0.trackID == fixture.firstTrack.persistentModelID })?.rank == 1)
        #expect(outcomes.first(where: { $0.trackID == fixture.secondTrack.persistentModelID })?.rank == 3)
        #expect(outcomes.first(where: { $0.trackID == fixture.thirdTrack.persistentModelID })?.rank == 2)

        let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
        let ranksByTrack = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.trackIdentityKey, $0.rank) })
        #expect(snapshots.count == 3)
        #expect(ranksByTrack[fixture.firstTrack.identityKey] == 1)
        #expect(ranksByTrack[fixture.secondTrack.identityKey] == 3)
        #expect(ranksByTrack[fixture.thirdTrack.identityKey] == 2)

        let crawls = try modelContext.fetch(FetchDescriptor<KeywordRankingCrawl>())
        #expect(crawls.count == 2)
        #expect(crawls.allSatisfy { $0.confidenceRaw == "single_source" })
        #expect(crawls.first(where: { $0.queryKey == fixture.firstTrack.queryKey })?.submissionCount == 1)
        #expect(crawls.first(where: { $0.queryKey == fixture.firstTrack.queryKey })?.winningCount == 1)
        #expect(await progressRecorder.values() == [
            RankingRefreshProgressValue(completed: 0, total: 3, failureCount: 0),
            RankingRefreshProgressValue(completed: 1, total: 3, failureCount: 0),
            RankingRefreshProgressValue(completed: 2, total: 3, failureCount: 0),
            RankingRefreshProgressValue(completed: 3, total: 3, failureCount: 0),
        ])
    }

    @Test
    func refreshTracksFansSharedQueryFailureOutAndCompletesUnrelatedQuery() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let fixture = try makeDeduplicatedRefreshFixture(in: modelContext)
        fixture.firstTrack.term = " Pages "
        try modelContext.save()

        let provider = QueryRankingProvider(responses: [
            QueryRankingProvider.key(term: "pages", storefront: "us", platform: .iphone): .failure(.networkUnavailable),
            QueryRankingProvider.key(term: "pages", storefront: "gb", platform: .iphone): .page(
                SearchRankingPage(
                    items: [
                        rankingItem(position: 1, appStoreID: 998, platform: .iphone),
                        rankingItem(position: 2, appStoreID: fixture.thirdApp.appStoreID, platform: .iphone),
                    ],
                    source: .iTunesFallback
                )
            ),
        ])
        let progressRecorder = RankingRefreshProgressRecorder()
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )

        let outcomes = await coordinator.refresh(
            tracks: fixture.tracks,
            in: modelContext,
            progress: { completed, total, failureCount in
                await progressRecorder.record(
                    completed: completed,
                    total: total,
                    failureCount: failureCount
                )
            }
        )

        #expect(await provider.callCounts() == [
            "pages::us::iphone": 1,
            "pages::gb::iphone": 1,
        ])
        #expect(outcomes.count == 3)
        #expect(outcomes.first(where: { $0.trackID == fixture.firstTrack.persistentModelID })?.error == .networkUnavailable)
        #expect(outcomes.first(where: { $0.trackID == fixture.secondTrack.persistentModelID })?.error == .networkUnavailable)
        #expect(outcomes.first(where: { $0.trackID == fixture.thirdTrack.persistentModelID })?.rank == 2)
        let statuses = try TrackedKeywordRefreshStatusStore.snapshots(
            for: [
                fixture.firstTrack.identityKey,
                fixture.secondTrack.identityKey,
                fixture.thirdTrack.identityKey,
            ],
            in: modelContext
        )
        #expect(statuses[fixture.firstTrack.identityKey]?.rankingMessage?.contains("network") == true)
        #expect(statuses[fixture.secondTrack.identityKey]?.rankingMessage?.contains("network") == true)
        #expect(statuses[fixture.thirdTrack.identityKey]?.rankingMessage == nil)

        let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
        #expect(snapshots.map(\.trackIdentityKey) == [fixture.thirdTrack.identityKey])
        let crawls = try modelContext.fetch(FetchDescriptor<KeywordRankingCrawl>())
        #expect(crawls.count == 1)
        #expect(crawls.first?.queryKey == fixture.thirdTrack.queryKey)
        #expect(crawls.first?.confidenceRaw == "single_source")
        #expect(await progressRecorder.values() == [
            RankingRefreshProgressValue(completed: 0, total: 3, failureCount: 0),
            RankingRefreshProgressValue(completed: 1, total: 3, failureCount: 1),
            RankingRefreshProgressValue(completed: 2, total: 3, failureCount: 2),
            RankingRefreshProgressValue(completed: 3, total: 3, failureCount: 2),
        ])
    }

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
            rankingSource: .iTunesFallback,
            fetchedAt: .now,
            requestedPlatform: .iphone,
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
    func rankingPersistenceKeepsProviderProvenanceTimestampsAndCanonicalPlatform() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 100,
            bundleID: "com.example.target",
            name: "Target",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let macTrack = try makeTrackedAppKeyword(
            term: "notes",
            platform: .mac,
            trackedApp: trackedApp,
            in: modelContext
        )
        let ipadTrack = try makeTrackedAppKeyword(
            term: "notepad",
            platform: .ipad,
            trackedApp: trackedApp,
            in: modelContext
        )
        trackedApp.keywordTracks.append(contentsOf: [macTrack, ipadTrack])
        modelContext.insert(trackedApp)
        modelContext.insert(macTrack)
        modelContext.insert(ipadTrack)
        try modelContext.save()

        let catalogService = AppCatalogService(appResolver: StubAppResolver())
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: StubRankingProvider(
                page: SearchRankingPage(items: [], source: .iTunesFallback)
            ),
            appCatalogService: catalogService
        )
        let webDate = Date(timeIntervalSince1970: 1_800_000_000)
        let fallbackDate = webDate.addingTimeInterval(60)
        let item = SearchRankingItem(
            position: 1,
            appStoreID: 200,
            bundleID: "com.example.result",
            name: "Result",
            sellerName: "Example",
            supportedLanguageCodes: ["EN"],
            screenshotURLs: ["https://example.com/result.png"],
            ipadScreenshotURLs: ["https://example.com/result-ipad.png"],
            ratingCount: 42,
            averageRating: 4.5,
            platform: .mac
        )

        _ = try coordinator.persistRankingPage(
            RankingRefreshPageResult(
                request: RankingRefreshRequest(track: macTrack),
                page: SearchRankingPage(items: [item], source: .appStoreWeb),
                searchedAt: webDate,
                observedHour: nil,
                submissionCount: 1,
                winningCount: 1,
                confidence: "single_source"
            ),
            in: modelContext,
            scheduleMetadataEnrichment: false
        )

        var storeApp = try #require(modelContext.fetch(FetchDescriptor<StoreApp>()).first {
            $0.appStoreID == 200
        })
        var metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first {
            $0.appStoreID == 200
        })
        var screenshot = try #require(modelContext.fetch(FetchDescriptor<AppStoreScreenshot>()).first {
            $0.appStoreID == 200
        })
        var latestRating = try #require(modelContext.fetch(FetchDescriptor<LatestAppRating>()).first {
            $0.appStoreID == 200
        })
        var dailyRating = try #require(modelContext.fetch(FetchDescriptor<AppDailyRating>()).first {
            $0.appStoreID == 200
        })

        #expect(storeApp.defaultPlatform == .mac)
        #expect(storeApp.supportedLanguageCodesSource == .appStoreWebSearch)
        #expect(storeApp.supportedLanguageCodesFetchedAt == webDate)
        #expect(storeApp.lastMetadataRefreshAt == webDate)
        #expect(metadata.defaultPlatform == .mac)
        #expect(metadata.source == .appStoreWebSearch)
        #expect(metadata.lastFetchedAt == webDate)
        #expect(screenshot.source == .appStoreWebSearch)
        #expect(screenshot.lastFetchedAt == webDate)
        #expect(latestRating.source == .appStorePage)
        #expect(latestRating.observedAt == webDate)
        #expect(dailyRating.source == .appStorePage)
        #expect(dailyRating.observedAt == webDate)
        #expect(storeApp.storefrontLatest.contains { $0 === latestRating })
        #expect(storeApp.ratingSnapshots.contains { $0 === dailyRating })

        let fallbackItem = SearchRankingItem(
            position: 1,
            appStoreID: 200,
            bundleID: "com.example.result",
            name: "Result",
            sellerName: "Example",
            supportedLanguageCodes: ["FR"],
            screenshotURLs: ["https://example.com/result.png"],
            ratingCount: 43,
            averageRating: 4.6,
            platform: .ipad
        )

        _ = try coordinator.persistRankingPage(
            RankingRefreshPageResult(
                request: RankingRefreshRequest(track: ipadTrack),
                page: SearchRankingPage(items: [fallbackItem], source: .iTunesFallback),
                searchedAt: fallbackDate,
                observedHour: nil,
                submissionCount: 1,
                winningCount: 1,
                confidence: "single_source"
            ),
            in: modelContext,
            scheduleMetadataEnrichment: false
        )

        storeApp = try #require(modelContext.fetch(FetchDescriptor<StoreApp>()).first { $0.appStoreID == 200 })
        metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first { $0.appStoreID == 200 })
        let screenshots = try modelContext.fetch(FetchDescriptor<AppStoreScreenshot>()).filter {
            $0.appStoreID == 200
        }
        screenshot = try #require(screenshots.first { $0.platformRaw == "iphone" })
        let retainedIPadScreenshot = try #require(screenshots.first { $0.platformRaw == "ipad" })
        latestRating = try #require(modelContext.fetch(FetchDescriptor<LatestAppRating>()).first { $0.appStoreID == 200 })
        dailyRating = try #require(modelContext.fetch(FetchDescriptor<AppDailyRating>()).first { $0.appStoreID == 200 })

        #expect(storeApp.defaultPlatform == .mac)
        #expect(storeApp.supportedLanguageCodes == ["FR"])
        #expect(storeApp.supportedLanguageCodesSource == .iTunesSearch)
        #expect(storeApp.supportedLanguageCodesFetchedAt == fallbackDate)
        #expect(metadata.defaultPlatform == .mac)
        #expect(metadata.source == .iTunesSearch)
        #expect(metadata.lastFetchedAt == fallbackDate)
        #expect(screenshot.source == .iTunesSearch)
        #expect(screenshot.lastFetchedAt == fallbackDate)
        #expect(retainedIPadScreenshot.source == .appStoreWebSearch)
        #expect(retainedIPadScreenshot.lastFetchedAt == webDate)
        #expect(latestRating.source == .iTunesSearch)
        #expect(latestRating.observedAt == fallbackDate)
        #expect(latestRating.ratingCount == 43)
        #expect(dailyRating.source == .iTunesSearch)
        #expect(dailyRating.observedAt == fallbackDate)
        #expect(dailyRating.ratingCount == 43)
        #expect(storeApp.storefrontLatest.contains { $0 === latestRating })
        #expect(storeApp.ratingSnapshots.contains { $0 === dailyRating })

        let olderWebItem = SearchRankingItem(
            position: 1,
            appStoreID: 200,
            bundleID: "com.example.result",
            name: "Stale Result",
            sellerName: "Example",
            supportedLanguageCodes: ["DE"],
            screenshotURLs: ["https://example.com/stale.png"],
            ratingCount: 99,
            averageRating: 1,
            platform: .mac
        )
        _ = try coordinator.persistRankingPage(
            RankingRefreshPageResult(
                request: RankingRefreshRequest(track: macTrack),
                page: SearchRankingPage(items: [olderWebItem], source: .appStoreWeb),
                searchedAt: webDate.addingTimeInterval(30),
                observedHour: nil,
                submissionCount: 1,
                winningCount: 1,
                confidence: "single_source"
            ),
            in: modelContext,
            scheduleMetadataEnrichment: false
        )

        storeApp = try #require(modelContext.fetch(FetchDescriptor<StoreApp>()).first { $0.appStoreID == 200 })
        metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first { $0.appStoreID == 200 })
        latestRating = try #require(modelContext.fetch(FetchDescriptor<LatestAppRating>()).first { $0.appStoreID == 200 })
        dailyRating = try #require(modelContext.fetch(FetchDescriptor<AppDailyRating>()).first { $0.appStoreID == 200 })
        #expect(storeApp.name == "Result")
        #expect(storeApp.supportedLanguageCodes == ["FR"])
        #expect(storeApp.supportedLanguageCodesSource == .iTunesSearch)
        #expect(storeApp.supportedLanguageCodesFetchedAt == fallbackDate)
        #expect(metadata.source == .iTunesSearch)
        #expect(metadata.lastFetchedAt == fallbackDate)
        #expect(latestRating.ratingCount == 43)
        #expect(latestRating.source == .iTunesSearch)
        #expect(latestRating.observedAt == fallbackDate)
        #expect(dailyRating.ratingCount == 43)
        #expect(dailyRating.source == .iTunesSearch)
        #expect(dailyRating.observedAt == fallbackDate)
    }

    @Test
    func rankingCatalogRejectsOlderMetadataEvidence() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let catalogService = AppCatalogService(appResolver: StubAppResolver())
        let newerDate = Date(timeIntervalSince1970: 1_800_000_000)
        let olderDate = newerDate.addingTimeInterval(-60)
        let newerItem = SearchRankingItem(
            position: 1,
            appStoreID: 300,
            bundleID: "com.example.new",
            name: "New Evidence",
            sellerName: "Example",
            screenshotURLs: ["https://example.com/new.png"],
            platform: .iphone
        )
        let olderItem = SearchRankingItem(
            position: 1,
            appStoreID: 300,
            bundleID: "com.example.old",
            name: "Old Evidence",
            sellerName: "Old Example",
            screenshotURLs: ["https://example.com/old.png"],
            platform: .ipad
        )

        _ = try catalogService.upsertStoreApp(
            from: newerItem,
            storefrontCode: "us",
            rankingSource: .appStoreWeb,
            fetchedAt: newerDate,
            requestedPlatform: .iphone,
            in: modelContext
        )
        _ = try catalogService.upsertStoreApp(
            from: olderItem,
            storefrontCode: "us",
            rankingSource: .iTunesFallback,
            fetchedAt: olderDate,
            requestedPlatform: .ipad,
            in: modelContext
        )
        try modelContext.save()

        let storeApp = try #require(modelContext.fetch(FetchDescriptor<StoreApp>()).first { $0.appStoreID == 300 })
        let metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first { $0.appStoreID == 300 })
        let screenshots = try modelContext.fetch(FetchDescriptor<AppStoreScreenshot>()).filter { $0.appStoreID == 300 }

        #expect(storeApp.name == "New Evidence")
        #expect(storeApp.defaultPlatform == .iphone)
        #expect(storeApp.lastMetadataRefreshAt == newerDate)
        #expect(metadata.name == "New Evidence")
        #expect(metadata.source == .appStoreWebSearch)
        #expect(metadata.defaultPlatform == .iphone)
        #expect(metadata.lastFetchedAt == newerDate)
        #expect(screenshots.map(\.urlString) == ["https://example.com/new.png"])
        #expect(screenshots.first?.source == .appStoreWebSearch)
        #expect(screenshots.first?.lastFetchedAt == newerDate)
    }

    @Test
    func shallowWebRankingEvidenceDoesNotSuppressDetailEnrichment() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let catalogService = AppCatalogService(appResolver: StubAppResolver())
        let detailDate = Date.now.addingTimeInterval(-60)
        let richFallbackItem = SearchRankingItem(
            position: 1,
            appStoreID: 350,
            bundleID: "com.example.rich",
            name: "Rich Result",
            subtitle: "Useful subtitle",
            sellerName: "Example",
            version: "1.0",
            descriptionText: "A complete retained description.",
            supportedLanguageCodes: ["EN"],
            screenshotURLs: ["https://example.com/rich-phone.png"],
            platform: .iphone
        )
        _ = try catalogService.upsertStoreApp(
            from: richFallbackItem,
            storefrontCode: "us",
            rankingSource: .iTunesFallback,
            fetchedAt: detailDate,
            requestedPlatform: .iphone,
            in: modelContext
        )
        let shallowWebItem = SearchRankingItem(
            position: 1,
            appStoreID: 350,
            bundleID: "com.example.rich",
            name: "Rich Result",
            sellerName: "Example",
            screenshotURLs: ["https://example.com/rich-phone.png"],
            platform: .ipad
        )
        _ = try catalogService.upsertStoreApp(
            from: shallowWebItem,
            storefrontCode: "us",
            rankingSource: .appStoreWeb,
            fetchedAt: .now,
            requestedPlatform: .ipad,
            in: modelContext
        )
        try modelContext.save()

        var metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first {
            $0.appStoreID == 350
        })
        #expect(metadata.source == .iTunesSearch)
        #expect(metadata.lastFetchedAt == detailDate)
        #expect(try catalogService.shouldEnrichStorefrontMetadata(
            appStoreID: 350,
            storefrontCode: "us",
            platform: .ipad,
            freshnessInterval: 5 * 24 * 60 * 60,
            in: modelContext
        ))

        _ = try catalogService.upsertStoreApp(
            from: AppStoreWebMetadata(
                appStoreID: 350,
                storefront: "us",
                name: "Rich Result",
                subtitle: "Useful subtitle",
                sellerName: "Example",
                averageRating: nil,
                ratingCount: nil,
                screenshotGroups: [
                    AppStoreWebScreenshotGroup(
                        platformRaw: "ipad",
                        displayTypeRaw: "tablet",
                        screenshots: [
                            AppStoreWebScreenshot(
                                urlString: "https://example.com/rich-ipad.png",
                                width: 2_048,
                                height: 2_732
                            )
                        ]
                    )
                ]
            ),
            storefrontCode: "us",
            in: modelContext
        )
        try modelContext.save()

        metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first {
            $0.appStoreID == 350
        })
        #expect(metadata.source == .appStoreWeb)
        #expect(!(try catalogService.shouldEnrichStorefrontMetadata(
            appStoreID: 350,
            storefrontCode: "us",
            platform: .ipad,
            freshnessInterval: 5 * 24 * 60 * 60,
            in: modelContext
        )))
    }

    @Test
    func pureWebDetailBoundsRetriesWhenOptionalFieldsAreUnavailable() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let catalogService = AppCatalogService(appResolver: StubAppResolver())

        _ = try catalogService.upsertStoreApp(
            from: AppStoreWebMetadata(
                appStoreID: 351,
                storefront: "us",
                name: "Web-only Result",
                subtitle: nil,
                sellerName: "Example",
                averageRating: nil,
                ratingCount: nil,
                screenshotGroups: []
            ),
            storefrontCode: "us",
            in: modelContext
        )
        try modelContext.save()

        let storeApp = try #require(modelContext.fetch(FetchDescriptor<StoreApp>()).first {
            $0.appStoreID == 351
        })
        let metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first {
            $0.appStoreID == 351
        })
        #expect(storeApp.supportedLanguageCodes.isEmpty)
        #expect(storeApp.supportedLanguageCodesFetchedAt == nil)
        #expect(metadata.subtitle == nil)
        #expect(metadata.screenshots.isEmpty)
        #expect(metadata.source == .appStoreWeb)
        #expect(!(try catalogService.shouldEnrichStorefrontMetadata(
            appStoreID: 351,
            storefrontCode: "us",
            platform: .ipad,
            freshnessInterval: 5 * 24 * 60 * 60,
            in: modelContext
        )))
    }

    @Test
    func sparseWebRankingDoesNotDowngradeRichSamePlatformScreenshots() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let catalogService = AppCatalogService(appResolver: StubAppResolver())

        _ = try catalogService.upsertStoreApp(
            from: AppStoreWebMetadata(
                appStoreID: 352,
                storefront: "us",
                name: "Detailed Result",
                subtitle: "Detailed subtitle",
                sellerName: "Example",
                averageRating: nil,
                ratingCount: nil,
                screenshotGroups: [
                    AppStoreWebScreenshotGroup(
                        platformRaw: "iphone",
                        displayTypeRaw: "phone_6_9",
                        screenshots: [
                            AppStoreWebScreenshot(
                                urlString: "https://example.com/detail-phone.png",
                                width: 1_320,
                                height: 2_868
                            )
                        ]
                    )
                ]
            ),
            storefrontCode: "us",
            in: modelContext
        )
        try modelContext.save()

        var metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first {
            $0.appStoreID == 352
        })
        let detailDate = metadata.lastFetchedAt
        let sparseDate = detailDate.addingTimeInterval(60)
        _ = try catalogService.upsertStoreApp(
            from: SearchRankingItem(
                position: 1,
                appStoreID: 352,
                bundleID: "com.example.detail",
                name: "Sparse Search Result",
                sellerName: "Example",
                screenshotURLs: ["https://example.com/sparse-phone.png"],
                platform: .iphone
            ),
            storefrontCode: "us",
            rankingSource: .appStoreWeb,
            fetchedAt: sparseDate,
            requestedPlatform: .iphone,
            in: modelContext
        )
        try modelContext.save()

        metadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first {
            $0.appStoreID == 352
        })
        let screenshot = try #require(modelContext.fetch(FetchDescriptor<AppStoreScreenshot>()).first {
            $0.appStoreID == 352 && $0.platformRaw == "iphone"
        })
        #expect(metadata.name == "Detailed Result")
        #expect(metadata.subtitle == "Detailed subtitle")
        #expect(metadata.source == .appStoreWeb)
        #expect(metadata.lastFetchedAt == detailDate)
        #expect(screenshot.urlString == "https://example.com/detail-phone.png")
        #expect(screenshot.displayTypeRaw == "phone_6_9")
        #expect(screenshot.width == 1_320)
        #expect(screenshot.height == 2_868)
        #expect(screenshot.source == .appStoreWeb)
        #expect(screenshot.lastFetchedAt <= sparseDate)
    }

    @Test
    func newerSparsePlatformScreenshotsRejectDelayedFallbackEvidence() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let catalogService = AppCatalogService(appResolver: StubAppResolver())

        _ = try catalogService.upsertStoreApp(
            from: AppStoreWebMetadata(
                appStoreID: 353,
                storefront: "us",
                name: "Detailed Result",
                subtitle: "Detailed subtitle",
                sellerName: "Example",
                averageRating: nil,
                ratingCount: nil,
                screenshotGroups: [
                    AppStoreWebScreenshotGroup(
                        platformRaw: "iphone",
                        displayTypeRaw: "phone_6_9",
                        screenshots: [
                            AppStoreWebScreenshot(
                                urlString: "https://example.com/detail-phone.png",
                                width: 1_320,
                                height: 2_868
                            )
                        ]
                    )
                ]
            ),
            storefrontCode: "us",
            in: modelContext
        )
        try modelContext.save()

        let detailMetadata = try #require(modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>()).first {
            $0.appStoreID == 353
        })
        let sparseDate = detailMetadata.lastFetchedAt.addingTimeInterval(120)
        let delayedFallbackDate = detailMetadata.lastFetchedAt.addingTimeInterval(60)
        _ = try catalogService.upsertStoreApp(
            from: SearchRankingItem(
                position: 1,
                appStoreID: 353,
                bundleID: "com.example.detail",
                name: "Sparse Search Result",
                sellerName: "Example",
                ipadScreenshotURLs: ["https://example.com/new-ipad.png"],
                platform: .ipad
            ),
            storefrontCode: "us",
            rankingSource: .appStoreWeb,
            fetchedAt: sparseDate,
            requestedPlatform: .ipad,
            in: modelContext
        )
        _ = try catalogService.upsertStoreApp(
            from: SearchRankingItem(
                position: 1,
                appStoreID: 353,
                bundleID: "com.example.detail",
                name: "Delayed Fallback Result",
                sellerName: "Example",
                ipadScreenshotURLs: ["https://example.com/old-ipad.png"],
                platform: .ipad
            ),
            storefrontCode: "us",
            rankingSource: .iTunesFallback,
            fetchedAt: delayedFallbackDate,
            requestedPlatform: .ipad,
            in: modelContext
        )
        try modelContext.save()

        let screenshots = try modelContext.fetch(FetchDescriptor<AppStoreScreenshot>()).filter {
            $0.appStoreID == 353
        }
        let ipadScreenshot = try #require(screenshots.first { $0.platformRaw == "ipad" })
        let iphoneScreenshot = try #require(screenshots.first { $0.platformRaw == "iphone" })
        #expect(ipadScreenshot.urlString == "https://example.com/new-ipad.png")
        #expect(ipadScreenshot.source == .appStoreWebSearch)
        #expect(ipadScreenshot.lastFetchedAt == sparseDate)
        #expect(iphoneScreenshot.urlString == "https://example.com/detail-phone.png")
        #expect(iphoneScreenshot.width == 1_320)
        #expect(!screenshots.contains { $0.urlString == "https://example.com/old-ipad.png" })
    }

    @Test
    func keywordSuggestionsUseTheNewestRankingEvidenceSource() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let trackedApp = TrackedApp(
            appStoreID: 400,
            bundleID: "com.example.target",
            name: "Target",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)

        func insertEvidence(
            keyword: String,
            source: RankingSource,
            observedAt: Date,
            position: Int
        ) throws {
            let query = try KeywordQuery.fetchOrInsert(
                term: keyword,
                storefront: "us",
                platform: .iphone,
                in: modelContext
            )
            let observation = KeywordRankingCrawl(
                keyword: keyword,
                storefront: "us",
                platform: .iphone,
                observedAt: observedAt,
                source: source,
                resultCount: 10,
                query: query
            )
            let item = KeywordAppRanking(
                position: position,
                appStoreID: trackedApp.appStoreID,
                bundleID: trackedApp.bundleID,
                name: trackedApp.name,
                sellerName: trackedApp.sellerName,
                observation: observation
            )
            observation.items.append(item)
            query.observations.append(observation)
            modelContext.insert(observation)
            modelContext.insert(item)
        }

        try insertEvidence(
            keyword: "calendar",
            source: .iTunesFallback,
            observedAt: now.addingTimeInterval(-86_400),
            position: 3
        )
        try insertEvidence(
            keyword: "planner",
            source: .iTunesFallback,
            observedAt: now.addingTimeInterval(-2 * 86_400),
            position: 2
        )
        try insertEvidence(
            keyword: "planner",
            source: .appStoreWeb,
            observedAt: now.addingTimeInterval(-86_400),
            position: 4
        )
        try modelContext.save()

        let suggestions = try KeywordSuggestionService(now: { now }).suggestions(
            for: trackedApp,
            in: modelContext
        )
        let byKeyword = Dictionary(uniqueKeysWithValues: suggestions.keywordSuggestions.map {
            ($0.keyword, $0)
        })

        #expect(byKeyword["calendar"]?.source == .iTunesFallback)
        #expect(byKeyword["planner"]?.source == .appStoreWeb)
        #expect(byKeyword["planner"]?.currentObservedRank == 4)
        #expect(byKeyword["planner"]?.bestObservedRank == 2)
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
        secondApp.storeApp.defaultStorefront = "gb"
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
        if let request = requestsByAppID[842842640],
           case .all(let codes) = request.storefrontSelection {
            #expect(codes == ["us"])
        } else {
            Issue.record("Expected the tracked app to use its keyword storefronts.")
        }
        if let request = requestsByAppID[361309726],
           case .all(let codes) = request.storefrontSelection {
            #expect(codes == ["gb"])
        } else {
            Issue.record("Expected the no-keyword app to use its default storefront.")
        }
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
            appStorefrontRatingService: AppStorefrontRatingService(httpClient: httpClient),
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

private struct DeduplicatedRefreshFixture {
    let firstApp: TrackedApp
    let secondApp: TrackedApp
    let thirdApp: TrackedApp
    let firstTrack: TrackedAppKeyword
    let secondTrack: TrackedAppKeyword
    let thirdTrack: TrackedAppKeyword

    var tracks: [TrackedAppKeyword] {
        [firstTrack, secondTrack, thirdTrack]
    }
}

@MainActor
private func makeDeduplicatedRefreshFixture(in modelContext: ModelContext) throws -> DeduplicatedRefreshFixture {
    let firstApp = TrackedApp(
        appStoreID: 101,
        bundleID: "example.first",
        name: "First App",
        sellerName: "Example",
        defaultPlatform: .iphone
    )
    let firstTrack = try makeTrackedAppKeyword(
        term: "Pages",
        storefront: "us",
        platform: .iphone,
        trackedApp: firstApp,
        in: modelContext
    )
    firstApp.keywordTracks.append(firstTrack)
    modelContext.insert(firstApp)
    modelContext.insert(firstTrack)

    let secondApp = TrackedApp(
        appStoreID: 202,
        bundleID: "example.second",
        name: "Second App",
        sellerName: "Example",
        defaultPlatform: .iphone
    )
    let secondTrack = try makeTrackedAppKeyword(
        term: "pages",
        storefront: "us",
        platform: .iphone,
        trackedApp: secondApp,
        in: modelContext
    )
    secondApp.keywordTracks.append(secondTrack)
    modelContext.insert(secondApp)
    modelContext.insert(secondTrack)

    let thirdApp = TrackedApp(
        appStoreID: 303,
        bundleID: "example.third",
        name: "Third App",
        sellerName: "Example",
        defaultPlatform: .iphone
    )
    let thirdTrack = try makeTrackedAppKeyword(
        term: "pages",
        storefront: "gb",
        platform: .iphone,
        trackedApp: thirdApp,
        in: modelContext
    )
    thirdApp.keywordTracks.append(thirdTrack)
    modelContext.insert(thirdApp)
    modelContext.insert(thirdTrack)
    try modelContext.save()

    return DeduplicatedRefreshFixture(
        firstApp: firstApp,
        secondApp: secondApp,
        thirdApp: thirdApp,
        firstTrack: firstTrack,
        secondTrack: secondTrack,
        thirdTrack: thirdTrack
    )
}

private func rankingItem(position: Int, appStoreID: Int64, platform: AppPlatform) -> SearchRankingItem {
    SearchRankingItem(
        position: position,
        appStoreID: appStoreID,
        bundleID: "example.\(appStoreID)",
        name: "App \(appStoreID)",
        sellerName: "Example",
        platform: platform
    )
}

private struct RankingRefreshProgressValue: Equatable, Sendable {
    let completed: Int
    let total: Int
    let failureCount: Int
}

private actor RankingRefreshProgressRecorder {
    private var recordedValues: [RankingRefreshProgressValue] = []

    func record(completed: Int, total: Int, failureCount: Int) {
        recordedValues.append(RankingRefreshProgressValue(
            completed: completed,
            total: total,
            failureCount: failureCount
        ))
    }

    func values() -> [RankingRefreshProgressValue] {
        recordedValues
    }
}

private actor QueryRankingProvider: SearchRankingProvider {
    enum Response: Sendable {
        case page(SearchRankingPage)
        case failure(OpenASOError)
    }

    private let responses: [String: Response]
    private var queryCallCounts: [String: Int] = [:]

    init(responses: [String: Response]) {
        self.responses = responses
    }

    static func key(term: String, storefront: String, platform: AppPlatform) -> String {
        [
            term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform.rawValue,
        ].joined(separator: "::")
    }

    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        let queryKey = Self.key(term: keyword, storefront: storefrontCode, platform: platform)
        queryCallCounts[queryKey, default: 0] += 1

        guard let response = responses[queryKey] else {
            throw OpenASOError.unexpectedResponse
        }
        switch response {
        case .page(let page):
            return page
        case .failure(let error):
            throw error
        }
    }

    func callCounts() -> [String: Int] {
        queryCallCounts
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
        TrackedKeywordRefreshStatus.self,
        TrackedKeywordDailyRanking.self,
        TrackedKeywordRankedResult.self,
        Storefront.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

private func makeTrackedAppKeyword(
    term: String,
    storefront: String = "us",
    platform: AppPlatform = .iphone,
    trackedApp: TrackedApp,
    in modelContext: ModelContext
) throws -> TrackedAppKeyword {
    let query = try KeywordQuery.fetchOrInsert(
        term: term,
        storefront: storefront,
        platform: platform,
        in: modelContext
    )
    return TrackedAppKeyword(
        term: term,
        storefront: storefront,
        platform: platform,
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
