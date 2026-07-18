import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct AppStorefrontRatingServiceTests {
    @Test
    func parserReadsRatingCountAndAverageFromAppStoreText() throws {
        let html = """
        <html><body>
          <section>
            <figcaption>4.8 out of 5</figcaption>
            <p>6.8M Ratings</p>
          </section>
        </body></html>
        """

        let parsed = try #require(AppStorefrontRatingParser().parse(html: html))

        #expect(parsed.averageRating == 4.8)
        #expect(parsed.ratingCount == 6_800_000)
    }

    @Test
    func parserReadsRatingCountAndAverageFromAppStoreStructuredData() throws {
        let html = """
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "SoftwareApplication",
          "name": "ChatGPT",
          "aggregateRating": {
            "@type": "AggregateRating",
            "ratingValue": 4.8,
            "reviewCount": 6790079
          }
        }
        </script>
        """

        let parsed = try #require(AppStorefrontRatingParser().parse(html: html))

        #expect(parsed.averageRating == 4.8)
        #expect(parsed.ratingCount == 6_790_079)
    }

    @Test
    func parserReadsRatingCountsFromSerializedAppStoreData() throws {
        let html = """
        <script type="application/ld+json">
        {"aggregateRating":{"ratingValue":4.7,"reviewCount":17850696}}
        </script>
        <script type="application/json" id="serialized-server-data">
        {"data":[{"data":{"shelfMapping":{"productRatings":{"items":[{"ratingAverage":4.7,"totalNumberOfRatings":17850696,"ratingCounts":[15083006,1395200,539852,237702,594936]}]}}}}]}
        </script>
        """

        let parsed = try #require(AppStorefrontRatingParser().parse(html: html))

        #expect(parsed.ratingCounts?.fiveStar == 15_083_006)
        #expect(parsed.ratingCounts?.fourStar == 1_395_200)
        #expect(parsed.ratingCounts?.threeStar == 539_852)
        #expect(parsed.ratingCounts?.twoStar == 237_702)
        #expect(parsed.ratingCounts?.oneStar == 594_936)
    }

    @Test
    func parserReadsAttenAppBlockerRatingFromCurrentAppStoreShape() throws {
        let html = """
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"SoftwareApplication","name":"Atten - App Blocker","aggregateRating":{"@type":"AggregateRating","ratingValue":4.7,"reviewCount":151}}
        </script>
        <section id="productRatings">
          <div data-testid="amp-rating__average-rating">4.7</div>
          <div data-testid="amp-rating__total-text">out of 5</div>
          <div data-testid="amp-rating__rating-count-text">151 Ratings</div>
        </section>
        """

        let parsed = try #require(AppStorefrontRatingParser().parse(html: html))

        #expect(parsed.averageRating == 4.7)
        #expect(parsed.ratingCount == 151)
    }

    @Test
    func parserReadsCanonicalStorefrontFromAppStoreHTML() throws {
        let html = """
        <html><head>
          <link rel="canonical" href="https://apps.apple.com/ae/app/atten-app-blocker/id6608976383">
          <meta property="og:url" content="https://apps.apple.com/ae/app/atten-app-blocker/id6608976383">
        </head></html>
        """

        let storefront = AppStorefrontRatingParser().storefrontCode(html: html, responseURL: nil)

        #expect(storefront == "ae")
    }

    @Test
    func ratingDateUsesNoonUTCCutoff() {
        let beforeCutoff = makeUTCDate(year: 2026, month: 4, day: 29, hour: 11, minute: 59)
        let atCutoff = makeUTCDate(year: 2026, month: 4, day: 29, hour: 12, minute: 0)

        #expect(LatestAppRating.ratingDateString(for: beforeCutoff) == "2026-04-28")
        #expect(LatestAppRating.ratingDateString(for: atCutoff) == "2026-04-29")
    }

    @Test
    func refreshReviewsStoresUnknownReviewsOnPageBeforeStoppingAfterKnownReview() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6_448_311_069,
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            sellerName: "OpenAI",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)
        modelContext.insert(
            AppStorefrontReview(
                appStoreID: storeApp.appStoreID,
                storefront: "us",
                reviewID: "9003",
                reviewerName: "Existing User",
                title: "Already stored",
                content: "This review is already in the local store.",
                rating: 3,
                reviewedAt: try #require(Self.reviewDate("2026-04-29T09:00:00-07:00")),
                storeApp: storeApp
            )
        )

        var requestedPages: [Int] = []
        let client = MockHTTPClient { request in
            let url = try #require(request.url)
            let path = url.path
            let page = path.contains("page=1") ? 1 : path.contains("page=2") ? 2 : 3
            requestedPages.append(page)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

            let payload: String
            switch page {
            case 1:
                payload = Self.reviewFeedJSON(entries: [
                    Self.reviewEntryJSON(id: "9001", author: "Maya", title: "Great app", content: "Helpful every day.", rating: 5, updated: "2026-05-01T12:00:00-07:00", version: "1.2026.120"),
                    Self.reviewEntryJSON(id: "9002", author: "Jordan", title: "Good", content: "Works well for research.", rating: 4, updated: "2026-04-30T12:00:00-07:00", version: "1.2026.120")
                ])
            case 2:
                payload = Self.reviewFeedJSON(entries: [
                    Self.reviewEntryJSON(id: "9004", author: "Priya", title: "Newer than stored", content: "This review should be saved before stopping.", rating: 5, updated: "2026-04-29T10:00:00-07:00", version: "1.2026.120"),
                    Self.reviewEntryJSON(id: "9003", author: "Existing User", title: "Already stored", content: "This review is already in the local store.", rating: 3, updated: "2026-04-29T09:00:00-07:00", version: nil)
                ])
            default:
                Issue.record("Review refresh should stop after the known review on page 2.")
                payload = Self.reviewFeedJSON(entries: [])
            }

            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let service = AppStorefrontReviewService(httpClient: client)

        let outcomes = await service.refreshReviews(for: storeApp, storefronts: ["US"], in: modelContext)
        let reviews = try modelContext.fetch(FetchDescriptor<AppStorefrontReview>())

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.error == nil)
        #expect(outcomes.first?.fetchedReviews == 4)
        #expect(outcomes.first?.storedReviews == 3)
        #expect(requestedPages == [1, 2])
        #expect(reviews.count == 4)
        #expect(reviews.first(where: { $0.reviewID == "9001" })?.reviewerName == "Maya")
        #expect(reviews.first(where: { $0.reviewID == "9001" })?.content == "Helpful every day.")
        #expect(reviews.first(where: { $0.reviewID == "9001" })?.rating == 5)
        #expect(reviews.first(where: { $0.reviewID == "9004" })?.reviewerName == "Priya")
    }

    @Test
    func refreshRatingsStoresLatestAndSnapshotPerStorefront() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6448311069,
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            sellerName: "OpenAI",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)

        let client = MockHTTPClient { request in
            #expect(request.url?.absoluteString == "https://itunes.apple.com/lookup?id=6448311069&country=us")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json,text/javascript,*/*;q=0.8")
            let payload = """
            {
              "resultCount": 1,
              "results": [
                {
                  "trackId": 6448311069,
                  "averageUserRating": 4.9,
                  "userRatingCount": 123400
                }
              ]
            }
            """
            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = AppStorefrontRatingService(httpClient: client)

        let outcomes = await service.refreshRatings(for: storeApp, storefronts: ["US"], in: modelContext)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.error == nil)

        let latest = try modelContext.fetch(FetchDescriptor<LatestAppRating>())
        let snapshots = try modelContext.fetch(FetchDescriptor<AppDailyRating>())

        #expect(latest.count == 1)
        #expect(latest.first?.storefront == "us")
        #expect(latest.first?.ratingCount == 123_400)
        #expect(latest.first?.averageRating == 4.9)
        #expect(latest.first?.source == .iTunesSearch)
        #expect(snapshots.count == 1)
    }

    @Test
    func refreshRatingsTreatsLookupMissAsUnavailableStorefrontNotFailure() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6_480_417_616,
            bundleID: "com.example.regional",
            name: "Regional App",
            sellerName: "Example",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)
        modelContext.insert(LatestAppRating(
            appStoreID: storeApp.appStoreID,
            storefront: "ru",
            ratingCount: 10,
            averageRating: 4.1,
            storeApp: storeApp
        ))
        modelContext.insert(AppDailyRating(
            appStoreID: storeApp.appStoreID,
            storefront: "ru",
            ratingCount: 10,
            averageRating: 4.1,
            storeApp: storeApp
        ))
        try modelContext.save()

        var requestedURLs: [String] = []
        let progressRecorder = RatingProgressRecorder()
        let client = MockHTTPClient { request in
            requestedURLs.append(try #require(request.url?.absoluteString))
            let payload = """
            {
              "resultCount": 0,
              "results": []
            }
            """
            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = AppStorefrontRatingService(httpClient: client)

        let outcomes = await service.refreshRatings(
            for: storeApp,
            storefronts: ["RU"],
            in: modelContext,
            progress: { completed, total, failureCount in
                await progressRecorder.record(completed: completed, total: total, failureCount: failureCount)
            }
        )

        #expect(requestedURLs == ["https://itunes.apple.com/lookup?id=6480417616&country=ru"])
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.storefront == "ru")
        #expect(outcomes.first?.result == nil)
        #expect(outcomes.first?.error == nil)
        #expect(outcomes.first?.unavailabilityReason == "App 6480417616 is not available in RU.")
        #expect(await progressRecorder.failureCounts == [0, 0])
        #expect(try modelContext.fetch(FetchDescriptor<LatestAppRating>()).isEmpty)
        #expect(try modelContext.fetch(FetchDescriptor<AppDailyRating>()).isEmpty)
    }

    @Test
    func refreshRatingsStoresAttenAppBlockerResult() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6_608_976_383,
            bundleID: "com.thirdtech.limited",
            name: "Atten - App Blocker",
            sellerName: "Third tech",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)

        let client = MockHTTPClient { request in
            #expect(request.url?.absoluteString == "https://itunes.apple.com/lookup?id=6608976383&country=us")
            let payload = """
            {
              "resultCount": 1,
              "results": [
                {
                  "trackId": 6608976383,
                  "averageUserRating": 4.72848,
                  "userRatingCount": 151
                }
              ]
            }
            """
            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = AppStorefrontRatingService(httpClient: client)

        let outcomes = await service.refreshRatings(for: storeApp, storefronts: ["us"], in: modelContext)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.result?.ratingCount == 151)
        #expect(outcomes.first?.result?.averageRating == 4.72848)
        #expect(outcomes.first?.result?.source == .iTunesSearch)

        let latest = try #require(try modelContext.fetch(FetchDescriptor<LatestAppRating>()).first)
        #expect(latest.appStoreID == 6_608_976_383)
        #expect(latest.storefront == "us")
        #expect(latest.ratingCount == 151)
        #expect(latest.averageRating == 4.72848)
        #expect(latest.source == .iTunesSearch)
    }

    @Test
    func refreshRatingsRetriesRateLimitedFetchAndStoresSuccessfulRetry() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6_497_229_487,
            bundleID: "com.wisprflow.keyboard",
            name: "Wispr Flow",
            sellerName: "Wispr AI",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)

        var attempts = 0
        let client = MockHTTPClient { request in
            attempts += 1
            #expect(request.url?.absoluteString == "https://itunes.apple.com/lookup?id=6497229487&country=id")

            if attempts == 1 {
                return (
                    Data("rate limited".utf8),
                    makeHTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 429,
                        headerFields: ["Retry-After": "0"]
                    )
                )
            }

            let payload = """
            {
              "resultCount": 1,
              "results": [
                {
                  "trackId": 6497229487,
                  "averageUserRating": 4.9,
                  "userRatingCount": 42
                }
              ]
            }
            """
            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = AppStorefrontRatingService(httpClient: makeRatingRetryGate(base: client))

        let outcomes = await service.refreshRatings(for: storeApp, storefronts: ["id"], in: modelContext)

        #expect(attempts == 2)
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.error == nil)
        #expect(outcomes.first?.result?.ratingCount == 42)
        #expect(outcomes.first?.result?.averageRating == 4.9)
        #expect(outcomes.first?.result?.source == .iTunesSearch)
        let latest = try #require(try modelContext.fetch(FetchDescriptor<LatestAppRating>()).first)
        #expect(latest.storefront == "id")
        #expect(latest.ratingCount == 42)
    }

    @Test
    func refreshRatingsStopsAfterRetryLimitForRateLimits() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6_497_229_487,
            bundleID: "com.wisprflow.keyboard",
            name: "Wispr Flow",
            sellerName: "Wispr AI",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)

        var attempts = 0
        let client = MockHTTPClient { request in
            attempts += 1
            #expect([
                "https://itunes.apple.com/lookup?id=6497229487&country=id",
                "https://apps.apple.com/id/app/id6497229487?l=en-US"
            ].contains(request.url?.absoluteString))
            return (
                Data("rate limited".utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 429)
            )
        }
        let service = AppStorefrontRatingService(httpClient: makeRatingRetryGate(base: client))

        let outcomes = await service.refreshRatings(for: storeApp, storefronts: ["id"], in: modelContext)

        #expect(attempts == 4)
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.result == nil)
        #expect(outcomes.first?.error == .rateLimited)
        #expect(try modelContext.fetch(FetchDescriptor<LatestAppRating>()).isEmpty)
    }

    @Test
    func refreshRatingsWithoutGateRequestsEachSourceOnceForRateLimits() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6_497_229_487,
            bundleID: "com.wisprflow.keyboard",
            name: "Wispr Flow",
            sellerName: "Wispr AI",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)

        var requestedURLs: [String] = []
        let client = MockHTTPClient { request in
            requestedURLs.append(try #require(request.url?.absoluteString))
            return (
                Data("rate limited".utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 429)
            )
        }
        let service = AppStorefrontRatingService(httpClient: client)

        let outcomes = await service.refreshRatings(for: storeApp, storefronts: ["id"], in: modelContext)

        #expect(requestedURLs == [
            "https://itunes.apple.com/lookup?id=6497229487&country=id",
            "https://apps.apple.com/id/app/id6497229487?l=en-US"
        ])
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.result == nil)
        #expect(outcomes.first?.error == .rateLimited)
        #expect(try modelContext.fetch(FetchDescriptor<LatestAppRating>()).isEmpty)
    }

    @Test
    func refreshRatingsRejectsRedirectedStorefrontAndClearsStaleRows() async throws {
        let container = try makeRatingContainer()
        let modelContext = ModelContext(container)
        let storeApp = StoreApp(
            appStoreID: 6_608_976_383,
            bundleID: "com.thirdtech.limited",
            name: "Atten - App Blocker",
            sellerName: "Third tech",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)
        modelContext.insert(LatestAppRating(
            appStoreID: storeApp.appStoreID,
            storefront: "ad",
            ratingCount: 151,
            averageRating: 4.7,
            storeApp: storeApp
        ))
        modelContext.insert(AppDailyRating(
            appStoreID: storeApp.appStoreID,
            storefront: "ad",
            ratingCount: 151,
            averageRating: 4.7,
            storeApp: storeApp
        ))
        try modelContext.save()

        var requestURLs: [String] = []
        let client = MockHTTPClient { request in
            requestURLs.append(try #require(request.url?.absoluteString))
            if request.url?.host == "itunes.apple.com" {
                let payload = """
                {
                  "resultCount": 1,
                  "results": [
                    {
                      "trackId": 6608976383
                    }
                  ]
                }
                """
                return (
                    Data(payload.utf8),
                    makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
                )
            }

            #expect(request.url?.absoluteString == "https://apps.apple.com/ad/app/id6608976383?l=en-US")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            let payload = """
            <html><head>
              <link rel="canonical" href="https://apps.apple.com/us/app/atten-app-blocker/id6608976383">
              <meta property="og:url" content="https://apps.apple.com/us/app/atten-app-blocker/id6608976383">
            </head><body>
              <script type="application/ld+json">
              {"@context":"https://schema.org","@type":"SoftwareApplication","aggregateRating":{"@type":"AggregateRating","ratingValue":4.7,"reviewCount":151}}
              </script>
            </body></html>
            """
            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let service = AppStorefrontRatingService(httpClient: client)

        let outcomes = await service.refreshRatings(for: storeApp, storefronts: ["ad"], in: modelContext)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.storefront == "ad")
        #expect(outcomes.first?.result == nil)
        #expect(outcomes.first?.error != nil)
        #expect(requestURLs == [
            "https://itunes.apple.com/lookup?id=6608976383&country=ad",
            "https://apps.apple.com/ad/app/id6608976383?l=en-US"
        ])
        #expect(try modelContext.fetch(FetchDescriptor<LatestAppRating>()).isEmpty)
        #expect(try modelContext.fetch(FetchDescriptor<AppDailyRating>()).isEmpty)
    }

    private static func reviewFeedJSON(entries: [String]) -> String {
        """
        {
          "feed": {
            "entry": [
              \(entries.joined(separator: ",\n"))
            ]
          }
        }
        """
    }

    private static func reviewEntryJSON(
        id: String,
        author: String,
        title: String,
        content: String,
        rating: Int,
        updated: String,
        version: String?
    ) -> String {
        let versionField = version.map { #","im:version":{"label":"\#($0)"}"# } ?? ""
        return """
        {
          "author": { "name": { "label": "\(author)" } },
          "updated": { "label": "\(updated)" },
          "im:rating": { "label": "\(rating)" },
          "id": { "label": "\(id)" },
          "title": { "label": "\(title)" },
          "content": { "label": "\(content)" }
          \(versionField)
        }
        """
    }

    private static func reviewDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private func makeRatingContainer() throws -> ModelContainer {
    let schema = Schema([
        AppFolder.self,
        AppKeywordStats.self,
        LatestAppRating.self,
        AppDailyRating.self,
        AppStorefrontReview.self,
        StoreApp.self,
        AppStorefrontMetadata.self,
        AppStoreScreenshot.self,
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

private func makeUTCDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    )) ?? Date(timeIntervalSince1970: 0)
}

private actor RatingProgressRecorder {
    private var recordedValues: [(completed: Int, total: Int, failureCount: Int)] = []

    func record(completed: Int, total: Int, failureCount: Int) {
        recordedValues.append((completed, total, failureCount))
    }

    var failureCounts: [Int] {
        recordedValues.map(\.failureCount)
    }
}

private func makeRatingRetryGate(base: any HTTPClient) -> ProviderRequestGate {
    let policy = ProviderRequestPolicy(
        minimumIntervalNanoseconds: 0,
        maximumAttempts: 2,
        baseBackoffNanoseconds: 0,
        maximumBackoffNanoseconds: 0,
        maximumElapsedNanoseconds: 1_000_000_000,
        jitterFraction: 0
    )
    return ProviderRequestGate(
        base: base,
        policies: ProviderRequestPolicies(default: policy)
    )
}
