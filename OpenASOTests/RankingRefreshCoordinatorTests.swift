import Foundation
import Observation
import SwiftData
import Synchronization
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

        let result = await coordinator.refresh(track: track, in: modelContext)

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
    func persistenceFailureAfterMutationRollsBackTheEntireRefresh() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        let trackedApp = TrackedApp(
            appStoreID: 700,
            bundleID: "example.tracked.700",
            name: "Tracked",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let track = try makeTrackedAppKeyword(
            term: "rollback test",
            trackedApp: trackedApp,
            in: modelContext
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()
        let baseline = try rankingPersistenceState(in: modelContext)

        let checkpoint = FailingRankingPersistenceCheckpoint(failingOnCall: 1)
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: StubRankingProvider(
                page: SearchRankingPage(items: [], source: .iTunesFallback)
            ),
            appCatalogService: AppCatalogService(appResolver: StubAppResolver()),
            persistenceMutationCheckpoint: checkpoint.call
        )
        let pageResult = RankingRefreshPageResult(
            request: RankingRefreshRequest(track: track),
            page: SearchRankingPage(
                items: [SearchRankingItem(
                    position: 1,
                    appStoreID: 701,
                    bundleID: "example.result.701",
                    name: "Result",
                    sellerName: "Example",
                    screenshotURLs: ["https://example.com/result-701.png"],
                    ratingCount: 42,
                    averageRating: 4.5,
                    platform: .iphone
                )],
                source: .iTunesFallback
            ),
            searchedAt: date(
                year: 2026,
                month: 7,
                day: 19,
                hour: 12,
                minute: 0,
                calendar: utcCalendar()
            ),
            observedHour: nil,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source"
        )

        #expect(throws: OpenASOError.unexpectedResponse) {
            _ = try coordinator.persistRankingPage(pageResult, in: modelContext)
        }

        #expect(checkpoint.callCount() == 1)
        #expect(!modelContext.hasChanges)
        #expect(try rankingPersistenceState(in: modelContext) == baseline)
    }

    @Test
    func pendingUnrelatedEditArrivingDuringFetchIsNeitherCommittedNorRolledBack() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        let trackedApp = TrackedApp(
            appStoreID: 710,
            bundleID: "example.tracked.710",
            name: "Tracked",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let track = try makeTrackedAppKeyword(
            term: "pending edit test",
            trackedApp: trackedApp,
            in: modelContext
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        let unrelatedStorefront = Storefront(
            code: "zz",
            name: "Persisted storefront name",
            flagEmoji: "ZZ",
            languageCode: "en"
        )
        modelContext.insert(unrelatedStorefront)
        try modelContext.save()
        let baseline = try rankingPersistenceState(in: modelContext)

        let provider = GatedRankingProvider()
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let refreshTask = Task { @MainActor in
            await coordinator.refresh(tracks: [track], in: modelContext)
        }
        await provider.waitUntilStarted()

        unrelatedStorefront.name = "Pending storefront name"
        #expect(modelContext.hasChanges)
        await provider.succeed(SearchRankingPage(
            items: [rankingItem(position: 1, appStoreID: trackedApp.appStoreID, platform: .iphone)],
            source: .iTunesFallback
        ))
        let outcomes = await refreshTask.value

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.error != nil)
        #expect(outcomes.first?.snapshotID == nil)
        #expect(modelContext.hasChanges)
        #expect(unrelatedStorefront.name == "Pending storefront name")

        let verificationContext = ModelContext(container)
        verificationContext.autosaveEnabled = false
        let durableStorefront = try #require(
            verificationContext.fetch(FetchDescriptor<Storefront>())
                .first(where: { $0.code == "zz" })
        )
        #expect(durableStorefront.name == "Persisted storefront name")
        #expect(try rankingPersistenceState(in: verificationContext) == baseline)
        #expect(try verificationContext.fetchCount(FetchDescriptor<TrackedKeywordRefreshStatus>()) == 0)
    }

    @Test
    func pendingEditFromProgressSkipsFinalStatsWithoutCommitOrRollback() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        let trackedApp = TrackedApp(
            appStoreID: 720,
            bundleID: "example.tracked.720",
            name: "Tracked",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let track = try makeTrackedAppKeyword(
            term: "stats reentrancy test",
            trackedApp: trackedApp,
            in: modelContext
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        let unrelatedStorefront = Storefront(
            code: "yy",
            name: "Persisted stats storefront name",
            flagEmoji: "YY",
            languageCode: "en"
        )
        modelContext.insert(unrelatedStorefront)
        try modelContext.save()

        let provider = StubRankingProvider(page: SearchRankingPage(
            items: [rankingItem(position: 1, appStoreID: trackedApp.appStoreID, platform: .iphone)],
            source: .iTunesFallback
        ))
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        )
        let editInjector = RankingPendingEditInjector(
            storefront: unrelatedStorefront,
            pendingName: "Pending stats storefront name"
        )

        let outcomes = await coordinator.refresh(
            tracks: [track],
            in: modelContext,
            progress: { completed, _, _ in
                await editInjector.injectIfPagePersistenceCompleted(completed)
            }
        )

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.error == nil)
        #expect(outcomes.first?.rank == 1)
        #expect(editInjector.injectionCount == 1)
        #expect(modelContext.hasChanges)
        #expect(unrelatedStorefront.name == "Pending stats storefront name")

        let verificationContext = ModelContext(container)
        verificationContext.autosaveEnabled = false
        let durableStorefront = try #require(
            verificationContext.fetch(FetchDescriptor<Storefront>())
                .first(where: { $0.code == "yy" })
        )
        #expect(durableStorefront.name == "Persisted stats storefront name")
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordRankingCrawl>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<TrackedKeywordDailyRanking>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<AppKeywordStats>()) == 0)
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

        _ = await coordinator.refresh(track: track, in: modelContext)

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

        let result = await coordinator.refresh(track: track, in: modelContext)

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
@Suite(.timeLimit(.minutes(1)))
struct AppDetailRefreshServiceQueueTests {
    @Test
    func refreshSerializesConcurrentAppRefreshRequests() async throws {
        let progressStore = AppRefreshProgressStore()
        let recorder = RefreshMetricsRecorder(clock: .appDetailTestConstant)
        let httpClient = ControlledRatingsHTTPClient()
        let fixture = try makeAppDetailRefreshQueueFixture(
            appStoreIDs: [1, 2],
            httpClient: httpClient,
            progressStore: progressStore,
            recorder: recorder
        )

        let firstTask = Task {
            await fixture.service.refresh(Self.request(appStoreID: 1))
        }
        defer { firstTask.cancel() }
        try await httpClient.waitForRequestCount(1)
        #expect(progressStore.pendingAppRefreshCount == 0)

        let secondTask = Task {
            await fixture.service.refresh(Self.request(appStoreID: 2))
        }
        defer { secondTask.cancel() }
        try await waitForPendingAppRefreshCount(1, in: progressStore)
        #expect(await httpClient.requestedAppStoreIDs() == [1])
        #expect(progressStore.pendingAppRefreshCount == 1)

        #expect(await httpClient.complete(appStoreID: 1))
        let firstResult = await firstTask.value
        #expect(firstResult.firstError == nil)
        #expect(firstResult.ratingOutcomes.map { $0.storefront } == ["us"])

        try await httpClient.waitForRequestCount(2)
        #expect(await httpClient.requestedAppStoreIDs() == [1, 2])
        #expect(progressStore.pendingAppRefreshCount == 0)

        #expect(await httpClient.complete(appStoreID: 2))
        let secondResult = await secondTask.value
        #expect(secondResult.firstError == nil)
        #expect(secondResult.ratingOutcomes.map { $0.storefront } == ["us"])
    }

