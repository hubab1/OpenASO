import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct TrackedKeywordRefreshStatusTests {
    @Test
    func rankingAndPopularityStatusesCoexistAndClearIndependently() throws {
        let fixture = try makeFixture()
        let rankingDate = Date(timeIntervalSince1970: 1_000)
        let popularityDate = Date(timeIntervalSince1970: 2_000)

        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. Network unavailable.",
            domain: .ranking,
            for: fixture.track,
            updatedAt: rankingDate,
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            "Popularity failed to fetch. Connect Apple Ads in Settings.",
            domain: .popularity,
            for: fixture.track,
            updatedAt: popularityDate,
            in: fixture.modelContext
        )

        var snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: fixture.track,
            in: fixture.modelContext
        )
        #expect(snapshot.rankingMessage == "Ranking failed to refresh. Network unavailable.")
        #expect(snapshot.rankingUpdatedAt == rankingDate)
        #expect(snapshot.popularityMessage == "Popularity failed to fetch. Connect Apple Ads in Settings.")
        #expect(snapshot.popularityUpdatedAt == popularityDate)
        #expect(snapshot.preferredMessage == snapshot.rankingMessage)
        #expect(snapshot.displayMessage?.contains(snapshot.rankingMessage ?? "") == true)
        #expect(snapshot.displayMessage?.contains(snapshot.popularityMessage ?? "") == true)
        #expect(fixture.track.statusMessage == nil)

        try TrackedKeywordRefreshStatusStore.set(
            nil,
            domain: .ranking,
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            in: fixture.modelContext
        )
        snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: fixture.track,
            in: fixture.modelContext
        )
        #expect(snapshot.rankingMessage == nil)
        #expect(snapshot.popularityMessage == "Popularity failed to fetch. Connect Apple Ads in Settings.")
    }

    @Test
    func olderCompletionCannotClearOrOverwriteANewerSameDomainFailure() throws {
        let fixture = try makeFixture()
        let newerDate = Date(timeIntervalSince1970: 3_000)
        let olderDate = Date(timeIntervalSince1970: 2_000)

        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. Newer failure.",
            domain: .ranking,
            for: fixture.track,
            updatedAt: newerDate,
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            nil,
            domain: .ranking,
            for: fixture.track,
            updatedAt: olderDate,
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. Older failure.",
            domain: .ranking,
            for: fixture.track,
            updatedAt: olderDate,
            in: fixture.modelContext
        )

        let snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: fixture.track,
            in: fixture.modelContext
        )
        #expect(snapshot.rankingMessage == "Ranking failed to refresh. Newer failure.")
        #expect(snapshot.rankingUpdatedAt == newerDate)
    }

    @Test
    func newerClearWatermarkPreventsAnOlderFailureFromResurfacing() throws {
        let fixture = try makeFixture()
        let failureDate = Date(timeIntervalSince1970: 1_000)
        let clearDate = Date(timeIntervalSince1970: 3_000)
        let delayedFailureDate = Date(timeIntervalSince1970: 2_000)

        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. Initial failure.",
            domain: .ranking,
            for: fixture.track,
            updatedAt: failureDate,
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            nil,
            domain: .ranking,
            for: fixture.track,
            updatedAt: clearDate,
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. Delayed stale failure.",
            domain: .ranking,
            for: fixture.track,
            updatedAt: delayedFailureDate,
            in: fixture.modelContext
        )

        let snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: fixture.track,
            in: fixture.modelContext
        )
        #expect(snapshot.rankingMessage == nil)
        #expect(snapshot.rankingUpdatedAt == clearDate)
    }

    @Test
    func concurrentContextsResolveByTimestampInsteadOfSaveOrder() throws {
        let fixture = try makeFixture()
        try fixture.modelContext.save()
        let identityKey = fixture.track.identityKey
        let olderContext = ModelContext(fixture.container)
        let newerContext = ModelContext(fixture.container)
        olderContext.autosaveEnabled = false
        newerContext.autosaveEnabled = false
        let olderTrack = try #require(olderContext.fetch(FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.identityKey == identityKey
            }
        )).first)
        let newerTrack = try #require(newerContext.fetch(FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.identityKey == identityKey
            }
        )).first)

        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. Delayed stale failure.",
            domain: .ranking,
            for: olderTrack,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            in: olderContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            nil,
            domain: .ranking,
            for: newerTrack,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            in: newerContext
        )

        // Deliberately commit the stale context last. An upsert can regress in
        // this ordering; timestamped contenders remain deterministic.
        try newerContext.save()
        try olderContext.save()

        let verificationContext = ModelContext(fixture.container)
        let verificationTrack = try #require(verificationContext.fetch(
            FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    track.identityKey == identityKey
                }
            )
        ).first)
        let snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: verificationTrack,
            in: verificationContext
        )
        #expect(snapshot.rankingMessage == nil)
        #expect(snapshot.rankingUpdatedAt == Date(timeIntervalSince1970: 3_000))
    }

    @Test
    func staleStatusSavedAfterDeletionDoesNotAttachToAReaddedTrack() throws {
        let fixture = try makeFixture()
        try fixture.modelContext.save()
        let identityKey = fixture.track.identityKey
        let staleRefreshContext = ModelContext(fixture.container)
        let deletionContext = ModelContext(fixture.container)
        staleRefreshContext.autosaveEnabled = false
        deletionContext.autosaveEnabled = false
        let staleTrack = try #require(staleRefreshContext.fetch(
            FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    track.identityKey == identityKey
                }
            )
        ).first)
        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. Stale deleted generation.",
            domain: .ranking,
            for: staleTrack,
            in: staleRefreshContext
        )

        let deletingTrack = try #require(deletionContext.fetch(
            FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    track.identityKey == identityKey
                }
            )
        ).first)
        try TrackedKeywordRefreshStatusStore.deleteStatuses(
            for: [identityKey],
            in: deletionContext
        )
        deletionContext.delete(deletingTrack)
        try deletionContext.save()

        // The in-flight refresh commits after deletion and leaves an orphaned
        // event for the old track generation.
        try staleRefreshContext.save()

        let readdContext = ModelContext(fixture.container)
        let trackedApp = try #require(readdContext.fetch(FetchDescriptor<TrackedApp>()).first)
        let query = try KeywordQuery.fetchOrInsert(
            term: "focus app",
            storefront: "us",
            platform: .iphone,
            in: readdContext
        )
        let readdedTrack = TrackedAppKeyword(
            term: "focus app",
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query,
            createdAt: Date(timeIntervalSince1970: 9_999)
        )
        #expect(readdedTrack.identityKey == identityKey)
        trackedApp.keywordTracks.append(readdedTrack)
        readdContext.insert(readdedTrack)
        try readdContext.save()

        let snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: readdedTrack,
            in: readdContext
        )
        #expect(snapshot.rankingMessage == nil)
        #expect(snapshot.popularityMessage == nil)
        #expect(try readdContext.fetch(FetchDescriptor<TrackedKeywordRefreshStatus>()).count == 1)
    }

    @Test(arguments: [
        ("Popularity failed to fetch. Missing session.", KeywordRefreshStatusDomain.popularity),
        ("Popularity unavailable. Unsupported storefront.", KeywordRefreshStatusDomain.popularity),
        ("Ranking failed to refresh. Network unavailable.", KeywordRefreshStatusDomain.ranking),
        ("released-status-sentinel", KeywordRefreshStatusDomain.ranking),
        ("popularity failed to fetch. Wrong case.", KeywordRefreshStatusDomain.ranking)
    ])
    func legacyClassificationIsExactAndConservative(
        message: String,
        expectedDomain: KeywordRefreshStatusDomain
    ) {
        #expect(TrackedKeywordRefreshStatusStore.domain(forLegacyMessage: message) == expectedDomain)
    }

    @Test
    func legacyPopularityStatusMovesToCompanionRowAndClearsTheV1Field() throws {
        let fixture = try makeFixture()
        let legacyMessage = "Popularity unavailable. Unsupported storefront."
        let migratedAt = Date(timeIntervalSince1970: 1_000)
        fixture.track.statusMessage = legacyMessage

        try TrackedKeywordRefreshStatusStore.migrateLegacyStatusIfNeeded(
            for: fixture.track,
            migratedAt: migratedAt,
            in: fixture.modelContext
        )

        let snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: fixture.track,
            in: fixture.modelContext
        )
        #expect(fixture.track.statusMessage == nil)
        #expect(snapshot.rankingMessage == nil)
        #expect(snapshot.popularityMessage == legacyMessage)
        #expect(snapshot.popularityUpdatedAt == migratedAt)
    }

    @Test
    func bulkSnapshotsStayScopedAndStatusDeletionPreventsResurrection() throws {
        let fixture = try makeFixture()
        let secondTrack = try makeTrack(
            term: "second keyword",
            appStoreID: fixture.track.appStoreID,
            trackedApp: fixture.trackedApp,
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            "Ranking failed to refresh. First.",
            domain: .ranking,
            for: fixture.track,
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            "Popularity failed to fetch. Second.",
            domain: .popularity,
            for: secondTrack,
            in: fixture.modelContext
        )

        var snapshots = try TrackedKeywordRefreshStatusStore.snapshots(
            for: [fixture.track.identityKey],
            in: fixture.modelContext
        )
        #expect(snapshots.count == 1)
        #expect(snapshots[fixture.track.identityKey]?.rankingMessage == "Ranking failed to refresh. First.")

        try TrackedKeywordRefreshStatusStore.deleteStatuses(
            for: [fixture.track.identityKey],
            in: fixture.modelContext
        )
        snapshots = try TrackedKeywordRefreshStatusStore.snapshots(
            for: [fixture.track.identityKey, secondTrack.identityKey],
            in: fixture.modelContext
        )
        #expect(snapshots[fixture.track.identityKey] == nil)
        #expect(snapshots[secondTrack.identityKey]?.popularityMessage == "Popularity failed to fetch. Second.")
    }

    @Test
    func workspaceUsesRankingForGeneralStatusAndPopularityForItsIndicator() throws {
        let fixture = try makeFixture()
        let rankingMessage = "Ranking failed to refresh. Network unavailable."
        let popularityMessage = "Popularity failed to fetch. Connect Apple Ads in Settings."
        let row = KeywordWorkspaceRow(
            track: fixture.track,
            storefront: nil,
            metrics: Optional<KeywordMetricsSnapshot>.none,
            refreshStatus: KeywordRefreshStatusSnapshot(
                rankingMessage: rankingMessage,
                rankingUpdatedAt: Date(timeIntervalSince1970: 1_000),
                popularityMessage: popularityMessage,
                popularityUpdatedAt: Date(timeIntervalSince1970: 2_000)
            ),
            latestSnapshot: Optional<KeywordRankingCrawlSummary>.none,
            trendSnapshots: [],
            rankingApps: []
        )

        #expect(row.statusMessage?.contains(rankingMessage) == true)
        #expect(row.statusMessage?.contains(popularityMessage) == true)
        #expect(row.popularityIndicatorState(now: Date(timeIntervalSince1970: 3_000)) == .needsSetup(
            message: popularityMessage
        ))
    }

    @Test
    func freshMetricsClearOnlyPopularityStatus() async throws {
        let fixture = try makeFixture()
        let metricDate = Date(timeIntervalSince1970: 2_000_000_000)
        let rankingMessage = "Ranking failed to refresh. Keep this failure."
        try TrackedKeywordRefreshStatusStore.set(
            rankingMessage,
            domain: .ranking,
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 1_999_999_998),
            in: fixture.modelContext
        )
        try TrackedKeywordRefreshStatusStore.set(
            "Popularity failed to fetch. Resolved failure.",
            domain: .popularity,
            for: fixture.track,
            updatedAt: Date(timeIntervalSince1970: 1_999_999_999),
            in: fixture.modelContext
        )
        fixture.modelContext.insert(KeywordDailyMetric(
            queryKey: fixture.track.queryKey,
            keyword: fixture.track.term,
            storefront: fixture.track.storefront,
            platform: fixture.track.platform,
            popularityScore: 75,
            difficultyScore: nil,
            source: .appleAdsPopularity,
            updatedAt: metricDate
        ))
        try fixture.modelContext.save()
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                Issue.record("Unexpected request to \(request.url?.absoluteString ?? "unknown")")
                throw OpenASOError.networkUnavailable
            },
            modelContainer: fixture.container
        )

        _ = await services.keywordMetricsService.refreshMetrics(
            for: fixture.trackedApp,
            tracks: [fixture.track],
            in: fixture.modelContext
        )

        let snapshot = try TrackedKeywordRefreshStatusStore.snapshot(
            for: fixture.track,
            in: fixture.modelContext
        )
        #expect(snapshot.rankingMessage == rankingMessage)
        #expect(snapshot.popularityMessage == nil)
    }

    @Test
    func backgroundFreshSharedQueryClearsEveryPopularitySiblingOnly() async throws {
        let fixture = try makeFixture()
        let secondApp = TrackedApp(
            appStoreID: 456,
            bundleID: "com.example.second",
            name: "Second",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        fixture.modelContext.insert(secondApp)
        let secondTrack = try makeTrack(
            term: fixture.track.term,
            appStoreID: secondApp.appStoreID,
            trackedApp: secondApp,
            in: fixture.modelContext
        )
        let rankingMessages = [
            fixture.track.identityKey: "Ranking failed to refresh. First.",
            secondTrack.identityKey: "Ranking failed to refresh. Second.",
        ]
        let firstIdentityKey = fixture.track.identityKey
        let secondIdentityKey = secondTrack.identityKey
        let identityKeys = [firstIdentityKey, secondIdentityKey]
        for track in [fixture.track, secondTrack] {
            try TrackedKeywordRefreshStatusStore.set(
                rankingMessages[track.identityKey],
                domain: .ranking,
                for: track,
                updatedAt: Date(timeIntervalSince1970: 1_999_999_998),
                in: fixture.modelContext
            )
            try TrackedKeywordRefreshStatusStore.set(
                "Popularity failed to fetch. Resolved shared-query failure.",
                domain: .popularity,
                for: track,
                updatedAt: Date(timeIntervalSince1970: 1_999_999_999),
                in: fixture.modelContext
            )
        }
        fixture.modelContext.insert(KeywordDailyMetric(
            queryKey: fixture.track.queryKey,
            keyword: fixture.track.term,
            storefront: fixture.track.storefront,
            platform: fixture.track.platform,
            popularityScore: 80,
            difficultyScore: nil,
            source: .appleAdsPopularity,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        ))
        try fixture.modelContext.save()
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { _ in throw OpenASOError.networkUnavailable },
            modelContainer: fixture.container
        )
        let backgroundStore = BackgroundModelStore(modelContainer: fixture.container)

        _ = try await services.keywordMetricsService.refreshMetrics(
            for: identityKeys,
            using: backgroundStore
        )

        let snapshots = try await backgroundStore.read { modelContext in
            try TrackedKeywordRefreshStatusStore.snapshots(
                for: identityKeys,
                in: modelContext
            )
        }
        #expect(snapshots[firstIdentityKey]?.rankingMessage == rankingMessages[firstIdentityKey])
        #expect(snapshots[secondIdentityKey]?.rankingMessage == rankingMessages[secondIdentityKey])
        #expect(snapshots[firstIdentityKey]?.popularityMessage == nil)
        #expect(snapshots[secondIdentityKey]?.popularityMessage == nil)
    }

    @Test
    func backgroundSharedQueryFailureMarksEveryPopularitySiblingOnly() async throws {
        let fixture = try makeFixture()
        let secondApp = TrackedApp(
            appStoreID: 456,
            bundleID: "com.example.second",
            name: "Second",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        fixture.modelContext.insert(secondApp)
        let secondTrack = try makeTrack(
            term: fixture.track.term,
            appStoreID: secondApp.appStoreID,
            trackedApp: secondApp,
            in: fixture.modelContext
        )
        let tracks = [fixture.track, secondTrack]
        for track in tracks {
            try TrackedKeywordRefreshStatusStore.set(
                "Ranking failed to refresh. Preserve this failure.",
                domain: .ranking,
                for: track,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                in: fixture.modelContext
            )
        }
        try fixture.modelContext.save()
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { _ in
                Issue.record("Missing credentials should not make a request")
                throw OpenASOError.networkUnavailable
            },
            modelContainer: fixture.container
        )
        let backgroundStore = BackgroundModelStore(modelContainer: fixture.container)
        let identityKeys = tracks.map(\.identityKey)

        _ = try await services.keywordMetricsService.refreshMetrics(
            for: identityKeys,
            using: backgroundStore
        )

        let snapshots = try await backgroundStore.read { modelContext in
            try TrackedKeywordRefreshStatusStore.snapshots(
                for: identityKeys,
                in: modelContext
            )
        }
        for identityKey in identityKeys {
            #expect(snapshots[identityKey]?.rankingMessage == "Ranking failed to refresh. Preserve this failure.")
            #expect(
                snapshots[identityKey]?.popularityMessage
                    == "Popularity failed to fetch. Configure and verify Apple Ads Platform API credentials in Settings."
            )
        }
    }

    private func makeFixture() throws -> StatusFixture {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 123,
            bundleID: "com.example.app",
            name: "Example",
            sellerName: "Example",
            defaultPlatform: .iphone,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        modelContext.insert(trackedApp)
        let track = try makeTrack(
            term: "focus app",
            appStoreID: trackedApp.appStoreID,
            trackedApp: trackedApp,
            in: modelContext
        )
        return StatusFixture(
            container: container,
            modelContext: modelContext,
            trackedApp: trackedApp,
            track: track
        )
    }

    private func makeTrack(
        term: String,
        appStoreID: Int64,
        trackedApp: TrackedApp,
        in modelContext: ModelContext
    ) throws -> TrackedAppKeyword {
        let query = try KeywordQuery.fetchOrInsert(
            term: term,
            storefront: "us",
            platform: .iphone,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: term,
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query,
            createdAt: Date(timeIntervalSince1970: 200 + Double(appStoreID))
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)
        return track
    }
}

@MainActor
private struct StatusFixture {
    let container: ModelContainer
    let modelContext: ModelContext
    let trackedApp: TrackedApp
    let track: TrackedAppKeyword
}
