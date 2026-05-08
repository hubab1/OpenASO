import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct OpenASOMCPServiceTests {
    @Test
    func listAppsHandlesEmptyWorkspace() async throws {
        let service = try makeService()

        let page = try await service.listApps()

        #expect(page.items.isEmpty)
        #expect(page.total == 0)
        #expect(page.nextCursor == nil)
    }

    @Test
    func searchAndAddTrackedAppUseResolverAndReturnMutationSummaries() async throws {
        let resolved = makeResolvedApp(appStoreID: 123, name: "Focus Timer", subtitle: "Deep work")
        let resolver = StubMCPAppResolver(resolvedApps: [123: resolved], searchResults: [resolved])
        let service = try makeService(resolver: resolver)

        let searchResults = try await service.searchAppStoreApps(query: " focus ", storefront: " GB ", limit: 10)
        #expect(searchResults.map(\.name) == ["Focus Timer"])
        #expect(searchResults.first?.appStoreID == "123")

        let inserted = try await service.addTrackedApp(appStoreID: 123, storefront: " GB ")
        #expect(inserted.summary.inserted == 1)
        #expect(inserted.summary.updated == 0)
        #expect(inserted.app.defaultStorefront == "gb")
        #expect(inserted.app.name == "Focus Timer")

        let updated = try await service.addTrackedApp(appStoreID: 123, storefront: "us")
        #expect(updated.summary.inserted == 0)
        #expect(updated.summary.updated == 1)
        #expect(updated.app.appStoreID == "123")
        #expect(updated.app.defaultStorefront == "us")
    }

    @Test
    func addKeywordsSkipsDuplicatesAndUpdatesOnlyMatchingNotes() async throws {
        let context = try MCPTestContext()
        let service = context.service
        try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer")

        let first = try await service.addKeywords(
            appStoreID: 123,
            keywords: ["focus timer", "Focus Timer", "pomodoro"],
            storefronts: ["US", "us", "gb"],
            platform: "iphone"
        )
        #expect(first.summary.inserted == 4)
        #expect(first.summary.skipped == 0)
        #expect(Set(first.inserted.map(\.storefront)) == ["gb", "us"])
        #expect(Set(first.inserted.map(\.keyword)) == ["focus timer", "pomodoro"])

        let second = try await service.addKeywords(
            appStoreID: 123,
            keywords: ["pomodoro", "habit tracker"],
            storefronts: ["us"],
            platform: "iphone"
        )
        #expect(second.summary.inserted == 1)
        #expect(second.summary.skipped == 1)
        #expect(second.skipped == [
            OpenASOMCPSkippedKeyword(keyword: "pomodoro", storefront: "us", platform: "iphone", reason: "already_tracked")
        ])

        let notes = try await service.updateKeywordNotes(
            appStoreID: 123,
            keyword: "pomodoro",
            storefront: "US",
            platform: "iphone",
            notes: "Prioritize after review refresh."
        )
        #expect(notes.summary.updated == 1)
        #expect(notes.track.notes == "Prioritize after review refresh.")
        #expect(notes.track.keyword == "pomodoro")
        #expect(notes.track.storefront == "us")
    }

    @Test
    func listReviewsFiltersAndPaginatesNewestFirst() async throws {
        let context = try MCPTestContext()
        let service = context.service
        let storeApp = try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer").storeApp
        try context.insertReviews(
            for: storeApp,
            [
                ReviewSeed(id: "old-us", storefront: "us", rating: 2, version: "1.0", reviewedAt: isoDate("2026-01-01T10:00:00Z")),
                ReviewSeed(id: "new-us", storefront: "us", rating: 5, version: "2.0", reviewedAt: isoDate("2026-03-01T10:00:00Z")),
                ReviewSeed(id: "gb-mid", storefront: "gb", rating: 4, version: "2.0", reviewedAt: isoDate("2026-02-01T10:00:00Z"))
            ]
        )

        let firstPage = try await service.listReviews(
            appStoreID: 123,
            storefronts: ["us", "gb"],
            ratingMin: 4,
            version: "2.0",
            page: OpenASOMCPPageRequest(limit: 1, cursor: nil)
        )
        #expect(firstPage.items.map(\.reviewID) == ["new-us"])
        #expect(firstPage.nextCursor == "1")
        #expect(firstPage.total == 2)

        let secondPage = try await service.listReviews(
            appStoreID: 123,
            storefronts: ["us", "gb"],
            ratingMin: 4,
            version: "2.0",
            page: OpenASOMCPPageRequest(limit: 1, cursor: firstPage.nextCursor)
        )
        #expect(secondPage.items.map(\.reviewID) == ["gb-mid"])
        #expect(secondPage.nextCursor == nil)
    }

    @Test
    func refreshReviewsCapsTargetAppReviewsPerStorefront() async throws {
        let context = try MCPTestContext(includeReviewService: true, httpHandler: { request in
            let url = request.url!
            if url.absoluteString.contains("/rss/customerreviews/") {
                return (makeReviewsFeed(reviewCount: 650), makeHTTPURLResponse(url: url, statusCode: 200))
            }
            return (Data(), makeHTTPURLResponse(url: url, statusCode: 200))
        })
        try context.insertStoreApp(appStoreID: 123, name: "Cal AI")

        let refresh = try await context.service.refreshReviews(
            appStoreID: 123,
            storefronts: ["us"],
            limitPerStorefront: 5
        )

        #expect(refresh.summary.inserted == 5)
        #expect(refresh.summary.refreshed == 5)
        #expect(refresh.reviewLimitPerStorefront == 5)
        #expect(refresh.outcomes.first?.fetchedReviews == 5)
        #expect(refresh.outcomes.first?.storedReviews == 5)
        #expect(refresh.outcomes.first?.reachedLimit == true)
        #expect(refresh.notes.contains { $0.contains("per-storefront cap") })

        let repeatedRefresh = try await context.service.refreshReviews(
            appStoreID: 123,
            storefronts: ["us"],
            limitPerStorefront: 5
        )
        #expect(repeatedRefresh.summary.inserted == 0)
        #expect(repeatedRefresh.summary.refreshed == 5)

        let reviews = try await context.service.listReviews(
            appStoreID: 123,
            storefronts: ["us"],
            page: OpenASOMCPPageRequest(limit: 10, cursor: nil)
        )
        #expect(reviews.total == 5)
    }

    @Test
    func refreshReviewsDefaultsToUSStorefront() async throws {
        let context = try MCPTestContext(includeReviewService: true, httpHandler: { request in
            let url = request.url!
            if url.absoluteString.contains("/rss/customerreviews/") {
                #expect(url.absoluteString.contains("cc=us"))
                return (makeReviewsFeed(reviewCount: 1), makeHTTPURLResponse(url: url, statusCode: 200))
            }
            return (Data(), makeHTTPURLResponse(url: url, statusCode: 200))
        })
        try context.insertStoreApp(appStoreID: 123, name: "Cal AI")

        let refresh = try await context.service.refreshReviews(appStoreID: 123, limitPerStorefront: 5)

        #expect(refresh.reviewLimitPerStorefront == 5)
        #expect(refresh.outcomes.map(\.storefront) == ["us"])
        #expect(refresh.summary.inserted == 1)
    }

    @Test
    func downloadAllReviewsPersistsEveryBatchUntilPagesAreExhausted() async throws {
        let context = try MCPTestContext(includeReviewService: true, httpHandler: { request in
            let url = request.url!
            if url.absoluteString.contains("/rss/customerreviews/") {
                if url.absoluteString.contains("page=1") {
                    return (makeReviewsFeed(reviewCount: 2, startIndex: 1), makeHTTPURLResponse(url: url, statusCode: 200))
                }
                if url.absoluteString.contains("page=2") {
                    return (makeReviewsFeed(reviewCount: 2, startIndex: 3), makeHTTPURLResponse(url: url, statusCode: 200))
                }
                return (makeReviewsFeed(reviewCount: 0), makeHTTPURLResponse(url: url, statusCode: 200))
            }
            return (Data(), makeHTTPURLResponse(url: url, statusCode: 200))
        })
        try context.insertStoreApp(appStoreID: 123, name: "Cal AI")

        let download = try await context.service.downloadAllReviews(
            appStoreID: 123,
            storefronts: ["us"],
            batchPageCount: 1
        )

        #expect(download.batchPageCount == 1)
        #expect(download.summary.inserted == 4)
        #expect(download.summary.refreshed == 4)
        #expect(download.outcomes.first?.batchCount == 2)
        #expect(download.outcomes.first?.exhausted == true)

        let reviews = try await context.service.listReviews(
            appStoreID: 123,
            storefronts: ["us"],
            page: OpenASOMCPPageRequest(limit: 10, cursor: nil)
        )
        #expect(reviews.total == 4)
    }

    @Test
    func downloadAllReviewsPersistsPartialBatchWhenLaterPageFails() async throws {
        let context = try MCPTestContext(includeReviewService: true, httpHandler: { request in
            let url = request.url!
            if url.absoluteString.contains("/rss/customerreviews/") {
                if url.absoluteString.contains("page=1") {
                    return (makeReviewsFeed(reviewCount: 2, startIndex: 1), makeHTTPURLResponse(url: url, statusCode: 200))
                }
                return (Data(), makeHTTPURLResponse(url: url, statusCode: 500))
            }
            return (Data(), makeHTTPURLResponse(url: url, statusCode: 200))
        })
        try context.insertStoreApp(appStoreID: 123, name: "Cal AI")

        let download = try await context.service.downloadAllReviews(
            appStoreID: 123,
            storefronts: ["us"],
            batchPageCount: 5
        )

        #expect(download.summary.inserted == 2)
        #expect(download.summary.refreshed == 2)
        #expect(download.summary.failed == 1)
        #expect(download.outcomes.first?.fetchedReviews == 2)
        #expect(download.outcomes.first?.storedReviews == 2)
        #expect(download.outcomes.first?.batchCount == 1)
        #expect(download.outcomes.first?.exhausted == false)
        #expect(download.outcomes.first?.error != nil)

        let reviews = try await context.service.listReviews(
            appStoreID: 123,
            storefronts: ["us"],
            page: OpenASOMCPPageRequest(limit: 10, cursor: nil)
        )
        #expect(reviews.total == 2)
    }

    @Test
    func listScreenshotsFiltersByStorefrontAndPlatform() async throws {
        let context = try MCPTestContext()
        let service = context.service
        let storeApp = try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer").storeApp
        try context.insertScreenshots(for: storeApp)

        let screenshots = try await service.listScreenshots(
            appStoreID: 123,
            storefronts: ["US"],
            platform: "iphone"
        )

        #expect(screenshots.total == 2)
        #expect(screenshots.items.map(\.urlString) == [
            "https://example.com/us-iphone-1.png",
            "https://example.com/us-iphone-2.png"
        ])
        #expect(screenshots.items.allSatisfy { $0.storefront == "us" && $0.platform == "iphone" })
    }

    @Test
    func exportScreenshotsCreatesDestinationDirectoryWhenMissing() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("openaso-mcp-missing-screenshot-test-\(UUID().uuidString)", isDirectory: true)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let context = try MCPTestContext(screenshotDataProvider: { url in
            (imageBytes, makeHTTPURLResponse(
                url: url,
                statusCode: 200,
                headerFields: ["Content-Type": "image/png"]
            ))
        })
        let storeApp = try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer").storeApp
        try context.insertScreenshots(for: storeApp)

        let export = try await context.service.exportScreenshots(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone",
            destinationDirectoryPath: destination.path
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(export.summary.refreshed == 2)
        #expect(export.failed.isEmpty)
        #expect(export.completed.allSatisfy { FileManager.default.fileExists(atPath: $0.filePath) })
    }

    @Test
    func scoreKeywordsClassifiesTrackedKeywordsForTriage() async throws {
        let context = try MCPTestContext()
        let storeApp = try context.insertTrackedApp(appStoreID: 123, name: "ScreenZen").storeApp
        let screenTime = try context.insertKeyword("screen time control", trackedApp: storeApp, storefront: "us")
        _ = try context.insertKeyword("after certain", trackedApp: storeApp, storefront: "us")
        let brand = try context.insertKeyword("screenzen screen time", trackedApp: storeApp, storefront: "us")
        try context.insertRankingCrawl(
            keyword: screenTime.term,
            query: screenTime.query,
            storefront: "us",
            observedAt: isoDate("2026-05-01T10:00:00Z"),
            rows: [
                RankingRow(position: 1, appStoreID: 123, name: "ScreenZen"),
                RankingRow(position: 2, appStoreID: 456, name: "Competitor")
            ]
        )
        try context.insertDailyRanking(track: screenTime, rank: 1, resultCount: 2)
        try context.insertRankingCrawl(
            keyword: brand.term,
            query: brand.query,
            storefront: "us",
            observedAt: isoDate("2026-05-01T10:00:00Z"),
            rows: [
                RankingRow(position: 1, appStoreID: 123, name: "ScreenZen")
            ]
        )
        try context.insertDailyRanking(track: brand, rank: 1, resultCount: 1)

        let result = try await context.service.scoreKeywords(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone"
        )

        #expect(result.summary.totalCount == 3)
        #expect(result.items.first { $0.keyword == "screen time control" }?.priority == "defend")
        #expect(result.items.first { $0.keyword == "screenzen screen time" }?.priority == "brand")
        #expect(result.items.first { $0.keyword == "after certain" }?.priority == "noisy")
    }

    @Test
    func localizationResearchContextReturnsMetadataAndScreenshotComparisons() async throws {
        let context = try MCPTestContext()
        let target = try context.insertTrackedApp(appStoreID: 100, name: "Focus Timer").storeApp
        target.supportedLanguageCodes = ["EN", "FR"]
        target.supportedLanguageCodesSource = .iTunesLookup
        target.supportedLanguageCodesFetchedAt = isoDate("2026-05-01T00:00:00Z")
        let competitor = try context.insertStoreApp(appStoreID: 200, name: "Structured")
        competitor.supportedLanguageCodes = ["EN", "FR", "DE"]
        try context.insertLocalizationMetadata(
            for: target,
            storefront: "us",
            name: "Focus Timer",
            subtitle: "Block distractions",
            description: "Focus timer and app blocker.",
            screenshotURLs: ["https://example.com/target-us-1.png", "https://example.com/shared.png"]
        )
        try context.insertLocalizationMetadata(
            for: target,
            storefront: "fr",
            name: "Minuteur Focus",
            subtitle: "Bloquer les distractions",
            description: "Minuteur et blocage d'apps.",
            screenshotURLs: ["https://example.com/target-fr-1.png", "https://example.com/shared.png"]
        )
        try context.insertLocalizationMetadata(
            for: competitor,
            storefront: "us",
            name: "Structured",
            subtitle: "Daily planner",
            description: "Plan your day.",
            screenshotURLs: ["https://example.com/competitor-us-1.png"]
        )
        try context.insertLocalizationMetadata(
            for: competitor,
            storefront: "fr",
            name: "Structured",
            subtitle: "Planificateur quotidien",
            description: "Planifiez votre jour.",
            screenshotURLs: ["https://example.com/competitor-fr-1.png"]
        )
        let track = try context.insertKeyword("focus timer", trackedApp: target, storefront: "us")
        try context.insertRankingCrawl(
            keyword: track.term,
            query: track.query,
            storefront: "us",
            observedAt: isoDate("2026-05-01T10:00:00Z"),
            rows: [
                RankingRow(position: 1, appStoreID: competitor.appStoreID, name: competitor.name),
                RankingRow(position: 2, appStoreID: target.appStoreID, name: target.name)
            ]
        )

        let result = try await context.service.getLocalizationResearchContext(
            appStoreID: 100,
            storefronts: ["us", "fr"],
            platform: "iphone",
            competitorLimit: 1,
            refreshMissingMetadata: false
        )

        #expect(result.baselineStorefront == "us")
        #expect(result.apps.map(\.role) == ["target", "competitor"])
        let targetContext = try #require(result.apps.first { $0.role == "target" })
        #expect(targetContext.supportedLanguageCodes == ["EN", "FR"])
        let french = try #require(targetContext.storefronts.first { $0.storefront == "fr" })
        #expect(french.languageCode == "fr-FR")
        #expect(french.comparison.nameDiffersFromUS)
        #expect(french.comparison.subtitleDiffersFromUS)
        #expect(french.comparison.descriptionDiffersFromUS)
        let screenshotComparison = try #require(french.screenshotComparisons.first { $0.displayType == "phone" })
        #expect(screenshotComparison.screenshotURLsDifferFromUS)
        #expect(screenshotComparison.screenshotURLAddedCount == 1)
        #expect(screenshotComparison.screenshotURLRemovedCount == 1)
        #expect(screenshotComparison.screenshotURLSharedCount == 1)
        #expect(screenshotComparison.hasStorefrontScreenshots)
        #expect(screenshotComparison.hasBaselineScreenshots)
    }

    @Test
    func localizationResearchContextRefreshesMissingMetadataWhenEnabled() async throws {
        let localized = ResolvedApp(
            appStoreID: 123,
            bundleID: "com.example.123",
            name: "Fokus Timer",
            subtitle: "Ablenkungen blockieren",
            sellerName: "Example Seller",
            supportedLanguageCodes: ["EN", "DE"],
            screenshotURLs: ["https://example.com/de-1.png"],
            defaultPlatform: .iphone
        )
        let resolver = StubMCPAppResolver(
            resolvedApps: [123: makeResolvedApp(appStoreID: 123, name: "Focus Timer")],
            storefrontResolvedApps: ["123::de": localized]
        )
        let context = try MCPTestContext(resolver: resolver)
        let target = try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer").storeApp
        try context.insertLocalizationMetadata(
            for: target,
            storefront: "us",
            name: "Focus Timer",
            subtitle: "Block distractions",
            description: "Focus timer and app blocker.",
            screenshotURLs: ["https://example.com/us-1.png"]
        )

        let result = try await context.service.getLocalizationResearchContext(
            appStoreID: 123,
            storefronts: ["de"],
            platform: "iphone",
            competitorLimit: 1,
            refreshMissingMetadata: true
        )

        #expect(result.errors.isEmpty)
        let targetContext = try #require(result.apps.first { $0.role == "target" })
        let german = try #require(targetContext.storefronts.first { $0.storefront == "de" })
        #expect(german.metadata?.name == "Fokus Timer")
        #expect(german.comparison.nameDiffersFromUS)
        #expect(german.screenshotComparisons.first?.screenshotURLsDifferFromUS == true)
    }

    @Test
    func localizationResearchContextReportsMissingMetadataWhenRefreshDisabled() async throws {
        let context = try MCPTestContext()
        let target = try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer").storeApp
        try context.insertLocalizationMetadata(
            for: target,
            storefront: "us",
            name: "Focus Timer",
            subtitle: "Block distractions",
            description: "Focus timer and app blocker.",
            screenshotURLs: ["https://example.com/us-1.png"]
        )

        let result = try await context.service.getLocalizationResearchContext(
            appStoreID: 123,
            storefronts: ["de"],
            platform: "iphone",
            refreshMissingMetadata: false
        )

        let targetContext = try #require(result.apps.first { $0.role == "target" })
        let german = try #require(targetContext.storefronts.first { $0.storefront == "de" })
        #expect(german.metadata == nil)
        #expect(german.notes.contains("No storefront metadata is stored for de."))
        #expect(result.notes.contains("Missing storefront metadata was not refreshed because refresh_missing_metadata was false."))
    }

    @Test
    func fetchWebsiteMarkdownUsesMarkdownNewAndDoesNotPersistResult() async throws {
        let context = try MCPTestContext(httpHandler: { request in
            #expect(request.url?.absoluteString == "https://markdown.new/https://example.com/privacy")
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/markdown,text/plain,*/*")
            let data = Data("# Privacy\n\nNo tracking.".utf8)
            return (data, makeHTTPURLResponse(url: request.url!, statusCode: 200))
        })

        let result = try await context.service.fetchWebsiteMarkdown(urlString: " https://example.com/privacy ")

        #expect(result.sourceURLString == "https://example.com/privacy")
        #expect(result.markdownURLString == "https://markdown.new/https://example.com/privacy")
        #expect(result.markdown.contains("No tracking."))
        #expect(result.byteCount > 0)
    }

    @Test
    func detectAppAndFetchAppWebsiteMarkdownSupportInteractiveOnboarding() async throws {
        let resolved = makeResolvedApp(
            appStoreID: 123,
            name: "Cal AI",
            subtitle: "AI calorie tracker",
            sellerURLString: "https://calai.app",
            trackViewURLString: "https://apps.apple.com/us/app/cal-ai/id123"
        )
        let resolver = StubMCPAppResolver(resolvedApps: [123: resolved], searchResults: [resolved])
        let context = try MCPTestContext(resolver: resolver, httpHandler: { request in
            #expect(request.url?.absoluteString == "https://markdown.new/https://calai.app")
            let data = Data("# Cal AI\n\nPhoto calorie tracking, macros, fasting, and weight loss plans.".utf8)
            return (data, makeHTTPURLResponse(url: request.url!, statusCode: 200))
        })

        let detection = try await context.service.detectApp(query: "Cal AI", storefront: "US", limit: 5)

        #expect(detection.recommendedAppStoreID == "123")
        #expect(detection.requiresConfirmation == true)
        #expect(detection.confirmationPrompt.contains("Cal AI"))

        let website = try await context.service.fetchAppWebsiteMarkdown(appStoreID: 123, storefront: "US")

        #expect(website.selectedURLString == "https://calai.app")
        #expect(website.markdownResult?.markdown.contains("Photo calorie tracking") == true)
        #expect(website.discoveredURLs == ["https://calai.app"])
    }

    @Test
    func fetchAppWebsiteMarkdownFallsBackToAppStoreSupportAndPrivacyLinks() async throws {
        let resolved = makeResolvedApp(
            appStoreID: 123,
            name: "Cal AI",
            trackViewURLString: "https://apps.apple.com/us/app/cal-ai/id123"
        )
        let resolver = StubMCPAppResolver(resolvedApps: [123: resolved])
        let context = try MCPTestContext(resolver: resolver, httpHandler: { request in
            if request.url?.absoluteString == "https://apps.apple.com/us/app/cal-ai/id123" {
                let html = """
                <html>
                  <body>
                    <a href="https://example.com/support">App Support</a>
                    <a href="https://example.com/privacy">Privacy Policy</a>
                    <a href="https://apps.apple.com/us/app/cal-ai/id123">App Store</a>
                    <img src="https://is1-ssl.mzstatic.com/image/thumb/test.png">
                  </body>
                </html>
                """
                return (Data(html.utf8), makeHTTPURLResponse(url: request.url!, statusCode: 200))
            }
            #expect(request.url?.absoluteString == "https://markdown.new/https://example.com/support")
            let markdown = "# Support\n\nContact Cal AI support."
            return (Data(markdown.utf8), makeHTTPURLResponse(url: request.url!, statusCode: 200))
        })

        let website = try await context.service.fetchAppWebsiteMarkdown(appStoreID: 123, storefront: "US")

        #expect(website.selectedURLString == "https://example.com/support")
        #expect(website.markdownResult?.markdown.contains("Cal AI support") == true)
        #expect(website.discoveredURLs == ["https://example.com/support", "https://example.com/privacy"])
    }

    @Test
    func fetchAppWebsiteMarkdownReturnsStatusWhenNoPublicWebsiteExists() async throws {
        let resolved = makeResolvedApp(
            appStoreID: 123,
            name: "Cal AI",
            trackViewURLString: "https://apps.apple.com/us/app/cal-ai/id123"
        )
        let resolver = StubMCPAppResolver(resolvedApps: [123: resolved])
        let context = try MCPTestContext(resolver: resolver, httpHandler: { request in
            #expect(request.url?.absoluteString == "https://apps.apple.com/us/app/cal-ai/id123")
            let html = """
            <html>
              <body>
                <a href="https://apps.apple.com/us/app/cal-ai/id123">App Store</a>
                <img src="https://is1-ssl.mzstatic.com/image/thumb/test.png">
              </body>
            </html>
            """
            return (Data(html.utf8), makeHTTPURLResponse(url: request.url!, statusCode: 200))
        })

        let website = try await context.service.fetchAppWebsiteMarkdown(appStoreID: 123, storefront: "US")

        #expect(website.selectedURLString == nil)
        #expect(website.markdownResult == nil)
        #expect(website.discoveredURLs.isEmpty)
        #expect(website.statusMessage?.contains("No public seller") == true)
    }

    @Test
    func listCompetitorsDerivesRankEvidenceFromSharedKeywordCrawls() async throws {
        let context = try MCPTestContext()
        let service = context.service
        let target = try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer").storeApp
        _ = try context.insertStoreApp(appStoreID: 456, name: "Structured", sellerName: "Structured GmbH")
        _ = try context.insertStoreApp(appStoreID: 789, name: "TickTick", sellerName: "Appest")

        let focusTrack = try context.insertKeyword("focus timer", trackedApp: target, storefront: "us")
        let pomodoroTrack = try context.insertKeyword("pomodoro", trackedApp: target, storefront: "us")
        try context.insertRankingCrawl(
            keyword: "focus timer",
            query: focusTrack.query,
            storefront: "us",
            observedAt: isoDate("2026-05-01T10:00:00Z"),
            rows: [
                RankingRow(position: 1, appStoreID: 456, name: "Structured"),
                RankingRow(position: 2, appStoreID: 123, name: "Focus Timer"),
                RankingRow(position: 3, appStoreID: 789, name: "TickTick")
            ]
        )
        try context.insertRankingCrawl(
            keyword: "pomodoro",
            query: pomodoroTrack.query,
            storefront: "us",
            observedAt: isoDate("2026-05-02T10:00:00Z"),
            rows: [
                RankingRow(position: 1, appStoreID: 789, name: "TickTick"),
                RankingRow(position: 2, appStoreID: 456, name: "Structured"),
                RankingRow(position: 8, appStoreID: 123, name: "Focus Timer")
            ]
        )

        let competitors = try await service.listCompetitors(appStoreID: 123, storefronts: ["US"], platform: "iphone", limit: 10)

        #expect(competitors.map(\.appStoreID) == ["456", "789"])
        #expect(competitors.first?.name == "Structured")
        #expect(competitors.first?.sharedKeywordCount == 2)
        #expect(competitors.first?.occurrenceCount == 2)
        #expect(competitors.first?.bestRank == 1)
        #expect(competitors.first?.evidence.map(\.keyword) == ["focus timer", "pomodoro"])
        #expect(competitors.allSatisfy { $0.appStoreID != "123" })

        let capped = try await service.listCompetitors(
            appStoreID: 123,
            storefronts: ["US"],
            platform: "iphone",
            limit: 10,
            evidenceLimit: 1
        )
        #expect(capped.first?.sharedKeywordCount == 2)
        #expect(capped.first?.evidence.count == 1)
    }

    @Test
    func suggestKeywordsUsesMetadataAndLiveRankingEvidenceForUntrackedApp() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 456, name: "MyFitnessPal", ratingCount: 3_000_000),
                makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback),
            "ai calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 123, name: "Cal AI", ratingCount: 50_000),
                makeRankingItem(position: 2, appStoreID: 789, name: "Macro AI", ratingCount: 25_000)
            ], source: .iTunesFallback)
        ])
        let context = try MCPTestContext(rankingProvider: rankingProvider, useRankingRefreshCoordinator: true)
        let service = context.service
        let storeApp = try context.insertStoreApp(appStoreID: 123, name: "Cal AI", sellerName: "Viral Development")
        try context.insertMetadata(
            for: storeApp,
            storefront: "us",
            description: "AI calorie tracker with photo meal scanning, macro tracking, nutrition breakdown, and weight loss plans."
        )

        let result = try await service.suggestKeywords(appStoreID: 123, storefronts: ["us"], limit: 10)

        #expect(result.app.isTracked == false)
        #expect(result.errors.isEmpty)
        #expect(result.candidates.contains { $0.keyword == "calorie tracker" && $0.targetRank == 2 })
        #expect(result.candidates.contains { $0.keyword == "ai calorie tracker" && $0.targetRank == 1 })
        #expect(result.candidates.first?.topRatedAppCount ?? 0 > 0)
    }

    @Test
    func suggestKeywordsKeepsPartialResultsWhenOneSeedFails() async throws {
        let rankingProvider = StubMCPRankingProvider(
            pages: [
                "calorie tracker::us::iphone": SearchRankingPage(items: [
                    makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
                ], source: .iTunesFallback)
            ],
            failures: [
                "ai calorie tracker::us::iphone": OpenASOError.networkUnavailable
            ]
        )
        let context = try MCPTestContext(rankingProvider: rankingProvider, useRankingRefreshCoordinator: true)
        let storeApp = try context.insertStoreApp(appStoreID: 123, name: "Cal AI", sellerName: "Viral Development")
        try context.insertMetadata(
            for: storeApp,
            storefront: "us",
            description: "AI calorie tracker with photo meal scanning and calorie tracking."
        )

        let result = try await context.service.suggestKeywords(appStoreID: 123, storefronts: ["us"], limit: 10)

        #expect(result.candidates.contains { $0.keyword == "calorie tracker" })
        #expect(result.errors.contains { $0.keyword == "ai calorie tracker" && $0.error.code == "network_unavailable" })
    }

    @Test
    func suggestKeywordsUsesEphemeralWebsiteMarkdownSeeds() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "fasting tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 456, name: "Zero", ratingCount: 700_000),
                makeRankingItem(position: 3, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback)
        ])
        let context = try MCPTestContext(rankingProvider: rankingProvider)
        let storeApp = try context.insertStoreApp(appStoreID: 123, name: "Cal AI", sellerName: "Viral Development")
        try context.insertMetadata(
            for: storeApp,
            storefront: "us",
            description: "AI calorie tracker with photo meal scanning."
        )

        let result = try await context.service.suggestKeywords(
            appStoreID: 123,
            storefronts: ["us"],
            limit: 10,
            websiteMarkdown: "Cal AI supports fasting tracker workflows, intermittent fasting plans, and weight loss coaching."
        )

        #expect(result.candidates.contains {
            $0.keyword == "fasting tracker"
                && $0.sources.contains("website_markdown")
                && $0.targetRank == 3
        })
    }

    @Test
    func getRankedAppsForKeywordReturnsTargetRankAndBigAppSignal() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 456, name: "MyFitnessPal", ratingCount: 3_000_000),
                makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback)
        ])
        let context = try MCPTestContext(rankingProvider: rankingProvider)

        let result = try await context.service.getRankedAppsForKeyword(
            keyword: "calorie tracker",
            storefront: "US",
            targetAppStoreID: 123,
            limit: 10
        )

        #expect(result.targetRank == 2)
        #expect(result.topRatedAppCount == 2)
        #expect(result.maximumRatingCount == 3_000_000)
        #expect(result.topApps.map(\.name) == ["MyFitnessPal", "Cal AI"])
    }

    @Test
    func discoverKeywordLandscapeAggregatesCompetitorsFromVerifiedKeywords() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 456, name: "MyFitnessPal", ratingCount: 3_000_000),
                makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback),
            "ai calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 123, name: "Cal AI", ratingCount: 50_000),
                makeRankingItem(position: 2, appStoreID: 456, name: "MyFitnessPal", ratingCount: 3_000_000)
            ], source: .iTunesFallback)
        ])
        let context = try MCPTestContext(rankingProvider: rankingProvider)
        let storeApp = try context.insertTrackedApp(appStoreID: 123, name: "Cal AI").storeApp
        try context.insertMetadata(
            for: storeApp,
            storefront: "us",
            description: "AI calorie tracker with photo meal scanning, calorie tracking, and nutrition plans."
        )

        let result = try await context.service.discoverKeywordLandscape(
            appStoreID: 123,
            storefronts: ["us"],
            keywordLimit: 10,
            competitorLimit: 3,
            includeReviews: false
        )

        #expect(result.verifiedKeywords.contains { $0.keyword == "calorie tracker" })
        #expect(result.verifiedKeywords.contains { $0.keyword == "calorie tracker" && $0.isTracked })
        #expect(result.errors.isEmpty)
        #expect(result.competitors.first?.app.appStoreID == "456")
        #expect(result.competitors.first?.evidenceKeywords.contains("calorie tracker") == true)
        #expect(result.competitors.first?.recentReviews.isEmpty == true)

        let keywords = try await context.service.listKeywords(appStoreID: 123, storefronts: ["us"], platform: "iphone")
        #expect(keywords.items.contains { $0.keyword == "calorie tracker" && $0.latestRank == 2 })

        let competitors = try await context.service.listCompetitors(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone",
            limit: 10
        )
        #expect(competitors.first?.appStoreID == "456")
    }

    @Test
    func suggestKeywordsStopsVerificationBeforeToolTimeoutBudget() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [:])
        let context = try MCPTestContext(rankingProvider: rankingProvider)
        let storeApp = try context.insertTrackedApp(appStoreID: 123, name: "Focus Blocker").storeApp
        try context.insertMetadata(
            for: storeApp,
            storefront: "us",
            description: """
            screen time blocker screen time blocker website blocker website blocker social media blocker social media blocker
            app limit app limit focus timer focus timer digital detox digital detox strict mode strict mode schedule blocker schedule blocker
            """
        )

        let result = try await context.service.suggestKeywords(
            appStoreID: 123,
            storefronts: ["us", "de", "gb", "ca", "au"],
            platform: "iphone",
            limit: 50
        )

        #expect(await rankingProvider.searchedKeysSnapshot().count == 16)
        #expect(result.errors.contains { $0.error.code == "verification_budget_exceeded" })
    }

    @Test
    func refreshKeywordRankingsPersistsRanksAndMetricsFailGracefullyWithoutCredentials() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 456, name: "MyFitnessPal", ratingCount: 3_000_000),
                makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback)
        ])
        let context = try MCPTestContext(rankingProvider: rankingProvider)
        try context.insertTrackedApp(appStoreID: 123, name: "Cal AI")
        _ = try await context.service.addKeywords(
            appStoreID: 123,
            keywords: ["calorie tracker"],
            storefronts: ["us"],
            platform: "iphone"
        )

        let rankingRefresh = try await context.service.refreshKeywordRankings(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone"
        )

        #expect(rankingRefresh.summary.refreshed == 1)
        #expect(rankingRefresh.outcomes.first?.track.latestRank == 2)

        let competitors = try await context.service.listCompetitors(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone",
            limit: 10
        )
        #expect(competitors.first?.appStoreID == "456")

        let metricsRefresh = try await context.service.refreshKeywordMetrics(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone"
        )

        #expect(metricsRefresh.summary.failed == 1)
        #expect(metricsRefresh.outcomes.first?.error?.code == "apple_ads_not_configured")
        #expect(metricsRefresh.outcomes.first?.track.statusMessage?.contains("Connect an Apple Ads") == true)
    }

    @Test
    func refreshKeywordRankingsLimitCapsKeywordTracksRefreshed() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback),
            "macro tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 3, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback)
        ])
        let context = try MCPTestContext(rankingProvider: rankingProvider)
        try context.insertTrackedApp(appStoreID: 123, name: "Cal AI")
        _ = try await context.service.addKeywords(
            appStoreID: 123,
            keywords: ["calorie tracker", "macro tracker"],
            storefronts: ["us"],
            platform: "iphone"
        )

        let refresh = try await context.service.refreshKeywordRankings(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone",
            limit: 1
        )

        #expect(refresh.summary.refreshed == 1)
        #expect(refresh.summary.skipped == 1)
        #expect(await rankingProvider.searchedKeysSnapshot().count == 1)
    }

    @Test
    func refreshKeywordRankingsIsIdempotentAndPrunesStaleTopResults() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 456, name: "MyFitnessPal", ratingCount: 3_000_000),
                makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback)
        ])
        let context = try MCPTestContext(rankingProvider: rankingProvider)
        try context.insertTrackedApp(appStoreID: 123, name: "Cal AI")
        _ = try await context.service.addKeywords(
            appStoreID: 123,
            keywords: ["calorie tracker"],
            storefronts: ["us"],
            platform: "iphone"
        )

        _ = try await context.service.refreshKeywordRankings(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone"
        )
        await rankingProvider.setPage(SearchRankingPage(items: [
            makeRankingItem(position: 1, appStoreID: 789, name: "Macro AI", ratingCount: 100_000),
            makeRankingItem(position: 3, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
        ], source: .iTunesFallback), for: "calorie tracker::us::iphone")
        _ = try await context.service.refreshKeywordRankings(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone"
        )

        let snapshots = try context.modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.rank == 3)
        #expect(snapshot.topResults.map(\.appStoreID).sorted() == [123, 789])
        #expect(snapshot.topResults.count == 2)

        let crawls = try context.modelContext.fetch(FetchDescriptor<KeywordRankingCrawl>())
        let crawl = try #require(crawls.first)
        #expect(crawl.items.map(\.appStoreID).sorted() == [123, 789])
        #expect(crawl.items.count == 2)
    }

    @Test
    func refreshKeywordMetricsWithInjectedServiceFailsGracefullyWhenAppleAdsIsNotConfigured() async throws {
        let resolver = StubMCPAppResolver(resolvedApps: [
            123: makeResolvedApp(appStoreID: 123, name: "Cal AI")
        ])
        let context = try MCPTestContext(
            resolver: resolver,
            includeKeywordMetricsService: true,
            popularityContextAppStoreIDProvider: { nil },
            appleAdsWebSessionProvider: { nil },
            httpHandler: { request in
                Issue.record("Unexpected Apple Ads request to \(request.url?.absoluteString ?? "unknown URL")")
                throw OpenASOError.providerUnavailable("Unexpected request")
            }
        )
        _ = try await context.service.addTrackedApp(appStoreID: 123, storefront: "us")
        _ = try await context.service.addKeywords(
            appStoreID: 123,
            keywords: ["calorie tracker"],
            storefronts: ["us"],
            platform: "iphone"
        )

        let metricsRefresh = try await context.service.refreshKeywordMetrics(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone"
        )

        #expect(metricsRefresh.summary.failed == 1)
        #expect(metricsRefresh.summary.refreshed == 0)
        #expect(metricsRefresh.outcomes.first?.track.popularityScore == nil)
        #expect(metricsRefresh.outcomes.first?.error?.code == "keyword_popularity_unavailable")
        #expect(metricsRefresh.outcomes.first?.error?.message.contains("Reconnect Apple Ads") == true)
    }

    @Test
    func refreshKeywordMetricsDoesNotReportStaleRankingStatusAsPopularityFailure() async throws {
        let context = try MCPTestContext(includeKeywordMetricsService: true)
        try context.insertTrackedApp(appStoreID: 123, name: "Cal AI")
        _ = try await context.service.addKeywords(
            appStoreID: 123,
            keywords: ["calorie tracker"],
            storefronts: ["us"],
            platform: "iphone"
        )
        let tracks = try context.modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
        let track = try #require(tracks.first)
        track.statusMessage = "Ranking failed to refresh. Network request failed."
        context.modelContext.insert(KeywordDailyMetric(
            queryKey: track.queryKey,
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            popularityScore: 42,
            difficultyScore: nil,
            source: .appleAdsPopularity,
            updatedAt: Date()
        ))
        try context.modelContext.save()

        let metricsRefresh = try await context.service.refreshKeywordMetrics(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone"
        )

        #expect(metricsRefresh.summary.failed == 0)
        #expect(metricsRefresh.outcomes.first?.error == nil)
        #expect(metricsRefresh.outcomes.first?.track.statusMessage?.contains("Ranking failed") == true)
        #expect(metricsRefresh.outcomes.first?.track.popularityScore == 42)
    }

    @Test
    func derivedCompetitorsCanRefreshBoundedReviewsAndExportScreenshots() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "calorie tracker::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 456, name: "MyFitnessPal", ratingCount: 3_000_000),
                makeRankingItem(position: 2, appStoreID: 123, name: "Cal AI", ratingCount: 50_000)
            ], source: .iTunesFallback)
        ])
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("openaso-mcp-screenshot-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let context = try MCPTestContext(
            rankingProvider: rankingProvider,
            includeReviewService: true,
            screenshotDataProvider: { url in
                (imageBytes, makeHTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    headerFields: ["Content-Type": "image/png"]
                ))
            },
            httpHandler: { request in
                let url = request.url!
                if url.absoluteString.contains("/rss/customerreviews/") {
                    return (makeReviewsFeed(reviewCount: 2), makeHTTPURLResponse(url: url, statusCode: 200))
                }
                return (Data(), makeHTTPURLResponse(url: url, statusCode: 200))
            }
        )
        let storeApp = try context.insertTrackedApp(appStoreID: 123, name: "Cal AI").storeApp
        try context.insertMetadata(
            for: storeApp,
            storefront: "us",
            description: "AI calorie tracker with photo meal scanning, calorie tracking, and nutrition plans."
        )

        _ = try await context.service.discoverKeywordLandscape(
            appStoreID: 123,
            storefronts: ["us"],
            keywordLimit: 5,
            competitorLimit: 3,
            includeReviews: false
        )

        let reviewRefresh = try await context.service.refreshCompetitorReviews(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone",
            competitorLimit: 3,
            reviewsPerStorefront: 1
        )

        #expect(reviewRefresh.reviewLimitPerStorefront == 1)
        #expect(reviewRefresh.summary.refreshed == 1)
        #expect(reviewRefresh.summary.inserted == 1)

        let reviews = try await context.service.listReviews(
            appStoreID: 456,
            storefronts: ["us"],
            page: OpenASOMCPPageRequest(limit: 10, cursor: nil)
        )
        #expect(reviews.total == 1)
        #expect(reviews.items.first?.title == "Review 1")

        let screenshotExport = try await context.service.exportCompetitorScreenshots(
            appStoreID: 123,
            storefronts: ["us"],
            platform: "iphone",
            competitorLimit: 3,
            destinationDirectoryPath: destination.path
        )

        #expect(screenshotExport.summary.refreshed == 1)
        #expect(screenshotExport.exports.first?.completed.count == 1)
        let exportedPath = try #require(screenshotExport.exports.first?.completed.first?.filePath)
        #expect(FileManager.default.fileExists(atPath: exportedPath))
        #expect(screenshotExport.notes.contains { $0.contains("agent-side visual analysis") })
    }

    @Test
    func exportCompetitorScreenshotsReturnsPartialFailuresWhenCatalogMetadataIsMissing() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("openaso-mcp-partial-screenshot-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let context = try MCPTestContext(screenshotDataProvider: { url in
            (imageBytes, makeHTTPURLResponse(
                url: url,
                statusCode: 200,
                headerFields: ["Content-Type": "image/png"]
            ))
        })
        let target = try context.insertTrackedApp(appStoreID: 100, name: "Target").storeApp
        let exportableCompetitor = try context.insertStoreApp(appStoreID: 456, name: "Exportable")
        try context.insertScreenshots(for: exportableCompetitor)
        let track = try context.insertKeyword("calorie tracker", trackedApp: target, storefront: "us")
        try context.insertRankingCrawl(
            keyword: track.term,
            query: track.query,
            storefront: "us",
            observedAt: isoDate("2026-05-01T10:00:00Z"),
            rows: [
                RankingRow(position: 1, appStoreID: 789, name: "Missing Metadata"),
                RankingRow(position: 2, appStoreID: 456, name: "Exportable"),
                RankingRow(position: 3, appStoreID: 100, name: "Target")
            ]
        )

        let result = try await context.service.exportCompetitorScreenshots(
            appStoreID: 100,
            storefronts: ["us"],
            platform: "iphone",
            competitorLimit: 2,
            destinationDirectoryPath: destination.path
        )

        #expect(result.competitors.map(\.appStoreID) == ["789", "456"])
        #expect(result.summary.refreshed == 2)
        #expect(result.summary.failed == 1)
        #expect(result.exports.count == 1)
        #expect(result.exports.first?.completed.count == 2)
        #expect(result.failures.first?.competitor.appStoreID == "789")
        #expect(result.failures.first?.error.code == "app_not_found")
    }

    @Test
    func competitorLandscapeExportsScreenshotsAndRefreshesReviewsForMultipleAppsWithLimit500() async throws {
        let rankingProvider = StubMCPRankingProvider(pages: [
            "task manager::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 200, name: "Todoist", ratingCount: 850_000),
                makeRankingItem(position: 2, appStoreID: 100, name: "Notion", ratingCount: 320_000),
                makeRankingItem(position: 3, appStoreID: 300, name: "Trello", ratingCount: 420_000),
                makeRankingItem(position: 4, appStoreID: 400, name: "Asana", ratingCount: 1_200_000)
            ], source: .iTunesFallback),
            "project management::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 300, name: "Trello", ratingCount: 420_000),
                makeRankingItem(position: 2, appStoreID: 200, name: "Todoist", ratingCount: 850_000),
                makeRankingItem(position: 3, appStoreID: 100, name: "Notion", ratingCount: 320_000)
            ], source: .iTunesFallback),
            "kanban board::us::iphone": SearchRankingPage(items: [
                makeRankingItem(position: 1, appStoreID: 200, name: "Todoist", ratingCount: 850_000),
                makeRankingItem(position: 2, appStoreID: 300, name: "Trello", ratingCount: 420_000),
                makeRankingItem(position: 5, appStoreID: 100, name: "Notion", ratingCount: 320_000)
            ], source: .iTunesFallback)
        ])
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("openaso-mcp-multi-competitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let context = try MCPTestContext(
            rankingProvider: rankingProvider,
            includeReviewService: true,
            screenshotDataProvider: { url in
                (imageBytes, makeHTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    headerFields: ["Content-Type": "image/png"]
                ))
            },
            httpHandler: { request in
                let url = request.url!
                if url.absoluteString.contains("/rss/customerreviews/") {
                    return (makeReviewsFeed(reviewCount: 650), makeHTTPURLResponse(url: url, statusCode: 200))
                }
                return (Data(), makeHTTPURLResponse(url: url, statusCode: 200))
            }
        )
        try context.insertTrackedApp(appStoreID: 100, name: "Notion")
        _ = try await context.service.addKeywords(
            appStoreID: 100,
            keywords: ["task manager", "project management", "kanban board"],
            storefronts: ["us"],
            platform: "iphone"
        )
        _ = try await context.service.refreshKeywordRankings(
            appStoreID: 100,
            storefronts: ["us"],
            platform: "iphone"
        )

        let competitors = try await context.service.listCompetitors(
            appStoreID: 100,
            storefronts: ["us"],
            platform: "iphone",
            limit: 3
        )

        #expect(Array(competitors.map(\.appStoreID).prefix(2)) == ["200", "300"])
        #expect(competitors[0].sharedKeywordCount == 3)
        #expect(competitors[1].sharedKeywordCount == 3)
        #expect(competitors[0].evidence.map(\.keyword).contains("kanban board"))

        let screenshotExport = try await context.service.exportCompetitorScreenshots(
            appStoreID: 100,
            storefronts: ["us"],
            platform: "iphone",
            competitorLimit: 2,
            destinationDirectoryPath: destination.path
        )

        #expect(screenshotExport.competitors.map(\.appStoreID) == ["200", "300"])
        #expect(screenshotExport.summary.refreshed == 2)
        #expect(screenshotExport.exports.count == 2)
        #expect(screenshotExport.exports.allSatisfy { $0.completed.count == 1 })
        for export in screenshotExport.exports {
            let filePath = try #require(export.completed.first?.filePath)
            #expect(FileManager.default.fileExists(atPath: filePath))
        }

        let reviewRefresh = try await context.service.refreshCompetitorReviews(
            appStoreID: 100,
            storefronts: ["us"],
            platform: "iphone",
            competitorLimit: 2,
            reviewsPerStorefront: 999
        )

        #expect(reviewRefresh.competitors.map(\.appStoreID) == ["200", "300"])
        #expect(reviewRefresh.reviewLimitPerStorefront == 500)
        #expect(reviewRefresh.summary.refreshed == 1_000)
        #expect(reviewRefresh.summary.inserted == 1_000)
        #expect(reviewRefresh.outcomes.allSatisfy { $0.fetchedReviews == 500 && $0.storedReviews == 500 })
        #expect(reviewRefresh.notes.contains { $0.contains("praise, complaints, feature requests") })

        let todoistReviews = try await context.service.listReviews(
            appStoreID: 200,
            storefronts: ["us"],
            page: OpenASOMCPPageRequest(limit: 10, cursor: nil)
        )
        let trelloReviews = try await context.service.listReviews(
            appStoreID: 300,
            storefronts: ["us"],
            page: OpenASOMCPPageRequest(limit: 10, cursor: nil)
        )

        #expect(todoistReviews.total == 500)
        #expect(trelloReviews.total == 500)
        #expect(todoistReviews.items.first?.content.contains("Feature request") == true)
    }

    @Test
    func overviewCapsVerboseStorefrontRatingsAndCompetitorEvidence() async throws {
        let context = try MCPTestContext()
        let service = context.service
        let target = try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer").storeApp
        try context.insertVerboseMetadataAndRatings(for: target)
        let competitor = try context.insertStoreApp(appStoreID: 456, name: "Structured", sellerName: "Structured GmbH")

        for index in 0..<12 {
            let track = try context.insertKeyword("focus \(index)", trackedApp: target, storefront: "us")
            try context.insertRankingCrawl(
                keyword: track.term,
                query: track.query,
                storefront: "us",
                observedAt: isoDate("2026-05-01T10:00:00Z"),
                rows: [
                    RankingRow(position: 1, appStoreID: competitor.appStoreID, name: competitor.name),
                    RankingRow(position: 2, appStoreID: target.appStoreID, name: target.name)
                ]
            )
        }

        let overview = try await service.getAppOverview(appStoreID: 123)

        #expect(overview.storefrontMetadata.count == 8)
        #expect(overview.ratings.count == 25)
        #expect(overview.storefrontMetadata.allSatisfy { ($0.descriptionText?.count ?? 0) <= 1_200 })
        #expect(overview.storefrontMetadata.allSatisfy { ($0.releaseNotes?.count ?? 0) <= 800 })
        #expect(overview.topCompetitors.first?.sharedKeywordCount == 12)
        #expect(overview.topCompetitors.first?.evidence.count == 8)
    }

    @Test
    func validationRejectsUnsafeWebsiteURLsAndCapsPagination() throws {
        #expect(throws: OpenASOError.self) {
            _ = try OpenASOMCPValidation.webURL("file:///tmp/secret")
        }
        #expect(throws: OpenASOError.self) {
            _ = try OpenASOMCPValidation.webURL("http://")
        }
        #expect(throws: OpenASOError.self) {
            _ = try OpenASOMCPValidation.webURL("http://localhost:8080")
        }
        #expect(throws: OpenASOError.self) {
            _ = try OpenASOMCPValidation.webURL("http://127.0.0.1:8080")
        }
        #expect(throws: OpenASOError.self) {
            _ = try OpenASOMCPValidation.webURL("http://192.168.1.10")
        }
        #expect(throws: OpenASOError.self) {
            _ = try OpenASOMCPValidation.webURL("https://user:password@example.com")
        }

        let request = OpenASOMCPPageRequest(limit: 10_000, cursor: "12")
        #expect(request.limit == 200)
        #expect(request.offset == 12)
    }
}

private struct MCPTestContext {
    let container: ModelContainer
    let modelContext: ModelContext
    let backgroundModelStore: BackgroundModelStore
    let resolver: StubMCPAppResolver
    let service: OpenASOMCPService

    @MainActor
    init(
        resolver: StubMCPAppResolver = StubMCPAppResolver(),
        rankingProvider: StubMCPRankingProvider? = nil,
        useRankingRefreshCoordinator: Bool = false,
        includeReviewService: Bool = false,
        includeKeywordMetricsService: Bool = false,
        popularityContextAppStoreIDProvider: @escaping @MainActor @Sendable () -> Int64? = { nil },
        appleAdsWebSessionProvider: @escaping @MainActor @Sendable () -> AppleAdsWebSession? = { nil },
        screenshotDataProvider: ScreenshotDownloadService.DataProvider? = nil,
        httpHandler: @escaping (URLRequest) throws -> (Data, URLResponse) = { request in
            (Data(), makeHTTPURLResponse(url: request.url!, statusCode: 200))
        }
    ) throws {
        self.container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        self.modelContext = ModelContext(container)
        self.backgroundModelStore = BackgroundModelStore(modelContainer: container)
        self.resolver = resolver
        let httpClient = MockHTTPClient(handler: httpHandler)
        let appCatalogService = AppCatalogService(appResolver: resolver)
        let rankingRefreshCoordinator = rankingProvider.flatMap { provider in
            useRankingRefreshCoordinator
                ? RankingRefreshCoordinator(rankingProvider: provider, appCatalogService: appCatalogService)
                : nil
        }
        self.service = OpenASOMCPService(
            backgroundModelStore: backgroundModelStore,
            appResolver: resolver,
            appCatalogService: appCatalogService,
            httpClient: httpClient,
            screenshotDownloadService: screenshotDataProvider.map(ScreenshotDownloadService.init(dataProvider:)) ?? ScreenshotDownloadService(),
            rankingProvider: rankingProvider,
            rankingRefreshCoordinator: rankingRefreshCoordinator,
            reviewService: includeReviewService ? AppStorefrontReviewService(httpClient: httpClient) : nil,
            keywordMetricsService: includeKeywordMetricsService
                ? KeywordMetricsService(
                    httpClient: httpClient,
                    credentialStore: AppleAdsCredentialStore(keychain: InMemoryKeychainService()),
                    settingsStore: AppSettingsStore(defaults: UserDefaults(suiteName: "com.thirdtech.openaso.mcp.tests.\(UUID().uuidString)") ?? .standard),
                    webSessionStore: AppleAdsWebSessionStore(keychain: InMemoryKeychainService())
                )
                : nil,
            popularityContextAppStoreIDProvider: popularityContextAppStoreIDProvider,
            appleAdsWebSessionProvider: appleAdsWebSessionProvider,
            now: { isoDate("2026-05-07T12:00:00Z") }
        )
    }

    @discardableResult
    func insertTrackedApp(appStoreID: Int64, name: String) throws -> TrackedApp {
        let storeApp = try insertStoreApp(appStoreID: appStoreID, name: name)
        let trackedApp = TrackedApp(appStoreID: appStoreID, storeApp: storeApp)
        modelContext.insert(trackedApp)
        try modelContext.save()
        return trackedApp
    }

    @discardableResult
    func insertStoreApp(
        appStoreID: Int64,
        name: String,
        sellerName: String? = "Test Seller"
    ) throws -> StoreApp {
        let storeApp = StoreApp(
            appStoreID: appStoreID,
            bundleID: "com.example.\(appStoreID)",
            name: name,
            sellerName: sellerName,
            iconURLString: "https://example.com/\(appStoreID).png",
            defaultPlatform: .iphone,
            lastMetadataRefreshAt: isoDate("2026-05-01T00:00:00Z")
        )
        modelContext.insert(storeApp)
        try modelContext.save()
        return storeApp
    }

    func insertReviews(for storeApp: StoreApp, _ seeds: [ReviewSeed]) throws {
        for seed in seeds {
            let review = AppStorefrontReview(
                appStoreID: storeApp.appStoreID,
                storefront: seed.storefront,
                reviewID: seed.id,
                reviewerName: "Reviewer \(seed.id)",
                title: "Title \(seed.id)",
                content: "Content \(seed.id)",
                rating: seed.rating,
                reviewedAt: seed.reviewedAt,
                version: seed.version,
                observedAt: seed.reviewedAt,
                storeApp: storeApp
            )
            storeApp.reviews.append(review)
            modelContext.insert(review)
        }
        try modelContext.save()
    }

    func insertScreenshots(for storeApp: StoreApp) throws {
        let us = AppStorefrontMetadata(
            appStoreID: storeApp.appStoreID,
            storefront: "us",
            defaultPlatform: .iphone,
            name: storeApp.name,
            source: .appStoreWeb,
            lastFetchedAt: isoDate("2026-05-01T00:00:00Z"),
            storeApp: storeApp
        )
        let gb = AppStorefrontMetadata(
            appStoreID: storeApp.appStoreID,
            storefront: "gb",
            defaultPlatform: .ipad,
            name: storeApp.name,
            source: .appStoreWeb,
            lastFetchedAt: isoDate("2026-05-02T00:00:00Z"),
            storeApp: storeApp
        )
        storeApp.storefrontMetadata.append(contentsOf: [us, gb])
        modelContext.insert(us)
        modelContext.insert(gb)

        let screenshots = [
            AppStoreScreenshot(appStoreID: storeApp.appStoreID, storefront: "us", platformRaw: "iphone", displayTypeRaw: "phone", sortOrder: 1, urlString: "https://example.com/us-iphone-1.png", width: 1290, height: 2796, source: .appStoreWeb, metadata: us),
            AppStoreScreenshot(appStoreID: storeApp.appStoreID, storefront: "us", platformRaw: "iphone", displayTypeRaw: "phone", sortOrder: 2, urlString: "https://example.com/us-iphone-2.png", width: 1290, height: 2796, source: .appStoreWeb, metadata: us),
            AppStoreScreenshot(appStoreID: storeApp.appStoreID, storefront: "gb", platformRaw: "ipad", displayTypeRaw: "tablet", sortOrder: 1, urlString: "https://example.com/gb-ipad-1.png", width: 2048, height: 2732, source: .appStoreWeb, metadata: gb)
        ]
        us.screenshots.append(contentsOf: Array(screenshots.prefix(2)))
        gb.screenshots.append(screenshots[2])
        screenshots.forEach(modelContext.insert)
        try modelContext.save()
    }

    func insertVerboseMetadataAndRatings(for storeApp: StoreApp) throws {
        let description = String(repeating: "Description ", count: 200)
        let releaseNotes = String(repeating: "Release notes ", count: 120)
        for index in 0..<30 {
            let storefront = String(format: "s%02d", index)
            let metadata = AppStorefrontMetadata(
                appStoreID: storeApp.appStoreID,
                storefront: storefront,
                defaultPlatform: .iphone,
                name: storeApp.name,
                descriptionText: description,
                releaseNotes: releaseNotes,
                source: .appStoreWeb,
                lastFetchedAt: isoDate("2026-05-01T00:00:00Z"),
                storeApp: storeApp
            )
            let rating = LatestAppRating(
                appStoreID: storeApp.appStoreID,
                storefront: storefront,
                ratingCount: 100 + index,
                averageRating: 4.0,
                observedAt: isoDate("2026-05-01T00:00:00Z"),
                storeApp: storeApp
            )
            storeApp.storefrontMetadata.append(metadata)
            storeApp.storefrontLatest.append(rating)
            modelContext.insert(metadata)
            modelContext.insert(rating)
        }
        try modelContext.save()
    }

    func insertMetadata(
        for storeApp: StoreApp,
        storefront: String,
        description: String,
        subtitle: String? = nil
    ) throws {
        let metadata = AppStorefrontMetadata(
            appStoreID: storeApp.appStoreID,
            storefront: storefront,
            defaultPlatform: .iphone,
            name: storeApp.name,
            subtitle: subtitle,
            descriptionText: description,
            source: .iTunesSearch,
            lastFetchedAt: isoDate("2026-05-01T00:00:00Z"),
            storeApp: storeApp
        )
        storeApp.storefrontMetadata.append(metadata)
        modelContext.insert(metadata)
        try modelContext.save()
    }

    func insertLocalizationMetadata(
        for storeApp: StoreApp,
        storefront: String,
        name: String,
        subtitle: String?,
        description: String,
        screenshotURLs: [String]
    ) throws {
        let metadata = AppStorefrontMetadata(
            appStoreID: storeApp.appStoreID,
            storefront: storefront,
            defaultPlatform: .iphone,
            name: name,
            subtitle: subtitle,
            descriptionText: description,
            releaseNotes: "Release notes for \(storefront)",
            source: .appStoreWeb,
            lastFetchedAt: isoDate("2026-05-01T00:00:00Z"),
            storeApp: storeApp
        )
        storeApp.storefrontMetadata.append(metadata)
        modelContext.insert(metadata)
        for (index, urlString) in screenshotURLs.enumerated() {
            let screenshot = AppStoreScreenshot(
                appStoreID: storeApp.appStoreID,
                storefront: storefront,
                platformRaw: "iphone",
                displayTypeRaw: "phone",
                sortOrder: index,
                urlString: urlString,
                width: 1290,
                height: 2796,
                source: .appStoreWeb,
                metadata: metadata
            )
            metadata.screenshots.append(screenshot)
            modelContext.insert(screenshot)
        }
        try modelContext.save()
    }

    @discardableResult
    func insertKeyword(_ term: String, trackedApp: StoreApp, storefront: String) throws -> TrackedAppKeyword {
        let query = try KeywordQuery.fetchOrInsert(
            term: term,
            storefront: storefront,
            platform: .iphone,
            in: modelContext
        )
        let appStoreID = trackedApp.appStoreID
        let trackedAppModel = try modelContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { app in
                app.appStoreID == appStoreID
            }
        )).first!
        let track = TrackedAppKeyword(
            term: term,
            storefront: storefront,
            platform: .iphone,
            trackedApp: trackedAppModel,
            query: query
        )
        trackedAppModel.keywordTracks.append(track)
        modelContext.insert(track)
        try modelContext.save()
        return track
    }

    func insertRankingCrawl(
        keyword: String,
        query: KeywordQuery,
        storefront: String,
        observedAt: Date,
        rows: [RankingRow]
    ) throws {
        let crawl = KeywordRankingCrawl(
            keyword: keyword,
            storefront: storefront,
            platform: .iphone,
            observedAt: observedAt,
            source: .iTunesFallback,
            resultCount: rows.count,
            query: query
        )
        modelContext.insert(crawl)
        for row in rows {
            let ranking = KeywordAppRanking(
                position: row.position,
                appStoreID: row.appStoreID,
                bundleID: "com.example.\(row.appStoreID)",
                name: row.name,
                sellerName: nil,
                observation: crawl
            )
            crawl.items.append(ranking)
            modelContext.insert(ranking)
        }
        try modelContext.save()
    }

    func insertDailyRanking(
        track: TrackedAppKeyword,
        rank: Int?,
        resultCount: Int,
        searchedAt: Date = isoDate("2026-05-01T10:00:00Z")
    ) throws {
        let snapshot = TrackedKeywordDailyRanking(
            rank: rank,
            searchedAt: searchedAt,
            source: .iTunesFallback,
            resultCount: resultCount,
            keywordTrack: track
        )
        track.snapshots.append(snapshot)
        modelContext.insert(snapshot)
        try modelContext.save()
    }
}

private struct StubMCPAppResolver: AppResolver {
    private let resolvedApps: [Int64: ResolvedApp]
    private let storefrontResolvedApps: [String: ResolvedApp]
    private let searchResults: [ResolvedApp]

    init(
        resolvedApps: [Int64: ResolvedApp] = [:],
        storefrontResolvedApps: [String: ResolvedApp] = [:],
        searchResults: [ResolvedApp] = []
    ) {
        self.resolvedApps = resolvedApps
        self.storefrontResolvedApps = storefrontResolvedApps
        self.searchResults = searchResults
    }

    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        let key = "\(appStoreID)::\(storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        if let app = storefrontResolvedApps[key] {
            return app
        }
        guard let app = resolvedApps[appStoreID] else {
            throw OpenASOError.appNotFound
        }
        return app
    }

    func searchApps(named query: String, storefrontCode: String, limit: Int) async throws -> [ResolvedApp] {
        Array(searchResults.prefix(limit))
    }
}

private actor StubMCPRankingProvider: SearchRankingProvider {
    private var pages: [String: SearchRankingPage]
    private var failures: [String: OpenASOError]
    private var searchedKeys: [String] = []

    init(
        pages: [String: SearchRankingPage],
        failures: [String: OpenASOError] = [:]
    ) {
        self.pages = pages
        self.failures = failures
    }

    func setPage(_ page: SearchRankingPage, for key: String) {
        pages[key] = page
    }

    func searchedKeysSnapshot() -> [String] {
        searchedKeys
    }

    func search(keyword: String, storefrontCode: String, platform: AppPlatform, limit: Int) async throws -> SearchRankingPage {
        let key = TrackedAppKeyword.makeQueryKey(
            term: keyword,
            storefront: storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform: platform
        )
        searchedKeys.append(key)
        if let failure = failures[key] {
            throw failure
        }
        guard let page = pages[key] else {
            return SearchRankingPage(items: [], source: .iTunesFallback)
        }
        return SearchRankingPage(items: Array(page.items.prefix(limit)), source: page.source)
    }
}

private struct ReviewSeed {
    let id: String
    let storefront: String
    let rating: Int
    let version: String
    let reviewedAt: Date
}

private struct RankingRow {
    let position: Int
    let appStoreID: Int64
    let name: String
}

@MainActor
private func makeService(
    resolver: StubMCPAppResolver = StubMCPAppResolver()
) throws -> OpenASOMCPService {
    try MCPTestContext(resolver: resolver).service
}

private func makeResolvedApp(
    appStoreID: Int64,
    name: String,
    subtitle: String? = nil,
    sellerURLString: String? = nil,
    trackViewURLString: String? = nil
) -> ResolvedApp {
    ResolvedApp(
        appStoreID: appStoreID,
        bundleID: "com.example.\(appStoreID)",
        name: name,
        subtitle: subtitle,
        sellerName: "Example Seller",
        iconURLString: "https://example.com/\(appStoreID).png",
        version: "1.0",
        primaryGenreName: "Productivity",
        sellerURLString: sellerURLString,
        trackViewURLString: trackViewURLString,
        screenshotURLs: ["https://example.com/screenshot.png"],
        defaultPlatform: .iphone
    )
}

private func makeRankingItem(
    position: Int,
    appStoreID: Int64,
    name: String,
    ratingCount: Int
) -> SearchRankingItem {
    SearchRankingItem(
        position: position,
        appStoreID: appStoreID,
        bundleID: "com.example.\(appStoreID)",
        name: name,
        sellerName: "Example Seller",
        iconURLString: "https://example.com/\(appStoreID).png",
        primaryGenreName: "Health & Fitness",
        screenshotURLs: ["https://example.com/\(appStoreID)-1.png"],
        ratingCount: ratingCount,
        averageRating: 4.7,
        platform: .iphone
    )
}

private func isoDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
}

private func makeReviewsFeed(reviewCount: Int, startIndex: Int = 1) -> Data {
    let reviewIndexes = reviewCount > 0 ? Array(startIndex..<(startIndex + reviewCount)) : []
    let entries = reviewIndexes.map { index in
        let day = ((index - 1) % 28) + 1
        let date = String(format: "2026-05-%02dT10:00:00Z", day)
        return """
        {
          "author": { "name": { "label": "Reviewer \(index)" } },
          "updated": { "label": "\(date)" },
          "im:rating": { "label": "\(max(1, 6 - index))" },
          "im:version": { "label": "1.\(index)" },
          "id": { "label": "review-\(index)" },
          "title": { "label": "Review \(index)" },
          "content": { "label": "Competitor review content \(index). Feature request: better planning and clearer onboarding." }
        }
        """
    }.joined(separator: ",")
    return Data("""
    {
      "feed": {
        "entry": [\(entries)]
      }
    }
    """.utf8)
}