    @Test
    func queuedMiddleCancellationRemovesOnlyThatWaiterAndPreservesFIFO() async throws {
        let progressStore = AppRefreshProgressStore()
        let recorder = RefreshMetricsRecorder(clock: .appDetailTestConstant)
        let httpClient = ControlledRatingsHTTPClient()
        let fixture = try makeAppDetailRefreshQueueFixture(
            appStoreIDs: [1, 2, 3],
            httpClient: httpClient,
            progressStore: progressStore,
            recorder: recorder
        )

        let firstTask = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 1))
        }
        defer { firstTask.cancel() }
        try await httpClient.waitForRequestCount(1)

        let middleTask = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 2))
        }
        defer { middleTask.cancel() }
        try await waitForPendingAppRefreshCount(1, in: progressStore)

        let lastTask = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 3))
        }
        defer { lastTask.cancel() }
        try await waitForPendingAppRefreshCount(2, in: progressStore)

        middleTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await middleTask.value
        }

        #expect(progressStore.pendingAppRefreshCount == 1)
        #expect(await httpClient.requestedAppStoreIDs() == [1])
        #expect(await httpClient.cancellationCount() == 0)
        #expect(await recorder.activeRunCount() == 1)
        #expect(await recorder.completedSummaries().isEmpty)

        #expect(await httpClient.complete(appStoreID: 1))
        let firstResult = try await firstTask.value
        #expect(firstResult.firstError == nil)

        try await httpClient.waitForRequestCount(2)
        #expect(progressStore.pendingAppRefreshCount == 0)
        #expect(await httpClient.requestedAppStoreIDs() == [1, 3])

        #expect(await httpClient.complete(appStoreID: 3))
        let lastResult = try await lastTask.value
        #expect(lastResult.firstError == nil)

        let summaries = await recorder.completedSummaries()
        #expect(summaries.map(\.result) == [.success, .success])
        #expect(await recorder.activeRunCount() == 0)
    }

    @Test
    func activeCancellationCancelsTransportAndCleansProgressAndObservation() async throws {
        let progressStore = AppRefreshProgressStore()
        let recorder = RefreshMetricsRecorder(clock: .appDetailTestConstant)
        let httpClient = ControlledRatingsHTTPClient()
        let fixture = try makeAppDetailRefreshQueueFixture(
            appStoreIDs: [1],
            httpClient: httpClient,
            progressStore: progressStore,
            recorder: recorder
        )

        let task = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 1))
        }
        defer { task.cancel() }
        try await httpClient.waitForRequestCount(1)
        #expect(progressStore.activeRefresh?.appStoreID == 1)

        task.cancel()
        try await httpClient.waitForCancellationCount(1)
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(progressStore.pendingAppRefreshCount == 0)
        #expect(progressStore.activeRefresh == nil)
        #expect(await recorder.activeRunCount() == 0)

        let completedSummaries = await recorder.completedSummaries()
        #expect(completedSummaries.count == 1)
        let summary = try #require(completedSummaries.first)
        let provider = try #require(summary.providers[.iTunesStore])
        #expect(summary.result == .cancelled)
        #expect(summary.observedCancellation)
        #expect(provider.resultCounts[.cancelled] == 1)
        #expect(await httpClient.cancellationCount() == 1)
        #expect((summary.stages[.ratings]?.failureCount ?? 0) == 0)

        let persistedRatingCount = try await fixture.backgroundModelStore.read { modelContext in
            let latestCount = try modelContext.fetch(FetchDescriptor<LatestAppRating>()).count
            let dailyCount = try modelContext.fetch(FetchDescriptor<AppDailyRating>()).count
            return latestCount + dailyCount
        }
        #expect(persistedRatingCount == 0)
    }

    @Test
    func promotedCancellationFinishesCleanupBeforeNextPromotionWithoutWedging() async throws {
        let progressStore = AppRefreshProgressStore()
        let recorder = RefreshMetricsRecorder(clock: .appDetailTestConstant)
        let snapshotRecorder = AppDetailRefreshStartSnapshotRecorder()
        let httpClient = ControlledRatingsHTTPClient { appStoreID in
            await snapshotRecorder.recordStart(
                appStoreID: appStoreID,
                progressStore: progressStore,
                recorder: recorder
            )
        }
        let fixture = try makeAppDetailRefreshQueueFixture(
            appStoreIDs: [1, 2, 3, 4],
            httpClient: httpClient,
            progressStore: progressStore,
            recorder: recorder
        )

        let firstTask = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 1))
        }
        defer { firstTask.cancel() }
        try await httpClient.waitForRequestCount(1)

        let promotedTask = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 2))
        }
        defer { promotedTask.cancel() }
        try await waitForPendingAppRefreshCount(1, in: progressStore)

        let thirdTask = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 3))
        }
        defer { thirdTask.cancel() }
        try await waitForPendingAppRefreshCount(2, in: progressStore)

        let fourthTask = Task {
            try await fixture.service.refreshCancellable(Self.request(appStoreID: 4))
        }
        defer { fourthTask.cancel() }
        try await waitForPendingAppRefreshCount(3, in: progressStore)

        firstTask.cancel()
        try await httpClient.waitForCancellationCount(1)
        try await httpClient.waitForRequestCount(2)
        await #expect(throws: CancellationError.self) {
            _ = try await firstTask.value
        }

        let promotedSnapshot = try #require(await snapshotRecorder.snapshot(for: 2))
        #expect(promotedSnapshot.pendingAppRefreshCount == 2)
        #expect(promotedSnapshot.activeAppStoreID == 2)
        #expect(promotedSnapshot.activeRunCount == 1)
        #expect(promotedSnapshot.completedResults == [.cancelled])

        promotedTask.cancel()
        try await httpClient.waitForCancellationCount(2)
        try await httpClient.waitForRequestCount(3)

        let thirdSnapshot = try #require(await snapshotRecorder.snapshot(for: 3))
        let thirdRefreshID = try #require(thirdSnapshot.activeRefreshID)
        #expect(thirdSnapshot.pendingAppRefreshCount == 1)
        #expect(thirdSnapshot.activeAppStoreID == 3)
        #expect(thirdSnapshot.activeRunCount == 1)
        #expect(thirdSnapshot.completedResults == [.cancelled, .cancelled])

        await #expect(throws: CancellationError.self) {
            _ = try await promotedTask.value
        }
        #expect(progressStore.activeRefresh?.id == thirdRefreshID)
        #expect(progressStore.activeRefresh?.appStoreID == 3)

        #expect(await httpClient.complete(appStoreID: 3))
        let thirdResult = try await thirdTask.value
        #expect(thirdResult.firstError == nil)

        try await httpClient.waitForRequestCount(4)
        let fourthSnapshot = try #require(await snapshotRecorder.snapshot(for: 4))
        #expect(fourthSnapshot.pendingAppRefreshCount == 0)
        #expect(fourthSnapshot.activeAppStoreID == 4)
        #expect(fourthSnapshot.activeRunCount == 1)
        #expect(fourthSnapshot.completedResults == [.cancelled, .cancelled, .success])

        #expect(await httpClient.complete(appStoreID: 4))
        let fourthResult = try await fourthTask.value
        #expect(fourthResult.firstError == nil)

        #expect(await httpClient.requestedAppStoreIDs() == [1, 2, 3, 4])
        #expect(await httpClient.cancellationCount() == 2)
        #expect(progressStore.pendingAppRefreshCount == 0)
        #expect(await recorder.activeRunCount() == 0)
        #expect(await recorder.completedSummaries().map(\.result) == [
            .cancelled,
            .cancelled,
            .success,
            .success,
        ])
    }

    @Test
    func ordinaryProviderFailureReturnsResultAndReleasesPermit() async throws {
        let progressStore = AppRefreshProgressStore()
        let recorder = RefreshMetricsRecorder(clock: .appDetailTestConstant)
        let httpClient = ScriptedRatingsHTTPClient(steps: [
            .failure(.notConnectedToInternet),
            .failure(.notConnectedToInternet),
            .success,
        ])
        let fixture = try makeAppDetailRefreshQueueFixture(
            appStoreIDs: [1, 2],
            httpClient: httpClient,
            progressStore: progressStore,
            recorder: recorder
        )

        let failedResult = try await fixture.service.refreshCancellable(Self.request(appStoreID: 1))
        #expect(failedResult.firstError != nil)
        #expect(!failedResult.wasCancelled)
        #expect(failedResult.ratingOutcomes.count == 1)
        #expect(failedResult.ratingOutcomes.first?.error != nil)

        let successfulResult = try await fixture.service.refreshCancellable(Self.request(appStoreID: 2))
        #expect(successfulResult.firstError == nil)
        #expect(!successfulResult.wasCancelled)
        #expect(successfulResult.ratingOutcomes.map(\.storefront) == ["us"])

        #expect(await httpClient.requestCount() == 3)
        #expect(progressStore.pendingAppRefreshCount == 0)
        #expect(await recorder.activeRunCount() == 0)

        let summaries = await recorder.completedSummaries()
        #expect(summaries.map(\.result) == [.failure, .success])
        #expect(summaries.allSatisfy { !$0.observedCancellation })
    }

    private static func request(appStoreID: Int64) -> AppDetailRefreshRequest {
        AppDetailRefreshRequest(
            app: AppDetailRefreshAppSnapshot(
                appStoreID: appStoreID,
                bundleID: nil,
                name: "App \(appStoreID)",
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

    @Test
    func appDetailFanOutSchedulesMetadataOnlyForAppliedSharedObservation() async throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let fixture = try makeDeduplicatedRefreshFixture(in: modelContext)
        let searchedAt = isoDate("2026-07-18T13:00:00Z")
        let provider = QueryRankingProvider(responses: [
            QueryRankingProvider.key(
                term: fixture.firstTrack.term,
                storefront: fixture.firstTrack.storefront,
                platform: fixture.firstTrack.platform
            ): .page(SearchRankingPage(
                items: [
                    rankingItem(position: 1, appStoreID: fixture.firstApp.appStoreID, platform: .iphone),
                    rankingItem(position: 2, appStoreID: fixture.secondApp.appStoreID, platform: .iphone),
                ],
                source: .iTunesFallback
            )),
        ])
        let metadataRecorder = RankingMetadataEnrichmentRecorder()
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver()),
            now: { searchedAt },
            metadataEnrichmentScheduler: metadataRecorder.record
        )
        let httpClient = MockHTTPClient { request in
            throw OpenASOError.providerUnavailable(
                "Unexpected request to \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        let defaults = makeDefaults()
        let keychain = InMemoryKeychainService()
        let service = AppDetailRefreshService(
            backgroundModelStore: BackgroundModelStore(modelContainer: container),
            refreshCoordinator: coordinator,
            keywordMetricsService: KeywordMetricsService(
                httpClient: httpClient,
                credentialStore: AppleAdsCredentialStore(
                    defaults: defaults,
                    keychain: keychain,
                    loadsEnvironmentCredentials: false
                ),
                settingsStore: AppSettingsStore(defaults: defaults),
                webSessionStore: AppleAdsWebSessionStore(
                    defaults: defaults,
                    keychain: keychain
                )
            ),
            appStorefrontRatingService: AppStorefrontRatingService(httpClient: httpClient),
            appStorefrontReviewService: AppStorefrontReviewService(httpClient: httpClient),
            appStoreConnectReviewService: AppStoreConnectReviewService(
                httpClient: httpClient,
                credentialStore: AppStoreConnectCredentialStore(
                    defaults: defaults,
                    keychain: keychain
                )
            )
        )

        let result = await service.refresh(AppDetailRefreshRequest(
            app: AppDetailRefreshAppSnapshot(
                appStoreID: fixture.firstApp.appStoreID,
                bundleID: fixture.firstApp.bundleID,
                name: fixture.firstApp.name,
                subtitle: fixture.firstApp.subtitle,
                sellerName: fixture.firstApp.sellerName,
                defaultPlatform: fixture.firstApp.defaultPlatform
            ),
            workspace: .keywords,
            storefrontSelection: .storefront(code: "us"),
            trackIdentityKeys: [fixture.firstTrack.identityKey, fixture.secondTrack.identityKey],
            trigger: "manual",
            refreshKeywords: true,
            refreshMetrics: false,
            refreshRatings: false,
            refreshReviews: false,
            recordsRatingsReviewsRefresh: false,
            popularityContextAppStoreID: nil,
            appleAdsWebSession: nil,
            appStoreConnectCredentials: AppStoreConnectCredentials(
                issuerID: "",
                keyID: "",
                privateKey: ""
            )
        ))

        #expect(result.keywordOutcomes.count == 2)
        #expect(result.keywordOutcomes.allSatisfy { $0.error == nil })
        #expect(result.firstError == nil)
        #expect(await provider.callCounts() == ["pages::us::iphone": 1])
        #expect(metadataRecorder.recordedBatches() == [[
            RankingMetadataEnrichmentRequest(
                appStoreID: fixture.firstApp.appStoreID,
                storefront: "us",
                platform: .iphone
            ),
            RankingMetadataEnrichmentRequest(
                appStoreID: fixture.secondApp.appStoreID,
                storefront: "us",
                platform: .iphone
            ),
        ]])

        let state = try await BackgroundModelStore(modelContainer: container).read { modelContext in
            try rankingPersistenceState(in: modelContext)
        }
        #expect(state.crawlCount == 1)
        #expect(state.snapshotCount == 2)
    }

    @Test
    func rankingBatchFailureRollsBackEarlierPagesBeforeRecordingFailures() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 800,
            bundleID: "example.tracked.800",
            name: "Tracked",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let firstTrack = try makeTrackedAppKeyword(
            term: "first rollback query",
            trackedApp: trackedApp,
            in: modelContext
        )
        let secondTrack = try makeTrackedAppKeyword(
            term: "second rollback query",
            trackedApp: trackedApp,
            in: modelContext
        )
        trackedApp.keywordTracks.append(contentsOf: [firstTrack, secondTrack])
        modelContext.insert(trackedApp)
        modelContext.insert(firstTrack)
        modelContext.insert(secondTrack)
        try modelContext.save()

        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let baseline = try await backgroundModelStore.read { modelContext in
            try rankingPersistenceState(in: modelContext)
        }
        let provider = QueryRankingProvider(responses: [
            QueryRankingProvider.key(
                term: firstTrack.term,
                storefront: firstTrack.storefront,
                platform: firstTrack.platform
            ): .page(SearchRankingPage(
                items: [SearchRankingItem(
                    position: 1,
                    appStoreID: 801,
                    bundleID: "example.result.801",
                    name: "First result",
                    sellerName: "Example",
                    screenshotURLs: ["https://example.com/result-801.png"],
                    ratingCount: 81,
                    averageRating: 4.1,
                    platform: .iphone
                )],
                source: .iTunesFallback
            )),
            QueryRankingProvider.key(
                term: secondTrack.term,
                storefront: secondTrack.storefront,
                platform: secondTrack.platform
            ): .page(SearchRankingPage(
                items: [SearchRankingItem(
                    position: 1,
                    appStoreID: 802,
                    bundleID: "example.result.802",
                    name: "Second result",
                    sellerName: "Example",
                    screenshotURLs: ["https://example.com/result-802.png"],
                    ratingCount: 82,
                    averageRating: 4.2,
                    platform: .iphone
                )],
                source: .iTunesFallback
            )),
        ])
        let checkpoint = FailingRankingPersistenceCheckpoint(failingOnCall: 2)
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: StubAppResolver()),
            persistenceMutationCheckpoint: checkpoint.call
        )
        let httpClient = MockHTTPClient { request in
            throw OpenASOError.providerUnavailable(
                "Unexpected request to \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        let defaults = makeDefaults()
        let keychain = InMemoryKeychainService()
        let service = AppDetailRefreshService(
            backgroundModelStore: backgroundModelStore,
            refreshCoordinator: coordinator,
            keywordMetricsService: KeywordMetricsService(
                httpClient: httpClient,
                credentialStore: AppleAdsCredentialStore(
                    defaults: defaults,
                    keychain: keychain,
                    loadsEnvironmentCredentials: false
                ),
                settingsStore: AppSettingsStore(defaults: defaults),
                webSessionStore: AppleAdsWebSessionStore(
                    defaults: defaults,
                    keychain: keychain
                )
            ),
            appStorefrontRatingService: AppStorefrontRatingService(httpClient: httpClient),
            appStorefrontReviewService: AppStorefrontReviewService(httpClient: httpClient),
            appStoreConnectReviewService: AppStoreConnectReviewService(
                httpClient: httpClient,
                credentialStore: AppStoreConnectCredentialStore(
                    defaults: defaults,
                    keychain: keychain
                )
            )
        )
        let result = await service.refresh(AppDetailRefreshRequest(
            app: AppDetailRefreshAppSnapshot(
                appStoreID: trackedApp.appStoreID,
                bundleID: trackedApp.bundleID,
                name: trackedApp.name,
                subtitle: trackedApp.subtitle,
                sellerName: trackedApp.sellerName,
                defaultPlatform: trackedApp.defaultPlatform
            ),
            workspace: .keywords,
            storefrontSelection: .storefront(code: "us"),
            trackIdentityKeys: [firstTrack.identityKey, secondTrack.identityKey],
            trigger: "manual",
            refreshKeywords: true,
            refreshMetrics: false,
            refreshRatings: false,
            refreshReviews: false,
            recordsRatingsReviewsRefresh: false,
            popularityContextAppStoreID: nil,
            appleAdsWebSession: nil,
            appStoreConnectCredentials: AppStoreConnectCredentials(
                issuerID: "",
                keyID: "",
                privateKey: ""
            )
        ))

        #expect(checkpoint.callCount() == 2)
        #expect(result.keywordOutcomes.count == 2)
        #expect(result.keywordOutcomes.allSatisfy { $0.error != nil })
        #expect(result.firstError != nil)
        let state = try await backgroundModelStore.read { modelContext in
            try rankingPersistenceState(in: modelContext)
        }
        #expect(state.crawlCount == baseline.crawlCount)
        #expect(state.observationItemCount == baseline.observationItemCount)
        #expect(state.snapshotCount == baseline.snapshotCount)
        #expect(state.rankedResultCount == baseline.rankedResultCount)
        #expect(state.storeAppIDs == baseline.storeAppIDs)
        #expect(state.storefrontMetadataCount == baseline.storefrontMetadataCount)
        #expect(state.screenshotCount == baseline.screenshotCount)
        #expect(state.latestRatingCount == baseline.latestRatingCount)
        #expect(state.dailyRatingCount == baseline.dailyRatingCount)
        #expect(state.statsCount == baseline.statsCount)
        #expect(state.trackStates == baseline.trackStates)
        #expect(state.statusCount == 2)
    }

}

