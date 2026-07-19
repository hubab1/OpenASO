import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct DailyRefreshSchedulerTests {
    @Test
    func ratingsReviewsStorefrontsScopeToTrackedKeywordCountries() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)

        let app = TrackedApp(
            appStoreID: 842842640,
            bundleID: "com.google.Docs",
            name: "Google Docs",
            sellerName: "Google",
            defaultPlatform: .iphone
        )
        modelContext.insert(app)
        for storefront in ["us", "GB", " ca "] {
            let track = try makeTrackedAppKeyword(
                term: "pages",
                storefront: storefront,
                trackedApp: app,
                in: modelContext
            )
            app.keywordTracks.append(track)
            modelContext.insert(track)
        }
        try modelContext.save()

        let codes = DailyRefreshScheduler.ratingsReviewsStorefrontCodes(
            for: app,
            fallback: ["us", "gb", "fr", "de", "jp"]
        )

        // Only the (normalized, de-duplicated, sorted) tracked countries — not the fallback.
        #expect(codes == ["ca", "gb", "us"])
    }

    @Test
    func ratingsReviewsStorefrontsUseDefaultWhenNoKeywordsTracked() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)

        let app = TrackedApp(
            appStoreID: 1,
            bundleID: "com.example.app",
            name: "Example",
            sellerName: "Example Inc",
            defaultPlatform: .iphone
        )
        modelContext.insert(app)
        try modelContext.save()

        app.storeApp.defaultStorefront = " GB "
        let fallback = ["us", "fr"]
        let codes = DailyRefreshScheduler.ratingsReviewsStorefrontCodes(
            for: app,
            fallback: fallback
        )

        #expect(codes == ["gb"])
    }

    @Test
    func ratingsReviewsStorefrontsPreferUSCatalogFallback() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)

        let app = TrackedApp(
            appStoreID: 1,
            bundleID: "com.example.app",
            name: "Example",
            sellerName: "Example Inc",
            defaultPlatform: .iphone
        )
        app.storeApp.defaultStorefront = "  "
        modelContext.insert(app)
        try modelContext.save()

        let codes = DailyRefreshScheduler.ratingsReviewsStorefrontCodes(
            for: app,
            fallback: ["", " FR ", "us"]
        )

        #expect(codes == ["us"])
    }

    @Test
    func ratingsReviewsStorefrontsUseFirstValidCatalogFallbackWhenUSUnavailable() throws {
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)

        let app = TrackedApp(
            appStoreID: 1,
            bundleID: "com.example.app",
            name: "Example",
            sellerName: "Example Inc",
            defaultPlatform: .iphone
        )
        app.storeApp.defaultStorefront = "  "
        modelContext.insert(app)
        try modelContext.save()

        let codes = DailyRefreshScheduler.ratingsReviewsStorefrontCodes(
            for: app,
            fallback: ["", " FR ", "gb"]
        )

        #expect(codes == ["fr"])
    }

    @Test
    func cancelledAppRefreshIsNotRecordedAsSuccessfulDailyRefresh() async throws {
        let defaults = makeDailyRefreshDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = dailyRefreshUTCCalendar()
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 1,
            day: 2,
            hour: 7,
            minute: 1
        )))
        let container = try makeInMemoryContainer()
        let modelContext = ModelContext(container)
        let app = TrackedApp(
            appStoreID: 1,
            bundleID: "com.example.cancelled",
            name: "Cancelled App",
            sellerName: "Example Inc",
            defaultPlatform: .iphone
        )
        app.storeApp.defaultStorefront = "us"
        modelContext.insert(app)
        modelContext.insert(TrackedApp(
            appStoreID: 2,
            bundleID: "com.example.not-started",
            name: "Not Started",
            sellerName: "Example Inc",
            defaultPlatform: .iphone
        ))
        try modelContext.save()

        var refreshCount = 0
        let scheduler = DailyRefreshScheduler(
            settingsStore: settingsStore,
            refreshCoordinator: RankingRefreshCoordinator(
                rankingProvider: DailyRefreshNoopRankingProvider(),
                appCatalogService: AppCatalogService(appResolver: DailyRefreshNoopAppResolver())
            ),
            appDetailRefresh: { _ in
                refreshCount += 1
                return .cancelled
            },
            storefrontCodesProvider: { ["us"] }
        )

        let didTrigger = await scheduler.triggerIfNeeded(
            in: modelContext,
            now: now,
            calendar: calendar
        )

        #expect(didTrigger)
        #expect(refreshCount == 1)
        #expect(scheduler.lastOutcome == DailyRefreshOutcome(
            triggeredAt: now,
            refreshedCount: 1,
            failureCount: 1
        ))
        #expect(settingsStore.hasTriggeredRefresh(on: now, calendar: calendar))
        #expect(!settingsStore.hasRefreshedRatingsReviews(on: now, calendar: calendar))
        #expect(!scheduler.isRefreshing)
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
    storefront: String,
    trackedApp: TrackedApp,
    in modelContext: ModelContext
) throws -> TrackedAppKeyword {
    let query = try KeywordQuery.fetchOrInsert(
        term: term,
        storefront: storefront,
        platform: .iphone,
        in: modelContext
    )
    return TrackedAppKeyword(
        term: term,
        storefront: storefront,
        platform: .iphone,
        trackedApp: trackedApp,
        query: query
    )
}

private struct DailyRefreshNoopRankingProvider: SearchRankingProvider {
    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        SearchRankingPage(items: [], source: .iTunesFallback)
    }
}

private struct DailyRefreshNoopAppResolver: AppResolver {
    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        ResolvedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.\(appStoreID)",
            name: "Example",
            sellerName: "Example Inc",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
    }

    func searchApps(
        named query: String,
        storefrontCode: String,
        limit: Int
    ) async throws -> [ResolvedApp] {
        []
    }
}

private func makeDailyRefreshDefaults() -> UserDefaults {
    let suiteName = "daily.refresh.cancellation.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func dailyRefreshUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
