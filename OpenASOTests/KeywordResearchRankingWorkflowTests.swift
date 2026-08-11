import Foundation
import SwiftData
import Synchronization
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchRankingWorkflowTests {
    @Test
    func sharedTargetResolverReturnsExactScalarTargetAndMatchingQuery() async throws {
        let fixture = try await makeFixture(
            provider: ScriptedResearchRankingProvider(steps: []),
            dates: []
        )
        let resolver = KeywordResearchTargetResolver()

        let target = try await fixture.backgroundStore.read { modelContext in
            let target = try resolver.requireTarget(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation,
                in: modelContext
            )
            _ = try resolver.requireQuery(for: target, in: modelContext)
            return target
        }

        #expect(target == KeywordResearchTarget(
            queryKey: fixture.keyword.queryKey,
            term: "launch::planner",
            storefront: "gb",
            platform: .ipad
        ))
    }

    @Test
    func refreshPersistsCanonicalSharedObservationWithoutCreatingTrackedState() async throws {
        let searchedAt = utcDate(year: 2026, month: 7, day: 1, hour: 13)
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(
                items: [
                    rankingItem(position: 2, appStoreID: 20, name: "Zulu", ratingCount: 20),
                    rankingItem(position: 1, appStoreID: 10, name: "First", ratingCount: 10),
                    rankingItem(position: 2, appStoreID: 20, name: "Alpha", ratingCount: 21),
                    rankingItem(position: 9, appStoreID: 10, name: "Late duplicate", ratingCount: 99),
                ],
                source: .iTunesFallback
            )),
        ])
        let fixture = try await makeFixture(provider: provider, dates: [searchedAt])

        let snapshot = try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation
        )

        #expect(snapshot.projectGeneration == fixture.project.generation)
        #expect(snapshot.keywordGeneration == fixture.keyword.generation)
        #expect(snapshot.queryKey == fixture.keyword.queryKey)
        #expect(snapshot.term == "launch::planner")
        #expect(snapshot.storefront == "gb")
        #expect(snapshot.platform == .ipad)
        #expect(snapshot.observedAt == searchedAt)
        #expect(snapshot.resultCount == 2)
        #expect(snapshot.items.map(\.appStoreID) == [10, 20])
        #expect(snapshot.items.map(\.name) == ["First", "Alpha"])

        let calls = await provider.recordedCalls()
        #expect(calls == [ProviderCall(
            keyword: "launch::planner",
            storefront: "gb",
            platform: .ipad,
            limit: 200
        )])

        let state = try await databaseState(in: fixture.backgroundStore)
        #expect(state.crawlCount == 1)
        #expect(state.observationItemCount == 2)
        #expect(state.storeAppIDs == [10, 20])
        #expect(state.metadataCount == 2)
        #expect(state.screenshotCount == 2)
        #expect(state.latestRatingIDs == [10, 20])
        #expect(state.dailyRatingIDs == [10, 20])
        #expect(state.statsAppStoreIDs.isEmpty)
        #expect(state.trackedCount == 0)
    }

    @Test
    func canonicalizationIsPermutationStableForDuplicateProviderRows() async throws {
        let lower = rankingItem(position: 2, appStoreID: 20, name: "Alpha", ratingCount: 1)
        let higher = rankingItem(position: 2, appStoreID: 20, name: "Zulu", ratingCount: 2)
        let first = rankingItem(position: 1, appStoreID: 10, name: "First")
        let request = RankingRefreshRequest(
            identityKey: "research-membership",
            queryKey: "opaque::query::key::v1",
            term: "opaque::term",
            storefront: "gb",
            platform: .ipad
        )
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(items: [higher, first, lower], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [lower, higher, first], source: .iTunesFallback)),
        ])
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: NoOpAppResolver())
        )

        let forward = try await coordinator.fetchRankingPage(for: request, limit: 200)
        let reversed = try await coordinator.fetchRankingPage(for: request, limit: 200)

        #expect(forward.page.items == reversed.page.items)
        #expect(forward.page.items.map(\.appStoreID) == [10, 20])
        #expect(forward.page.items.map(\.name) == ["First", "Alpha"])
    }

    @Test
    func delayedRetargetRejectsOldMembershipGenerationWithoutLateWrites() async throws {
        let provider = GatedResearchRankingProvider()
        let fixture = try await makeFixture(
            provider: provider,
            dates: [utcDate(year: 2026, month: 7, day: 2, hour: 13)]
        )
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation
            )
        }
        await provider.waitUntilStarted()

        let projectAfterRemoval = try await fixture.projectStore.removeKeyword(
            revision: fixture.keyword.revision,
            from: fixture.project.revision
        )
        _ = try await fixture.projectStore.addKeyword(
            id: fixture.keyword.id,
            to: projectAfterRemoval.revision,
            term: "retargeted keyword",
            storefront: "us",
            platform: .iphone
        )
        await provider.succeed(SearchRankingPage(
            items: [rankingItem(position: 1, appStoreID: 10)],
            source: .iTunesFallback
        ))

        await #expect(throws: KeywordResearchProjectStoreError.staleKeywordRevision(
            fixture.keyword.id
        )) {
            _ = try await task.value
        }
        #expect(try await sharedWriteCount(in: fixture.backgroundStore) == 0)
    }

    @Test
    func delayedProjectReplacementRejectsOldGenerationWithoutLateWrites() async throws {
        let provider = GatedResearchRankingProvider()
        let fixture = try await makeFixture(
            provider: provider,
            dates: [utcDate(year: 2026, month: 7, day: 3, hour: 13)]
        )
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation
            )
        }
        await provider.waitUntilStarted()

        try await fixture.projectStore.deleteProject(revision: fixture.project.revision)
        _ = try await fixture.projectStore.createProject(
            id: fixture.project.id,
            name: "Replacement project",
            defaultStorefront: "gb",
            defaultPlatform: .ipad
        )
        await provider.succeed(SearchRankingPage(
            items: [rankingItem(position: 1, appStoreID: 10)],
            source: .iTunesFallback
        ))

        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(
            fixture.project.id
        )) {
            _ = try await task.value
        }
        #expect(try await sharedWriteCount(in: fixture.backgroundStore) == 0)
    }

    @Test
    func cancellationAfterProviderStartsIsPreservedAndRollsBackAllWrites() async throws {
        let provider = GatedResearchRankingProvider()
        let metadataRecorder = MetadataEnrichmentRecorder()
        let fixture = try await makeFixture(
            provider: provider,
            dates: [utcDate(year: 2026, month: 7, day: 4, hour: 13)],
            metadataEnrichmentScheduler: metadataRecorder.record
        )
        let task = Task {
            try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation
            )
        }
        await provider.waitUntilStarted()

        task.cancel()
        await provider.succeed(SearchRankingPage(
            items: [rankingItem(position: 1, appStoreID: 10)],
            source: .iTunesFallback
        ))

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(try await sharedWriteCount(in: fixture.backgroundStore) == 0)
        #expect(metadataRecorder.recordedBatches().isEmpty)
    }

    @Test
    func providerFailureIsReturnedWithoutPersistenceSideEffects() async throws {
        let provider = ScriptedResearchRankingProvider(steps: [.failure(.networkUnavailable)])
        let metadataRecorder = MetadataEnrichmentRecorder()
        let fixture = try await makeFixture(
            provider: provider,
            dates: [],
            metadataEnrichmentScheduler: metadataRecorder.record
        )

        await #expect(throws: OpenASOError.networkUnavailable) {
            _ = try await fixture.workflow.refresh(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation
            )
        }

        #expect(try await sharedWriteCount(in: fixture.backgroundStore) == 0)
        #expect(metadataRecorder.recordedBatches().isEmpty)
    }

    @Test
    func newerSameDayPageReplacesObservationWhileOlderAndEqualPagesAreCompleteNoOps() async throws {
        let firstDate = utcDate(year: 2026, month: 7, day: 5, hour: 12)
        let newestDate = utcDate(year: 2026, month: 7, day: 5, hour: 13)
        let olderDate = utcDate(year: 2026, month: 7, day: 5, hour: 12, minute: 30)
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 1, ratingCount: 10),
                rankingItem(position: 2, appStoreID: 2, ratingCount: 20),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 2, ratingCount: 21),
                rankingItem(position: 2, appStoreID: 3, ratingCount: 30),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 4, ratingCount: 40),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 5, ratingCount: 50),
            ], source: .iTunesFallback)),
        ])
        let metadataRecorder = MetadataEnrichmentRecorder()
        let fixture = try await makeFixture(
            provider: provider,
            dates: [firstDate, newestDate, olderDate, newestDate],
            metadataEnrichmentScheduler: metadataRecorder.record
        )

        _ = try await refresh(fixture)
        #expect(metadataRecorder.recordedBatches() == [[
            RankingMetadataEnrichmentRequest(appStoreID: 1, storefront: "gb", platform: .ipad),
            RankingMetadataEnrichmentRequest(appStoreID: 2, storefront: "gb", platform: .ipad),
        ]])
        let newest = try await refresh(fixture)
        #expect(metadataRecorder.recordedBatches() == [
            [
                RankingMetadataEnrichmentRequest(appStoreID: 1, storefront: "gb", platform: .ipad),
                RankingMetadataEnrichmentRequest(appStoreID: 2, storefront: "gb", platform: .ipad),
            ],
            [
                RankingMetadataEnrichmentRequest(appStoreID: 2, storefront: "gb", platform: .ipad),
                RankingMetadataEnrichmentRequest(appStoreID: 3, storefront: "gb", platform: .ipad),
            ],
        ])
        let afterOlder = try await refresh(fixture)
        #expect(metadataRecorder.recordedBatches().count == 2)
        let afterEqualConflict = try await refresh(fixture)
        #expect(metadataRecorder.recordedBatches().count == 2)

        #expect(afterOlder == newest)
        #expect(afterEqualConflict == newest)
        let observations = try await observationRecords(in: fixture.backgroundStore)
        #expect(observations == [ObservationRecord(
            observedAt: newestDate,
            source: .iTunesFallback,
            appStoreIDs: [2, 3],
            positions: [1, 2]
        )])
        let state = try await databaseState(in: fixture.backgroundStore)
        #expect(state.storeAppIDs == [1, 2, 3])
        #expect(state.latestRatingIDs == [1, 2, 3])
        #expect(state.statsAppStoreIDs.isEmpty)
        #expect(!state.storeAppIDs.contains(4))
        #expect(!state.storeAppIDs.contains(5))
    }

    @Test
    func differentDayAndSourceCreateDistinctCrawlsAndOlderRatingsCannotReplaceNewerValues() async throws {
        let newestFirstDay = utcDate(year: 2026, month: 7, day: 6, hour: 14)
        let olderOtherSource = utcDate(year: 2026, month: 7, day: 6, hour: 13)
        let secondDay = utcDate(year: 2026, month: 7, day: 7, hour: 14)
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 1, ratingCount: 100, averageRating: 4.0),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 2, appStoreID: 1, ratingCount: 50, averageRating: 2.0),
            ], source: .appStoreWeb)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 3, appStoreID: 1, ratingCount: 200, averageRating: 4.5),
            ], source: .iTunesFallback)),
        ])
        let fixture = try await makeFixture(
            provider: provider,
            dates: [newestFirstDay, olderOtherSource, secondDay]
        )

        _ = try await refresh(fixture)
        _ = try await refresh(fixture)
        let firstDayRating = try await latestRatingRecord(in: fixture.backgroundStore)
        #expect(firstDayRating == RatingRecord(
            observedAt: newestFirstDay,
            ratingCount: 100,
            averageRating: 4.0
        ))
        _ = try await refresh(fixture)

        let observations = try await observationRecords(in: fixture.backgroundStore)
        #expect(observations.count == 3)
        #expect(Set(observations.map(\.source)) == [.iTunesFallback, .appStoreWeb])
        #expect(try await latestRatingRecord(in: fixture.backgroundStore) == RatingRecord(
            observedAt: secondDay,
            ratingCount: 200,
            averageRating: 4.5
        ))
        #expect(try await statsRecords(in: fixture.backgroundStore).isEmpty)
    }

    @Test
    func delayedSourceUpdateCannotRegressNewerCrossSourceCatalogAndRatingWatermarks() async throws {
        let firstITunesObservation = utcDate(year: 2026, month: 7, day: 8, hour: 12)
        let newerWebObservation = utcDate(year: 2026, month: 7, day: 8, hour: 13)
        let delayedITunesObservation = utcDate(year: 2026, month: 7, day: 8, hour: 12, minute: 30)
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 1, name: "Fresh", ratingCount: 100),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 1, name: "Fresh", ratingCount: 100),
            ], source: .appStoreWeb)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 1, name: "Stale", ratingCount: 50),
            ], source: .iTunesFallback)),
        ])
        let fixture = try await makeFixture(
            provider: provider,
            dates: [firstITunesObservation, newerWebObservation, delayedITunesObservation]
        )

        _ = try await refresh(fixture)
        _ = try await refresh(fixture)
        _ = try await refresh(fixture)

        let record = try await crossSourceWatermarkRecord(
            queryKey: fixture.keyword.queryKey,
            appStoreID: 1,
            storefront: "gb",
            in: fixture.backgroundStore
        )
        #expect(record == CrossSourceWatermarkRecord(
            latestRatingCount: 100,
            latestRatingObservedAt: newerWebObservation,
            latestRatingSource: .appStorePage,
            dailyRatingCount: 100,
            dailyRatingObservedAt: newerWebObservation,
            dailyRatingSource: .appStorePage,
            storeAppName: "Fresh",
            storeAppMetadataObservedAt: newerWebObservation,
            storeAppLanguageSource: .appStoreWebSearch,
            storefrontMetadataName: "Stale",
            storefrontMetadataObservedAt: delayedITunesObservation,
            storefrontMetadataSource: .iTunesSearch,
            iTunesCrawlName: "Stale",
            iTunesCrawlObservedAt: delayedITunesObservation
        ))
    }

    @Test
    func defaultStorefrontCanonicalMetadataUsesItsOwnWatermarkWithoutRegressingGlobalFields() async throws {
        let defaultStorefrontObservation = utcDate(year: 2026, month: 7, day: 9, hour: 12)
        let newerNonDefaultObservation = utcDate(year: 2026, month: 7, day: 9, hour: 13)
        let newerDefaultStorefrontObservation = utcDate(
            year: 2026,
            month: 7,
            day: 9,
            hour: 12,
            minute: 30
        )
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(items: [
                rankingItem(
                    position: 1,
                    appStoreID: 77,
                    name: "Default t12",
                    bundleID: "example.default.t12",
                    sellerName: "Default Seller t12",
                    iconURLString: "https://example.com/default-t12.png",
                    version: "1.0",
                    supportedLanguageCodes: ["EN"]
                ),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(
                    position: 1,
                    appStoreID: 77,
                    name: "Non-default t13",
                    bundleID: "example.global.t13",
                    sellerName: "Global Seller t13",
                    iconURLString: "https://example.com/non-default-t13.png",
                    version: "2.0",
                    supportedLanguageCodes: ["EN"]
                ),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(
                    position: 1,
                    appStoreID: 77,
                    name: "Default t12.5",
                    bundleID: "example.stale.t12-5",
                    sellerName: "Stale Seller t12.5",
                    iconURLString: "https://example.com/default-t12-5.png",
                    version: "1.5",
                    supportedLanguageCodes: ["FR"]
                ),
            ], source: .iTunesFallback)),
        ])
        let fixture = try await makeFixture(
            provider: provider,
            dates: [
                defaultStorefrontObservation,
                newerNonDefaultObservation,
                newerDefaultStorefrontObservation,
            ],
            term: "catalog watermark"
        )
        let nonDefaultAddition = try await fixture.projectStore.addKeyword(
            to: fixture.project.revision,
            term: fixture.keyword.term,
            storefront: "us",
            platform: .ipad
        )
        let projectGeneration = nonDefaultAddition.project.generation

        _ = try await fixture.workflow.refresh(
            projectGeneration: projectGeneration,
            keywordGeneration: fixture.keyword.generation
        )
        _ = try await fixture.workflow.refresh(
            projectGeneration: projectGeneration,
            keywordGeneration: nonDefaultAddition.keyword.generation
        )
        _ = try await fixture.workflow.refresh(
            projectGeneration: projectGeneration,
            keywordGeneration: fixture.keyword.generation
        )

        let record = try await catalogWatermarkRecord(
            appStoreID: 77,
            defaultStorefront: "gb",
            nonDefaultStorefront: "us",
            in: fixture.backgroundStore
        )
        #expect(record == CatalogWatermarkRecord(
            defaultStorefront: "gb",
            name: "Default t12.5",
            iconURLString: "https://example.com/default-t12-5.png",
            bundleID: "example.global.t13",
            sellerName: "Global Seller t13",
            version: "2.0",
            globalMetadataObservedAt: newerNonDefaultObservation,
            supportedLanguageCodes: ["EN"],
            supportedLanguageCodesObservedAt: newerNonDefaultObservation,
            defaultMetadataName: "Default t12.5",
            defaultMetadataIconURLString: "https://example.com/default-t12-5.png",
            defaultMetadataObservedAt: newerDefaultStorefrontObservation,
            nonDefaultMetadataName: "Non-default t13",
            nonDefaultMetadataIconURLString: "https://example.com/non-default-t13.png",
            nonDefaultMetadataObservedAt: newerNonDefaultObservation
        ))
    }

    @Test
    func persistedResearchAlwaysRequestsAndCapsTheFullResultWindow() async throws {
        let searchedAt = utcDate(year: 2026, month: 7, day: 8, hour: 13)
        let oversizedItems = (1...201).map {
            rankingItem(position: $0, appStoreID: Int64($0))
        }
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(items: oversizedItems, source: .iTunesFallback)),
        ])
        let fixture = try await makeFixture(
            provider: provider,
            dates: [searchedAt]
        )

        let snapshot = try await refresh(fixture)

        #expect(snapshot.items.count == 200)
        #expect(snapshot.items.last?.appStoreID == 200)
        #expect(await provider.recordedCalls().map(\.limit) == [200])
    }

    @Test
    func corruptedOpaqueQueryIsRejectedWithoutRewritingOrSharedWrites() async throws {
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(
                items: [rankingItem(position: 1, appStoreID: 1)],
                source: .iTunesFallback
            )),
        ])
        let fixture = try await makeFixture(
            provider: provider,
            dates: [utcDate(year: 2026, month: 7, day: 10, hour: 13)]
        )
        try await fixture.backgroundStore.write { modelContext in
            let queryKey = fixture.keyword.queryKey
            var descriptor = FetchDescriptor<KeywordQuery>(
                predicate: #Predicate { query in query.queryKey == queryKey }
            )
            descriptor.fetchLimit = 1
            let query = try #require(modelContext.fetch(descriptor).first)
            query.term = "corrupted term"
        }

        await #expect(throws: OpenASOError.unexpectedResponse) {
            _ = try await refresh(fixture)
        }

        #expect(try await sharedWriteCount(in: fixture.backgroundStore) == 0)
        let queryTerms = try await fixture.backgroundStore.read { modelContext in
            try modelContext.fetch(FetchDescriptor<KeywordQuery>()).map(\.term)
        }
        #expect(queryTerms == ["corrupted term"])
    }

    @Test
    func newerResearchCrawlCannotDriveDelayedTrackedPageState() async throws {
        let trackedPageAt = utcDate(year: 2026, month: 7, day: 11, hour: 12)
        let failureAt = utcDate(year: 2026, month: 7, day: 11, hour: 12, minute: 30)
        let researchPageAt = utcDate(year: 2026, month: 7, day: 11, hour: 13)
        let previousRefreshAt = utcDate(year: 2026, month: 7, day: 10, hour: 12)
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(
                items: [rankingItem(position: 1, appStoreID: 1_300)],
                source: .iTunesFallback
            )),
        ])
        let fixture = try await makeFixture(provider: provider, dates: [researchPageAt])
        let trackIdentityKey = try await fixture.backgroundStore.write { modelContext in
            let queryKey = fixture.keyword.queryKey
            var descriptor = FetchDescriptor<KeywordQuery>(
                predicate: #Predicate { query in query.queryKey == queryKey }
            )
            descriptor.fetchLimit = 1
            guard let query = try modelContext.fetch(descriptor).first else {
                throw OpenASOError.unexpectedResponse
            }
            let trackedApp = TrackedApp(
                appStoreID: 99,
                bundleID: "example.99",
                name: "Tracked",
                sellerName: "Tracked Seller",
                defaultPlatform: .ipad,
                createdAt: utcDate(year: 2026, month: 6, day: 1, hour: 10)
            )
            let track = TrackedAppKeyword(
                term: query.term,
                storefront: query.storefront,
                platform: query.platform,
                trackedApp: trackedApp,
                query: query,
                createdAt: utcDate(year: 2026, month: 6, day: 2, hour: 10)
            )
            track.lastRefreshAt = previousRefreshAt
            track.rankingAppCount = 17
            trackedApp.keywordTracks.append(track)
            modelContext.insert(trackedApp)
            modelContext.insert(track)
            try TrackedKeywordRefreshStatusStore.set(
                "t12.5 ranking failure",
                domain: .ranking,
                for: track,
                updatedAt: failureAt,
                in: modelContext
            )
            return track.identityKey
        }

        _ = try await refresh(fixture)

        let trackedPage = RankingRefreshPageResult(
            request: RankingRefreshRequest(
                identityKey: trackIdentityKey,
                queryKey: fixture.keyword.queryKey,
                term: fixture.keyword.term,
                storefront: fixture.keyword.storefront,
                platform: fixture.keyword.platform
            ),
            page: SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 1_200),
                rankingItem(position: 2, appStoreID: 99),
            ], source: .iTunesFallback),
            searchedAt: trackedPageAt,
            observedHour: nil,
            submissionCount: 1,
            winningCount: 1,
            confidence: "tracked_page"
        )
        let appliedSharedObservation = try await fixture.backgroundStore.write { modelContext in
            try fixture.coordinator.persistRankingPageTransaction(
                trackedPage,
                in: modelContext
            ).appliedSharedObservation
        }

        #expect(!appliedSharedObservation)
        let state = try await trackedSharedRaceState(
            trackIdentityKey: trackIdentityKey,
            queryKey: fixture.keyword.queryKey,
            in: fixture.backgroundStore
        )
        #expect(state.sharedObservedAt == researchPageAt)
        #expect(state.sharedAppStoreIDs == [1_300])
        #expect(state.snapshotSearchedAt == trackedPageAt)
        #expect(state.snapshotRank == 2)
        #expect(state.snapshotResultCount == 2)
        #expect(state.snapshotAppStoreIDs == [1_200, 99])
        #expect(state.snapshotPositions == [1, 2])
        #expect(state.trackLastRefreshAt == trackedPageAt)
        #expect(state.trackRankingAppCount == 2)
        #expect(state.rankingStatusMessage == "t12.5 ranking failure")
        #expect(state.rankingStatusUpdatedAt == failureAt)
    }

    @Test
    func researchRefreshLeavesFullySeededTrackedGraphUnchanged() async throws {
        let researchPageAt = utcDate(year: 2026, month: 7, day: 12, hour: 13)
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(
                items: [rankingItem(position: 1, appStoreID: 10)],
                source: .iTunesFallback
            )),
        ])
        let fixture = try await makeFixture(provider: provider, dates: [researchPageAt])
        try await seedFullyPopulatedTrackedGraph(
            queryKey: fixture.keyword.queryKey,
            in: fixture.backgroundStore
        )
        let before = try await trackedGraphState(in: fixture.backgroundStore)

        _ = try await refresh(fixture)

        let after = try await trackedGraphState(in: fixture.backgroundStore)
        #expect(after == before)
    }

    @Test
    func trackedPersistenceDefersMetadataUntilExplicitPostCommitScheduling() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 99,
            bundleID: "example.99",
            name: "Tracked",
            sellerName: "Seller",
            defaultPlatform: .ipad
        )
        let query = try KeywordQuery.fetchOrInsert(
            term: "deferred metadata",
            storefront: "gb",
            platform: .ipad,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()

        let recorder = MetadataEnrichmentRecorder()
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: ScriptedResearchRankingProvider(steps: []),
            appCatalogService: AppCatalogService(appResolver: NoOpAppResolver()),
            metadataEnrichmentScheduler: recorder.record
        )
        let pageResult = RankingRefreshPageResult(
            request: RankingRefreshRequest(track: track),
            page: SearchRankingPage(
                items: [rankingItem(position: 1, appStoreID: 10)],
                source: .iTunesFallback
            ),
            searchedAt: utcDate(year: 2026, month: 7, day: 13, hour: 13),
            observedHour: nil,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source"
        )

        let persistence = try coordinator.persistRankingPageTransaction(
            pageResult,
            in: modelContext
        )
        #expect(recorder.recordedBatches().isEmpty)

        try modelContext.save()
        #expect(recorder.recordedBatches().isEmpty)

        coordinator.scheduleTopRankingMetadataEnrichment(
            for: persistence.canonicalPageResult
        )
        let requests = try #require(recorder.recordedBatches().first)
        #expect(requests == [RankingMetadataEnrichmentRequest(
            appStoreID: 10,
            storefront: "gb",
            platform: .ipad
        )])
    }

    @Test
    func equalTimestampTrackedRetryCannotMutateSharedOrTrackedRows() async throws {
        let searchedAt = utcDate(year: 2026, month: 7, day: 11, hour: 13)
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 99,
            bundleID: "example.99",
            name: "Tracked",
            sellerName: "Seller",
            defaultPlatform: .iphone
        )
        let query = try KeywordQuery.fetchOrInsert(
            term: "tracked term",
            storefront: "us",
            platform: .iphone,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)
        try modelContext.save()
        let provider = ScriptedResearchRankingProvider(steps: [
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 99),
                rankingItem(position: 2, appStoreID: 1),
            ], source: .iTunesFallback)),
            .page(SearchRankingPage(items: [
                rankingItem(position: 1, appStoreID: 2),
            ], source: .iTunesFallback)),
        ])
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: NoOpAppResolver()),
            now: DateSequence([searchedAt, searchedAt]).next
        )

        let first = await coordinator.refresh(track: track, in: modelContext)
        let second = await coordinator.refresh(track: track, in: modelContext)

        guard case .success(let firstSnapshot) = first,
              case .success(let secondSnapshot) = second
        else {
            Issue.record("Expected both tracked refreshes to succeed")
            return
        }
        #expect(firstSnapshot.persistentModelID == secondSnapshot.persistentModelID)
        #expect(secondSnapshot.rank == 1)
        #expect(secondSnapshot.topResults.isEmpty)
        #expect(try modelContext.fetch(FetchDescriptor<RankingCrawlRecord>()).count == 1)
        #expect(try modelContext.fetch(FetchDescriptor<RankingFact>()).map(\.appStoreID).sorted() == [1, 99])
        #expect(try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>()).count == 1)
        #expect(try modelContext.fetchCount(FetchDescriptor<TrackedKeywordRankedResult>()) == 0)
        #expect(try modelContext.fetchCount(FetchDescriptor<TrackedRankingCrawlLink>()) == 1)
        #expect(try modelContext.fetch(FetchDescriptor<StoreApp>()).map(\.appStoreID).sorted() == [1, 99])
        #expect(try modelContext.fetchCount(FetchDescriptor<AppKeywordStats>()) == 0)
    }
}

