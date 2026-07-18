import Foundation
import SwiftData
import Synchronization
import Testing
@testable import OpenASO

@MainActor
struct KeywordMetricsServiceTests {
    @Test
    func failedRefreshPreservesExistingPopularityScoreAndUpdatedAt() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                let payload = """
                <html><body>Sign in</body></html>
                """
                return (
                    Data(payload.utf8),
                    makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
                )
            },
            modelContainer: container
        )
        services.settingsStore.savePopularityContextAppStoreID(123_456_789)
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(cookieHeader: "cookie=value; XSRF-TOKEN-CM=token", xsrfToken: "token", updatedAt: .now)
        )

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
        try modelContext.save()

        _ = await services.keywordMetricsService.refreshMetrics(for: trackedApp, tracks: [track], in: modelContext)

        #expect(metrics.popularityScore == 72)
        #expect(metrics.updatedAt == previousUpdatedAt)
        #expect(track.statusMessage == "Popularity failed to fetch. Apple Ads web session expired. Refresh it in Settings.")
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
        #expect(track.statusMessage == "Popularity failed to fetch. Reconnect Apple Ads in Settings so OpenASO can detect a linked app.")
    }

    @Test
    func resolveDefaultAppleAdsAppReturnsFirstCampaignLinkedApp() async throws {
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                let url = try #require(request.url)
                if url.host == "appleid.apple.com" {
                    return (
                        Data(#"{"access_token":"token"}"#.utf8),
                        makeHTTPURLResponse(url: url, statusCode: 200)
                    )
                }

                if url.path == "/api/v5/acls" {
                    return (
                        Data(#"{"data":[{"orgId":12345}]}"#.utf8),
                        makeHTTPURLResponse(url: url, statusCode: 200)
                    )
                }

                if url.path == "/api/v5/campaigns" {
                    #expect(request.value(forHTTPHeaderField: "X-AP-Context") == "orgId=12345")
                    let payload = """
                    {
                      "data": [
                        {
                          "adamId": 6448311069,
                          "appName": "Atten",
                          "countriesOrRegions": ["US"],
                          "deleted": false
                        }
                      ]
                    }
                    """
                    return (
                        Data(payload.utf8),
                        makeHTTPURLResponse(url: url, statusCode: 200)
                    )
                }

                Issue.record("Unexpected request to \(url.absoluteString)")
                throw OpenASOError.providerUnavailable("Unexpected request")
            }
        )

        let app = try await services.keywordMetricsService.resolveDefaultAppleAdsApp(
            using: AppleAdsCredentials(
                clientID: "client",
                teamID: "team",
                keyID: "key",
                privateKey: Self.privateKey,
                orgID: ""
            )
        )

        #expect(app.adamId == 6_448_311_069)
        #expect(app.appName == "Atten")
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
            modelContainer: container
        )
        services.settingsStore.savePopularityContextAppStoreID(123_456_789)
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(cookieHeader: "cookie=value; XSRF-TOKEN-CM=token", xsrfToken: "token", updatedAt: .now)
        )

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
    func unsupportedAppleAdsStorefrontDoesNotAskForSetup() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                (
                    Data(#"{"error":{"errors":[{"message":"Bad request"}]}}"#.utf8),
                    makeHTTPURLResponse(url: try #require(request.url), statusCode: 400)
                )
            },
            modelContainer: container
        )
        services.settingsStore.savePopularityContextAppStoreID(123_456_789)
        try services.appleAdsWebSessionStore.save(
            AppleAdsWebSession(cookieHeader: "cookie=value; XSRF-TOKEN-CM=token", xsrfToken: "token", updatedAt: .now)
        )

        let trackedApp = TrackedApp(appStoreID: 1, bundleID: nil, name: "App", sellerName: nil, defaultPlatform: .iphone)
        let query = try KeywordQuery.fetchOrInsert(term: "focus app", storefront: "ao", platform: .iphone, in: modelContext)
        let track = TrackedAppKeyword(term: "focus app", storefront: "ao", platform: .iphone, trackedApp: trackedApp, query: query)
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        _ = await services.keywordMetricsService.refreshMetrics(for: trackedApp, tracks: [track], in: modelContext)

        #expect(track.statusMessage == "Popularity unavailable. Apple Ads does not support keyword popularity in Angola.")
        let storedMetrics = try #require(try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>()).first)
        let row = KeywordWorkspaceRow(
            track: track,
            storefront: nil,
            metrics: storedMetrics,
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
            popularityContextAppStoreID: 123_456_789,
            webSession: AppleAdsWebSession(cookieHeader: "cookie=value; XSRF-TOKEN-CM=token", xsrfToken: "token", updatedAt: .now),
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
            popularityContextAppStoreID: 123_456_789,
            webSession: completeWebSession,
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let storedScores = try await backgroundModelStore.read { context in
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            return Dictionary(uniqueKeysWithValues: metrics.map { ($0.keyword, $0.popularityScore) })
        }
        let progressUpdates = await progressRecorder.snapshot()
        let recordedRequests = requestBodies.snapshot()

        #expect(outcomes.count == terms.count)
        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(recordedRequests.count == 1)
        #expect(recordedRequests.first?.storefronts == ["US"])
        #expect(Set(recordedRequests.first?.terms ?? []) == Set(terms).subtracting(freshTerms))
        #expect(freshTerms.allSatisfy { storedScores[$0] == 91 })
        #expect(Set(terms).subtracting(freshTerms).allSatisfy { storedScores[$0] == 74 })
        #expect(progressUpdates.count == terms.count + 1)
        #expect(progressUpdates.first == .init(completed: 0, total: terms.count, failureCount: 0))
        #expect(progressUpdates.last == .init(completed: terms.count, total: terms.count, failureCount: 0))
        #expect(freshnessFetchRecorder.snapshot() == [terms.count])
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
            popularityContextAppStoreID: 123_456_789,
            webSession: completeWebSession,
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
    func backgroundRefreshPreservesMissingContextOutcomesWithoutProviderRequests() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let client = MockHTTPClient { request in
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            throw OpenASOError.providerUnavailable("Unexpected request")
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
            popularityContextAppStoreID: nil,
            webSession: completeWebSession,
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let progressUpdates = await progressRecorder.snapshot()
        let storedState = try await backgroundModelStore.read { context in
            let persistedTracks = try context.fetch(FetchDescriptor<TrackedAppKeyword>())
            let metrics = try context.fetch(FetchDescriptor<KeywordDailyMetric>())
            return (
                statuses: persistedTracks.compactMap(\.statusMessage),
                metricCount: metrics.count,
                populatedMetricCount: metrics.compactMap(\.popularityScore).count
            )
        }

        #expect(outcomes.count == tracks.count)
        #expect(outcomes.allSatisfy { $0.errorMessage?.contains("Reconnect Apple Ads") == true })
        #expect(storedState.statuses.count == tracks.count)
        #expect(storedState.metricCount == tracks.count)
        #expect(storedState.populatedMetricCount == 0)
        #expect(progressUpdates.count == tracks.count + 1)
        #expect(progressUpdates.last == .init(completed: tracks.count, total: tracks.count, failureCount: tracks.count))
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
        let service = makeKeywordMetricsService(httpClient: client, freshnessFetchRecorder: freshnessFetchRecorder)
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
            popularityContextAppStoreID: 123_456_789,
            webSession: nil,
            using: backgroundModelStore,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )
        let progressUpdates = await progressRecorder.snapshot()

        #expect(outcomes.count == tracks.count)
        #expect(outcomes.allSatisfy { $0.errorMessage?.contains("Connect an Apple Ads web session") == true })
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
            popularityContextAppStoreID: 123_456_789,
            webSession: completeWebSession,
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
            popularityContextAppStoreID: 123_456_789,
            webSession: completeWebSession,
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

        #expect(freshRow.popularityIndicatorState(now: now) == .none)
        #expect(staleRow.popularityIndicatorState(now: now) == .stale(lastUpdatedAt: staleUpdatedAt))
        #expect(needsSetupRow.popularityIndicatorState(now: now) == .needsSetup(message: "Popularity failed to fetch. Connect an Apple Ads web session in Settings."))
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
        bulkFreshnessFetchHook: @escaping @Sendable () throws -> Void = {}
    ) -> KeywordMetricsService {
        let dependencies = AppServices.mocked(httpClient: httpClient)
        return KeywordMetricsService(
            httpClient: httpClient,
            credentialStore: dependencies.appleAdsCredentialStore,
            settingsStore: dependencies.settingsStore,
            webSessionStore: dependencies.appleAdsWebSessionStore,
            freshnessFetchObserver: freshnessFetchRecorder.record,
            bulkFreshnessFetchHook: bulkFreshnessFetchHook
        )
    }

    private var completeWebSession: AppleAdsWebSession {
        AppleAdsWebSession(
            cookieHeader: "cookie=value; XSRF-TOKEN-CM=token",
            xsrfToken: "token",
            updatedAt: .now
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