@MainActor
private struct AppDetailRefreshQueueFixture {
    let service: AppDetailRefreshService
    let backgroundModelStore: BackgroundModelStore
}

@MainActor
private func makeAppDetailRefreshQueueFixture(
    appStoreIDs: [Int64],
    httpClient: any HTTPClient,
    progressStore: AppRefreshProgressStore,
    recorder: RefreshMetricsRecorder
) throws -> AppDetailRefreshQueueFixture {
    let container = try makeInMemoryContainer()
    let modelContext = ModelContext(container)
    for appStoreID in appStoreIDs {
        modelContext.insert(StoreApp(
            appStoreID: appStoreID,
            bundleID: nil,
            name: "App \(appStoreID)",
            sellerName: nil,
            iconURLString: nil,
            defaultPlatform: .iphone
        ))
    }
    try modelContext.save()

    let backgroundModelStore = BackgroundModelStore(modelContainer: container)
    let observedHTTPClient = ProviderHTTPClientPipeline.make(
        transport: httpClient,
        mode: .disabled,
        refreshMetricsRecorder: recorder,
        refreshObservationClock: .appDetailTestConstant
    )
    let defaults = makeDefaults()
    let keychain = InMemoryKeychainService()
    let service = AppDetailRefreshService(
        backgroundModelStore: backgroundModelStore,
        refreshCoordinator: RankingRefreshCoordinator(
            rankingProvider: StubRankingProvider(page: SearchRankingPage(items: [], source: .iTunesFallback)),
            appCatalogService: AppCatalogService(appResolver: StubAppResolver())
        ),
        keywordMetricsService: KeywordMetricsService(
            httpClient: observedHTTPClient,
            credentialStore: AppleAdsCredentialStore(
                defaults: defaults,
                keychain: keychain,
                loadsEnvironmentCredentials: false
            ),
            settingsStore: AppSettingsStore(defaults: defaults),
            webSessionStore: AppleAdsWebSessionStore(defaults: defaults, keychain: keychain)
        ),
        appStorefrontRatingService: AppStorefrontRatingService(httpClient: observedHTTPClient),
        appStorefrontReviewService: AppStorefrontReviewService(httpClient: observedHTTPClient),
        appStoreConnectReviewService: AppStoreConnectReviewService(
            httpClient: observedHTTPClient,
            credentialStore: AppStoreConnectCredentialStore(defaults: defaults, keychain: keychain)
        ),
        progressStore: progressStore,
        refreshMetricsRecorder: recorder
    )
    return AppDetailRefreshQueueFixture(
        service: service,
        backgroundModelStore: backgroundModelStore
    )
}

