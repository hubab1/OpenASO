import Foundation
import SwiftData
import Synchronization
import Testing
@testable import OpenASO

@MainActor
struct KeywordMetricsServiceTests {
    @Test
    func expiredRefreshPreservesExistingPopularityAndRequiresReconnect() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        var requestCount = 0
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                requestCount += 1
                let payload = """
                <html><body>Sign in</body></html>
                """
                return (
                    Data(payload.utf8),
                    makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
                )
            },
            modelContainer: container,
            appleAdsPlatformAPI: HTTPBackedSearchPopularityAPI(
                httpClient: MockHTTPClient { request in
                    requestCount += 1
                    let payload = """
                    <html><body>Sign in</body></html>
                    """
                    return (
                        Data(payload.utf8),
                        makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
                    )
                }
            )
        )
        try saveTestCredentials(in: services.appleAdsCredentialStore)

        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        let query = try KeywordQuery.fetchOrInsert(term: "focus app", storefront: "us", platform: .iphone, in: modelContext)
        let track = TrackedAppKeyword(term: "focus app", storefront: "us", platform: .iphone, trackedApp: trackedApp, query: query)
        let previousUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -8, to: .now))
        let metrics = KeywordDailyMetric(
            queryKey: track.queryKey,
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            popularityScore: 72,
            difficultyScore: nil,
            source: .appleAdsPopularity,
            updatedAt: previousUpdatedAt
        )

        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        modelContext.insert(metrics)
        let rankingStatus = "Ranking failed to refresh. Preserve this failure."
        try TrackedKeywordRefreshStatusStore.set(
            rankingStatus,
            domain: .ranking,
            for: track,
            in: modelContext
        )
        try modelContext.save()

        _ = await services.keywordMetricsService.refreshMetrics(for: trackedApp, tracks: [track], in: modelContext)

        #expect(metrics.popularityScore == 72)
        #expect(metrics.updatedAt == previousUpdatedAt)
        let refreshStatus = try TrackedKeywordRefreshStatusStore.snapshot(
            for: track,
            in: modelContext
        )
        #expect(refreshStatus.rankingMessage == rankingStatus)
        #expect(refreshStatus.popularityMessage?.contains("Popularity failed to fetch") == true)
        #expect(track.statusMessage == nil)
        #expect(!services.appleAdsWebSessionStore.requiresReconnect)
        #expect(requestCount == 1)
    }

    @Test
    func failedFirstRefreshLeavesPopularityNilAndStoresStatus() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
                throw OpenASOError.providerUnavailable("Unexpected request")
            },
            modelContainer: container
        )

        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        let query = try KeywordQuery.fetchOrInsert(term: "focus app", storefront: "us", platform: .iphone, in: modelContext)
        let track = TrackedAppKeyword(term: "focus app", storefront: "us", platform: .iphone, trackedApp: trackedApp, query: query)
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        _ = await services.keywordMetricsService.refreshMetrics(for: trackedApp, tracks: [track], in: modelContext)
        let storedMetrics = try #require(try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>()).first)

        #expect(storedMetrics.popularityScore == nil)
        #expect(try TrackedKeywordRefreshStatusStore.snapshot(
            for: track,
            in: modelContext
        ).popularityMessage == "Popularity failed to fetch. Configure and verify Apple Ads Platform API credentials in Settings.")
    }

    @Test
    func resolveDefaultAppleAdsAppReturnsFirstCampaignLinkedApp() async throws {
        let expectedApp = AppleAdsPromotedApp(
            adamId: 6_448_311_069,
            appName: "Atten",
            developerName: "Third Tech",
            countryOrRegionCodes: ["US"]
        )
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                throw OpenASOError.providerUnavailable(
                    "Unexpected request to \(request.url?.absoluteString ?? "unknown URL")"
                )
            },
            appleAdsPlatformAPI: StaticAppleAdsPlatformAPI(apps: [expectedApp])
        )

        let app = try await services.keywordMetricsService.resolveDefaultAppleAdsApp(
            using: AppleAdsCredentials(
                clientID: "client",
                teamID: "team",
                keyID: "key",
                privateKey: Self.privateKey,
                adAccountID: "12345"
            )
        )

        #expect(app == expectedApp)
    }

    @Test
    func webSessionResolvesDefaultAppleAdsAppWithoutAPICredentials() async throws {
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                let url = try #require(request.url)
                #expect(url.host == "app-ads.apple.com")
                #expect(url.path == "/reporting/graphql")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "searchads.soid=session")
                #expect(request.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") == "xsrf")

                let payload = """
                {
                  "data": {
                    "reportingV5": {
                      "getReportsByCampaign": {
                        "row": [
                          {
                            "metadata": {
                              "countriesOrRegions": ["GB"],
                              "app": {
                                "adamId": "6608976383",
                                "appName": "Atten - App Blocker"
                              }
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return (
                    Data(payload.utf8),
                    makeHTTPURLResponse(url: url, statusCode: 200)
                )
            }
        )
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(
                cookieHeader: "searchads.soid=session",
                xsrfToken: "xsrf",
                updatedAt: .now
            )
        )

        let app = try await services.appleAdsWebSessionManager.resolveDefaultLinkedApp()

        #expect(app.adamId == 6_608_976_383)
        #expect(app.appName == "Atten - App Blocker")
        #expect(app.countryOrRegionCodes == ["GB"])
    }

    @Test
    func webSessionAuthenticationFailureStopsLinkedAppFallbacks() async throws {
        var requestedPaths: [String] = []
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                let url = try #require(request.url)
                requestedPaths.append(url.path)
                return (
                    Data(#"{"error":"unauthorized"}"#.utf8),
                    makeHTTPURLResponse(url: url, statusCode: 401)
                )
            }
        )
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(
                cookieHeader: "searchads.soid=session",
                xsrfToken: "xsrf",
                updatedAt: .now,
                accountName: "Third Tech Ltd"
            )
        )

        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await services.appleAdsWebSessionManager.resolveDefaultLinkedApp()
        }
        #expect(requestedPaths == ["/reporting/graphql"])
        #expect(services.appleAdsWebSessionStore.requiresReconnect)
        #expect(services.appleAdsWebSessionStore.hasSession)
    }

    @Test
    func campaignAuthenticationFailureStopsLaterEndpointAndSellerFallbacks() async throws {
        var requestedPaths: [String] = []
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                let url = try #require(request.url)
                requestedPaths.append(url.path)
                if url.path == "/reporting/graphql" {
                    let payload = #"{"data":{"reportingV5":{"getReportsByCampaign":{"row":[]}}}}"#
                    return (
                        Data(payload.utf8),
                        makeHTTPURLResponse(url: url, statusCode: 200)
                    )
                }

                return (
                    Data(#"{"error":"forbidden"}"#.utf8),
                    makeHTTPURLResponse(url: url, statusCode: 403)
                )
            }
        )
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(
                cookieHeader: "searchads.soid=session",
                xsrfToken: "xsrf",
                updatedAt: .now,
                accountName: "Third Tech Ltd"
            )
        )

        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await services.appleAdsWebSessionManager.resolveDefaultLinkedApp()
        }
        #expect(requestedPaths == ["/reporting/graphql", "/cm/api/v5/campaigns"])
        #expect(services.appleAdsWebSessionStore.requiresReconnect)
        #expect(services.appleAdsWebSessionStore.hasSession)
    }

    @Test
    func webSessionCancellationStopsLinkedAppFallbacks() async throws {
        var requestCount = 0
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { _ in
                requestCount += 1
                throw CancellationError()
            }
        )
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(
                cookieHeader: "searchads.soid=session",
                xsrfToken: "xsrf",
                updatedAt: .now,
                accountName: "Third Tech Ltd"
            )
        )

        await #expect(throws: CancellationError.self) {
            _ = try await services.appleAdsWebSessionManager.resolveDefaultLinkedApp()
        }
        #expect(requestCount == 1)
    }

    @Test
    func webSessionFallsBackToSellerAppsWhenCampaignEndpointFails() async throws {
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                let url = try #require(request.url)
                if url.host == "app-ads.apple.com" {
                    return (
                        Data("<html>Internal Server Error</html>".utf8),
                        makeHTTPURLResponse(url: url, statusCode: 500)
                    )
                }

                #expect(url.host == "itunes.apple.com")
                #expect(url.path == "/search")
                #expect(url.query?.contains("Third%20Tech%20Ltd") == true)
                let payload = """
                {
                  "resultCount": 2,
                  "results": [
                    {
                      "trackId": 6608976383,
                      "trackName": "Atten - App Blocker",
                      "sellerName": "Third Tech Ltd"
                    },
                    {
                      "trackId": 1485115388,
                      "trackName": "Rusty Blower 3D",
                      "sellerName": "Zplay (Beijing) Info. Tech. Co.,Ltd."
                    }
                  ]
                }
                """
                return (
                    Data(payload.utf8),
                    makeHTTPURLResponse(url: url, statusCode: 200)
                )
            }
        )
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(
                cookieHeader: "searchads.soid=session",
                xsrfToken: "xsrf",
                updatedAt: .now,
                accountName: "Third Tech Ltd"
            )
        )

        let app = try await services.appleAdsWebSessionManager.resolveDefaultLinkedApp()

        #expect(app.adamId == 6_608_976_383)
        #expect(app.appName == "Atten - App Blocker")
    }

    @Test
    func successfulRefreshStoresPopularityAndClearsPriorStatus() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                let payload = """
                {
                  "status": "success",
                  "data": [
                    {"name": "focus app", "popularity": 88}
                  ]
                }
                """
                return (
                    Data(payload.utf8),
                    makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
                )
            },
            modelContainer: container,
            appleAdsPlatformAPI: StaticAppleAdsPlatformAPI(
                apps: [],
                popularityRows: [
                    AppleAdsSearchTermPopularity(
                        searchTerm: "focus app",
                        countryOrRegion: "US",
                        genre: "Productivity",
                        week: "2026-08-08",
                        month: nil,
                        rankInGenre: 1,
                        popularityInGenre: 88,
                        popularity1to100: 88,
                        popularity1to5: 5
                    )
                ]
            )
        )
        try saveTestCredentials(in: services.appleAdsCredentialStore)

        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        let query = try KeywordQuery.fetchOrInsert(term: "focus app", storefront: "us", platform: .iphone, in: modelContext)
        let track = TrackedAppKeyword(term: "focus app", storefront: "us", platform: .iphone, trackedApp: trackedApp, query: query)
        track.statusMessage = "Popularity failed to fetch. Connect an Apple Ads web session in Settings."
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        _ = await services.keywordMetricsService.refreshMetrics(for: trackedApp, tracks: [track], in: modelContext)
        let storedMetrics = try #require(try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>()).first)

        #expect(storedMetrics.popularityScore == 88)
        #expect(track.statusMessage == nil)
    }

    @Test
    func unavailableOfficialPopularityClearsLegacyScoreWithoutReportingFailure() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
                throw OpenASOError.providerUnavailable("Unexpected request")
            },
            modelContainer: container,
            appleAdsPlatformAPI: StaticAppleAdsPlatformAPI(apps: [], popularityRows: [])
        )
        try saveTestCredentials(in: services.appleAdsCredentialStore)

        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "App",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let track = try makeTrack(
            term: "long-tail keyword",
            trackedApp: trackedApp,
            in: modelContext
        )
        let previousUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -8, to: .now))
        modelContext.insert(
            KeywordDailyMetric(
                queryKey: track.queryKey,
                keyword: track.term,
                storefront: track.storefront,
                platform: track.platform,
                popularityScore: 74,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: previousUpdatedAt
            )
        )
        try modelContext.save()

        let progressRecorder = KeywordMetricsProgressRecorder()
        let result = try await services.keywordMetricsService.refreshMetricsBatch(
            for: [track.identityKey],
            using: BackgroundModelStore(modelContainer: container),
            progress: { completed, total, failureCount in
                await progressRecorder.record(
                    completed: completed,
                    total: total,
                    failureCount: failureCount
                )
            }
        )
        let trackID = track.persistentModelID
        let stored = try await BackgroundModelStore(modelContainer: container).read { context in
            let storedTrack = try #require(context.model(for: trackID) as? TrackedAppKeyword)
            let metric = try #require(try context.fetch(FetchDescriptor<KeywordDailyMetric>()).first)
            let refreshStatus = try TrackedKeywordRefreshStatusStore.snapshot(
                for: storedTrack,
                in: context
            )
            return (
                popularityScore: metric.popularityScore,
                statusMessage: refreshStatus.popularityMessage
            )
        }
        let progressUpdates = await progressRecorder.snapshot()

        #expect(result.outcomes.count == 1)
        #expect(result.outcomes.first?.disposition == .skipped)
        #expect(result.skippedCount == 1)
        #expect(result.failureCount == 0)
        #expect(result.firstErrorMessage == nil)
        #expect(stored.popularityScore == nil)
        #expect(stored.statusMessage?.contains("at least 500 searches and 10 impressions") == true)
        #expect(progressUpdates == [
            .init(completed: 0, total: 1, failureCount: 0),
            .init(completed: 1, total: 1, failureCount: 0),
        ])

        let secondResult = try await services.keywordMetricsService.refreshMetricsBatch(
            for: [track.identityKey],
            using: BackgroundModelStore(modelContainer: container)
        )
        let retainedUnavailableStatus = try await BackgroundModelStore(
            modelContainer: container
        ).read { context in
            let storedTrack = try #require(context.model(for: trackID) as? TrackedAppKeyword)
            return try TrackedKeywordRefreshStatusStore.snapshot(
                for: storedTrack,
                in: context
            ).popularityMessage
        }

        #expect(secondResult.outcomes.first?.disposition == .upToDate)
        #expect(secondResult.failureCount == 0)
        #expect(retainedUnavailableStatus?.contains("at least 500 searches and 10 impressions") == true)
    }

    @Test
    func unsupportedAppleAdsStorefrontDoesNotAskForSetup() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { _ in
                throw OpenASOError.providerUnavailable("Unexpected request")
            },
            modelContainer: container,
            appleAdsPlatformAPI: FailingSearchPopularityAPI(
                error: .providerUnavailable(
                    "Apple Ads does not support keyword popularity in Angola."
                )
            )
        )
        try saveTestCredentials(in: services.appleAdsCredentialStore)

        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        let query = try KeywordQuery.fetchOrInsert(term: "focus app", storefront: "ao", platform: .iphone, in: modelContext)
        let track = TrackedAppKeyword(term: "focus app", storefront: "ao", platform: .iphone, trackedApp: trackedApp, query: query)
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        _ = await services.keywordMetricsService.refreshMetrics(for: trackedApp, tracks: [track], in: modelContext)

        let refreshStatus = try TrackedKeywordRefreshStatusStore.snapshot(
            for: track,
            in: modelContext
        )
        #expect(refreshStatus.popularityMessage == "Popularity unavailable. Apple Ads does not support keyword popularity in Angola.")
        let storedMetrics = try #require(try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>()).first)
        let row = KeywordWorkspaceRow(
            track: track,
            storefront: nil,
            metrics: storedMetrics,
            refreshStatus: refreshStatus,
            latestSnapshot: Optional<KeywordRankingCrawlSummary>.none,
            trendSnapshots: [KeywordRankingCrawlSummary](),
            rankingApps: [KeywordRankingAppSummary]()
        )
        #expect(row.popularityIndicatorState == .unavailable(message: "Popularity unavailable. Apple Ads does not support keyword popularity in Angola."))
    }

    @Test
    func connectionRefreshUsesOneBulkLookupPerSelectionAndOnlyFetchesStaleMetrics() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        var requestedTerms: [String] = []
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            let payload = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
            requestedTerms.append(contentsOf: payload.terms)

            let response = """
            {
              "status": "success",
              "data": [
                {"name": "missing", "popularity": 81},
                {"name": "stale", "popularity": 67}
              ]
            }
            """
            return (
                Data(response.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let services = AppServices.mocked(httpClient: client, modelContainer: container)
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(httpClient: client, freshnessFetchRecorder: freshnessFetchRecorder)

        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        modelContext.insert(trackedApp)
        let freshTrack = try makeTrack(term: "fresh", trackedApp: trackedApp, in: modelContext)
        let staleTrack = try makeTrack(term: "stale", trackedApp: trackedApp, in: modelContext)
        _ = try makeTrack(term: "missing", trackedApp: trackedApp, in: modelContext)
        let staleUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -8, to: .now))
        let freshUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        modelContext.insert(
            KeywordDailyMetric(
                queryKey: freshTrack.queryKey,
                keyword: freshTrack.term,
                storefront: freshTrack.storefront,
                platform: freshTrack.platform,
                popularityScore: 91,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: freshUpdatedAt
            )
        )
        modelContext.insert(
            KeywordDailyMetric(
                queryKey: staleTrack.queryKey,
                keyword: staleTrack.term,
                storefront: staleTrack.storefront,
                platform: staleTrack.platform,
                popularityScore: 12,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: staleUpdatedAt
            )
        )
        try modelContext.save()

        let backgroundModelStore = try #require(services.backgroundModelStore)
        let outcomes = try await service.refreshStalePopularityMetrics(
            using: backgroundModelStore
        )
        let storedScores = try await backgroundModelStore.read { modelContext in
            let metrics = try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>())
            return Dictionary(uniqueKeysWithValues: metrics.map { ($0.keyword, $0.popularityScore) })
        }

        #expect(outcomes.count == 2)
        #expect(Set(requestedTerms) == ["missing", "stale"])
        #expect(!requestedTerms.contains("fresh"))
        #expect(storedScores["fresh"] == 91)
        #expect(storedScores["stale"] == 67)
        #expect(storedScores["missing"] == 81)
        #expect(freshnessFetchRecorder.snapshot() == [3, 2])
    }

    @Test
    func appIndependentPopularityUsesCanonicalSequentialStorefrontBatchesWithoutTrackedMutation() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let requestBodies = KeywordPopularityRequestRecorder()
        let legacyContextAppStoreID: Int64 = 6_608_976_383
        let session = completeWebSession
        let client = MockHTTPClient { request in
            #expect(
                URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "adamId" })?.value
                    == "123456789"
            )
            #expect(request.value(forHTTPHeaderField: "Cookie") == session.cookieHeader)
            #expect(request.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") == session.xsrfToken)
            let body = try #require(request.httpBody)
            let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
            requestBodies.record(requestBody)
            let entries = requestBody.terms.map { term in
                #"{"name":"\#(term)","popularity":71}"#
            }.joined(separator: ",")
            return (
                Data(#"{"status":"success","data":[\#(entries)]}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: KeywordMetricsFreshnessFetchRecorder()
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)

        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "Tracked sentinel",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let trackedQuery = try KeywordQuery.fetchOrInsert(
            term: "tracked sentinel",
            storefront: "us",
            platform: .iphone,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: trackedQuery.term,
            storefront: trackedQuery.storefront,
            platform: trackedQuery.platform,
            trackedApp: trackedApp,
            query: trackedQuery
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)
        try TrackedKeywordRefreshStatusStore.set(
            "Tracked status must remain unchanged.",
            domain: .ranking,
            for: track,
            updatedAt: Date(timeIntervalSince1970: 50),
            in: modelContext
        )
        modelContext.insert(AppKeywordStats(
            appStoreID: trackedApp.appStoreID,
            queryKey: trackedQuery.queryKey,
            keyword: trackedQuery.term,
            storefront: trackedQuery.storefront,
            platform: trackedQuery.platform,
            rank: 4,
            observedAt: Date(timeIntervalSince1970: 40),
            popularityScore: 88,
            difficultyScore: 33
        ))
        try modelContext.save()

        let gbTargets = try (0..<2).map {
            try makePopularityTarget(term: "gb-\(String(format: "%03d", $0))", storefront: "gb")
        }
        let usTargets = try (0..<102).map {
            try makePopularityTarget(term: "us-\(String(format: "%03d", $0))", storefront: "us")
        }
        let targets = Array((usTargets + gbTargets + [usTargets[0]]).reversed())
        let observedAt = Date(timeIntervalSince1970: 100)

        let evidence = try await service.fetchPopularityMetrics(
            for: targets,
            contextAppStoreID: legacyContextAppStoreID,
            webSession: session,
            now: { observedAt }
        )
        let outcomes = try await backgroundModelStore.write { context in
            try service.persistPopularityMetrics(evidence, in: context)
        }

        let requests = requestBodies.snapshot()
        #expect(requests.map(\.storefronts) == [["GB"], ["US"], ["US"]])
        #expect(requests.map { $0.terms.count } == [2, 100, 2])
        #expect(requests[0].terms == gbTargets.sorted { $0.queryKey < $1.queryKey }.map(\.term))
        #expect(
            Array(requests[1...].flatMap(\.terms))
                == usTargets.sorted { $0.queryKey < $1.queryKey }.map(\.term)
        )
        #expect(outcomes.count == gbTargets.count + usTargets.count)
        #expect(outcomes.allSatisfy {
            $0.popularityScore == 71 && $0.disposition == .inserted && $0.observedAt == observedAt
        })

        let storedState = try await backgroundModelStore.read { context in
            let persistedTrack = try #require(
                context.fetch(FetchDescriptor<TrackedAppKeyword>()).first
            )
            let trackStatus = try TrackedKeywordRefreshStatusStore.snapshot(
                for: persistedTrack,
                in: context
            )
            let stats = try #require(context.fetch(FetchDescriptor<AppKeywordStats>()).first)
            return AppIndependentPopularityStoredState(
                metricCount: try context.fetchCount(FetchDescriptor<KeywordDailyMetric>()),
                queryCount: try context.fetchCount(FetchDescriptor<KeywordQuery>()),
                trackedAppCount: try context.fetchCount(FetchDescriptor<TrackedApp>()),
                trackCount: try context.fetchCount(FetchDescriptor<TrackedAppKeyword>()),
                rankingStatus: trackStatus.rankingMessage,
                popularityStatus: trackStatus.popularityMessage,
                statsCount: try context.fetchCount(FetchDescriptor<AppKeywordStats>()),
                statsPopularity: stats.popularityScore,
                statsDifficulty: stats.difficultyScore
            )
        }
        #expect(storedState == AppIndependentPopularityStoredState(
            metricCount: 104,
            queryCount: 1,
            trackedAppCount: 1,
            trackCount: 1,
            rankingStatus: "Tracked status must remain unchanged.",
            popularityStatus: nil,
            statsCount: 1,
            statsPopularity: 88,
            statsDifficulty: 33
        ))
        #expect(outcomes.allSatisfy { $0.target.queryKey.hasPrefix("opaque-query/") })
    }

    @Test
    func appIndependentPopularityOnlyAppliesStrictlyNewerSuccessesAndPreservesOtherFields() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let observedAt = Date(timeIntervalSince1970: 200)
        let olderTarget = try makePopularityTarget(term: "older", storefront: "us")
        let equalTarget = try makePopularityTarget(term: "equal", storefront: "us")
        let newerTarget = try makePopularityTarget(term: "newer", storefront: "us")
        let insertedTarget = try makePopularityTarget(term: "inserted", storefront: "us")
        let missingTarget = try makePopularityTarget(term: "missing", storefront: "us")
        let responseScores = [
            olderTarget.term: 71,
            equalTarget.term: 72,
            newerTarget.term: 73,
            insertedTarget.term: 120,
        ]
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
            let entries = requestBody.terms.compactMap { term -> String? in
                guard let score = responseScores[term] else { return nil }
                return #"{"name":"\#(term)","popularity":\#(score)}"#
            }.joined(separator: ",")
            return (
                Data(#"{"status":"success","data":[\#(entries)]}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: KeywordMetricsFreshnessFetchRecorder()
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)

        modelContext.insert(makePopularityMetric(
            target: olderTarget,
            popularityScore: 11,
            difficultyScore: 41,
            updatedAt: Date(timeIntervalSince1970: 100),
            notes: "preserve older notes"
        ))
        modelContext.insert(makePopularityMetric(
            target: equalTarget,
            popularityScore: 22,
            difficultyScore: 42,
            updatedAt: observedAt,
            notes: "preserve equal notes"
        ))
        modelContext.insert(makePopularityMetric(
            target: newerTarget,
            popularityScore: 33,
            difficultyScore: 43,
            updatedAt: Date(timeIntervalSince1970: 300),
            notes: "preserve newer notes"
        ))
        modelContext.insert(AppKeywordStats(
            appStoreID: 99,
            queryKey: olderTarget.queryKey,
            keyword: olderTarget.term,
            storefront: olderTarget.storefront,
            platform: olderTarget.platform,
            rank: 2,
            observedAt: Date(timeIntervalSince1970: 90),
            popularityScore: 11,
            difficultyScore: 41
        ))
        try modelContext.save()

        let evidence = try await service.fetchPopularityMetrics(
            for: [missingTarget, newerTarget, insertedTarget, olderTarget, equalTarget],
            contextAppStoreID: 123_456_789,
            webSession: completeWebSession,
            now: { observedAt }
        )
        #expect(!modelContext.hasChanges)
        let outcomes = try service.persistPopularityMetrics(evidence, in: modelContext)
        #expect(modelContext.hasChanges)
        try modelContext.save()

        let dispositions = Dictionary(uniqueKeysWithValues: outcomes.map {
            ($0.target.queryKey, $0.disposition)
        })
        #expect(dispositions[olderTarget.queryKey] == .updated)
        #expect(dispositions[equalTarget.queryKey] == .ignoredNotNewer)
        #expect(dispositions[newerTarget.queryKey] == .ignoredNotNewer)
        #expect(dispositions[insertedTarget.queryKey] == .inserted)
        #expect(dispositions[missingTarget.queryKey] == .notFound)
        #expect(outcomes.first(where: { $0.target == insertedTarget })?.popularityScore == 100)

        let storedState = try await backgroundModelStore.read { context in
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            let records = Dictionary(uniqueKeysWithValues: metrics.map { metric in
                (metric.queryKey, StoredPopularityMetric(
                    popularityScore: metric.popularityScore,
                    difficultyScore: metric.difficultyScore,
                    updatedAt: metric.updatedAt,
                    notes: metric.notes,
                    confidence: metric.confidenceRaw
                ))
            })
            let stats = try #require(context.fetch(FetchDescriptor<AppKeywordStats>()).first)
            return PopularityUpsertStoredState(
                metrics: records,
                trackedAppCount: try context.fetchCount(FetchDescriptor<TrackedApp>()),
                trackCount: try context.fetchCount(FetchDescriptor<TrackedAppKeyword>()),
                statsPopularity: stats.popularityScore,
                statsDifficulty: stats.difficultyScore
            )
        }
        #expect(storedState.metrics[olderTarget.queryKey] == StoredPopularityMetric(
            popularityScore: 71,
            difficultyScore: 41,
            updatedAt: observedAt,
            notes: "preserve older notes",
            confidence: "single_source"
        ))
        #expect(storedState.metrics[equalTarget.queryKey] == StoredPopularityMetric(
            popularityScore: 22,
            difficultyScore: 42,
            updatedAt: observedAt,
            notes: "preserve equal notes",
            confidence: "legacy_confidence"
        ))
        #expect(storedState.metrics[newerTarget.queryKey] == StoredPopularityMetric(
            popularityScore: 33,
            difficultyScore: 43,
            updatedAt: Date(timeIntervalSince1970: 300),
            notes: "preserve newer notes",
            confidence: "legacy_confidence"
        ))
        #expect(storedState.metrics[insertedTarget.queryKey] == StoredPopularityMetric(
            popularityScore: 100,
            difficultyScore: nil,
            updatedAt: observedAt,
            notes: nil,
            confidence: "single_source"
        ))
        #expect(storedState.metrics[missingTarget.queryKey] == nil)
        #expect(storedState.trackedAppCount == 0)
        #expect(storedState.trackCount == 0)
        #expect(storedState.statsPopularity == 11)
        #expect(storedState.statsDifficulty == 41)
    }

    @Test
    func firstPopularitySuccessIsNotSuppressedByNewerDifficultyOnlyRow() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let service = makeKeywordMetricsService(
            httpClient: MockHTTPClient { _ in
                throw OpenASOError.providerUnavailable("Unexpected provider request")
            },
            freshnessFetchRecorder: KeywordMetricsFreshnessFetchRecorder()
        )
        let target = try makePopularityTarget(term: "difficulty only", storefront: "us")
        let observedAt = Date(timeIntervalSince1970: 200)
        modelContext.insert(makePopularityMetric(
            target: target,
            popularityScore: nil,
            difficultyScore: 64,
            updatedAt: Date(timeIntervalSince1970: 300),
            notes: "preserve difficulty evidence"
        ))
        try modelContext.save()

        let outcomes = try service.persistPopularityMetrics([
            KeywordPopularityMetricEvidence(
                target: target,
                popularityScore: 83,
                observedAt: observedAt
            )
        ], in: modelContext)
        try modelContext.save()

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.disposition == .updated)
        let metric = try #require(modelContext.fetch(FetchDescriptor<KeywordDailyMetric>()).first)
        #expect(metric.popularityScore == 83)
        #expect(metric.difficultyScore == 64)
        #expect(metric.notes == "preserve difficulty evidence")
        #expect(metric.updatedAt == Date(timeIntervalSince1970: 300))
    }

    @Test
    func appIndependentPopularityCancellationStopsLaterBatchesAndAllPersistence() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let client = GatedKeywordPopularityHTTPClient()
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: KeywordMetricsFreshnessFetchRecorder()
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let targets = try (0..<101).map {
            try makePopularityTarget(term: "cancel-\(String(format: "%03d", $0))", storefront: "us")
        }
        let refreshTask = Task {
            try await service.fetchPopularityMetrics(
                for: targets,
                contextAppStoreID: 123_456_789,
                webSession: completeWebSession,
                now: { Date(timeIntervalSince1970: 500) }
            )
        }
        await client.waitUntilStarted()

        refreshTask.cancel()
        await client.succeed()

        await #expect(throws: CancellationError.self) {
            _ = try await refreshTask.value
        }
        #expect(await client.requestCount() == 1)
        #expect(
            try await backgroundModelStore.fetchCount(FetchDescriptor<KeywordDailyMetric>()) == 0
        )
    }

    @Test
    func backgroundRefreshUsesOneFreshnessFetchForLargeSharedQueryFixtureAndSkipsFreshMetrics() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let requestBodies = KeywordPopularityRequestRecorder()
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
            requestBodies.record(requestBody)
            let entries = requestBody.terms.map { term in
                #"{"name":"\#(term)","popularity":74}"#
            }.joined(separator: ",")
            let response = #"{"status":"success","data":[\#(entries)]}"#
            return (
                Data(response.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(httpClient: client, freshnessFetchRecorder: freshnessFetchRecorder)
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let progressRecorder = KeywordMetricsProgressRecorder()
        let terms = (0..<30).map { "shared-\($0)" }
        let freshTerms = Set(terms.prefix(10))
        let staleTerms = Set(terms.dropFirst(10).prefix(5))
        var identityKeys: [String] = []

        for appIndex in 0..<8 {
            let trackedApp = TrackedApp(
                appStoreID: Int64(appIndex + 1),
                bundleID: nil,
                name: "App \(appIndex)",
                sellerName: nil,
                defaultPlatform: .iphone
            )
            modelContext.insert(trackedApp)
            for term in terms {
                let track = try makeTrack(term: term, trackedApp: trackedApp, in: modelContext)
                track.statusMessage = "Popularity failed to fetch. Resolved shared-query failure."
                identityKeys.append(track.identityKey)
            }
        }

        let freshUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        let staleUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -8, to: .now))
        for term in freshTerms.union(staleTerms) {
            let queryKey = KeywordQuery.makeQueryKey(term: term, storefront: "us", platform: .iphone)
            modelContext.insert(
                KeywordDailyMetric(
                    queryKey: queryKey,
                    keyword: term,
                    storefront: "us",
                    platform: .iphone,
                    popularityScore: freshTerms.contains(term) ? 91 : 12,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    updatedAt: freshTerms.contains(term) ? freshUpdatedAt : staleUpdatedAt
                )
            )
        }
        try modelContext.save()

        let outcomes = try await service.refreshMetrics(
            for: identityKeys,
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let storedState = try await backgroundModelStore.read { context in
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            let tracks = try context.fetch(FetchDescriptor<TrackedAppKeyword>())
            return (
                scores: Dictionary(uniqueKeysWithValues: metrics.map { ($0.keyword, $0.popularityScore) }),
                tracksWithStatus: tracks.filter { $0.statusMessage != nil }.count
            )
        }
        let progressUpdates = await progressRecorder.snapshot()
        let recordedRequests = requestBodies.snapshot()

        #expect(outcomes.count == terms.count)
        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(recordedRequests.count == 1)
        #expect(recordedRequests.first?.storefronts == ["US"])
        #expect(Set(recordedRequests.first?.terms ?? []) == Set(terms).subtracting(freshTerms))
        #expect(freshTerms.allSatisfy { storedState.scores[$0] == 91 })
        #expect(Set(terms).subtracting(freshTerms).allSatisfy { storedState.scores[$0] == 74 })
        #expect(storedState.tracksWithStatus == 0)
        #expect(progressUpdates.count == terms.count + 1)
        #expect(progressUpdates.first == .init(completed: 0, total: terms.count, failureCount: 0))
        #expect(progressUpdates.last == .init(completed: terms.count, total: terms.count, failureCount: 0))
        #expect(freshnessFetchRecorder.snapshot() == [terms.count])
    }

    @Test
    func popularityRefreshPreservesRankingHistory() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
            let entries = requestBody.terms.map { term in
                #"{"name":"\#(term)","popularity":74}"#
            }.joined(separator: ",")
            return (
                Data(#"{"status":"success","data":[\#(entries)]}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: KeywordMetricsFreshnessFetchRecorder()
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: "com.example.focus",
            name: "Focus",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let track = try makeTrack(term: "focus timer", trackedApp: trackedApp, in: modelContext)
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let crawl = RankingCrawlRecord(
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            observedAt: observedAt,
            source: .appStoreWeb,
            resultCount: 100,
            query: track.query
        )
        let ranking = makeRankingFact(
            position: 4,
            appStoreID: trackedApp.appStoreID,
            bundleID: trackedApp.bundleID,
            name: trackedApp.name,
            sellerName: trackedApp.sellerName,
            observation: crawl,
            in: modelContext
        )
        modelContext.insert(crawl)
        modelContext.insert(ranking)
        try modelContext.save()

        let outcomes = try await service.refreshMetrics(
            for: [track.identityKey],
            using: backgroundModelStore
        )
        let stored = try await backgroundModelStore.read { context in
            let crawls = try context.fetch(FetchDescriptor<RankingCrawlRecord>())
            let rankings = try context.fetch(FetchDescriptor<RankingFact>())
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            return (
                crawlKeys: crawls.map(\.observationKey),
                rankingPositions: rankings.map(\.position),
                popularityScores: metrics.compactMap(\.popularityScore)
            )
        }

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.errorMessage == nil)
        #expect(stored.crawlKeys == [crawl.observationKey])
        #expect(stored.rankingPositions == [4])
        #expect(stored.popularityScores == [74])
    }

    @Test
    func freshnessSkipClearsOnlyPopularityStatusMessages() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
                throw OpenASOError.providerUnavailable("Unexpected request")
            },
            modelContainer: container
        )
        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "App",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let failedTrack = try makeTrack(term: "failed", trackedApp: trackedApp, in: modelContext)
        let unavailableTrack = try makeTrack(term: "unavailable", trackedApp: trackedApp, in: modelContext)
        let rankingTrack = try makeTrack(term: "ranking", trackedApp: trackedApp, in: modelContext)
        failedTrack.statusMessage = "Popularity failed to fetch. Previous failure."
        unavailableTrack.statusMessage = "Popularity unavailable. Previous limitation."
        let rankingStatus = "Ranking failed to refresh. Previous failure."
        rankingTrack.statusMessage = rankingStatus

        for track in [failedTrack, unavailableTrack, rankingTrack] {
            modelContext.insert(
                KeywordDailyMetric(
                    queryKey: track.queryKey,
                    keyword: track.term,
                    storefront: track.storefront,
                    platform: track.platform,
                    popularityScore: 55,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    updatedAt: .now
                )
            )
        }
        try modelContext.save()

        let outcomes = await services.keywordMetricsService.refreshMetrics(
            for: trackedApp,
            tracks: [failedTrack, unavailableTrack, rankingTrack],
            in: modelContext
        )

        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(failedTrack.statusMessage == nil)
        #expect(unavailableTrack.statusMessage == nil)
        #expect(rankingTrack.statusMessage == nil)
        #expect(try TrackedKeywordRefreshStatusStore.snapshot(
            for: failedTrack,
            in: modelContext
        ).popularityMessage == nil)
        #expect(try TrackedKeywordRefreshStatusStore.snapshot(
            for: unavailableTrack,
            in: modelContext
        ).popularityMessage == nil)
        #expect(try TrackedKeywordRefreshStatusStore.snapshot(
            for: rankingTrack,
            in: modelContext
        ).rankingMessage == rankingStatus)
    }

    @Test
    func directFreshnessSkipDoesNotClobberSameStatusWrittenDuringLaterProviderWork() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let client = SuspendedKeywordMetricsHTTPClient()
        let services = AppServices.mocked(
            httpClient: client,
            modelContainer: container,
            appleAdsPlatformAPI: HTTPBackedSearchPopularityAPI(httpClient: client)
        )
        try saveTestCredentials(in: services.appleAdsCredentialStore)
        let backgroundModelStore = try #require(services.backgroundModelStore)
        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "App",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let freshTrack = try makeTrack(term: "fresh", trackedApp: trackedApp, in: modelContext)
        let staleTrack = try makeTrack(term: "needs-refresh", trackedApp: trackedApp, in: modelContext)
        let repeatedStatus = "Popularity failed to fetch. Same repeated failure."
        freshTrack.statusMessage = repeatedStatus
        modelContext.insert(
            KeywordDailyMetric(
                queryKey: freshTrack.queryKey,
                keyword: freshTrack.term,
                storefront: freshTrack.storefront,
                platform: freshTrack.platform,
                popularityScore: 55,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: .now
            )
        )
        try modelContext.save()

        let refreshTask = Task { @MainActor in
            await services.keywordMetricsService.refreshMetrics(
                for: trackedApp,
                tracks: [freshTrack, staleTrack],
                in: modelContext
            )
        }
        await client.waitUntilRequestStarts()
        let freshTrackIdentityKey = freshTrack.identityKey
        try await backgroundModelStore.write { context in
            let descriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    track.identityKey == freshTrackIdentityKey
                }
            )
            guard let persistedTrack = try context.fetch(descriptor).first else {
                throw OpenASOError.appNotFound
            }
            persistedTrack.statusMessage = repeatedStatus
        }
        await client.succeed()
        _ = await refreshTask.value

        let persistedStatus = try await backgroundModelStore.read { context in
            let descriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    track.identityKey == freshTrackIdentityKey
                }
            )
            return try context.fetch(descriptor).first?.statusMessage
        }
        #expect(persistedStatus == repeatedStatus)
    }

    @Test
    func backgroundFreshnessSkipAtomicallyClearsAndPreservesLaterStatus() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let client = MockHTTPClient { request in
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            throw OpenASOError.providerUnavailable("Unexpected request")
        }
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: freshnessFetchRecorder
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "App",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let clearTrack = try makeTrack(term: "clear", trackedApp: trackedApp, in: modelContext)
        let newerTrack = try makeTrack(term: "newer", trackedApp: trackedApp, in: modelContext)
        let rankingTrack = try makeTrack(term: "ranking", trackedApp: trackedApp, in: modelContext)
        clearTrack.statusMessage = "Popularity failed to fetch. Resolved failure."
        let newerStatus = "Popularity failed to fetch. Same repeated failure."
        newerTrack.statusMessage = newerStatus
        let rankingStatus = "Ranking failed to refresh. Keep this failure."
        rankingTrack.statusMessage = rankingStatus

        for track in [clearTrack, newerTrack, rankingTrack] {
            modelContext.insert(
                KeywordDailyMetric(
                    queryKey: track.queryKey,
                    keyword: track.term,
                    storefront: track.storefront,
                    platform: track.platform,
                    popularityScore: 55,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    updatedAt: .now
                )
            )
        }
        try modelContext.save()

        let outcomes = try await service.refreshStalePopularityMetrics(
            using: backgroundModelStore
        )
        let newerTrackIdentityKey = newerTrack.identityKey
        try await backgroundModelStore.write { context in
            let descriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    track.identityKey == newerTrackIdentityKey
                }
            )
            guard let persistedTrack = try context.fetch(descriptor).first else {
                throw OpenASOError.appNotFound
            }
            try TrackedKeywordRefreshStatusStore.set(
                newerStatus,
                domain: .popularity,
                for: persistedTrack,
                updatedAt: .now,
                in: context
            )
        }
        let persistedStatuses = try await backgroundModelStore.read { context in
            let tracks = try context.fetch(FetchDescriptor<TrackedAppKeyword>())
            guard let clearTrack = tracks.first(where: { $0.term == "clear" }),
                  let newerTrack = tracks.first(where: { $0.term == "newer" }),
                  let rankingTrack = tracks.first(where: { $0.term == "ranking" })
            else {
                throw OpenASOError.appNotFound
            }
            return (
                clear: try TrackedKeywordRefreshStatusStore.snapshot(
                    for: clearTrack,
                    in: context
                ).popularityMessage,
                newer: try TrackedKeywordRefreshStatusStore.snapshot(
                    for: newerTrack,
                    in: context
                ).popularityMessage,
                ranking: try TrackedKeywordRefreshStatusStore.snapshot(
                    for: rankingTrack,
                    in: context
                ).rankingMessage
            )
        }

        #expect(outcomes.isEmpty)
        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(persistedStatuses.clear == nil)
        #expect(persistedStatuses.newer == newerStatus)
        #expect(persistedStatuses.ranking == rankingStatus)
        #expect(freshnessFetchRecorder.snapshot() == [3])
    }

    @Test
    func sharedStaleQueryUsesOneProgressUnitAndSurvivingTrackForPersistence() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let firstApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "First",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        let secondApp = TrackedApp(
            appStoreID: 2,
            bundleID: nil,
            name: "Second",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(firstApp)
        modelContext.insert(secondApp)
        let firstTrack = try makeTrack(term: "shared stale", trackedApp: firstApp, in: modelContext)
        let secondTrack = try makeTrack(term: "shared stale", trackedApp: secondApp, in: modelContext)
        let staleStatus = "Popularity failed to fetch. Previous shared failure."
        firstTrack.statusMessage = staleStatus
        secondTrack.statusMessage = staleStatus
        try modelContext.save()

        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let representativeIdentityKey = min(firstTrack.identityKey, secondTrack.identityKey)
        let client = RemovingTrackHTTPClient(
            modelStore: backgroundModelStore,
            identityKeyToRemove: representativeIdentityKey
        )
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: freshnessFetchRecorder
        )

        let preparation = try await service.prepareStalePopularityRefresh(using: backgroundModelStore)
        let outcomes = try await service.refreshMetrics(
            for: preparation.trackIdentityKeys,
            using: backgroundModelStore
        )
        let persisted = try await backgroundModelStore.read { context in
            let tracks = try context.fetch(FetchDescriptor<TrackedAppKeyword>())
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            return (
                trackCount: tracks.count,
                statusMessage: tracks.first?.statusMessage,
                popularityScore: metrics.first?.popularityScore
            )
        }

        #expect(preparation.trackIdentityKeys.count == 2)
        #expect(preparation.refreshQueryCount == 1)
        #expect(preparation.clearedStatusCount == 0)
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.errorMessage == nil)
        #expect(persisted.trackCount == 1)
        #expect(persisted.statusMessage == nil)
        #expect(persisted.popularityScore == 63)
        #expect(freshnessFetchRecorder.snapshot() == [1, 1])
    }

    @Test
    func providerAuthenticationFailurePreservesNinetyTwoCachedMetrics() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let requestBodies = KeywordPopularityRequestRecorder()
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            requestBodies.record(try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body))
            return (
                Data(#"{"error":"forbidden"}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 403)
            )
        }
        let defaultsSuiteName = "KeywordMetricsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let namespace = AppNamespace(bundleIdentifier: defaultsSuiteName)
        let keychain = InMemoryKeychainService()
        let webSessionStore = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let session = completeWebSession
        try webSessionStore.save(session)
        let credentialStore = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        try saveTestCredentials(in: credentialStore)
        let service = KeywordMetricsService(
            httpClient: client,
            credentialStore: credentialStore,
            settingsStore: AppSettingsStore(defaults: defaults),
            webSessionStore: webSessionStore,
            apiClient: HTTPBackedSearchPopularityAPI(httpClient: client)
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let progressRecorder = KeywordMetricsProgressRecorder()
        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "App",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let staleUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -8, to: .now))
        var identityKeys: [String] = []
        var expectedScores: [String: Int] = [:]
        var expectedNotes: [String: String] = [:]
        var expectedStatuses: [String: String] = [:]
        var expectedFirstRequestTerms: [(identityKey: String, term: String)] = []

        for index in 0..<92 {
            let storefront = index < 46 ? "ca" : "us"
            let track = try makeTrack(
                term: "cached-\(index)",
                storefront: storefront,
                trackedApp: trackedApp,
                in: modelContext
            )
            let status = "Ranking failed to refresh. Cached sentinel \(index)."
            let note = "cached-note-\(index)"
            track.statusMessage = status
            identityKeys.append(track.identityKey)
            let score = 20 + (index % 70)
            expectedScores[track.queryKey] = score
            expectedNotes[track.queryKey] = note
            expectedStatuses[track.identityKey] = status
            if storefront == "ca" {
                expectedFirstRequestTerms.append((track.identityKey, track.term))
            }
            modelContext.insert(
                KeywordDailyMetric(
                    queryKey: track.queryKey,
                    keyword: track.term,
                    storefront: track.storefront,
                    platform: track.platform,
                    popularityScore: score,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    updatedAt: staleUpdatedAt,
                    notes: note
                )
            )
        }
        try modelContext.save()

        let result = try await service.refreshMetricsBatch(
            for: identityKeys,
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(
                    completed: completed,
                    total: total,
                    failureCount: failureCount
                )
            }
        )
        let repeatedResult = try await service.refreshMetricsBatch(
            for: identityKeys,
            using: backgroundModelStore
        )
        let storedState = try await backgroundModelStore.read { context in
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            let tracks = try context.fetch(FetchDescriptor<TrackedAppKeyword>())
            return (
                scores: Dictionary(uniqueKeysWithValues: metrics.map { ($0.queryKey, $0.popularityScore) }),
                updatedAt: Set(metrics.map(\.updatedAt)),
                notes: Dictionary(uniqueKeysWithValues: metrics.compactMap { metric in
                    metric.notes.map { (metric.queryKey, $0) }
                }),
                statuses: Dictionary(uniqueKeysWithValues: try tracks.compactMap { track in
                    try TrackedKeywordRefreshStatusStore.snapshot(
                        for: track,
                        in: context
                    ).rankingMessage.map { (track.identityKey, $0) }
                })
            )
        }
        let progressUpdates = await progressRecorder.snapshot()
        let requests = requestBodies.snapshot()

        #expect(requests.count == 4)
        #expect(requests.first?.storefronts == ["CA"])
        #expect(
            requests.first?.terms
                == expectedFirstRequestTerms.sorted { $0.identityKey < $1.identityKey }.map(\.term)
        )
        #expect(result.outcomes.count == 92)
        #expect(result.outcomes.allSatisfy { $0.errorMessage != nil && !$0.isSkipped })
        #expect(result.skippedCount == 0)
        #expect(result.batchErrors.isEmpty)
        #expect(result.failureCount == 92)
        #expect(repeatedResult.skippedCount == 0)
        #expect(repeatedResult.failureCount == 92)
        #expect(progressUpdates.first == .init(completed: 0, total: 92, failureCount: 0))
        #expect(progressUpdates.last == .init(completed: 92, total: 92, failureCount: 92))
        #expect(storedState.scores == expectedScores.mapValues(Optional.some))
        #expect(storedState.updatedAt == [staleUpdatedAt])
        #expect(storedState.notes == expectedNotes)
        #expect(storedState.statuses == expectedStatuses)
        #expect(!webSessionStore.requiresReconnect)
        #expect(webSessionStore.session == session)
    }

    @Test
    func cancelledBackgroundRefreshWithReconnectMarkerDoesNotReportCompletedSkips() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let requestCount = Mutex(0)
        let client = MockHTTPClient { request in
            requestCount.withLock { $0 += 1 }
            Issue.record("Unexpected Apple Ads request to \(request.url?.absoluteString ?? "unknown URL")")
            throw OpenASOError.providerUnavailable("Unexpected request")
        }
        let defaultsSuiteName = "KeywordMetricsServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let namespace = AppNamespace(bundleIdentifier: defaultsSuiteName)
        let keychain = InMemoryKeychainService()
        let webSessionStore = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let session = completeWebSession
        try webSessionStore.save(session)
        webSessionStore.markReconnectRequired(for: session)
        let service = KeywordMetricsService(
            httpClient: client,
            credentialStore: AppleAdsCredentialStore(
                defaults: defaults,
                keychain: keychain,
                namespace: namespace
            ),
            settingsStore: AppSettingsStore(defaults: defaults),
            webSessionStore: webSessionStore
        )
        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "App",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let track = try makeTrack(term: "cancelled", trackedApp: trackedApp, in: modelContext)
        track.statusMessage = "Ranking status must survive cancellation."
        try modelContext.save()
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)

        let refreshTask = Task {
            try await service.refreshMetricsBatch(
                for: [track.identityKey],
                using: backgroundModelStore
            )
        }
        refreshTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await refreshTask.value
        }
        #expect(requestCount.withLock { $0 } == 0)
        #expect(track.statusMessage == "Ranking status must survive cancellation.")
        #expect(try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>()).isEmpty)
    }

    @Test
    func cancelledForegroundPopularityRequestStopsLaterStorefrontsWithoutStatusWrites() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        var requestCount = 0
        let client = MockHTTPClient { _ in
            requestCount += 1
            throw CancellationError()
        }
        let services = AppServices.mocked(
            httpClient: client,
            modelContainer: container,
            appleAdsPlatformAPI: HTTPBackedSearchPopularityAPI(httpClient: client)
        )
        try saveTestCredentials(in: services.appleAdsCredentialStore)
        let trackedApp = TrackedApp(
            appStoreID: 1,
            bundleID: nil,
            name: "App",
            sellerName: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)
        let caTrack = try makeTrack(term: "first", storefront: "ca", trackedApp: trackedApp, in: modelContext)
        let usTrack = try makeTrack(term: "second", storefront: "us", trackedApp: trackedApp, in: modelContext)
        caTrack.statusMessage = "Ranking CA status"
        usTrack.statusMessage = "Ranking US status"
        try modelContext.save()

        let outcomes = await services.keywordMetricsService.refreshMetrics(
            for: trackedApp,
            tracks: [usTrack, caTrack],
            in: modelContext
        )

        #expect(outcomes.isEmpty)
        #expect(requestCount == 1)
        #expect(caTrack.statusMessage == "Ranking CA status")
        #expect(usTrack.statusMessage == "Ranking US status")
        #expect(try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>()).isEmpty)
    }

    @Test
    func backgroundRefreshFallsBackToPerQueryFreshnessAfterBulkFetchFailure() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let requestBodies = KeywordPopularityRequestRecorder()
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
            requestBodies.record(requestBody)
            let entries = requestBody.terms.map { term in
                #"{"name":"\#(term)","popularity":74}"#
            }.joined(separator: ",")
            return (
                Data(#"{"status":"success","data":[\#(entries)]}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: freshnessFetchRecorder,
            bulkFreshnessFetchHook: { throw ForcedBulkFreshnessFetchError() }
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let progressRecorder = KeywordMetricsProgressRecorder()
        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        modelContext.insert(trackedApp)
        let freshTrack = try makeTrack(term: "fresh-fallback", trackedApp: trackedApp, in: modelContext)
        let staleTrack = try makeTrack(term: "stale-fallback", trackedApp: trackedApp, in: modelContext)
        let missingTrack = try makeTrack(term: "missing-fallback", trackedApp: trackedApp, in: modelContext)
        let freshUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        let staleUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -8, to: .now))
        modelContext.insert(
            KeywordDailyMetric(
                queryKey: freshTrack.queryKey,
                keyword: freshTrack.term,
                storefront: freshTrack.storefront,
                platform: freshTrack.platform,
                popularityScore: 91,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: freshUpdatedAt
            )
        )
        modelContext.insert(
            KeywordDailyMetric(
                queryKey: staleTrack.queryKey,
                keyword: staleTrack.term,
                storefront: staleTrack.storefront,
                platform: staleTrack.platform,
                popularityScore: 12,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: staleUpdatedAt
            )
        )
        try modelContext.save()

        let outcomes = try await service.refreshMetrics(
            for: [freshTrack.identityKey, staleTrack.identityKey, missingTrack.identityKey],
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let progressUpdates = await progressRecorder.snapshot()
        let storedMetrics = try await backgroundModelStore.read { context in
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            return (
                scores: Dictionary(uniqueKeysWithValues: metrics.map { ($0.keyword, $0.popularityScore) }),
                updatedAt: Dictionary(uniqueKeysWithValues: metrics.map { ($0.keyword, $0.updatedAt) })
            )
        }
        let recordedRequests = requestBodies.snapshot()

        #expect(freshnessFetchRecorder.snapshot() == [3])
        #expect(recordedRequests.count == 1)
        #expect(Set(recordedRequests.first?.terms ?? []) == ["stale-fallback", "missing-fallback"])
        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(storedMetrics.scores["fresh-fallback"] == 91)
        #expect(storedMetrics.updatedAt["fresh-fallback"] == freshUpdatedAt)
        #expect(storedMetrics.scores["stale-fallback"] == 74)
        #expect(storedMetrics.scores["missing-fallback"] == 74)
        #expect(progressUpdates.map(\.completed) == [0, 1, 2, 3])
        #expect(progressUpdates.allSatisfy { $0.total == 3 && $0.failureCount == 0 })
    }

    @Test
    func backgroundRefreshDoesNotRequireLegacyContext() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
            let entries = requestBody.terms.map { term in
                #"{"name":"\#(term)","popularity":64}"#
            }.joined(separator: ",")
            return (
                Data(#"{"status":"success","data":[\#(entries)]}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(httpClient: client, freshnessFetchRecorder: freshnessFetchRecorder)
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let progressRecorder = KeywordMetricsProgressRecorder()
        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        modelContext.insert(trackedApp)
        let tracks = try (0..<24).map {
            try makeTrack(term: "missing-context-\($0)", trackedApp: trackedApp, in: modelContext)
        }
        try modelContext.save()

        let outcomes = try await service.refreshMetrics(
            for: tracks.map(\.identityKey),
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let progressUpdates = await progressRecorder.snapshot()
        let storedState = try await backgroundModelStore.read { context in
            let persistedTracks = try context.fetch(FetchDescriptor<TrackedAppKeyword>())
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            let statuses = try TrackedKeywordRefreshStatusStore.snapshots(
                for: persistedTracks.map(\.identityKey),
                in: context
            )
            return (
                statuses: statuses.values.compactMap(\.popularityMessage),
                metricCount: metrics.count,
                populatedMetricCount: metrics.compactMap(\.popularityScore).count
            )
        }

        #expect(outcomes.count == tracks.count)
        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(storedState.statuses.isEmpty)
        #expect(storedState.metricCount == tracks.count)
        #expect(storedState.populatedMetricCount == tracks.count)
        #expect(progressUpdates.count == tracks.count + 1)
        #expect(progressUpdates.last == .init(completed: tracks.count, total: tracks.count, failureCount: 0))
        #expect(freshnessFetchRecorder.snapshot() == [tracks.count])
    }

    @Test
    func backgroundRefreshPreservesMissingCredentialsOutcomes() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let client = MockHTTPClient { request in
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            throw OpenASOError.providerUnavailable("Unexpected request")
        }
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(
            httpClient: client,
            freshnessFetchRecorder: freshnessFetchRecorder,
            configuresCredentials: false
        )
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let progressRecorder = KeywordMetricsProgressRecorder()
        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        modelContext.insert(trackedApp)
        let tracks = try (0..<18).map {
            try makeTrack(term: "missing-credentials-\($0)", trackedApp: trackedApp, in: modelContext)
        }
        try modelContext.save()

        let outcomes = try await service.refreshMetrics(
            for: tracks.map(\.identityKey),
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let progressUpdates = await progressRecorder.snapshot()

        #expect(outcomes.count == tracks.count)
        #expect(outcomes.allSatisfy {
            $0.errorMessage?.contains("Configure and verify Apple Ads Platform API credentials") == true
        })
        #expect(progressUpdates.count == tracks.count + 1)
        #expect(progressUpdates.last == .init(completed: tracks.count, total: tracks.count, failureCount: tracks.count))
        #expect(freshnessFetchRecorder.snapshot() == [tracks.count])
    }

    @Test
    func backgroundRefreshPreservesProviderFailurePerStorefront() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let requestBodies = KeywordPopularityRequestRecorder()
        let client = MockHTTPClient { request in
            let body = try #require(request.httpBody)
            requestBodies.record(try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body))
            return (
                Data(#"{"error":{"errors":[{"message":"Temporary provider failure"}]}}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 503)
            )
        }
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(httpClient: client, freshnessFetchRecorder: freshnessFetchRecorder)
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let progressRecorder = KeywordMetricsProgressRecorder()
        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        modelContext.insert(trackedApp)
        let usTracks = try (0..<7).map {
            try makeTrack(term: "us-failure-\($0)", storefront: "us", trackedApp: trackedApp, in: modelContext)
        }
        let gbTracks = try (0..<5).map {
            try makeTrack(term: "gb-failure-\($0)", storefront: "gb", trackedApp: trackedApp, in: modelContext)
        }
        let tracks = usTracks + gbTracks
        try modelContext.save()

        let outcomes = try await service.refreshMetrics(
            for: tracks.map(\.identityKey),
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let progressUpdates = await progressRecorder.snapshot()

        #expect(outcomes.count == tracks.count)
        #expect(outcomes.allSatisfy { $0.errorMessage?.contains("HTTP 503") == true })
        #expect(requestBodies.snapshot().count == 2)
        #expect(Set(requestBodies.snapshot().flatMap(\.storefronts)) == ["US", "GB"])
        #expect(progressUpdates.count == tracks.count + 1)
        #expect(progressUpdates.last == .init(completed: tracks.count, total: tracks.count, failureCount: tracks.count))
        #expect(freshnessFetchRecorder.snapshot() == [tracks.count])
    }

    @Test
    func backgroundRefreshReportsTrackRemovedBeforePerItemPersistence() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        modelContext.insert(trackedApp)
        let removedTrack = try makeTrack(term: "removed", trackedApp: trackedApp, in: modelContext)
        let retainedTrack = try makeTrack(term: "retained", trackedApp: trackedApp, in: modelContext)
        try modelContext.save()
        let client = RemovingTrackHTTPClient(
            modelStore: backgroundModelStore,
            identityKeyToRemove: removedTrack.identityKey
        )
        let freshnessFetchRecorder = KeywordMetricsFreshnessFetchRecorder()
        let service = makeKeywordMetricsService(httpClient: client, freshnessFetchRecorder: freshnessFetchRecorder)
        let progressRecorder = KeywordMetricsProgressRecorder()

        let outcomes = try await service.refreshMetrics(
            for: [removedTrack.identityKey, retainedTrack.identityKey],
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let progressUpdates = await progressRecorder.snapshot()
        let stored = try await backgroundModelStore.read { context in
            let tracks = try context.fetch(FetchDescriptor<TrackedAppKeyword>())
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            return (trackTerms: Set(tracks.map(\.term)), metricScores: Dictionary(uniqueKeysWithValues: metrics.map { ($0.keyword, $0.popularityScore) }))
        }

        #expect(outcomes.count == 2)
        #expect(outcomes.filter { $0.errorMessage == OpenASOError.appNotFound.localizedDescription }.count == 1)
        #expect(outcomes.filter { $0.errorMessage == nil }.count == 1)
        #expect(stored.trackTerms == ["retained"])
        #expect(stored.metricScores["removed"] == nil)
        #expect(stored.metricScores["retained"] == 63)
        #expect(progressUpdates.count == 3)
        #expect(progressUpdates.last == .init(completed: 2, total: 2, failureCount: 1))
        #expect(freshnessFetchRecorder.snapshot() == [2])
    }

    @Test
    func popularityIndicatorStateIsExclusive() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 3, hour: 12)))
        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        modelContext.insert(trackedApp)

        let freshRow = makeRow(
            term: "fresh",
            trackedApp: trackedApp,
            modelContext: modelContext,
            popularityScore: 80,
            updatedAt: try #require(Calendar.current.date(byAdding: .day, value: -6, to: now)),
            statusMessage: nil
        )
        let staleUpdatedAt = try #require(Calendar.current.date(byAdding: .day, value: -7, to: now))
        let staleRow = makeRow(
            term: "stale",
            trackedApp: trackedApp,
            modelContext: modelContext,
            popularityScore: 70,
            updatedAt: staleUpdatedAt,
            statusMessage: "Popularity failed to fetch. Apple Ads web session expired. Refresh it in Settings."
        )
        let needsSetupRow = makeRow(
            term: "needs setup",
            trackedApp: trackedApp,
            modelContext: modelContext,
            popularityScore: nil,
            updatedAt: now,
            statusMessage: "Popularity failed to fetch. Connect an Apple Ads web session in Settings."
        )
        let unavailableMessage = "Popularity unavailable. Apple Ads returned no eligible row."
        let unavailableRow = makeRow(
            term: "unavailable",
            trackedApp: trackedApp,
            modelContext: modelContext,
            popularityScore: 65,
            updatedAt: staleUpdatedAt,
            statusMessage: unavailableMessage
        )

        #expect(freshRow.popularityIndicatorState(now: now) == .none)
        #expect(staleRow.popularityIndicatorState(now: now) == .stale(lastUpdatedAt: staleUpdatedAt))
        #expect(needsSetupRow.popularityIndicatorState(now: now) == .needsSetup(message: "Popularity failed to fetch. Connect an Apple Ads web session in Settings."))
        #expect(unavailableRow.displayedPopularityScore == nil)
        #expect(unavailableRow.popularitySortValue == -1)
        #expect(unavailableRow.popularityIndicatorState(now: now) == .unavailable(message: unavailableMessage))
    }

    private func makeRow(
        term: String,
        trackedApp: TrackedApp,
        modelContext: ModelContext,
        popularityScore: Int?,
        updatedAt: Date,
        statusMessage: String?
    ) -> KeywordWorkspaceRow {
        let query = try! KeywordQuery.fetchOrInsert(term: term, storefront: "us", platform: .iphone, in: modelContext)
        let track = TrackedAppKeyword(term: term, storefront: "us", platform: .iphone, trackedApp: trackedApp, query: query)
        track.statusMessage = statusMessage
        let metrics = KeywordDailyMetric(
            queryKey: track.queryKey,
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            popularityScore: popularityScore,
            difficultyScore: nil,
            source: .appleAdsPopularity,
            updatedAt: updatedAt
        )

        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)
        modelContext.insert(metrics)

        return KeywordWorkspaceRow(
            track: track,
            storefront: nil,
            metrics: metrics,
            latestSnapshot: Optional<KeywordRankingCrawlSummary>.none,
            trendSnapshots: [KeywordRankingCrawlSummary](),
            rankingApps: [KeywordRankingAppSummary]()
        )
    }

    private func makeTrack(
        term: String,
        storefront: String = "us",
        trackedApp: TrackedApp,
        in modelContext: ModelContext
    ) throws -> TrackedAppKeyword {
        let query = try KeywordQuery.fetchOrInsert(term: term, storefront: storefront, platform: .iphone, in: modelContext)
        let track = TrackedAppKeyword(term: term, storefront: storefront, platform: .iphone, trackedApp: trackedApp, query: query)
        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)
        return track
    }

    private func makeKeywordMetricsService(
        httpClient: HTTPClient,
        freshnessFetchRecorder: KeywordMetricsFreshnessFetchRecorder,
        configuresCredentials: Bool = true,
        bulkFreshnessFetchHook: @escaping @Sendable () throws -> Void = {}
    ) -> KeywordMetricsService {
        let api = HTTPBackedSearchPopularityAPI(httpClient: httpClient)
        let dependencies = AppServices.mocked(
            httpClient: httpClient,
            appleAdsPlatformAPI: api
        )
        if configuresCredentials {
            do {
                try saveTestCredentials(in: dependencies.appleAdsCredentialStore)
            } catch {
                preconditionFailure("Could not configure the in-memory Apple Ads test keychain: \(error)")
            }
        }
        return KeywordMetricsService(
            httpClient: httpClient,
            credentialStore: dependencies.appleAdsCredentialStore,
            settingsStore: dependencies.settingsStore,
            webSessionStore: dependencies.appleAdsWebSessionStore,
            apiClient: api,
            freshnessFetchObserver: freshnessFetchRecorder.record,
            bulkFreshnessFetchHook: bulkFreshnessFetchHook
        )
    }

    private func saveTestCredentials(in store: AppleAdsCredentialStore) throws {
        try store.saveAPICredentials(
            AppleAdsCredentials(
                clientID: "test-client",
                teamID: "test-team",
                keyID: "test-key",
                privateKey: Self.privateKey,
                adAccountID: "123456789"
            )
        )
    }

    private var completeWebSession: AppleAdsWebSession {
        AppleAdsWebSession(
            cookieHeader: "cookie=value; XSRF-TOKEN-CM=token",
            xsrfToken: "token",
            updatedAt: .now
        )
    }

    private func makePopularityTarget(
        term: String,
        storefront: String,
        platform: AppPlatform = .iphone,
        queryKey: String? = nil
    ) throws -> KeywordResearchTarget {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStorefront = storefront
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return KeywordResearchTarget(
            queryKey: queryKey ?? [
                "opaque-query",
                normalizedStorefront,
                platform.rawValue,
                normalizedTerm,
            ].joined(separator: "/"),
            term: normalizedTerm,
            storefront: normalizedStorefront,
            platform: platform
        )
    }

    private func makePopularityMetric(
        target: KeywordResearchTarget,
        popularityScore: Int?,
        difficultyScore: Int,
        updatedAt: Date,
        notes: String
    ) -> KeywordDailyMetric {
        KeywordDailyMetric(
            queryKey: target.queryKey,
            keyword: target.term,
            storefront: target.storefront,
            platform: target.platform,
            popularityScore: popularityScore,
            difficultyScore: difficultyScore,
            source: .appleAdsPopularity,
            popularityDate: "legacy_date",
            submissionCount: 3,
            winningCount: 2,
            confidence: "legacy_confidence",
            updatedAt: updatedAt,
            notes: notes
        )
    }

    private static let privateKey = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIM2/+v/sUp+rKfUFKSaY3cDxp3E9Azvop6KV9VmlWgJ+oAoGCCqGSM49
    AwEHoUQDQgAETxX0A2qcgToC8eMpiyHyaM6G3/pdF4LcTCOd6W++qk7nO0Yjhnf3
    +JXc/3El4VXTjD1ZNEqLxFWE1tLOktEQMg==
    -----END EC PRIVATE KEY-----
    """
}

