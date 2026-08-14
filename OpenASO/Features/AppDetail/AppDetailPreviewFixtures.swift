import SwiftData
import SwiftUI

#if DEBUG
#Preview("App Detail - Crowded Suggestions") {
    AppDetailPreviewHarness()
}

private struct AppDetailPreviewHarness: View {
    private let previewContainer: OpenASOPreviewContainer<TrackedApp>

    init() {
        self.previewContainer = OpenASOPreviewContainer(seed: Self.seed)
    }

    private var trackedApp: TrackedApp {
        previewContainer.seedData
    }

    var body: some View {
        AppDetailView(trackedApp: trackedApp)
            .openASOPreviewEnvironment(previewContainer)
            .frame(width: 1400, height: 760)
    }

    private static func seed(in modelContext: ModelContext) -> TrackedApp {
        let trackedApp = TrackedApp(
            appStoreID: 6448311069,
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            sellerName: "OpenAI",
            defaultPlatform: .iphone
        )
        modelContext.insert(trackedApp)

        seedStorefronts(in: modelContext)
        let competitors = seedStoreApps(in: modelContext)
        seedTrackedKeywords(for: trackedApp, competitors: competitors, in: modelContext)
        seedSuggestedKeywordObservations(for: trackedApp, competitors: competitors, in: modelContext)
        try? modelContext.save()

        return trackedApp
    }

    private static func seedStorefronts(in modelContext: ModelContext) {
        let storefronts = [
            Storefront(code: "us", name: "United States", flagEmoji: "🇺🇸", languageCode: "en"),
            Storefront(code: "gb", name: "United Kingdom", flagEmoji: "🇬🇧", languageCode: "en"),
            Storefront(code: "ca", name: "Canada", flagEmoji: "🇨🇦", languageCode: "en"),
            Storefront(code: "de", name: "Germany", flagEmoji: "🇩🇪", languageCode: "de"),
            Storefront(code: "jp", name: "Japan", flagEmoji: "🇯🇵", languageCode: "ja")
        ]

        storefronts.forEach(modelContext.insert)
    }

    private static func seedStoreApps(in modelContext: ModelContext) -> [(id: Int64, bundleID: String, name: String, seller: String)] {
        let apps: [(Int64, String, String, String)] = [
            (6448311069, "com.openai.chat", "ChatGPT", "OpenAI"),
            (1669007652, "com.perplexity.ai", "Perplexity", "Perplexity AI"),
            (6475737981, "com.anthropic.claude", "Claude", "Anthropic"),
            (6472538445, "com.google.gemini", "Google Gemini", "Google"),
            (1477376905, "com.microsoft.copilot", "Microsoft Copilot", "Microsoft"),
            (1292942367, "com.poe.app", "Poe", "Quora"),
            (1668787639, "com.character.ai", "Character AI", "Character.AI"),
            (1318294667, "com.grammarly.keyboard", "Grammarly", "Grammarly"),
            (1480068668, "com.notion.id", "Notion", "Notion Labs"),
            (310633997, "com.evernote.iPhone.Evernote", "Evernote", "Evernote"),
            (284882215, "com.apple.mobilenotes", "Apple Notes", "Apple"),
            (835599320, "com.todoist.ios", "Todoist", "Doist"),
            (1551353775, "com.rewind.mobile", "Rewind", "Rewind AI")
        ]

        for app in apps {
            modelContext.insert(
                StoreApp(
                    appStoreID: app.0,
                    bundleID: app.1,
                    name: app.2,
                    sellerName: app.3,
                    iconURLString: nil,
                    defaultPlatform: .iphone
                )
            )
        }

        return apps.map { (id: $0.0, bundleID: $0.1, name: $0.2, seller: $0.3) }
    }