private extension RefreshObservationClock {
    static let appDetailTestConstant = RefreshObservationClock(nowNanoseconds: { 1_000 })
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

private struct RankingPersistenceTrackState: Equatable, Sendable {
    let identityKey: String
    let rankingAppCount: Int?
    let lastRefreshAt: Date?
    let snapshotCount: Int
}

private struct RankingPersistenceState: Equatable, Sendable {
    let crawlCount: Int
    let observationItemCount: Int
    let snapshotCount: Int
    let rankedResultCount: Int
    let storeAppIDs: [Int64]
    let storefrontMetadataCount: Int
    let screenshotCount: Int
    let latestRatingCount: Int
    let dailyRatingCount: Int
    let statsCount: Int
    let statusCount: Int
    let trackStates: [RankingPersistenceTrackState]
}

private func rankingPersistenceState(in modelContext: ModelContext) throws -> RankingPersistenceState {
    let tracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
        .map {
            RankingPersistenceTrackState(
                identityKey: $0.identityKey,
                rankingAppCount: $0.rankingAppCount,
                lastRefreshAt: $0.lastRefreshAt,
                snapshotCount: $0.snapshots.count
            )
        }
        .sorted { $0.identityKey < $1.identityKey }
    return RankingPersistenceState(
        crawlCount: try modelContext.fetchCount(FetchDescriptor<KeywordRankingCrawl>()),
        observationItemCount: try modelContext.fetchCount(FetchDescriptor<KeywordAppRanking>()),
        snapshotCount: try modelContext.fetchCount(FetchDescriptor<TrackedKeywordDailyRanking>()),
        rankedResultCount: try modelContext.fetchCount(FetchDescriptor<TrackedKeywordRankedResult>()),
        storeAppIDs: try modelContext.fetch(FetchDescriptor<StoreApp>()).map(\.appStoreID).sorted(),
        storefrontMetadataCount: try modelContext.fetchCount(FetchDescriptor<AppStorefrontMetadata>()),
        screenshotCount: try modelContext.fetchCount(FetchDescriptor<AppStoreScreenshot>()),
        latestRatingCount: try modelContext.fetchCount(FetchDescriptor<LatestAppRating>()),
        dailyRatingCount: try modelContext.fetchCount(FetchDescriptor<AppDailyRating>()),
        statsCount: try modelContext.fetchCount(FetchDescriptor<AppKeywordStats>()),
        statusCount: try modelContext.fetchCount(FetchDescriptor<TrackedKeywordRefreshStatus>()),
        trackStates: tracks
    )
}

private final class FailingRankingPersistenceCheckpoint: Sendable {
    private struct State: Sendable {
        var callCount = 0
    }