private struct KeywordPopularityRequestBody: Decodable, Sendable {
    let storefronts: [String]
    let terms: [String]
}

private struct ForcedBulkFreshnessFetchError: Error {}

private struct AppIndependentPopularityStoredState: Equatable, Sendable {
    let metricCount: Int
    let queryCount: Int
    let trackedAppCount: Int
    let trackCount: Int
    let rankingStatus: String?
    let popularityStatus: String?
    let statsCount: Int
    let statsPopularity: Int?
    let statsDifficulty: Int?
}

private struct StoredPopularityMetric: Equatable, Sendable {
    let popularityScore: Int?
    let difficultyScore: Int?
    let updatedAt: Date
    let notes: String?
    let confidence: String?
}

private struct PopularityUpsertStoredState: Equatable, Sendable {
    let metrics: [String: StoredPopularityMetric]
    let trackedAppCount: Int
    let trackCount: Int
    let statsPopularity: Int?
    let statsDifficulty: Int?
}

private final class KeywordPopularityRequestRecorder: Sendable {
    private let requestBodies = Mutex<[KeywordPopularityRequestBody]>([])

    func record(_ requestBody: KeywordPopularityRequestBody) {
        requestBodies.withLock { $0.append(requestBody) }
    }

    func snapshot() -> [KeywordPopularityRequestBody] {
        requestBodies.withLock { $0 }
    }
}