private extension KeywordResearchRankingWorkflowTests {
    func makeFixture(
        provider: any SearchRankingProvider,
        dates: [Date],
        term: String = "launch::planner",
        metadataEnrichmentScheduler: (@Sendable ([RankingMetadataEnrichmentRequest]) -> Void)? = nil
    ) async throws -> WorkflowFixture {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let createdAt = utcDate(year: 2026, month: 6, day: 1, hour: 12)
        let projectStore = KeywordResearchProjectStore(
            backgroundModelStore: backgroundStore,
            now: { createdAt }
        )
        let project = try await projectStore.createProject(
            name: "Pre-live research",
            defaultStorefront: "gb",
            defaultPlatform: .ipad
        )
        let addition = try await projectStore.addKeyword(
            to: project.revision,
            term: term,
            storefront: "gb",
            platform: .ipad
        )
        let dateSequence = DateSequence(dates)
        let coordinator = RankingRefreshCoordinator(
            rankingProvider: provider,
            appCatalogService: AppCatalogService(appResolver: NoOpAppResolver()),
            now: dateSequence.next,
            metadataEnrichmentScheduler: metadataEnrichmentScheduler
        )
        return WorkflowFixture(
            container: container,
            backgroundStore: backgroundStore,
            projectStore: projectStore,
            coordinator: coordinator,
            workflow: KeywordResearchRankingWorkflow(
                backgroundModelStore: backgroundStore,
                rankingCoordinator: coordinator
            ),
            project: addition.project,
            keyword: addition.keyword
        )
    }

