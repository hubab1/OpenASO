import Foundation
@testable import OpenASO
import SwiftData
import Testing

@MainActor
struct ExactV4StoreFixtureTests {
    @Test
    func exactV4FixtureManifestArtifactsAndEveryEntityAreValid() throws {
        let fixture = try ExactV4StoreFixture.loadFromTestBundle()

        #expect(fixture.manifest.formatVersion == 2)
        #expect(fixture.manifest.fixtureID == ExactV4FixtureSentinel.fixtureID)
        #expect(fixture.manifest.sourceTag == nil)
        #expect(fixture.manifest.sourceCommit == ExactV4FixtureSentinel.sourceCommit)
        #expect(fixture.manifest.sourceTree == ExactV4FixtureSentinel.sourceTree)
        #expect(fixture.manifest.schemaVersion == ExactV4FixtureSentinel.schemaVersion)
        try fixture.manifest.validate(against: .exactV4)

        let materialized = try fixture.makeTemporaryCopy()
        defer { try? FileManager.default.removeItem(at: materialized.directoryURL) }

        try autoreleasepool {
            let schema = Schema(versionedSchema: OpenASOSchemaV4.self)
            let configuration = ModelConfiguration(schema: schema, url: materialized.storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            try assertExactV4FixtureSentinels(in: ModelContext(container))
        }

        try fixture.verifyBundledArtifacts()
    }

    @Test
    func manifestValidationKeepsV1StrictAndRequiresExactV4SourceIdentity() throws {
        let v1Manifest = try ReleasedV1StoreFixture.loadFromTestBundle().manifest
        let invalidV1Mutations: [(inout [String: Any]) -> Void] = [
            { $0["formatVersion"] = 2 },
            { $0["sourceTag"] = "not-v0.3.2" },
            { $0["sourceTree"] = ExactV4FixtureSentinel.sourceTree },
        ]
        for mutation in invalidV1Mutations {
            let invalidManifest = try mutatedManifest(v1Manifest, mutation)
            #expect(throws: StoredMigrationFixtureError.self) {
                try invalidManifest.validate(against: .releasedV1)
            }
        }
        try v1Manifest.validate(against: .releasedV1)

        let v4Manifest = try ExactV4StoreFixture.loadFromTestBundle().manifest
        let invalidV4Mutations: [(inout [String: Any]) -> Void] = [
            { $0["formatVersion"] = 1 },
            { $0["fixtureID"] = "wrong-v4-fixture" },
            { $0["sourceTag"] = "fabricated-v4-tag" },
            { $0["sourceCommit"] = String(repeating: "0", count: 40) },
            { $0["sourceTree"] = String(repeating: "f", count: 40) },
            { $0["schemaVersion"] = "4.0.1" },
            { manifest in
                if let artifacts = manifest["artifacts"] as? [[String: Any]] {
                    manifest["artifacts"] = Array(artifacts.reversed())
                }
            },
        ]
        for mutation in invalidV4Mutations {
            let invalidManifest = try mutatedManifest(v4Manifest, mutation)
            #expect(throws: StoredMigrationFixtureError.self) {
                try invalidManifest.validate(against: .exactV4)
            }
        }
        try v4Manifest.validate(against: .exactV4)
    }

    @Test
    func exactV4FixtureRejectsATamperedCopyWithoutChangingBundledArtifacts() throws {
        let fixture = try ExactV4StoreFixture.loadFromTestBundle()
        let materialized = try fixture.makeTemporaryCopy()
        defer { try? FileManager.default.removeItem(at: materialized.directoryURL) }

        var data = try Data(contentsOf: materialized.storeURL)
        let firstByte = try #require(data.indices.first)
        data[firstByte] ^= 0xFF
        try data.write(to: materialized.storeURL, options: .atomic)

        #expect(throws: StoredMigrationFixtureError.self) {
            try fixture.verifyArtifacts(in: materialized.directoryURL)
        }
        try fixture.verifyBundledArtifacts()
    }

    @Test
    func injectedExactV4OpenFailurePreservesEveryCopiedArtifactByte() throws {
        let fixture = try ExactV4StoreFixture.loadFromTestBundle()
        let materialized = try fixture.makeTemporaryCopy()
        defer { try? FileManager.default.removeItem(at: materialized.directoryURL) }
        let bytesBeforeOpen = try fixture.artifactData(in: materialized.directoryURL)
        var openAttemptCount = 0

        #expect(throws: PersistentStoreError.self) {
            _ = try ModelContainerFactory.makePersistentModelContainer(
                at: materialized.storeURL,
                opener: { _, _ in
                    openAttemptCount += 1
                    throw InjectedExactV4FixtureOpenFailure.expected
                },
            )
        }

        #expect(openAttemptCount == 1)
        #expect(try fixture.artifactData(in: materialized.directoryURL) == bytesBeforeOpen)
        try fixture.verifyArtifacts(in: materialized.directoryURL)
        try fixture.verifyBundledArtifacts()
    }

    private func mutatedManifest(
        _ manifest: StoredMigrationFixtureManifest,
        _ mutation: (inout [String: Any]) -> Void,
    ) throws -> StoredMigrationFixtureManifest {
        let encoded = try JSONEncoder().encode(manifest)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw FixtureManifestMutationError.invalidJSONObject
        }
        mutation(&object)
        return try JSONDecoder().decode(
            StoredMigrationFixtureManifest.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        )
    }
}