private final class KeywordMetricsFreshnessFetchRecorder: Sendable {
    private let queryKeyCounts = Mutex<[Int]>([])

    func record(queryKeyCount: Int) {
        queryKeyCounts.withLock { $0.append(queryKeyCount) }
    }

    func snapshot() -> [Int] {
        queryKeyCounts.withLock { $0 }
    }
}

private actor KeywordMetricsProgressRecorder {
    struct Update: Equatable, Sendable {
        let completed: Int
        let total: Int
        let failureCount: Int
    }

    private var updates: [Update] = []

    func record(completed: Int, total: Int, failureCount: Int) {
        updates.append(Update(completed: completed, total: total, failureCount: failureCount))
    }

    func snapshot() -> [Update] {
        updates
    }
}

private actor SuspendedKeywordMetricsHTTPClient: HTTPClient {
    typealias Output = (Data, URLResponse)

    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingRequest: (
        request: URLRequest,
        continuation: CheckedContinuation<Output, any Error>
    )?

    func data(for request: URLRequest) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequest = (request, continuation)
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilRequestStarts() async {
        guard pendingRequest == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed() {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        let payload = #"{"status":"success","data":[{"name":"needs-refresh","popularity":63}]}"#
        pendingRequest.continuation.resume(returning: (
            Data(payload.utf8),
            makeHTTPURLResponse(url: pendingRequest.request.url!, statusCode: 200)
        ))
    }
}

private actor RemovingTrackHTTPClient: HTTPClient {
    private let modelStore: BackgroundModelStore
    private let identityKeyToRemove: String
    private var hasRemovedTrack = false

    init(modelStore: BackgroundModelStore, identityKeyToRemove: String) {
        self.modelStore = modelStore
        self.identityKeyToRemove = identityKeyToRemove
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if !hasRemovedTrack {
            let targetIdentityKey = identityKeyToRemove
            try await modelStore.write { modelContext in
                let descriptor = FetchDescriptor<TrackedAppKeyword>(
                    predicate: #Predicate { track in
                        track.identityKey == targetIdentityKey
                    }
                )
                if let track = try modelContext.fetch(descriptor).first {
                    modelContext.delete(track)
                }
            }
            hasRemovedTrack = true
        }

        let body = try #require(request.httpBody)
        let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
        let entries = requestBody.terms.map { term in
            "{\"name\":\"\(term)\",\"popularity\":63}"
        }.joined(separator: ",")
        let response = "{\"status\":\"success\",\"data\":[\(entries)]}"
        return (
            Data(response.utf8),
            makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
        )
    }
}