    func refresh(
        _ fixture: WorkflowFixture
    ) async throws -> KeywordResearchRankingObservationSnapshot {
        try await fixture.workflow.refresh(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation
        )
    }
}

private struct WorkflowFixture {
    let container: ModelContainer
    let backgroundStore: BackgroundModelStore
    let projectStore: KeywordResearchProjectStore
    let coordinator: RankingRefreshCoordinator
    let workflow: KeywordResearchRankingWorkflow
    let project: KeywordResearchProjectSnapshot
    let keyword: KeywordResearchKeywordSnapshot
}

private struct ProviderCall: Equatable, Sendable {
    let keyword: String
    let storefront: String
    let platform: AppPlatform
    let limit: Int
}

private actor ScriptedResearchRankingProvider: SearchRankingProvider {
    enum Step: Sendable {
        case page(SearchRankingPage)
        case failure(OpenASOError)
    }

    private var steps: [Step]
    private var calls: [ProviderCall] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        calls.append(ProviderCall(
            keyword: keyword,
            storefront: storefrontCode,
            platform: platform,
            limit: limit
        ))
        guard !steps.isEmpty else {
            throw OpenASOError.unexpectedResponse
        }
        switch steps.removeFirst() {
        case .page(let page):
            return page
        case .failure(let error):
            throw error
        }
    }

    func recordedCalls() -> [ProviderCall] {
        calls
    }
}

