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
    func ratingsReviewsStorefrontsFallBackWhenNoKeywordsTracked() throws {
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

        let fallback = ["us", "gb", "fr"]
        let codes = DailyRefreshScheduler.ratingsReviewsStorefrontCodes(
            for: app,
            fallback: fallback
        )

        #expect(codes == fallback)
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