    private static func seedTrackedKeywords(
        for trackedApp: TrackedApp,
        competitors: [(id: Int64, bundleID: String, name: String, seller: String)],
        in modelContext: ModelContext
    ) {
        let trackInputs: [(String, String, Int?)] = [
            ("ai chatbot", "us", 1),
            ("writing assistant", "us", 3),
            ("homework help", "us", 8),
            ("essay writer", "us", 12),
            ("ai search", "gb", 5),
            ("chat ai", "gb", 2),
            ("productivity ai", "gb", nil),
            ("ask ai", "ca", 4),
            ("study helper", "ca", 10),
            ("business assistant", "de", 7),
            ("ki chat", "de", 14),
            ("ai japanese", "jp", 6),
            ("translate ai", "jp", nil),
            ("coding assistant", "us", 2),
            ("summarizer", "gb", 9),
            ("meeting notes", "ca", 11),
            ("email writer", "de", 3),
            ("voice assistant", "jp", 15)
        ]

        for (offset, input) in trackInputs.enumerated() {
            let query = try! KeywordQuery.fetchOrInsert(
                term: input.0,
                storefront: input.1,
                platform: .iphone,
                in: modelContext
            )
            let track = TrackedAppKeyword(
                term: input.0,
                storefront: input.1,
                platform: .iphone,
                trackedApp: trackedApp,
                query: query,
                createdAt: date(daysAgo: 12 - min(offset, 10))
            )
            track.lastRefreshAt = date(hoursAgo: offset + 1)
            trackedApp.keywordTracks.append(track)
            modelContext.insert(track)

            modelContext.insert(
                KeywordDailyMetric(
                    queryKey: track.queryKey,
                    keyword: track.term,
                    storefront: track.storefront,
                    platform: track.platform,
                    popularityScore: 20 + ((offset * 9) % 72),
                    difficultyScore: 20 + ((offset * 9) % 72),
                    source: .appleAdsPopularity,
                    updatedAt: date(hoursAgo: offset)
                )
            )

            for snapshotIndex in 0..<3 {
                let rank = input.2.map { max(1, $0 + snapshotIndex - 1) }
                let snapshot = TrackedKeywordDailyRanking(
                    rank: rank,
                    searchedAt: date(daysAgo: 2 - snapshotIndex),
                    source: snapshotIndex == 0 ? .iTunesFallback : .appStoreWeb,
                    resultCount: 50,
                    errorMessage: rank == nil ? "Not in top 50" : nil,
                    keywordTrack: track
                )
                track.snapshots.append(snapshot)
                modelContext.insert(snapshot)
                seedRankedResults(rank: rank, snapshot: snapshot, competitors: competitors, in: modelContext)
            }

            seedObservation(keyword: track.term, storefront: track.storefront, trackedAppID: trackedApp.appStoreID, competitors: competitors, in: modelContext)
        }
    }

    private static func seedSuggestedKeywordObservations(
        for trackedApp: TrackedApp,
        competitors: [(id: Int64, bundleID: String, name: String, seller: String)],
        in modelContext: ModelContext
    ) {
        let suggestions: [(keyword: String, storefront: String)] = [
            ("ai tutor", "us"),
            ("cover letter", "us"),
            ("math solver", "gb"),
            ("ai notes", "ca"),
            ("business email", "de"),
            ("english practice", "jp")
        ]

        for suggestion in suggestions {
            seedObservation(
                keyword: suggestion.keyword,
                storefront: suggestion.storefront,
                trackedAppID: trackedApp.appStoreID,
                competitors: competitors,
                in: modelContext
            )
        }
    }

    private static func seedRankedResults(
        rank: Int?,
        snapshot: TrackedKeywordDailyRanking,
        competitors: [(id: Int64, bundleID: String, name: String, seller: String)],
        in modelContext: ModelContext
    ) {
        let visibleApps = rankedApps(rank: rank, competitors: competitors)

        for (index, app) in visibleApps.enumerated() {
            let result = TrackedKeywordRankedResult(
                position: index + 1,
                appStoreID: app.id,
                bundleID: app.bundleID,
                name: app.name,
                subtitle: nil,
                sellerName: app.seller,
                snapshot: snapshot
            )
            snapshot.topResults.append(result)
            modelContext.insert(result)
        }
    }

    private static func seedObservation(
        keyword: String,
        storefront: String,
        trackedAppID: Int64,
        competitors: [(id: Int64, bundleID: String, name: String, seller: String)],
        in modelContext: ModelContext
    ) {
        let query = try! KeywordQuery.fetchOrInsert(
            term: keyword,
            storefront: storefront,
            platform: .iphone,
            in: modelContext
        )
        let observation = RankingCrawlRecord(
            keyword: keyword,
            storefront: storefront,
            platform: .iphone,
            observedAt: date(hoursAgo: keyword.count),
            source: .appStoreWeb,
            resultCount: 50,
            query: query
        )
        modelContext.insert(observation)

        let rank = max(1, min(9, keyword.count % 10))
        for (index, app) in rankedApps(rank: rank, competitors: competitors).enumerated() {
            let rankingAppStoreID = app.id == 6448311069 ? trackedAppID : app.id
            let revision = RankingAppRevision(
                appStoreID: rankingAppStoreID,
                bundleID: app.bundleID,
                name: app.name,
                subtitle: nil,
                sellerName: app.seller
            )
            let item = RankingFact(
                position: index + 1,
                appStoreID: rankingAppStoreID,
                revision: revision,
                observation: observation
            )
            modelContext.insert(revision)
            modelContext.insert(item)
        }
    }

    private static func rankedApps(
        rank: Int?,
        competitors: [(id: Int64, bundleID: String, name: String, seller: String)]
    ) -> [(id: Int64, bundleID: String, name: String, seller: String)] {
        var apps = Array(competitors.dropFirst())
        guard let rank else {
            return Array(apps.prefix(10))
        }

        apps.insert(competitors[0], at: min(max(rank - 1, 0), apps.count))
        return Array(apps.prefix(10))
    }

    private static func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    }

    private static func date(hoursAgo: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: -hoursAgo, to: .now) ?? .now
    }
}
#endif