private actor GatedResearchRankingProvider: SearchRankingProvider {
    private var continuation: CheckedContinuation<SearchRankingPage, Never>?
    private var pendingPage: SearchRankingPage?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if let pendingPage {
            self.pendingPage = nil
            return pendingPage
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(_ page: SearchRankingPage) {
        guard let continuation else {
            pendingPage = page
            return
        }
        self.continuation = nil
        continuation.resume(returning: page)
    }
}

private final class MetadataEnrichmentRecorder: Sendable {
    private let batches = Mutex<[[RankingMetadataEnrichmentRequest]]>([])

    func record(_ requests: [RankingMetadataEnrichmentRequest]) {
        batches.withLock { batches in
            batches.append(requests)
        }
    }

    func recordedBatches() -> [[RankingMetadataEnrichmentRequest]] {
        batches.withLock { batches in
            batches
        }
    }
}

private final class DateSequence: Sendable {
    private let dates: Mutex<[Date]>

    init(_ dates: [Date]) {
        self.dates = Mutex(dates)
    }

    func next() -> Date {
        dates.withLock { dates in
            precondition(!dates.isEmpty, "A test provider returned more pages than expected")
            return dates.removeFirst()
        }
    }
}

private struct NoOpAppResolver: AppResolver {
    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        throw OpenASOError.appNotFound
    }

    func searchApps(
        named query: String,
        storefrontCode: String,
        limit: Int
    ) async throws -> [ResolvedApp] {
        []
    }
}

