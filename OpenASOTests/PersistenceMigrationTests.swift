import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct PersistenceMigrationTests {
    @Test
    func migrationPlanAppendsThroughV4AndKeepsTheReleasedV1SchemaFrozen() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)

        #expect(OpenASOSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(OpenASOSchemaV1.models.count == 17)
        #expect(OpenASOSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(OpenASOSchemaV2.models.count == 18)
        #expect(OpenASOSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
        #expect(OpenASOSchemaV3.models.count == 19)
        #expect(OpenASOSchemaV4.versionIdentifier == Schema.Version(4, 0, 0))
        #expect(OpenASOSchemaV4.models.count == 21)
        #expect(OpenASOMigrationPlan.currentSchema.versionIdentifier == Schema.Version(4, 0, 0))
        #expect(OpenASOMigrationPlan.schemas.count == 4)
        #expect(OpenASOMigrationPlan.schemas[0].versionIdentifier == OpenASOSchemaV1.versionIdentifier)
        #expect(OpenASOMigrationPlan.schemas[1].versionIdentifier == OpenASOSchemaV2.versionIdentifier)
        #expect(OpenASOMigrationPlan.schemas[2].versionIdentifier == OpenASOSchemaV3.versionIdentifier)
        #expect(OpenASOMigrationPlan.schemas[3].versionIdentifier == OpenASOSchemaV4.versionIdentifier)
        #expect(
            OpenASOMigrationPlan.currentSchema.versionIdentifier
                == OpenASOMigrationPlan.schemas.last?.versionIdentifier
        )
        #expect(OpenASOMigrationPlan.stages.count == 3)
        #expect(container.migrationPlan != nil)
    }

    @Test
    func releasedV032StoreOpensWritesAndReopensWithAllEntitiesAndRelationships() throws {
        let fixture = try ReleasedV1StoreFixture.loadFromTestBundle()
        let materialized = try fixture.makeTemporaryCopy()
        let migrationStartedAt = Date.now
        defer {
            try? FileManager.default.removeItem(at: materialized.directoryURL)
        }

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(
                at: materialized.storeURL
            )
            let modelContext = ModelContext(container)
            try assertReleasedV1Sentinels(in: modelContext)
            #expect(try modelContext.fetch(
                FetchDescriptor<TrackedAppKeywordRefreshAttempt>()
            ).isEmpty)
            #expect(try modelContext.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyMetric>()
            ).isEmpty)
            #expect(try modelContext.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
            ).isEmpty)
            let migratedStatus = try #require(modelContext.fetch(
                FetchDescriptor<TrackedKeywordRefreshStatus>()
            ).first)
            #expect(migratedStatus.trackIdentityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
            #expect(migratedStatus.domain == .ranking)
            #expect(migratedStatus.message == "released-status-sentinel")
            #expect(migratedStatus.updatedAt >= migrationStartedAt)
            #expect(migratedStatus.updatedAt <= Date.now)

            let track = try #require(modelContext.fetch(FetchDescriptor<TrackedAppKeyword>()).first)
            track.notes = ReleasedV1FixtureSentinel.reopenWriteNotes
            modelContext.insert(TrackedAppKeywordRefreshAttempt(
                trackIdentityKey: track.identityKey,
                appStoreID: track.appStoreID,
                lastRankingRefreshAttemptAt: ReleasedV1FixtureSentinel.refreshAttemptDate
            ))
            try modelContext.save()
        }

        try autoreleasepool {
            let reopenedContainer = try ModelContainerFactory.makePersistentModelContainer(
                at: materialized.storeURL
            )
            let reopenedContext = ModelContext(reopenedContainer)
            try assertReleasedV1Sentinels(
                in: reopenedContext,
                expectedTrackNotes: ReleasedV1FixtureSentinel.reopenWriteNotes
            )
            let attempt = try #require(reopenedContext.fetch(
                FetchDescriptor<TrackedAppKeywordRefreshAttempt>()
            ).first)
            #expect(attempt.trackIdentityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
            #expect(attempt.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
            #expect(
                attempt.lastRankingRefreshAttemptAt
                    == ReleasedV1FixtureSentinel.refreshAttemptDate
            )
            let migratedStatus = try #require(reopenedContext.fetch(
                FetchDescriptor<TrackedKeywordRefreshStatus>()
            ).first)
            #expect(migratedStatus.trackIdentityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
            #expect(migratedStatus.domain == .ranking)
            #expect(migratedStatus.message == "released-status-sentinel")
            #expect(try reopenedContext.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyMetric>()
            ).isEmpty)
            #expect(try reopenedContext.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
            ).isEmpty)
        }

        try fixture.verifyBundledArtifacts()
    }

    @Test
    func v2RefreshAttemptStoreMigratesToV4WithoutLosingAttemptState() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenASO-V2-to-V3-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)

        try autoreleasepool {
            let schema = Schema(versionedSchema: OpenASOSchemaV2.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(TrackedAppKeywordRefreshAttempt(
                trackIdentityKey: ReleasedV1FixtureSentinel.trackIdentityKey,
                appStoreID: ReleasedV1FixtureSentinel.appStoreID,
                lastRankingRefreshAttemptAt: ReleasedV1FixtureSentinel.refreshAttemptDate
            ))
            try context.save()
        }

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let context = ModelContext(container)
            let attempt = try #require(context.fetch(
                FetchDescriptor<TrackedAppKeywordRefreshAttempt>()
            ).first)
            #expect(attempt.trackIdentityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
            #expect(attempt.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
            #expect(attempt.lastRankingRefreshAttemptAt == ReleasedV1FixtureSentinel.refreshAttemptDate)
            #expect(try context.fetch(FetchDescriptor<TrackedKeywordRefreshStatus>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<EstimatedKeywordDifficultyMetric>()).isEmpty)
            #expect(try context.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
            ).isEmpty)
        }
    }

    @Test
    func v3StatusStoreMigratesToV4WithoutBackfillingDifficulty() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenASO-V3-to-V4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)
        let createdAt = Date(timeIntervalSinceReferenceDate: 795_100_000)
        let updatedAt = createdAt.addingTimeInterval(60)

        try autoreleasepool {
            let schema = Schema(versionedSchema: OpenASOSchemaV3.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(TrackedAppKeywordRefreshAttempt(
                trackIdentityKey: ReleasedV1FixtureSentinel.trackIdentityKey,
                appStoreID: ReleasedV1FixtureSentinel.appStoreID,
                lastRankingRefreshAttemptAt: updatedAt
            ))
            context.insert(TrackedKeywordRefreshStatus(
                trackIdentityKey: ReleasedV1FixtureSentinel.trackIdentityKey,
                trackCreatedAt: createdAt,
                appStoreID: ReleasedV1FixtureSentinel.appStoreID,
                domain: .popularity,
                message: "Popularity unavailable.",
                updatedAt: updatedAt
            ))
            try context.save()
        }

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let context = ModelContext(container)
            let attempt = try #require(context.fetch(
                FetchDescriptor<TrackedAppKeywordRefreshAttempt>()
            ).first)
            let status = try #require(context.fetch(
                FetchDescriptor<TrackedKeywordRefreshStatus>()
            ).first)
            #expect(attempt.lastRankingRefreshAttemptAt == updatedAt)
            #expect(status.domain == .popularity)
            #expect(status.message == "Popularity unavailable.")
            #expect(try context.fetch(FetchDescriptor<EstimatedKeywordDifficultyMetric>()).isEmpty)
            #expect(try context.fetch(
                FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
            ).isEmpty)
        }
    }

    @Test
    func fixtureManifestChecksumRejectsATamperedStoreCopy() throws {
        let fixture = try ReleasedV1StoreFixture.loadFromTestBundle()
        let materialized = try fixture.makeTemporaryCopy()
        defer {
            try? FileManager.default.removeItem(at: materialized.directoryURL)
        }

        var data = try Data(contentsOf: materialized.storeURL)
        let firstByte = try #require(data.indices.first)
        data[firstByte] ^= 0xff
        try data.write(to: materialized.storeURL, options: .atomic)

        #expect(throws: ReleasedV1StoreFixtureError.self) {
            try fixture.verifyArtifacts(in: materialized.directoryURL)
        }
        try fixture.verifyBundledArtifacts()
    }

    @Test
    func injectedFixtureOpenFailurePreservesEveryStoreArtifactByte() throws {
        let fixture = try ReleasedV1StoreFixture.loadFromTestBundle()
        let materialized = try fixture.makeTemporaryCopy()
        defer {
            try? FileManager.default.removeItem(at: materialized.directoryURL)
        }
        let bytesBeforeOpen = try fixture.artifactData(in: materialized.directoryURL)
        var openAttemptCount = 0

        #expect(throws: PersistentStoreError.self) {
            _ = try ModelContainerFactory.makePersistentModelContainer(
                at: materialized.storeURL,
                opener: { _, _ in
                    openAttemptCount += 1
                    throw InjectedReleasedFixtureOpenFailure.expected
                }
            )
        }

        #expect(openAttemptCount == 1)
        #expect(try fixture.artifactData(in: materialized.directoryURL) == bytesBeforeOpen)
        try fixture.verifyArtifacts(in: materialized.directoryURL)
        try fixture.verifyBundledArtifacts()
    }

    private func assertReleasedV1Sentinels(
        in modelContext: ModelContext,
        expectedTrackNotes: String = ReleasedV1FixtureSentinel.originalTrackNotes
    ) throws {
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

        #expect(folders.count == 1)
        #expect(appKeywordStats.count == 1)
        #expect(latestRatings.count == 1)
        #expect(dailyRatings.count == 1)
        #expect(reviews.count == 1)
        #expect(storeApps.count == 1)
        #expect(metadataRows.count == 1)
        #expect(screenshots.count == 1)
        #expect(queries.count == 1)
        #expect(keywordMetrics.count == 1)
        #expect(crawls.count == 1)
        #expect(crawlItems.count == 1)
        #expect(trackedApps.count == 1)
        #expect(tracks.count == 1)
        #expect(snapshots.count == 1)
        #expect(rankedResults.count == 1)
        #expect(storefronts.count == 1)

        let folder = try #require(folders.first)
        let stats = try #require(appKeywordStats.first)
        let latestRating = try #require(latestRatings.first)
        let dailyRating = try #require(dailyRatings.first)
        let review = try #require(reviews.first)
        let storeApp = try #require(storeApps.first)
        let metadata = try #require(metadataRows.first)
        let screenshot = try #require(screenshots.first)
        let query = try #require(queries.first)
        let metric = try #require(keywordMetrics.first)
        let crawl = try #require(crawls.first)
        let crawlItem = try #require(crawlItems.first)
        let trackedApp = try #require(trackedApps.first)
        let track = try #require(tracks.first)
        let snapshot = try #require(snapshots.first)
        let rankedResult = try #require(rankedResults.first)
        let storefront = try #require(storefronts.first)

        #expect(folder.id == ReleasedV1FixtureSentinel.folderID)
        #expect(folder.name == ReleasedV1FixtureSentinel.folderName)
        #expect(folder.sortOrder == 1)
        #expect(folder.colorRaw == "purple")
        #expect(!folder.isExpanded)
        #expect(folder.createdAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(folder.apps.map(\.appStoreID) == [ReleasedV1FixtureSentinel.appStoreID])

        #expect(storeApp.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
        #expect(storeApp.bundleID == ReleasedV1FixtureSentinel.bundleID)
        #expect(storeApp.name == ReleasedV1FixtureSentinel.appName)
        #expect(storeApp.subtitle == "Released-schema sentinel")
        #expect(storeApp.sellerName == "Third Tech Fixture")
        #expect(storeApp.iconURLString == "https://example.com/openaso-v032-icon.png")
        #expect(storeApp.defaultStorefront == ReleasedV1FixtureSentinel.storefront)
        #expect(storeApp.supportedLanguageCodes == ["en-GB", "fr"])
        #expect(storeApp.supportedLanguageCodesSource == .appStoreWeb)
        #expect(storeApp.supportedLanguageCodesFetchedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(storeApp.releaseDate == ReleasedV1FixtureSentinel.releaseDate)
        #expect(storeApp.currentVersionReleaseDate == ReleasedV1FixtureSentinel.priorDate)
        #expect(storeApp.version == "0.3.2")
        #expect(storeApp.primaryGenreID == 6002)
        #expect(storeApp.primaryGenreName == "Utilities")
        #expect(storeApp.defaultPlatform == .iphone)
        #expect(storeApp.lastMetadataRefreshAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(storeApp.storefrontMetadata.map(\.identityKey) == [metadata.identityKey])
        #expect(storeApp.storefrontLatest.map(\.identityKey) == [latestRating.identityKey])
        #expect(storeApp.ratingSnapshots.map(\.identityKey) == [dailyRating.identityKey])
        #expect(storeApp.reviews.map(\.reviewKey) == [review.reviewKey])

        #expect(trackedApp.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
        #expect(trackedApp.createdAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(trackedApp.isPinned)
        #expect(trackedApp.sidebarSortOrder == 3)
        #expect(trackedApp.storeApp.appStoreID == storeApp.appStoreID)
        #expect(trackedApp.folder?.id == folder.id)
        #expect(trackedApp.keywordTracks.map(\.identityKey) == [track.identityKey])

        #expect(metadata.appStoreID == storeApp.appStoreID)
        #expect(metadata.storeApp.appStoreID == storeApp.appStoreID)
        #expect(metadata.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(metadata.defaultPlatform == .iphone)
        #expect(metadata.name == ReleasedV1FixtureSentinel.appName)
        #expect(metadata.subtitle == "Fixture metadata subtitle")
        #expect(metadata.sellerName == "Third Tech Fixture")
        #expect(metadata.descriptionText == ReleasedV1FixtureSentinel.metadataDescription)
        #expect(metadata.releaseNotes == "Released fixture notes")
        #expect(metadata.iconURLString == "https://example.com/openaso-v032-metadata-icon.png")
        #expect(metadata.version == "0.3.2")
        #expect(metadata.releaseDate == ReleasedV1FixtureSentinel.releaseDate)
        #expect(metadata.currentVersionReleaseDate == ReleasedV1FixtureSentinel.priorDate)
        #expect(metadata.primaryGenreID == 6002)
        #expect(metadata.primaryGenreName == "Utilities")
        #expect(metadata.storefrontLanguageCode == "en-GB")
        #expect(metadata.servedLanguageCode == "en")
        #expect(metadata.isLocalized == true)
        #expect(metadata.isAvailable)
        #expect(metadata.source == .appStoreWeb)
        #expect(metadata.lastFetchedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(metadata.screenshots.map(\.identityKey) == [screenshot.identityKey])

        #expect(screenshot.appStoreID == storeApp.appStoreID)
        #expect(screenshot.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(screenshot.platformRaw == "iphone")
        #expect(screenshot.displayTypeRaw == "phone")
        #expect(screenshot.sortOrder == 0)
        #expect(screenshot.urlString == ReleasedV1FixtureSentinel.screenshotURLString)
        #expect(screenshot.width == 1290)
        #expect(screenshot.height == 2796)
        #expect(screenshot.source == .appStoreWeb)
        #expect(screenshot.lastFetchedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(screenshot.metadata.identityKey == metadata.identityKey)

        #expect(query.queryKey == ReleasedV1FixtureSentinel.queryKey)
        #expect(query.term == ReleasedV1FixtureSentinel.keyword)
        #expect(query.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(query.platform == .iphone)
        #expect(query.tracks.map(\.identityKey) == [track.identityKey])
        #expect(query.observations.map(\.observationKey) == [crawl.observationKey])

        #expect(track.identityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
        #expect(track.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
        #expect(track.term == ReleasedV1FixtureSentinel.keyword)
        #expect(track.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(track.platform == .iphone)
        #expect(track.rankingAppCount == ReleasedV1FixtureSentinel.resultCount)
        #expect(track.lastRefreshAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(track.notes == expectedTrackNotes)
        #expect(track.statusMessage == nil)
        #expect(track.createdAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(track.trackedApp.appStoreID == trackedApp.appStoreID)
        #expect(track.query.queryKey == query.queryKey)
        #expect(track.snapshots.map(\.snapshotKey) == [snapshot.snapshotKey])

        #expect(snapshot.trackIdentityKey == track.identityKey)
        #expect(snapshot.keywordTrack.identityKey == track.identityKey)
        #expect(snapshot.rank == ReleasedV1FixtureSentinel.rank)
        #expect(snapshot.resultCount == ReleasedV1FixtureSentinel.resultCount)
        #expect(snapshot.searchedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(snapshot.source == .iTunesFallback)
        #expect(snapshot.errorMessage == "released-snapshot-warning")
        #expect(snapshot.topResults.map(\.appStoreID) == [rankedResult.appStoreID])

        #expect(rankedResult.snapshot.snapshotKey == snapshot.snapshotKey)
        #expect(rankedResult.snapshotKey == snapshot.snapshotKey)
        #expect(rankedResult.position == ReleasedV1FixtureSentinel.competitorPosition)
        #expect(rankedResult.appStoreID == ReleasedV1FixtureSentinel.competitorAppStoreID)
        #expect(rankedResult.bundleID == ReleasedV1FixtureSentinel.competitorBundleID)
        #expect(rankedResult.name == ReleasedV1FixtureSentinel.competitorName)
        #expect(rankedResult.subtitle == "Fixture ranked subtitle")
        #expect(rankedResult.sellerName == "Fixture Ranked Seller")

        #expect(stats.identityKey == ReleasedV1FixtureSentinel.trackIdentityKey)
        #expect(stats.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
        #expect(stats.queryKey == ReleasedV1FixtureSentinel.queryKey)
        #expect(stats.keyword == ReleasedV1FixtureSentinel.keyword)
        #expect(stats.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(stats.platform == .iphone)
        #expect(stats.bestRank == 5)
        #expect(stats.latestRank == 8)
        #expect(stats.averageRank == 6.5)
        #expect(stats.observationCount == 4)
        #expect(stats.firstSeenAt == ReleasedV1FixtureSentinel.priorDate)
        #expect(stats.lastSeenAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(stats.popularityScore == 61)
        #expect(stats.difficultyScore == 42)

        #expect(latestRating.identityKey == "320032001::gb")
        #expect(latestRating.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
        #expect(latestRating.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(latestRating.ratingCount == 1_200)
        #expect(latestRating.averageRating == 4.625)
        #expect(latestRating.oneStarRatingCount == 11)
        #expect(latestRating.twoStarRatingCount == 22)
        #expect(latestRating.threeStarRatingCount == 33)
        #expect(latestRating.fourStarRatingCount == 44)
        #expect(latestRating.fiveStarRatingCount == 1_090)
        #expect(latestRating.ratingDate == ReleasedV1FixtureSentinel.ratingDate)
        #expect(latestRating.observedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(latestRating.submissionCount == 3)
        #expect(latestRating.winningCount == 2)
        #expect(latestRating.confidenceRaw == "fixture-high")
        #expect(latestRating.source == .appStorePage)
        #expect(latestRating.storeApp?.appStoreID == storeApp.appStoreID)

        #expect(dailyRating.identityKey == "320032001::gb::2026-04-30")
        #expect(dailyRating.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
        #expect(dailyRating.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(dailyRating.ratingDate == ReleasedV1FixtureSentinel.dailyRatingDate)
        #expect(dailyRating.ratingCount == 1_180)
        #expect(dailyRating.averageRating == 4.5)
        #expect(dailyRating.oneStarRatingCount == 12)
        #expect(dailyRating.twoStarRatingCount == 23)
        #expect(dailyRating.threeStarRatingCount == 34)
        #expect(dailyRating.fourStarRatingCount == 45)
        #expect(dailyRating.fiveStarRatingCount == 1_066)
        #expect(dailyRating.observedAt == ReleasedV1FixtureSentinel.priorDate)
        #expect(dailyRating.submissionCount == 4)
        #expect(dailyRating.winningCount == 3)
        #expect(dailyRating.confidenceRaw == "fixture-medium")
        #expect(dailyRating.source == .iTunesSearch)
        #expect(dailyRating.storeApp?.appStoreID == storeApp.appStoreID)

        #expect(review.reviewKey == ReleasedV1FixtureSentinel.reviewKey)
        #expect(review.appStoreID == ReleasedV1FixtureSentinel.appStoreID)
        #expect(review.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(review.reviewID == ReleasedV1FixtureSentinel.reviewID)
        #expect(review.reviewerName == "Fixture Reviewer")
        #expect(review.title == "Released fixture review")
        #expect(review.content == "A persisted review from the released schema.")
        #expect(review.rating == 5)
        #expect(review.reviewedAt == ReleasedV1FixtureSentinel.priorDate)
        #expect(review.version == "0.3.1")
        #expect(review.source == .appStoreConnect)
        #expect(review.observedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(review.ascReviewID == "asc-review-032")
        #expect(review.developerResponseID == "response-032")
        #expect(review.developerResponseBody == "Thanks from the released fixture.")
        #expect(review.developerResponseState == "PUBLISHED")
        #expect(review.developerResponseModifiedAt == ReleasedV1FixtureSentinel.priorDate)
        #expect(review.translatedTitle == "Avis de fixture")
        #expect(review.translatedContent == "Contenu de fixture traduit.")
        #expect(review.translationLanguage == "fr")
        #expect(review.translatedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(review.translationProviderRaw == "fixture-provider")
        #expect(review.translationModelID == "fixture-model-v1")
        #expect(review.assumedLanguageCode == "en")
        #expect(review.assumedLanguageConfidence == 0.97)
        #expect(review.storeApp?.appStoreID == storeApp.appStoreID)

        #expect(metric.queryKey == ReleasedV1FixtureSentinel.queryKey)
        #expect(metric.keyword == ReleasedV1FixtureSentinel.keyword)
        #expect(metric.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(metric.platform == .iphone)
        #expect(metric.popularityScore == 61)
        #expect(metric.difficultyScore == 42)
        #expect(metric.source == .appleAdsPopularity)
        #expect(metric.popularityDate == ReleasedV1FixtureSentinel.ratingDate)
        #expect(metric.submissionCount == 5)
        #expect(metric.winningCount == 4)
        #expect(metric.confidenceRaw == "fixture-strong")
        #expect(metric.updatedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(metric.notes == "released-metric-notes")

        #expect(crawl.queryKey == ReleasedV1FixtureSentinel.queryKey)
        #expect(crawl.keyword == ReleasedV1FixtureSentinel.keyword)
        #expect(crawl.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(crawl.platform == .iphone)
        #expect(crawl.observedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(crawl.observedHour == ReleasedV1FixtureSentinel.crawlObservedHour)
        #expect(crawl.source == .appStoreWeb)
        #expect(crawl.resultCount == ReleasedV1FixtureSentinel.crawlResultCount)
        #expect(crawl.submissionCount == 6)
        #expect(crawl.winningCount == 5)
        #expect(crawl.confidenceRaw == "fixture-crawl-confidence")
        #expect(crawl.query.queryKey == query.queryKey)
        #expect(crawl.items.map(\.itemKey) == [crawlItem.itemKey])

        #expect(crawlItem.position == 2)
        #expect(crawlItem.appStoreID == ReleasedV1FixtureSentinel.competitorAppStoreID)
        #expect(crawlItem.bundleID == ReleasedV1FixtureSentinel.competitorBundleID)
        #expect(crawlItem.name == ReleasedV1FixtureSentinel.competitorName)
        #expect(crawlItem.subtitle == "Fixture crawl subtitle")
        #expect(crawlItem.sellerName == "Fixture Crawl Seller")
        #expect(crawlItem.crawlKey == crawl.observationKey)
        #expect(crawlItem.queryKey == query.queryKey)
        #expect(crawlItem.storefront == ReleasedV1FixtureSentinel.storefront)
        #expect(crawlItem.platform == .iphone)
        #expect(crawlItem.observedAt == ReleasedV1FixtureSentinel.fixtureDate)
        #expect(crawlItem.observation.observationKey == crawl.observationKey)

        #expect(storefront.code == ReleasedV1FixtureSentinel.storefront)
        #expect(storefront.name == "United Kingdom")
        #expect(storefront.flagEmoji == "🇬🇧")
        #expect(storefront.languageCode == "en-GB")
        #expect(storefront.title == "🇬🇧 United Kingdom")
    }
}

private enum InjectedReleasedFixtureOpenFailure: Error {
    case expected
}