private actor GatedKeywordPopularityHTTPClient: HTTPClient {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releasePending = false
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedRequestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequestCount += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if releasePending {
            releasePending = false
        } else {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        let body = try #require(request.httpBody)
        let requestBody = try JSONDecoder().decode(KeywordPopularityRequestBody.self, from: body)
        let entries = requestBody.terms.map { term in
            #"{"name":"\#(term)","popularity":65}"#
        }.joined(separator: ",")
        return (
            Data(#"{"status":"success","data":[\#(entries)]}"#.utf8),
            makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
        )
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed() {
        guard let releaseContinuation else {
            releasePending = true
            return
        }
        self.releaseContinuation = nil
        releaseContinuation.resume()
    }

    func requestCount() -> Int {
        recordedRequestCount
    }
}

struct StaticAppleAdsPlatformAPI: AppleAdsPlatformAPI {
    let coverage = AppleAdsPlatformCoverage.current
    let apps: [AppleAdsPromotedApp]
    var popularityRows: [AppleAdsSearchTermPopularity] = []

    func verify(credentials: AppleAdsCredentials) async throws -> AppleAdsPlatformConnection {
        AppleAdsPlatformConnection(
            userID: 1,
            orgID: 2,
            accounts: [
                AppleAdsPlatformAccount(
                    id: Int64(credentials.adAccountID) ?? 12_345,
                    name: "Test account",
                    orgID: 2,
                    roles: ["API Account Manager"]
                )
            ],
            selectedAdAccountID: Int64(credentials.adAccountID) ?? 12_345
        )
    }

    func searchOwnedApps(
        named query: String?,
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPromotedApp] {
        Array(apps.prefix(limit))
    }

    func listCampaigns(
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPlatformCampaignSummary] {
        []
    }

    func searchTermPopularity(
        for searchTerms: [String],
        countryOrRegion: String,
        window: AppleAdsSearchTermPopularityWindow,
        using credentials: AppleAdsCredentials
    ) async throws -> [AppleAdsSearchTermPopularity] {
        popularityRows.filter {
            $0.countryOrRegion.caseInsensitiveCompare(countryOrRegion) == .orderedSame
                && searchTerms.map(AppleAdsSearchTermPopularity.normalized)
                    .contains($0.normalizedSearchTerm)
        }
    }
}

struct FailingSearchPopularityAPI: AppleAdsPlatformAPI {
    let coverage = AppleAdsPlatformCoverage.current
    let error: OpenASOError

    func verify(credentials: AppleAdsCredentials) async throws -> AppleAdsPlatformConnection {
        throw error
    }

    func searchOwnedApps(
        named query: String?,
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPromotedApp] {
        throw error
    }

    func listCampaigns(
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPlatformCampaignSummary] {
        throw error
    }

    func searchTermPopularity(
        for searchTerms: [String],
        countryOrRegion: String,
        window: AppleAdsSearchTermPopularityWindow,
        using credentials: AppleAdsCredentials
    ) async throws -> [AppleAdsSearchTermPopularity] {
        throw error
    }
}

/// Keeps the pre-existing persistence/concurrency fixtures useful while the
/// production service uses only Apple's official client. This adapter exists
/// solely in the test target and translates the fixture's historical HTTP
/// response into the new public Search Term Popularity model.
struct HTTPBackedSearchPopularityAPI: AppleAdsPlatformAPI {
    let coverage = AppleAdsPlatformCoverage.current
    let httpClient: any HTTPClient

    func verify(credentials: AppleAdsCredentials) async throws -> AppleAdsPlatformConnection {
        AppleAdsPlatformConnection(
            userID: 1,
            orgID: 2,
            accounts: [
                AppleAdsPlatformAccount(
                    id: Int64(credentials.adAccountID) ?? 123_456_789,
                    name: "Fixture account",
                    orgID: 2,
                    roles: ["API Account Manager"]
                )
            ],
            selectedAdAccountID: Int64(credentials.adAccountID) ?? 123_456_789
        )
    }

    func searchOwnedApps(
        named query: String?,
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPromotedApp] {
        []
    }

    func listCampaigns(
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPlatformCampaignSummary] {
        []
    }

    func searchTermPopularity(
        for searchTerms: [String],
        countryOrRegion: String,
        window: AppleAdsSearchTermPopularityWindow,
        using credentials: AppleAdsCredentials
    ) async throws -> [AppleAdsSearchTermPopularity] {
        let scores = try await AppleAdsCMPopularityClient(httpClient: httpClient)
            .keywordPopularities(
                for: searchTerms,
                storefrontCode: countryOrRegion,
                adamId: Int64(credentials.adAccountID) ?? 123_456_789,
                session: AppleAdsWebSession(
                    cookieHeader: "cookie=value; XSRF-TOKEN-CM=token",
                    xsrfToken: "token",
                    updatedAt: .now
                )
            )
        return scores.map { normalizedTerm, score in
            AppleAdsSearchTermPopularity(
                searchTerm: searchTerms.first {
                    AppleAdsSearchTermPopularity.normalized($0) == normalizedTerm
                } ?? normalizedTerm,
                countryOrRegion: countryOrRegion.uppercased(),
                genre: "Fixture",
                week: window.end,
                month: nil,
                rankInGenre: nil,
                popularityInGenre: score,
                popularity1to100: score,
                popularity1to5: nil
            )
        }
    }
}