private struct DatabaseState: Sendable {
    let crawlCount: Int
    let observationItemCount: Int
    let storeAppIDs: [Int64]
    let metadataCount: Int
    let screenshotCount: Int
    let latestRatingIDs: [Int64]
    let dailyRatingIDs: [Int64]
    let statsAppStoreIDs: [Int64]
    let trackedCount: Int
}

private struct TrackedSharedRaceState: Sendable {
    let sharedObservedAt: Date
    let sharedAppStoreIDs: [Int64]
    let snapshotSearchedAt: Date
    let snapshotRank: Int?
    let snapshotResultCount: Int
    let snapshotAppStoreIDs: [Int64]
    let snapshotPositions: [Int]
    let trackLastRefreshAt: Date?
    let trackRankingAppCount: Int?
    let rankingStatusMessage: String?
    let rankingStatusUpdatedAt: Date?
}

private func trackedSharedRaceState(
    trackIdentityKey: String,
    queryKey: String,
    in store: BackgroundModelStore
) async throws -> TrackedSharedRaceState {
    try await store.read { modelContext in
        let targetTrackIdentityKey = trackIdentityKey
        var trackDescriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.identityKey == targetTrackIdentityKey
            }
        )
        trackDescriptor.fetchLimit = 1
        guard let track = try modelContext.fetch(trackDescriptor).first else {
            throw OpenASOError.appNotFound
        }

        let targetQueryKey = queryKey
        let recoveryPrefix = RankingCrawlRecord.trackedRecoveryObservationKeyPrefix
        var crawlDescriptor = FetchDescriptor<RankingCrawlRecord>(
            predicate: #Predicate { crawl in
                crawl.queryKey == targetQueryKey
                    && !crawl.observationKey.starts(with: recoveryPrefix)
            }
        )
        crawlDescriptor.fetchLimit = 1
        guard let crawl = try modelContext.fetch(crawlDescriptor).first else {
            throw OpenASOError.unexpectedResponse
        }
        let crawlKey = crawl.observationKey
        let crawlItems = try modelContext.fetch(
            FetchDescriptor<RankingFact>(
                predicate: #Predicate { fact in
                    fact.observation.observationKey == crawlKey
                },
                sortBy: [SortDescriptor(\.position)]
            )
        )

        var snapshotDescriptor = FetchDescriptor<TrackedKeywordDailyRanking>(
            predicate: #Predicate { snapshot in
                snapshot.trackIdentityKey == targetTrackIdentityKey
            }
        )
        snapshotDescriptor.fetchLimit = 1
        guard let snapshot = try modelContext.fetch(snapshotDescriptor).first else {
            throw OpenASOError.unexpectedResponse
        }
        let snapshotKey = snapshot.snapshotKey
        var linkDescriptor = FetchDescriptor<TrackedRankingCrawlLink>(
            predicate: #Predicate { link in
                link.snapshotKey == snapshotKey
            }
        )
        linkDescriptor.fetchLimit = 1
        guard let linkedCrawlKey = try modelContext.fetch(linkDescriptor).first?.crawl.observationKey else {
            throw OpenASOError.unexpectedResponse
        }
        let rankedResults = try modelContext.fetch(
            FetchDescriptor<RankingFact>(
                predicate: #Predicate { fact in
                    fact.observation.observationKey == linkedCrawlKey
                },
                sortBy: [SortDescriptor(\.position)]
            )
        ).sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.appStoreID < $1.appStoreID
        }
        let status = try TrackedKeywordRefreshStatusStore.snapshot(
            for: track,
            in: modelContext
        )
        return TrackedSharedRaceState(
            sharedObservedAt: crawl.observedAt,
            sharedAppStoreIDs: crawlItems.map(\.appStoreID),
            snapshotSearchedAt: snapshot.searchedAt,
            snapshotRank: snapshot.rank,
            snapshotResultCount: snapshot.resultCount,
            snapshotAppStoreIDs: rankedResults.map(\.appStoreID),
            snapshotPositions: rankedResults.map(\.position),
            trackLastRefreshAt: track.lastRefreshAt,
            trackRankingAppCount: track.rankingAppCount,
            rankingStatusMessage: status.rankingMessage,
            rankingStatusUpdatedAt: status.rankingUpdatedAt
        )
    }
}