@MainActor
func assertExactV4FixtureSentinels(in modelContext: ModelContext) throws {
    let folders = try modelContext.fetch(FetchDescriptor<AppFolder>())
    let appKeywordStats = try modelContext.fetch(FetchDescriptor<AppKeywordStats>())
    let latestRatings = try modelContext.fetch(FetchDescriptor<LatestAppRating>())
    let dailyRatings = try modelContext.fetch(FetchDescriptor<AppDailyRating>())
    let reviews = try modelContext.fetch(FetchDescriptor<AppStorefrontReview>())
    let storeApps = try modelContext.fetch(FetchDescriptor<StoreApp>())
    let metadataRows = try modelContext.fetch(FetchDescriptor<AppStorefrontMetadata>())
    let screenshots = try modelContext.fetch(FetchDescriptor<AppStoreScreenshot>())
    let queries = try modelContext.fetch(FetchDescriptor<KeywordQuery>())
    let keywordMetrics = try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>())
    let crawls = try modelContext.fetch(FetchDescriptor<KeywordRankingCrawl>())
    let crawlItems = try modelContext.fetch(FetchDescriptor<KeywordAppRanking>())
    let trackedApps = try modelContext.fetch(FetchDescriptor<TrackedApp>())
    let tracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
    let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
    let rankedResults = try modelContext.fetch(FetchDescriptor<TrackedKeywordRankedResult>())
    let storefronts = try modelContext.fetch(FetchDescriptor<Storefront>())
    let attempts = try modelContext.fetch(FetchDescriptor<TrackedAppKeywordRefreshAttempt>())
    let statuses = try modelContext.fetch(FetchDescriptor<TrackedKeywordRefreshStatus>())
    let difficulties = try modelContext.fetch(FetchDescriptor<EstimatedKeywordDifficultyMetric>())
    let evidenceRows = try modelContext.fetch(
        FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>(),
    )

    #expect(folders.count == 1)
    #expect(appKeywordStats.count == 1)
    #expect(latestRatings.count == 1)
    #expect(dailyRatings.count == 1)
    #expect(reviews.count == 1)
    #expect(storeApps.count == 1)
    #expect(metadataRows.count == 1)
    #expect(screenshots.count == 1)
    #expect(queries.count == 2)
    #expect(keywordMetrics.count == 1)
    #expect(crawls.count == 1)
    #expect(crawlItems.count == 1)
    #expect(trackedApps.count == 1)
    #expect(tracks.count == 1)
    #expect(snapshots.count == 1)
    #expect(rankedResults.count == 1)
    #expect(storefronts.count == 1)
    #expect(attempts.count == 1)
    #expect(statuses.count == 2)
    #expect(difficulties.count == 2)
    #expect(evidenceRows.count == 5)

    let folder = try #require(folders.first)
    let stats = try #require(appKeywordStats.first)
    let latestRating = try #require(latestRatings.first)
    let dailyRating = try #require(dailyRatings.first)
    let review = try #require(reviews.first)
    let storeApp = try #require(storeApps.first)
    let metadata = try #require(metadataRows.first)
    let screenshot = try #require(screenshots.first)
    let queryByKey = Dictionary(uniqueKeysWithValues: queries.map { ($0.queryKey, $0) })
    let query = try #require(queryByKey[ReleasedV1FixtureSentinel.queryKey])
    let unavailableQuery = try #require(
        queryByKey[ExactV4FixtureSentinel.unavailableQueryKey],
    )
    let metric = try #require(keywordMetrics.first)
    let crawl = try #require(crawls.first)
    let crawlItem = try #require(crawlItems.first)
    let trackedApp = try #require(trackedApps.first)
    let track = try #require(tracks.first)
    let snapshot = try #require(snapshots.first)
    let rankedResult = try #require(rankedResults.first)
    let storefront = try #require(storefronts.first)
    let attempt = try #require(attempts.first)

    #expect(folder.id == ReleasedV1FixtureSentinel.folderID)
    #expect(folder.apps.map(\.appStoreID) == [ReleasedV1FixtureSentinel.appStoreID])
    #expect(stats.identityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
    #expect(stats.bestRank == 5)
    #expect(latestRating.identityKey == "320032001::gb")
    #expect(latestRating.averageRating == 4.625)
    #expect(dailyRating.identityKey == "320032001::gb::2026-04-30")
    #expect(dailyRating.ratingCount == 1180)
    #expect(review.reviewKey == ReleasedV1FixtureSentinel.reviewKey)
    #expect(review.developerResponseID == "response-032")

    #expect(storeApp.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
    #expect(storeApp.bundleID == ReleasedV1FixtureSentinel.bundleID)
    #expect(storeApp.storefrontMetadata.map(\.identityKey) == [metadata.identityKey])
    #expect(storeApp.reviews.map(\.reviewKey) == [review.reviewKey])
    #expect(metadata.descriptionText == ReleasedV1FixtureSentinel.metadataDescription)
    #expect(metadata.screenshots.map(\.identityKey) == [screenshot.identityKey])
    #expect(screenshot.urlString == ReleasedV1FixtureSentinel.screenshotURLString)
    #expect(screenshot.metadata.identityKey == metadata.identityKey)

    #expect(query.queryKey == ReleasedV1FixtureSentinel.queryKey)
    #expect(query.tracks.map(\.identityKey) == [track.identityKey])
    #expect(query.observations.map(\.observationKey) == [crawl.observationKey])
    #expect(unavailableQuery.term == ExactV4FixtureSentinel.unavailableKeyword)
    #expect(unavailableQuery.storefront == ReleasedV1FixtureSentinel.storefront)
    #expect(unavailableQuery.platform == .iphone)
    #expect(unavailableQuery.tracks.isEmpty)
    #expect(unavailableQuery.observations.isEmpty)
    #expect(metric.queryKey == ReleasedV1FixtureSentinel.queryKey)
    #expect(metric.notes == "released-metric-notes")
    #expect(crawl.observedHour == ReleasedV1FixtureSentinel.crawlObservedHour)
    #expect(crawl.items.map(\.itemKey) == [crawlItem.itemKey])
    #expect(crawlItem.appStoreID == ReleasedV1FixtureSentinel.competitorAppStoreID)
    #expect(crawlItem.observation.observationKey == crawl.observationKey)

    #expect(trackedApp.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
    #expect(trackedApp.folder?.id == folder.id)
    #expect(trackedApp.keywordTracks.map(\.identityKey) == [track.identityKey])
    #expect(track.identityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
    #expect(track.statusMessage == nil)
    #expect(track.snapshots.map(\.snapshotKey) == [snapshot.snapshotKey])
    #expect(snapshot.rank == ReleasedV1FixtureSentinel.rank)
    #expect(snapshot.topResults.map(\.appStoreID) == [rankedResult.appStoreID])
    #expect(rankedResult.position == ReleasedV1FixtureSentinel.competitorPosition)
    #expect(rankedResult.name == ReleasedV1FixtureSentinel.competitorName)
    #expect(storefront.code == ReleasedV1FixtureSentinel.storefront)
    #expect(storefront.title == "🇬🇧 United Kingdom")

    #expect(attempt.trackIdentityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
    #expect(attempt.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
    #expect(
        attempt.lastRankingRefreshAttemptAt
            == ReleasedV1FixtureSentinel.fixtureDate.addingTimeInterval(60),
    )

    let statusByKey = Dictionary(uniqueKeysWithValues: statuses.map { ($0.statusKey, $0) })
    let rankingStatus = try #require(statusByKey[ExactV4FixtureSentinel.rankingStatusKey])
    let popularityStatus = try #require(
        statusByKey[ExactV4FixtureSentinel.popularityStatusKey],
    )
    #expect(rankingStatus.domain == .ranking)
    #expect(rankingStatus.message == ExactV4FixtureSentinel.rankingStatusMessage)
    #expect(rankingStatus.updatedAt == ReleasedV1FixtureSentinel.fixtureDate.addingTimeInterval(120))
    #expect(popularityStatus.domain == .popularity)
    #expect(popularityStatus.message == nil)
    #expect(
        popularityStatus.updatedAt
            == ReleasedV1FixtureSentinel.fixtureDate.addingTimeInterval(180),
    )

    let difficultyByID = Dictionary(
        uniqueKeysWithValues: difficulties.map { ($0.calculationID, $0) },
    )
    let estimated = try #require(
        difficultyByID[ExactV4FixtureSentinel.estimatedCalculationID],
    )
    let unavailable = try #require(
        difficultyByID[ExactV4FixtureSentinel.unavailableCalculationID],
    )
    #expect(estimated.queryKey == ReleasedV1FixtureSentinel.queryKey)
    #expect(estimated.state == .estimated)
    #expect(estimated.score == 67)
    #expect(estimated.confidenceScore == 89)
    #expect(estimated.confidence == .high)
    #expect(estimated.consideredResultCount == 3)
    #expect(estimated.ratedResultCount == 3)
    #expect(estimated.weightedRatingCoveragePercentage == 100)
    #expect(estimated.algorithmIdentifier == "openaso.fixture.exact-v4")
    #expect(estimated.notes == ["V4 estimated difficulty sentinel", "immutable source fixture"])
    #expect(unavailable.queryKey == ExactV4FixtureSentinel.unavailableQueryKey)
    #expect(unavailable.keyword == ExactV4FixtureSentinel.unavailableKeyword)
    #expect(unavailable.state == .unavailable)
    #expect(unavailable.score == nil)
    #expect(unavailable.unavailableReason == .insufficientResults)
    #expect(unavailable.consideredResultCount == 2)
    #expect(unavailable.ratedResultCount == 2)
    #expect(unavailable.rankingSource == .iTunesFallback)
    #expect(unavailable.fallbackProviderRaw == RankingSource.appStoreWeb.rawValue)
    #expect(
        unavailable.fallbackCategoryRaw
            == EstimatedKeywordDifficultyFallbackCategory.httpStatus.rawValue,
    )
    #expect(unavailable.fallbackTransportCode == nil)
    #expect(unavailable.fallbackHTTPStatus == 503)
    #expect(unavailable.fallbackResponseFailureRaw == nil)
    #expect(unavailable.notes == ["V4 unavailable difficulty sentinel"])

    let evidenceByCalculationID = Dictionary(grouping: evidenceRows, by: \.calculationID)
    let estimatedEvidence = try #require(
        evidenceByCalculationID[ExactV4FixtureSentinel.estimatedCalculationID],
    ).sorted { $0.position < $1.position }
    let unavailableEvidence = try #require(
        evidenceByCalculationID[ExactV4FixtureSentinel.unavailableCalculationID],
    ).sorted { $0.position < $1.position }
    #expect(estimatedEvidence.map(\.position) == [1, 2, 3])
    #expect(estimatedEvidence.map(\.title) == [
        "First V4 Evidence",
        "Second V4 Evidence",
        "Third V4 Evidence",
    ])
    #expect(estimatedEvidence.map(\.ratingCount) == [12_345, 2_345, 789])
    #expect(estimatedEvidence.first?.exactTitlePhraseMatch == true)
    #expect(unavailableEvidence.map(\.position) == [1, 2])
    #expect(unavailableEvidence.map(\.title) == [
        "First Unavailable V4 Evidence",
        "Second Unavailable V4 Evidence",
    ])
    #expect(unavailableEvidence.map(\.ratingCount) == [300, 100])
}

private enum FixtureManifestMutationError: Error {
    case invalidJSONObject
}

private enum InjectedExactV4FixtureOpenFailure: Error {
    case expected
}
