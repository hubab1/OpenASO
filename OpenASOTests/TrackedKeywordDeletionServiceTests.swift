import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct TrackedKeywordDeletionServiceTests {
    @Test
    func appDeletionRemovesOwnedStateAndPreservesSharedQueryUntilLastTrack() async throws {
        let container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let fixture = try makeSharedQueryFixture(in: container)
        let store = BackgroundModelStore(modelContainer: container)

        let appDeletion = try await TrackedKeywordDeletionService.deleteApp(
            fixture.firstAppRequest,
            using: store
        )

        #expect(appDeletion.deletedApp)
        #expect(appDeletion.deletedTrackCount == 1)
        #expect(appDeletion.keywordDeletion.deletedQueryKeys.isEmpty)

        var verificationContext = ModelContext(container)
        #expect(try verificationContext.fetch(FetchDescriptor<TrackedApp>()).map(\.appStoreID) == [202])
        #expect(try verificationContext.fetch(FetchDescriptor<TrackedAppKeyword>()).map(\.identityKey) == [
            fixture.secondTrackRequest.identityKey
        ])
        #expect(try verificationContext.fetch(
            FetchDescriptor<TrackedAppKeywordRefreshAttempt>()
        ).map(\.trackIdentityKey) == [fixture.secondTrackRequest.identityKey])
        #expect(try verificationContext.fetch(
            FetchDescriptor<TrackedKeywordRefreshStatus>()
        ).map(\.trackIdentityKey) == [fixture.secondTrackRequest.identityKey])
        #expect(try verificationContext.fetch(
            FetchDescriptor<TrackedKeywordDailyRanking>()
        ).map(\.trackIdentityKey) == [fixture.secondTrackRequest.identityKey])
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<TrackedKeywordRankedResult>()
        ) == 1)

        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordQuery>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordRankingCrawl>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordAppRanking>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<AppKeywordStats>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordDailyMetric>()) == 1)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<EstimatedKeywordDifficultyMetric>()
        ) == 1)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
        ) == 3)

        let finalDeletion = try await TrackedKeywordDeletionService.deleteTracks(
            [fixture.secondTrackRequest],
            using: store
        )

        #expect(finalDeletion.deletedTrackCount == 1)
        #expect(finalDeletion.deletedQueryKeys == [fixture.queryKey])

        verificationContext = ModelContext(container)
        #expect(try verificationContext.fetchCount(FetchDescriptor<TrackedApp>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<TrackedAppKeyword>()) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<TrackedAppKeywordRefreshAttempt>()
        ) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<TrackedKeywordRefreshStatus>()
        ) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<TrackedKeywordDailyRanking>()
        ) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<TrackedKeywordRankedResult>()
        ) == 0)
        // Historical query/ranking/popularity data remains available for audit
        // views. The current heuristic is the generation-bound state removed
        // when its final active track goes away.
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordQuery>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordRankingCrawl>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordAppRanking>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<AppKeywordStats>()) == 1)
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordDailyMetric>()) == 1)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<EstimatedKeywordDifficultyMetric>()
        ) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
        ) == 0)
    }

    @Test
    func delayedOldGenerationCannotPersistIntoReaddedTrack() async throws {
        let container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let fixture = try makeOldGenerationFixture(in: container)
        let store = BackgroundModelStore(modelContainer: container)

        let deletion = try await TrackedKeywordDeletionService.deleteTracks(
            [fixture.deletionRequest],
            using: store
        )
        #expect(deletion.deletedTrackCount == 1)

        let readdedAt = fixture.oldTrackCreatedAt.addingTimeInterval(60)
        let readdContext = ModelContext(container)
        let appStoreID = fixture.appStoreID
        let trackedApp = try #require(readdContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { app in
                app.appStoreID == appStoreID
            }
        )).first)
        let query = try KeywordQuery.fetchOrInsert(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            in: readdContext
        )
        let readdedTrack = TrackedAppKeyword(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query,
            createdAt: readdedAt
        )
        trackedApp.keywordTracks.append(readdedTrack)
        readdContext.insert(readdedTrack)
        try readdContext.save()

        let delayedPage = SearchRankingPage(
            items: rankingItems,
            source: .appStoreWeb
        )
        let delayedResult = RankingRefreshPageResult(
            request: fixture.rankingRequest,
            page: delayedPage,
            searchedAt: Date(timeIntervalSince1970: 5_000),
            observedHour: nil,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source",
            requestedResultLimit: 10,
            estimatedDifficultyPayload: difficultyPayload(
                queryKey: fixture.queryKey,
                rankingFetchedAt: Date(timeIntervalSince1970: 5_000)
            )
        )
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: DeletionTestRankingProvider(),
            appCatalogService: AppCatalogService(
                appResolver: DeletionTestAppResolver()
            )
        )
        let delayedContext = ModelContext(container)

        #expect(throws: OpenASOError.providerUnavailable(
            "The keyword changed while its ranking refresh was in flight. Refresh it again."
        )) {
            try coordinator.persistRankingPage(
                delayedResult,
                in: delayedContext
            )
        }
        let failureResult = try coordinator.recordRefreshFailure(
            identityKey: fixture.rankingRequest.identityKey,
            trackCreatedAt: fixture.rankingRequest.trackCreatedAt,
            error: .networkUnavailable,
            in: delayedContext
        )
        #expect(failureResult == nil)
        try delayedContext.save()

        let verificationContext = ModelContext(container)
        let persistedTracks = try verificationContext.fetch(
            FetchDescriptor<TrackedAppKeyword>()
        )
        #expect(persistedTracks.count == 1)
        #expect(persistedTracks.first?.createdAt == readdedAt)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<TrackedKeywordDailyRanking>()
        ) == 0)
        #expect(try verificationContext.fetchCount(FetchDescriptor<KeywordRankingCrawl>()) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<TrackedKeywordRefreshStatus>()
        ) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<EstimatedKeywordDifficultyMetric>()
        ) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
        ) == 0)
    }

    private func makeSharedQueryFixture(
        in container: ModelContainer
    ) throws -> SharedQueryFixture {
        let context = ModelContext(container)
        let firstApp = TrackedApp(
            appStoreID: 101,
            bundleID: "com.example.first",
            name: "First",
            sellerName: "Example",
            defaultPlatform: .iphone,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let secondApp = TrackedApp(
            appStoreID: 202,
            bundleID: "com.example.second",
            name: "Second",
            sellerName: "Example",
            defaultPlatform: .iphone,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(firstApp)
        context.insert(secondApp)

        let query = try KeywordQuery.fetchOrInsert(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            in: context
        )
        let firstTrack = makeTrack(
            app: firstApp,
            query: query,
            createdAt: Date(timeIntervalSince1970: 300),
            in: context
        )
        let secondTrack = makeTrack(
            app: secondApp,
            query: query,
            createdAt: Date(timeIntervalSince1970: 400),
            in: context
        )
        try addTrackRanking(
            to: firstTrack,
            searchedAt: Date(timeIntervalSince1970: 1_000),
            rankedAppStoreID: 901,
            in: context
        )
        try addTrackRanking(
            to: secondTrack,
            searchedAt: Date(timeIntervalSince1970: 2_000),
            rankedAppStoreID: 902,
            in: context
        )

        let crawl = KeywordRankingCrawl(
            keyword: "focus timer",
            storefront: "us",
            platform: .iphone,
            observedAt: Date(timeIntervalSince1970: 2_000),
            source: .appStoreWeb,
            resultCount: 1,
            query: query
        )
        context.insert(crawl)
        let ranking = KeywordAppRanking(
            position: 1,
            appStoreID: 902,
            bundleID: "com.example.ranking",
            name: "Ranking App",
            sellerName: "Example",
            observation: crawl
        )
        crawl.items.append(ranking)
        context.insert(ranking)
        context.insert(KeywordDailyMetric(
            queryKey: query.queryKey,
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            popularityScore: 55,
            difficultyScore: nil,
            source: .appleAdsPopularity,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        ))
        context.insert(AppKeywordStats(
            appStoreID: ranking.appStoreID,
            queryKey: query.queryKey,
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            rank: ranking.position,
            observedAt: crawl.observedAt
        ))
        try TrackedKeywordRefreshStatusStore.set(
            "First status",
            domain: .ranking,
            for: firstTrack,
            in: context
        )
        try TrackedKeywordRefreshStatusStore.set(
            "Second status",
            domain: .ranking,
            for: secondTrack,
            in: context
        )
        context.insert(TrackedAppKeywordRefreshAttempt(
            trackIdentityKey: firstTrack.identityKey,
            appStoreID: firstTrack.appStoreID,
            lastRankingRefreshAttemptAt: Date(timeIntervalSince1970: 2_100)
        ))
        context.insert(TrackedAppKeywordRefreshAttempt(
            trackIdentityKey: secondTrack.identityKey,
            appStoreID: secondTrack.appStoreID,
            lastRankingRefreshAttemptAt: Date(timeIntervalSince1970: 2_200)
        ))
        _ = try EstimatedKeywordDifficultyStore.upsert(
            difficultyPayload(
                queryKey: query.queryKey,
                rankingFetchedAt: crawl.observedAt
            ),
            in: context
        )
        try context.save()

        return SharedQueryFixture(
            firstAppRequest: TrackedAppDeletionRequest(app: firstApp),
            secondTrackRequest: TrackedKeywordDeletionRequest(track: secondTrack),
            queryKey: query.queryKey
        )
    }

    private func makeOldGenerationFixture(
        in container: ModelContainer
    ) throws -> OldGenerationFixture {
        let context = ModelContext(container)
        let app = TrackedApp(
            appStoreID: 303,
            bundleID: "com.example.generation",
            name: "Generation",
            sellerName: "Example",
            defaultPlatform: .iphone,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        context.insert(app)
        let query = try KeywordQuery.fetchOrInsert(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            in: context
        )
        let createdAt = Date(timeIntervalSince1970: 300)
        let track = makeTrack(
            app: app,
            query: query,
            createdAt: createdAt,
            in: context
        )
        try context.save()

        return OldGenerationFixture(
            appStoreID: app.appStoreID,
            queryKey: query.queryKey,
            oldTrackCreatedAt: createdAt,
            deletionRequest: TrackedKeywordDeletionRequest(track: track),
            rankingRequest: RankingRefreshRequest(track: track)
        )
    }

    private func makeTrack(
        app: TrackedApp,
        query: KeywordQuery,
        createdAt: Date,
        in context: ModelContext
    ) -> TrackedAppKeyword {
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: app,
            query: query,
            createdAt: createdAt
        )
        app.keywordTracks.append(track)
        context.insert(track)
        return track
    }

    private func addTrackRanking(
        to track: TrackedAppKeyword,
        searchedAt: Date,
        rankedAppStoreID: Int64,
        in context: ModelContext
    ) throws {
        let snapshot = TrackedKeywordDailyRanking(
            rank: 1,
            searchedAt: searchedAt,
            source: .appStoreWeb,
            resultCount: 1,
            keywordTrack: track
        )
        track.snapshots.append(snapshot)
        context.insert(snapshot)
        let result = TrackedKeywordRankedResult(
            position: 1,
            appStoreID: rankedAppStoreID,
            bundleID: "com.example.\(rankedAppStoreID)",
            name: "Ranked \(rankedAppStoreID)",
            sellerName: "Example",
            snapshot: snapshot
        )
        snapshot.topResults.append(result)
        context.insert(result)
    }

    private var rankingItems: [SearchRankingItem] {
        (1 ... 3).map { position in
            SearchRankingItem(
                position: position,
                appStoreID: Int64(1_000 + position),
                bundleID: "com.example.\(position)",
                name: "Focus Timer \(position)",
                subtitle: "Focus Timer",
                sellerName: "Example",
                ratingCount: position * 100,
                averageRating: 4.5
            )
        }
    }

    private func difficultyPayload(
        queryKey: String,
        rankingFetchedAt: Date
    ) -> EstimatedKeywordDifficultyPersistencePayload {
        let evidenceItems = rankingItems.map { item in
            EstimatedKeywordDifficultyResultEvidence(
                position: item.position,
                appStoreID: item.appStoreID,
                title: item.name,
                subtitle: item.subtitle,
                ratingCount: item.ratingCount,
                ratingAuthorityScore: 50 + item.position,
                titleTokenCoveragePercentage: 100,
                combinedTokenCoveragePercentage: 100,
                metadataMatchScore: 100,
                exactTitlePhraseMatch: true,
                exactSubtitlePhraseMatch: true
            )
        }
        return EstimatedKeywordDifficultyPersistencePayload(
            queryKey: queryKey,
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-0000000000de")!,
            keyword: "focus timer",
            storefront: "us",
            platform: .iphone,
            result: .estimated(
                score: 65,
                confidenceScore: 80,
                confidence: .medium
            ),
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: 10,
            providerResultCount: evidenceItems.count,
            evidence: EstimatedKeywordDifficultyEvidence(
                consideredResultCount: evidenceItems.count,
                ratedResultCount: evidenceItems.count,
                weightedRatingCoveragePercentage: 100,
                maximumRatingCount: 300,
                medianRatingCount: 200,
                ratingAuthorityScore: 65,
                metadataSaturationScore: 100,
                resultEvidence: evidenceItems
            ),
            rankingSource: .appStoreWeb,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: rankingFetchedAt.addingTimeInterval(1),
            notes: ["Test evidence"]
        )
    }
}

private struct SharedQueryFixture {
    let firstAppRequest: TrackedAppDeletionRequest
    let secondTrackRequest: TrackedKeywordDeletionRequest
    let queryKey: String
}

private struct OldGenerationFixture {
    let appStoreID: Int64
    let queryKey: String
    let oldTrackCreatedAt: Date
    let deletionRequest: TrackedKeywordDeletionRequest
    let rankingRequest: RankingRefreshRequest
}

private actor DeletionTestRankingProvider: SearchRankingProvider {
    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        SearchRankingPage(items: [], source: .appStoreWeb)
    }
}

private actor DeletionTestAppResolver: AppResolver {
    func resolve(
        appStoreID: Int64,
        storefrontCode: String
    ) async throws -> ResolvedApp {
        ResolvedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.\(appStoreID)",
            name: "Example",
            sellerName: "Example",
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