private struct TrackedAppStateRecord: Equatable, Sendable {
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let sellerName: String?
    let createdAt: Date
    let isPinned: Bool
    let sidebarSortOrder: Int
}

private struct TrackedKeywordStateRecord: Equatable, Sendable {
    let identityKey: String
    let appStoreID: Int64
    let term: String
    let storefront: String
    let platform: AppPlatform
    let rankingAppCount: Int?
    let lastRefreshAt: Date?
    let notes: String
    let statusMessage: String?
    let createdAt: Date
}

private struct TrackedSnapshotStateRecord: Equatable, Sendable {
    let snapshotKey: String
    let trackIdentityKey: String
    let rank: Int?
    let searchedAt: Date
    let source: RankingSource
    let resultCount: Int
    let errorMessage: String?
}

private struct TrackedRankedResultStateRecord: Equatable, Sendable {
    let snapshotKey: String
    let position: Int
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
}

private struct TrackedStatusStateRecord: Equatable, Sendable {
    let statusKey: String
    let trackIdentityKey: String
    let trackCreatedAt: Date
    let appStoreID: Int64
    let domainRaw: String
    let message: String?
    let updatedAt: Date
}

private struct TrackedAttemptStateRecord: Equatable, Sendable {
    let trackIdentityKey: String
    let appStoreID: Int64
    let lastRankingRefreshAttemptAt: Date
}

private struct TrackedGraphState: Equatable, Sendable {
    let apps: [TrackedAppStateRecord]
    let keywords: [TrackedKeywordStateRecord]
    let snapshots: [TrackedSnapshotStateRecord]
    let results: [TrackedRankedResultStateRecord]
    let statuses: [TrackedStatusStateRecord]
    let attempts: [TrackedAttemptStateRecord]
}

private func seedFullyPopulatedTrackedGraph(
    queryKey: String,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let targetQueryKey = queryKey
        var descriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == targetQueryKey
            }
        )
        descriptor.fetchLimit = 1
        guard let query = try modelContext.fetch(descriptor).first else {
            throw OpenASOError.unexpectedResponse
        }

        let appCreatedAt = utcDate(year: 2026, month: 5, day: 1, hour: 9)
        let trackCreatedAt = utcDate(year: 2026, month: 5, day: 2, hour: 9)
        let snapshotAt = utcDate(year: 2026, month: 5, day: 3, hour: 9)
        let statusAt = utcDate(year: 2026, month: 5, day: 4, hour: 9)
        let attemptAt = utcDate(year: 2026, month: 5, day: 5, hour: 9)
        let trackedApp = TrackedApp(
            appStoreID: 900,
            bundleID: "example.tracked.900",
            name: "Seeded tracked app",
            sellerName: "Seeded seller",
            defaultPlatform: .ipad,
            sidebarSortOrder: 23,
            createdAt: appCreatedAt
        )
        trackedApp.isPinned = true
        let track = TrackedAppKeyword(
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            trackedApp: trackedApp,
            query: query,
            createdAt: trackCreatedAt
        )
        track.rankingAppCount = 88
        track.lastRefreshAt = snapshotAt
        track.notes = "seeded notes"
        trackedApp.keywordTracks.append(track)
        modelContext.insert(trackedApp)
        modelContext.insert(track)

        let snapshot = TrackedKeywordDailyRanking(
            rank: 7,
            searchedAt: snapshotAt,
            source: .appStoreWeb,
            resultCount: 88,
            errorMessage: "seeded snapshot error",
            keywordTrack: track
        )
        track.snapshots.append(snapshot)
        modelContext.insert(snapshot)
        let rankedResult = TrackedKeywordRankedResult(
            position: 4,
            appStoreID: 901,
            bundleID: "example.result.901",
            name: "Seeded ranked result",
            subtitle: "Seeded subtitle",
            sellerName: "Seeded result seller",
            snapshot: snapshot
        )
        snapshot.topResults.append(rankedResult)
        modelContext.insert(rankedResult)

        try TrackedKeywordRefreshStatusStore.set(
            "seeded ranking failure",
            domain: .ranking,
            for: track,
            updatedAt: statusAt,
            in: modelContext
        )
        track.statusMessage = "untouched legacy scalar"
        modelContext.insert(TrackedAppKeywordRefreshAttempt(
            trackIdentityKey: track.identityKey,
            appStoreID: track.appStoreID,
            lastRankingRefreshAttemptAt: attemptAt
        ))
    }
}

private func trackedGraphState(in store: BackgroundModelStore) async throws -> TrackedGraphState {
    try await store.read { modelContext in
        let apps = try modelContext.fetch(FetchDescriptor<TrackedApp>())
            .map {
                TrackedAppStateRecord(
                    appStoreID: $0.appStoreID,
                    bundleID: $0.bundleID,
                    name: $0.name,
                    sellerName: $0.sellerName,
                    createdAt: $0.createdAt,
                    isPinned: $0.isPinned,
                    sidebarSortOrder: $0.sidebarSortOrder
                )
            }
            .sorted { $0.appStoreID < $1.appStoreID }
        let keywords = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
            .map {
                TrackedKeywordStateRecord(
                    identityKey: $0.identityKey,
                    appStoreID: $0.appStoreID,
                    term: $0.term,
                    storefront: $0.storefront,
                    platform: $0.platform,
                    rankingAppCount: $0.rankingAppCount,
                    lastRefreshAt: $0.lastRefreshAt,
                    notes: $0.notes,
                    statusMessage: $0.statusMessage,
                    createdAt: $0.createdAt
                )
            }
            .sorted { $0.identityKey < $1.identityKey }
        let snapshots = try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
            .map {
                TrackedSnapshotStateRecord(
                    snapshotKey: $0.snapshotKey,
                    trackIdentityKey: $0.trackIdentityKey,
                    rank: $0.rank,
                    searchedAt: $0.searchedAt,
                    source: $0.source,
                    resultCount: $0.resultCount,
                    errorMessage: $0.errorMessage
                )
            }
            .sorted { $0.snapshotKey < $1.snapshotKey }
        let results = try modelContext.fetch(FetchDescriptor<TrackedKeywordRankedResult>())
            .map {
                TrackedRankedResultStateRecord(
                    snapshotKey: $0.snapshotKey,
                    position: $0.position,
                    appStoreID: $0.appStoreID,
                    bundleID: $0.bundleID,
                    name: $0.name,
                    subtitle: $0.subtitle,
                    sellerName: $0.sellerName
                )
            }
            .sorted {
                if $0.snapshotKey != $1.snapshotKey { return $0.snapshotKey < $1.snapshotKey }
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.appStoreID < $1.appStoreID
            }
        let statuses = try modelContext.fetch(FetchDescriptor<TrackedKeywordRefreshStatus>())
            .map {
                TrackedStatusStateRecord(
                    statusKey: $0.statusKey,
                    trackIdentityKey: $0.trackIdentityKey,
                    trackCreatedAt: $0.trackCreatedAt,
                    appStoreID: $0.appStoreID,
                    domainRaw: $0.domainRaw,
                    message: $0.message,
                    updatedAt: $0.updatedAt
                )
            }
            .sorted { $0.statusKey < $1.statusKey }
        let attempts = try modelContext.fetch(FetchDescriptor<TrackedAppKeywordRefreshAttempt>())
            .map {
                TrackedAttemptStateRecord(
                    trackIdentityKey: $0.trackIdentityKey,
                    appStoreID: $0.appStoreID,
                    lastRankingRefreshAttemptAt: $0.lastRankingRefreshAttemptAt
                )
            }
            .sorted { $0.trackIdentityKey < $1.trackIdentityKey }
        return TrackedGraphState(
            apps: apps,
            keywords: keywords,
            snapshots: snapshots,
            results: results,
            statuses: statuses,
            attempts: attempts
        )
    }
}

