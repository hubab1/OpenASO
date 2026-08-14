import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct RankingSchemaV6MigrationTests {
    @Test
    func migrationPaginatesMixedUnicodeKeysWithoutSkippingOrRepeatingRows() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let observedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let terms = (0..<80).flatMap { index in
            [
                String(format: "unexpected free time %03d", index),
                String(format: "éclair %03d", index),
                String(format: "番茄 %03d", index),
            ]
        }

        for term in terms {
            let query = KeywordQuery(term: term, storefront: "us", platform: .iphone)
            let crawl = LegacyKeywordRankingCrawl(
                keyword: term,
                storefront: "us",
                platform: .iphone,
                observedAt: observedAt,
                source: .appStoreWeb,
                resultCount: 1,
                query: query
            )
            let fact = LegacyKeywordAppRanking(
                position: 1,
                appStoreID: 100,
                bundleID: "com.example.shared",
                name: "Shared App",
                sellerName: "Example",
                observation: crawl
            )
            query.observations.append(crawl)
            crawl.items.append(fact)
            context.insert(query)
            context.insert(crawl)
            context.insert(fact)
        }
        try context.save()

        try RankingSchemaV6Migrator.migrateIfNeeded(in: container)

        #expect(try context.fetchCount(FetchDescriptor<LegacyKeywordRankingCrawl>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LegacyKeywordAppRanking>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RankingCrawlRecord>()) == terms.count)
        #expect(try context.fetchCount(FetchDescriptor<RankingFact>()) == terms.count)
        let state = try #require(context.fetch(FetchDescriptor<RankingMigrationState>()).first)
        #expect(state.phase == .completed)
        #expect(state.migratedCrawlCount == terms.count)
        #expect(state.migratedFactCount == terms.count)
    }

    @Test
    func migrationPreservesCanonicalAndTrackedOnlyRankingsThenIsIdempotent() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let canonicalDate = Date(timeIntervalSince1970: 1_787_000_000)
        let recoveredDate = canonicalDate.addingTimeInterval(86_400)

        let trackedApp = TrackedApp(
            appStoreID: 100,
            bundleID: "com.example.target",
            name: "Target",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(term: "focus timer", storefront: "us", platform: .iphone)
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query
        )
        let legacyCrawl = LegacyKeywordRankingCrawl(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: canonicalDate,
            source: .appStoreWeb,
            resultCount: 2,
            query: query,
            submissionCount: 3,
            winningCount: 2,
            confidence: "consensus"
        )
        let targetFact = LegacyKeywordAppRanking(
            position: 1,
            appStoreID: 100,
            bundleID: "com.example.target",
            name: "Target",
            subtitle: nil,
            sellerName: "Example",
            observation: legacyCrawl
        )
        let competitorFact = LegacyKeywordAppRanking(
            position: 2,
            appStoreID: 200,
            bundleID: "com.example.competitor",
            name: "Competitor",
            subtitle: "Stay focused",
            sellerName: "Competitor Ltd",
            observation: legacyCrawl
        )
        legacyCrawl.items.append(contentsOf: [targetFact, competitorFact])

        let canonicalSnapshot = TrackedKeywordDailyRanking(
            rank: 1,
            searchedAt: canonicalDate,
            source: .appStoreWeb,
            resultCount: 2,
            keywordTrack: track
        )
        let canonicalResults = [targetFact, competitorFact].map { fact in
            TrackedKeywordRankedResult(
                position: fact.position,
                appStoreID: fact.appStoreID,
                bundleID: fact.bundleID,
                name: fact.name,
                subtitle: fact.subtitle,
                sellerName: fact.sellerName,
                snapshot: canonicalSnapshot
            )
        }
        canonicalSnapshot.topResults.append(contentsOf: canonicalResults)

        let trackedOnlySnapshot = TrackedKeywordDailyRanking(
            rank: nil,
            searchedAt: recoveredDate,
            source: .iTunesFallback,
            resultCount: 1,
            keywordTrack: track
        )
        let trackedOnlyResult = TrackedKeywordRankedResult(
            position: 7,
            appStoreID: 300,
            bundleID: nil,
            name: "Legacy Only",
            subtitle: nil,
            sellerName: nil,
            snapshot: trackedOnlySnapshot
        )
        trackedOnlySnapshot.topResults.append(trackedOnlyResult)

        let stats = AppKeywordStats(
            appStoreID: 100,
            queryKey: query.queryKey,
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            rank: 1,
            observedAt: canonicalDate,
            popularityScore: 55,
            difficultyScore: 42
        )

        context.insert(trackedApp)
        context.insert(query)
        context.insert(track)
        context.insert(legacyCrawl)
        context.insert(targetFact)
        context.insert(competitorFact)
        context.insert(canonicalSnapshot)
        canonicalResults.forEach(context.insert)
        context.insert(trackedOnlySnapshot)
        context.insert(trackedOnlyResult)
        context.insert(stats)
        trackedApp.keywordTracks.append(track)
        query.tracks.append(track)
        query.observations.append(legacyCrawl)
        track.snapshots.append(contentsOf: [canonicalSnapshot, trackedOnlySnapshot])
        try context.save()

        try RankingSchemaV6Migrator.migrateIfNeeded(in: container)

        #expect(try context.fetchCount(FetchDescriptor<LegacyKeywordRankingCrawl>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LegacyKeywordAppRanking>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TrackedKeywordRankedResult>()) == 0)
        let preservedStats = try #require(
            context.fetch(FetchDescriptor<AppKeywordStats>()).first
        )
        #expect(preservedStats.identityKey == stats.identityKey)
        #expect(preservedStats.bestRank == stats.bestRank)
        #expect(preservedStats.latestRank == stats.latestRank)
        #expect(preservedStats.popularityScore == stats.popularityScore)
        #expect(preservedStats.difficultyScore == stats.difficultyScore)

        let normalizedCrawls = try context.fetch(FetchDescriptor<RankingCrawlRecord>())
        let normalizedFacts = try context.fetch(FetchDescriptor<RankingFact>())
        let links = try context.fetch(FetchDescriptor<TrackedRankingCrawlLink>())
        #expect(normalizedCrawls.count == 2)
        #expect(normalizedFacts.count == 3)
        #expect(links.count == 2)
        #expect(normalizedFacts.contains {
            $0.appStoreID == 200
                && $0.position == 2
                && $0.bundleID == "com.example.competitor"
                && $0.name == "Competitor"
                && $0.subtitle == "Stay focused"
                && $0.sellerName == "Competitor Ltd"
        })
        #expect(normalizedFacts.contains {
            $0.appStoreID == 300
                && $0.position == 7
                && $0.name == "Legacy Only"
        })

        let state = try #require(context.fetch(FetchDescriptor<RankingMigrationState>()).first)
        #expect(state.phase == .completed)
        #expect(state.legacyCrawlCount == 1)
        #expect(state.legacyFactCount == 2)
        #expect(state.legacyTrackedFactCount == 3)
        #expect(state.migratedCrawlCount == 1)
        #expect(state.migratedFactCount == 2)
        #expect(state.migratedTrackedLinkCount == 2)
        #expect(state.recoveredCrawlCount == 1)

        try RankingSchemaV6Migrator.migrateIfNeeded(in: container)
        #expect(try context.fetchCount(FetchDescriptor<RankingCrawlRecord>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<RankingFact>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<TrackedRankingCrawlLink>()) == 2)
    }
}