    private let failingCall: Int
    private let state = Mutex(State())

    init(failingOnCall: Int) {
        self.failingCall = failingOnCall
    }

    func call() throws {
        let shouldFail = state.withLock { state in
            state.callCount += 1
            return state.callCount == failingCall
        }
        if shouldFail {
            throw OpenASOError.unexpectedResponse
        }
    }

    func callCount() -> Int {
        state.withLock { $0.callCount }
    }
}

private final class RankingMetadataEnrichmentRecorder: Sendable {
    private let batches = Mutex<[[RankingMetadataEnrichmentRequest]]>([])

    func record(_ requests: [RankingMetadataEnrichmentRequest]) {
        batches.withLock { batches in
            batches.append(requests)
        }
    }

    func recordedBatches() -> [[RankingMetadataEnrichmentRequest]] {
        batches.withLock { batches in
            batches
        }
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

private actor GatedRankingProvider: SearchRankingProvider {
    private var continuation: CheckedContinuation<SearchRankingPage, Never>?
    private var pendingPage: SearchRankingPage?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if let pendingPage {
            self.pendingPage = nil
            return pendingPage
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(_ page: SearchRankingPage) {
        guard let continuation else {
            pendingPage = page
            return
        }
        self.continuation = nil
        continuation.resume(returning: page)
    }
}

@MainActor
private final class RankingPendingEditInjector {
    private let storefront: Storefront
    private let pendingName: String
    private(set) var injectionCount = 0

    init(storefront: Storefront, pendingName: String) {
        self.storefront = storefront
        self.pendingName = pendingName
    }

    func injectIfPagePersistenceCompleted(_ completed: Int) {
        guard completed == 1, injectionCount == 0 else { return }
        storefront.name = pendingName
        injectionCount += 1
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

private final class AppDetailOneShotSignal: Sendable {
    private enum Resolution: Sendable {
        case signalled
        case cancelled
    }

    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var resolution: Resolution?
    }

    private let state = Mutex(State())

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolution = state.withLock { state -> Resolution? in
                    if let resolution = state.resolution {
                        return resolution
                    }
                    precondition(state.continuation == nil)
                    state.continuation = continuation
                    return nil
                }
                if let resolution {
                    Self.resume(continuation, with: resolution)
                }
            }
        } onCancel: {
            self.resolve(.cancelled)
        }
    }

    func signal() {
        resolve(.signalled)
    }

    private func resolve(_ resolution: Resolution) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard case nil = state.resolution else { return nil }
            state.resolution = resolution
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        if let continuation {
            Self.resume(continuation, with: resolution)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<Void, any Error>,
        with resolution: Resolution
    ) {
        switch resolution {
        case .signalled:
            continuation.resume()
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
private func waitForPendingAppRefreshCount(
    _ expectedCount: Int,
    in progressStore: AppRefreshProgressStore
) async throws {
    precondition(expectedCount >= 0)
    while progressStore.pendingAppRefreshCount != expectedCount {
        try Task.checkCancellation()
        let signal = AppDetailOneShotSignal()
        _ = withObservationTracking {
            progressStore.pendingAppRefreshCount
        } onChange: {
            signal.signal()
        }
        if progressStore.pendingAppRefreshCount == expectedCount {
            signal.signal()
        }
        try await signal.wait()
    }
}

private struct AppDetailRefreshStartSnapshot: Sendable {
    let pendingAppRefreshCount: Int
    let activeRefreshID: UUID?
    let activeAppStoreID: Int64?
    let activeRunCount: Int
    let completedResults: [RefreshRunResult]
}

private actor AppDetailRefreshStartSnapshotRecorder {
    private var snapshotsByAppStoreID: [Int64: AppDetailRefreshStartSnapshot] = [:]

    func recordStart(
        appStoreID: Int64,
        progressStore: AppRefreshProgressStore,
        recorder: RefreshMetricsRecorder
    ) async {
        let progressSnapshot = await MainActor.run {
            (
                pendingCount: progressStore.pendingAppRefreshCount,
                activeRefreshID: progressStore.activeRefresh?.id,
                activeAppStoreID: progressStore.activeRefresh?.appStoreID
            )
        }
        let activeRunCount = await recorder.activeRunCount()
        let completedResults = await recorder.completedSummaries().map(\.result)
        precondition(snapshotsByAppStoreID[appStoreID] == nil)
        snapshotsByAppStoreID[appStoreID] = AppDetailRefreshStartSnapshot(
            pendingAppRefreshCount: progressSnapshot.pendingCount,
            activeRefreshID: progressSnapshot.activeRefreshID,
            activeAppStoreID: progressSnapshot.activeAppStoreID,
            activeRunCount: activeRunCount,
            completedResults: completedResults
        )
    }

    func snapshot(for appStoreID: Int64) -> AppDetailRefreshStartSnapshot? {
        snapshotsByAppStoreID[appStoreID]
    }
}

private actor ControlledRatingsHTTPClient: HTTPClient {
    private struct PendingResponse {
        let requestID: UUID
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
    }

    private struct CountWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let onRequestStart: (@Sendable (Int64) async -> Void)?
    private var requestedIDs: [Int64] = []
    private var pendingResponses: [Int64: PendingResponse] = [:]
    private var requestCountWaiters: [CountWaiter] = []
    private var cancellationCountWaiters: [CountWaiter] = []
    private var cancellations = 0

    init(onRequestStart: (@Sendable (Int64) async -> Void)? = nil) {
        self.onRequestStart = onRequestStart
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let appStoreID = ratingAppStoreID(from: request)
        requestedIDs.append(appStoreID)
        await onRequestStart?(appStoreID)
        resumeSatisfiedRequestCountWaiters()

        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                precondition(pendingResponses[appStoreID] == nil)
                pendingResponses[appStoreID] = PendingResponse(
                    requestID: requestID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelRequest(appStoreID: appStoreID, requestID: requestID)
            }
        }
    }

    func requestedAppStoreIDs() -> [Int64] {
        requestedIDs
    }

    func cancellationCount() -> Int {
        cancellations
    }

    func waitForRequestCount(_ count: Int) async throws {
        try Task.checkCancellation()
        guard requestedIDs.count < count else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                requestCountWaiters.append(CountWaiter(
                    id: waiterID,
                    count: count,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelRequestCountWaiter(id: waiterID) }
        }
    }

    func waitForCancellationCount(_ count: Int) async throws {
        try Task.checkCancellation()
        guard cancellations < count else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                cancellationCountWaiters.append(CountWaiter(
                    id: waiterID,
                    count: count,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelCancellationCountWaiter(id: waiterID) }
        }
    }

    func complete(appStoreID: Int64) -> Bool {
        guard let pending = pendingResponses.removeValue(forKey: appStoreID) else { return false }
        let url = URL(string: "https://itunes.apple.com/lookup?id=\(appStoreID)&country=us")!
        let data = Data(#"{"results":[{"trackId":\#(appStoreID),"userRatingCount":42,"averageUserRating":4.5}]}"#.utf8)
        pending.continuation.resume(returning: (
            data,
            makeHTTPURLResponse(url: url, statusCode: 200)
        ))
        return true
    }

    private func cancelRequest(appStoreID: Int64, requestID: UUID) {
        cancellations += 1
        if pendingResponses[appStoreID]?.requestID == requestID {
            let continuation = pendingResponses.removeValue(forKey: appStoreID)?.continuation
            continuation?.resume(throwing: CancellationError())
        }
        resumeSatisfiedCancellationCountWaiters()
    }

    private func resumeSatisfiedRequestCountWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in requestCountWaiters {
            if requestedIDs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }

    private func resumeSatisfiedCancellationCountWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in cancellationCountWaiters {
            if cancellations >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        cancellationCountWaiters = remaining
    }

    private func cancelRequestCountWaiter(id: UUID) {
        guard let index = requestCountWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = requestCountWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelCancellationCountWaiter(id: UUID) {
        guard let index = cancellationCountWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = cancellationCountWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private actor ScriptedRatingsHTTPClient: HTTPClient {
    enum Step: Sendable {
        case failure(URLError.Code)
        case success
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !steps.isEmpty else {
            throw OpenASOError.unexpectedResponse
        }
        let step = steps.removeFirst()
        switch step {
        case .failure(let code):
            throw URLError(code)
        case .success:
            let appStoreID = ratingAppStoreID(from: request)
            let url = request.url ?? URL(string: "https://itunes.apple.com/lookup?id=\(appStoreID)&country=us")!
            let data = Data(#"{"results":[{"trackId":\#(appStoreID),"userRatingCount":42,"averageUserRating":4.5}]}"#.utf8)
            return (data, makeHTTPURLResponse(url: url, statusCode: 200))
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}

private func ratingAppStoreID(from request: URLRequest) -> Int64 {
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