private func databaseState(in store: BackgroundModelStore) async throws -> DatabaseState {
    try await store.read { modelContext in
        let trackedCount = try modelContext.fetchCount(FetchDescriptor<TrackedApp>())
            + modelContext.fetchCount(FetchDescriptor<TrackedAppKeyword>())
            + modelContext.fetchCount(FetchDescriptor<TrackedKeywordDailyRanking>())
            + modelContext.fetchCount(FetchDescriptor<TrackedKeywordRankedResult>())
            + modelContext.fetchCount(FetchDescriptor<TrackedKeywordRefreshStatus>())
            + modelContext.fetchCount(FetchDescriptor<TrackedAppKeywordRefreshAttempt>())
        return DatabaseState(
            crawlCount: try modelContext.fetchCount(FetchDescriptor<RankingCrawlRecord>()),
            observationItemCount: try modelContext.fetchCount(FetchDescriptor<RankingFact>()),
            storeAppIDs: try modelContext.fetch(FetchDescriptor<StoreApp>()).map(\.appStoreID).sorted(),
            metadataCount: try modelContext.fetchCount(FetchDescriptor<AppStorefrontMetadata>()),
            screenshotCount: try modelContext.fetchCount(FetchDescriptor<AppStoreScreenshot>()),
            latestRatingIDs: try modelContext.fetch(FetchDescriptor<LatestAppRating>()).map(\.appStoreID).sorted(),
            dailyRatingIDs: try modelContext.fetch(FetchDescriptor<AppDailyRating>()).map(\.appStoreID).sorted(),
            statsAppStoreIDs: try modelContext.fetch(FetchDescriptor<AppKeywordStats>()).map(\.appStoreID).sorted(),
            trackedCount: trackedCount
        )
    }
}

private func sharedWriteCount(in store: BackgroundModelStore) async throws -> Int {
    try await store.read { modelContext in
        try modelContext.fetchCount(FetchDescriptor<RankingCrawlRecord>())
            + modelContext.fetchCount(FetchDescriptor<RankingFact>())
            + modelContext.fetchCount(FetchDescriptor<StoreApp>())
            + modelContext.fetchCount(FetchDescriptor<AppStorefrontMetadata>())
            + modelContext.fetchCount(FetchDescriptor<AppStoreScreenshot>())
            + modelContext.fetchCount(FetchDescriptor<LatestAppRating>())
            + modelContext.fetchCount(FetchDescriptor<AppDailyRating>())
            + modelContext.fetchCount(FetchDescriptor<AppKeywordStats>())
    }
}

private struct ObservationRecord: Equatable, Sendable {
    let observedAt: Date
    let source: RankingSource
    let appStoreIDs: [Int64]
    let positions: [Int]
}

private func observationRecords(in store: BackgroundModelStore) async throws -> [ObservationRecord] {
    try await store.read { modelContext in
        let factsByCrawlKey = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<RankingFact>())
        ) { fact in
            fact.observation.observationKey
        }
        return try modelContext.fetch(FetchDescriptor<RankingCrawlRecord>())
            .map { observation in
                let items = factsByCrawlKey[observation.observationKey, default: []].sorted {
                    if $0.position != $1.position { return $0.position < $1.position }
                    return $0.appStoreID < $1.appStoreID
                }
                return ObservationRecord(
                    observedAt: observation.observedAt,
                    source: observation.source,
                    appStoreIDs: items.map(\.appStoreID),
                    positions: items.map(\.position)
                )
            }
            .sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                return $0.source.rawValue < $1.source.rawValue
            }
    }
}

private struct RatingRecord: Equatable, Sendable {
    let observedAt: Date
    let ratingCount: Int?
    let averageRating: Double?
}

private func latestRatingRecord(in store: BackgroundModelStore) async throws -> RatingRecord? {
    try await store.read { modelContext in
        try modelContext.fetch(FetchDescriptor<LatestAppRating>()).first.map {
            RatingRecord(
                observedAt: $0.observedAt,
                ratingCount: $0.ratingCount,
                averageRating: $0.averageRating
            )
        }
    }
}

private struct CrossSourceWatermarkRecord: Equatable, Sendable {
    let latestRatingCount: Int?
    let latestRatingObservedAt: Date
    let latestRatingSource: AppStorefrontSource
    let dailyRatingCount: Int?
    let dailyRatingObservedAt: Date
    let dailyRatingSource: AppStorefrontSource
    let storeAppName: String
    let storeAppMetadataObservedAt: Date
    let storeAppLanguageSource: AppStorefrontMetadataSource?
    let storefrontMetadataName: String
    let storefrontMetadataObservedAt: Date
    let storefrontMetadataSource: AppStorefrontMetadataSource
    let iTunesCrawlName: String
    let iTunesCrawlObservedAt: Date
}

private func crossSourceWatermarkRecord(
    queryKey: String,
    appStoreID: Int64,
    storefront: String,
    in store: BackgroundModelStore
) async throws -> CrossSourceWatermarkRecord {
    try await store.read { modelContext in
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let latestRatingKey = LatestAppRating.makeIdentityKey(
            appStoreID: appStoreID,
            storefront: normalizedStorefront
        )
        let storefrontMetadataKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: appStoreID,
            storefront: normalizedStorefront
        )
        let targetAppStoreID = appStoreID
        let targetQueryKey = queryKey
        let iTunesSourceRaw = RankingSource.iTunesFallback.rawValue

        var latestRatingDescriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { rating in
                rating.identityKey == latestRatingKey
            }
        )
        latestRatingDescriptor.fetchLimit = 1
        var dailyRatingDescriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { rating in
                rating.appStoreID == targetAppStoreID
                    && rating.storefront == normalizedStorefront
            }
        )
        dailyRatingDescriptor.fetchLimit = 1
        var storeAppDescriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { app in
                app.appStoreID == targetAppStoreID
            }
        )
        storeAppDescriptor.fetchLimit = 1
        var storefrontMetadataDescriptor = FetchDescriptor<AppStorefrontMetadata>(
            predicate: #Predicate { metadata in
                metadata.identityKey == storefrontMetadataKey
            }
        )
        storefrontMetadataDescriptor.fetchLimit = 1
        var iTunesCrawlDescriptor = FetchDescriptor<RankingCrawlRecord>(
            predicate: #Predicate { crawl in
                crawl.queryKey == targetQueryKey
                    && crawl.sourceRaw == iTunesSourceRaw
            }
        )
        iTunesCrawlDescriptor.fetchLimit = 1

        guard let latestRating = try modelContext.fetch(latestRatingDescriptor).first,
              let dailyRating = try modelContext.fetch(dailyRatingDescriptor).first,
              let storeApp = try modelContext.fetch(storeAppDescriptor).first,
              let storefrontMetadata = try modelContext.fetch(storefrontMetadataDescriptor).first,
              let iTunesCrawl = try modelContext.fetch(iTunesCrawlDescriptor).first else {
            throw OpenASOError.unexpectedResponse
        }
        let iTunesCrawlKey = iTunesCrawl.observationKey
        var iTunesFactDescriptor = FetchDescriptor<RankingFact>(
            predicate: #Predicate { fact in
                fact.observation.observationKey == iTunesCrawlKey
                    && fact.appStoreID == targetAppStoreID
            }
        )
        iTunesFactDescriptor.fetchLimit = 1
        guard let iTunesCrawlItem = try modelContext.fetch(iTunesFactDescriptor).first else {
            throw OpenASOError.unexpectedResponse
        }

        return CrossSourceWatermarkRecord(
            latestRatingCount: latestRating.ratingCount,
            latestRatingObservedAt: latestRating.observedAt,
            latestRatingSource: latestRating.source,
            dailyRatingCount: dailyRating.ratingCount,
            dailyRatingObservedAt: dailyRating.observedAt,
            dailyRatingSource: dailyRating.source,
            storeAppName: storeApp.name,
            storeAppMetadataObservedAt: storeApp.lastMetadataRefreshAt,
            storeAppLanguageSource: storeApp.supportedLanguageCodesSource,
            storefrontMetadataName: storefrontMetadata.name,
            storefrontMetadataObservedAt: storefrontMetadata.lastFetchedAt,
            storefrontMetadataSource: storefrontMetadata.source,
            iTunesCrawlName: iTunesCrawlItem.name,
            iTunesCrawlObservedAt: iTunesCrawl.observedAt
        )
    }
}

private struct CatalogWatermarkRecord: Equatable, Sendable {
    let defaultStorefront: String
    let name: String
    let iconURLString: String?
    let bundleID: String?
    let sellerName: String?
    let version: String?
    let globalMetadataObservedAt: Date
    let supportedLanguageCodes: [String]
    let supportedLanguageCodesObservedAt: Date?
    let defaultMetadataName: String
    let defaultMetadataIconURLString: String?
    let defaultMetadataObservedAt: Date
    let nonDefaultMetadataName: String
    let nonDefaultMetadataIconURLString: String?
    let nonDefaultMetadataObservedAt: Date
}

private func catalogWatermarkRecord(
    appStoreID: Int64,
    defaultStorefront: String,
    nonDefaultStorefront: String,
    in store: BackgroundModelStore
) async throws -> CatalogWatermarkRecord {
    try await store.read { modelContext in
        let targetAppStoreID = appStoreID
        let defaultMetadataKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: appStoreID,
            storefront: defaultStorefront
        )
        let nonDefaultMetadataKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: appStoreID,
            storefront: nonDefaultStorefront
        )
        var storeAppDescriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { app in
                app.appStoreID == targetAppStoreID
            }
        )
        storeAppDescriptor.fetchLimit = 1
        var defaultMetadataDescriptor = FetchDescriptor<AppStorefrontMetadata>(
            predicate: #Predicate { metadata in
                metadata.identityKey == defaultMetadataKey
            }
        )
        defaultMetadataDescriptor.fetchLimit = 1
        var nonDefaultMetadataDescriptor = FetchDescriptor<AppStorefrontMetadata>(
            predicate: #Predicate { metadata in
                metadata.identityKey == nonDefaultMetadataKey
            }
        )
        nonDefaultMetadataDescriptor.fetchLimit = 1

        guard let storeApp = try modelContext.fetch(storeAppDescriptor).first,
              let defaultMetadata = try modelContext.fetch(defaultMetadataDescriptor).first,
              let nonDefaultMetadata = try modelContext.fetch(nonDefaultMetadataDescriptor).first else {
            throw OpenASOError.unexpectedResponse
        }

        return CatalogWatermarkRecord(
            defaultStorefront: storeApp.defaultStorefront,
            name: storeApp.name,
            iconURLString: storeApp.iconURLString,
            bundleID: storeApp.bundleID,
            sellerName: storeApp.sellerName,
            version: storeApp.version,
            globalMetadataObservedAt: storeApp.lastMetadataRefreshAt,
            supportedLanguageCodes: storeApp.supportedLanguageCodes,
            supportedLanguageCodesObservedAt: storeApp.supportedLanguageCodesFetchedAt,
            defaultMetadataName: defaultMetadata.name,
            defaultMetadataIconURLString: defaultMetadata.iconURLString,
            defaultMetadataObservedAt: defaultMetadata.lastFetchedAt,
            nonDefaultMetadataName: nonDefaultMetadata.name,
            nonDefaultMetadataIconURLString: nonDefaultMetadata.iconURLString,
            nonDefaultMetadataObservedAt: nonDefaultMetadata.lastFetchedAt
        )
    }
}

private struct StatsRecord: Equatable, Sendable {
    let appStoreID: Int64
    let bestRank: Int?
    let latestRank: Int?
    let observationCount: Int
}

private func statsRecords(in store: BackgroundModelStore) async throws -> [StatsRecord] {
    try await store.read { modelContext in
        try modelContext.fetch(FetchDescriptor<AppKeywordStats>())
            .map {
                StatsRecord(
                    appStoreID: $0.appStoreID,
                    bestRank: $0.bestRank,
                    latestRank: $0.latestRank,
                    observationCount: $0.observationCount
                )
            }
            .sorted { $0.appStoreID < $1.appStoreID }
    }
}

private func rankingItem(
    position: Int,
    appStoreID: Int64,
    name: String? = nil,
    bundleID: String? = nil,
    sellerName: String? = nil,
    iconURLString: String? = nil,
    version: String? = nil,
    supportedLanguageCodes: [String]? = nil,
    ratingCount: Int? = nil,
    averageRating: Double? = nil
) -> SearchRankingItem {
    SearchRankingItem(
        position: position,
        appStoreID: appStoreID,
        bundleID: bundleID ?? "example.\(appStoreID)",
        name: name ?? "App \(appStoreID)",
        subtitle: "Subtitle \(appStoreID)",
        sellerName: sellerName ?? "Seller \(appStoreID)",
        iconURLString: iconURLString ?? "https://example.com/\(appStoreID).png",
        version: version ?? "1.0",
        primaryGenreID: 6002,
        primaryGenreName: "Utilities",
        descriptionText: "Description \(appStoreID)",
        releaseNotes: "Notes \(appStoreID)",
        supportedLanguageCodes: supportedLanguageCodes ?? ["EN", "FR"],
        screenshotURLs: ["https://example.com/\(appStoreID)-iphone.png"],
        ratingCount: ratingCount,
        averageRating: averageRating,
        platform: .ipad
    )
}

private func utcDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    ))!
}
