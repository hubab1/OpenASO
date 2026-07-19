import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchHistoryReaderTests {
    @Test
    func ordersNewestFirstWithStableObservationKeyTieBreakAndPaginates() async throws {
        let fixture = try await makeFixture()
        let tiedDate = researchHistoryDate(day: 3, hour: 10)
        let oldDate = researchHistoryDate(day: 2, hour: 10)
        let keys = try await seedObservations(
            [
                ObservationSeed(observedAt: tiedDate, source: .iTunesFallback),
                ObservationSeed(observedAt: oldDate, source: .appStoreWeb),
                ObservationSeed(observedAt: tiedDate, source: .appStoreWeb),
            ],
            for: fixture.keyword,
            in: fixture.backgroundStore
        )

        let first = try await fixture.reader.page(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation,
            offset: 0,
            limit: 2
        )
        let second = try await fixture.reader.page(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation,
            offset: try #require(first.nextOffset),
            limit: 2
        )

        #expect(first.observations.map(\.id) == [keys[0], keys[2]].sorted())
        #expect(first.observations.map(\.observedAt) == [tiedDate, tiedDate])
        #expect(first.nextOffset == 2)
        #expect(second.observations.map(\.id) == [keys[1]])
        #expect(second.nextOffset == nil)
        #expect(Set(first.observations.map(\.id) + second.observations.map(\.id)).count == 3)
    }

    @Test
    func exactFullFinalPageDoesNotInventAnotherOffset() async throws {
        let fixture = try await makeFixture()
        _ = try await seedObservations(
            [
                ObservationSeed(
                    observedAt: researchHistoryDate(day: 2),
                    source: .appStoreWeb
                ),
                ObservationSeed(
                    observedAt: researchHistoryDate(day: 1),
                    source: .appStoreWeb
                ),
            ],
            for: fixture.keyword,
            in: fixture.backgroundStore
        )

        let page = try await fixture.reader.page(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation,
            limit: 2
        )

        #expect(page.observations.count == 2)
        #expect(page.nextOffset == nil)
    }

    @Test
    func snapshotsSortSearchResultsWithoutAddingAnAppRank() async throws {
        let fixture = try await makeFixture()
        _ = try await seedObservations(
            [
                ObservationSeed(
                    observedAt: researchHistoryDate(day: 1),
                    source: .appStoreWeb,
                    items: [
                        RankingSeed(position: 2, appStoreID: 20, name: "Twenty"),
                        RankingSeed(position: 1, appStoreID: 30, name: "Thirty"),
                        RankingSeed(position: 2, appStoreID: 10, name: "Ten"),
                    ]
                ),
            ],
            for: fixture.keyword,
            in: fixture.backgroundStore
        )

        let page = try await fixture.reader.page(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation
        )
        let observation = try #require(page.observations.first)

        #expect(observation.projectGeneration == fixture.project.generation)
        #expect(observation.keywordGeneration == fixture.keyword.generation)
        #expect(observation.items.map(\.position) == [1, 2, 2])
        #expect(observation.items.map(\.appStoreID) == [30, 10, 20])

        let observationFields = Set(
            Mirror(reflecting: observation).children.compactMap(\.label)
        )
        #expect(!observationFields.contains("rank"))
        #expect(!observationFields.contains("appRank"))
    }

    @Test
    func sharedQueryHistoryRemainsVisibleToIndependentMemberships() async throws {
        let fixture = try await makeFixture()
        let secondProject = try await fixture.projectStore.createProject(
            name: "Second project",
            defaultStorefront: "gb",
            defaultPlatform: .ipad
        )
        let secondAddition = try await fixture.projectStore.addKeyword(
            to: secondProject.revision,
            term: fixture.keyword.term,
            storefront: fixture.keyword.storefront,
            platform: fixture.keyword.platform
        )
        let keys = try await seedObservations(
            [
                ObservationSeed(
                    observedAt: researchHistoryDate(day: 1),
                    source: .appStoreWeb
                ),
            ],
            for: fixture.keyword,
            in: fixture.backgroundStore
        )

        let firstPage = try await fixture.reader.page(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation
        )
        let secondPage = try await fixture.reader.page(
            projectGeneration: secondAddition.project.generation,
            keywordGeneration: secondAddition.keyword.generation
        )
        _ = try await fixture.projectStore.removeKeyword(
            revision: secondAddition.keyword.revision,
            from: secondAddition.project.revision
        )
        let firstPageAfterRemoval = try await fixture.reader.page(
            projectGeneration: fixture.project.generation,
            keywordGeneration: fixture.keyword.generation
        )

        #expect(firstPage.observations.map(\.id) == keys)
        #expect(secondPage.observations.map(\.id) == keys)
        #expect(firstPageAfterRemoval.observations.map(\.id) == keys)
    }

    @Test
    func removedKeywordAndDeletedProjectAreRejected() async throws {
        let removedKeywordFixture = try await makeFixture()
        _ = try await removedKeywordFixture.projectStore.removeKeyword(
            revision: removedKeywordFixture.keyword.revision,
            from: removedKeywordFixture.project.revision
        )

        await #expect(throws: KeywordResearchProjectStoreError.keywordNotFound(
            removedKeywordFixture.keyword.id
        )) {
            _ = try await removedKeywordFixture.reader.page(
                projectGeneration: removedKeywordFixture.project.generation,
                keywordGeneration: removedKeywordFixture.keyword.generation
            )
        }

        let deletedProjectFixture = try await makeFixture()
        try await deletedProjectFixture.projectStore.deleteProject(
            revision: deletedProjectFixture.project.revision
        )

        await #expect(throws: KeywordResearchProjectStoreError.projectNotFound(
            deletedProjectFixture.project.id
        )) {
            _ = try await deletedProjectFixture.reader.page(
                projectGeneration: deletedProjectFixture.project.generation,
                keywordGeneration: deletedProjectFixture.keyword.generation
            )
        }
    }

    @Test
    func reincarnatedKeywordRejectsTheOldGenerationButKeepsSharedHistory() async throws {
        let fixture = try await makeFixture()
        let keys = try await seedObservations(
            [
                ObservationSeed(
                    observedAt: researchHistoryDate(day: 1),
                    source: .appStoreWeb
                ),
            ],
            for: fixture.keyword,
            in: fixture.backgroundStore
        )
        let projectAfterRemoval = try await fixture.projectStore.removeKeyword(
            revision: fixture.keyword.revision,
            from: fixture.project.revision
        )
        let replacement = try await fixture.projectStore.addKeyword(
            id: fixture.keyword.id,
            to: projectAfterRemoval.revision,
            term: fixture.keyword.term,
            storefront: fixture.keyword.storefront,
            platform: fixture.keyword.platform
        )

        #expect(replacement.keyword.incarnationID != fixture.keyword.incarnationID)
        await #expect(throws: KeywordResearchProjectStoreError.staleKeywordRevision(
            fixture.keyword.id
        )) {
            _ = try await fixture.reader.page(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation
            )
        }

        let replacementPage = try await fixture.reader.page(
            projectGeneration: replacement.project.generation,
            keywordGeneration: replacement.keyword.generation
        )
        #expect(replacementPage.observations.map(\.id) == keys)
    }

    @Test
    func reincarnatedProjectRejectsTheOldGenerationButKeepsSharedHistory() async throws {
        let fixture = try await makeFixture()
        let keys = try await seedObservations(
            [
                ObservationSeed(
                    observedAt: researchHistoryDate(day: 1),
                    source: .appStoreWeb
                ),
            ],
            for: fixture.keyword,
            in: fixture.backgroundStore
        )
        try await fixture.projectStore.deleteProject(revision: fixture.project.revision)
        let replacementProject = try await fixture.projectStore.createProject(
            id: fixture.project.id,
            name: "Replacement project",
            defaultStorefront: fixture.keyword.storefront,
            defaultPlatform: fixture.keyword.platform
        )
        let replacement = try await fixture.projectStore.addKeyword(
            id: fixture.keyword.id,
            to: replacementProject.revision,
            term: fixture.keyword.term,
            storefront: fixture.keyword.storefront,
            platform: fixture.keyword.platform
        )

        #expect(replacement.project.incarnationID != fixture.project.incarnationID)
        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(
            fixture.project.id
        )) {
            _ = try await fixture.reader.page(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation
            )
        }

        let replacementPage = try await fixture.reader.page(
            projectGeneration: replacement.project.generation,
            keywordGeneration: replacement.keyword.generation
        )
        #expect(replacementPage.observations.map(\.id) == keys)
    }

    @Test
    func rejectsInvalidPaginationBeforeReadingTheStore() async throws {
        let fixture = try await makeFixture()

        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.reader.page(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation,
                offset: -1
            )
        }
        for invalidLimit in [0, KeywordResearchHistoryReader.maximumPageLimit + 1] {
            await #expect(throws: KeywordResearchProjectStoreError.invalidLimit) {
                _ = try await fixture.reader.page(
                    projectGeneration: fixture.project.generation,
                    keywordGeneration: fixture.keyword.generation,
                    limit: invalidLimit
                )
            }
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.reader.page(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation,
                offset: Int.max,
                limit: 1
            )
        }
    }

    @Test
    func observesCancellationBeforeStartingARead() async throws {
        let fixture = try await makeFixture()
        let task = Task {
            try await fixture.reader.page(
                projectGeneration: fixture.project.generation,
                keywordGeneration: fixture.keyword.generation
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

@MainActor
private extension KeywordResearchHistoryReaderTests {
    func makeFixture(
        term: String = "shared research keyword"
    ) async throws -> ResearchHistoryFixture {
        let container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let projectStore = KeywordResearchProjectStore(
            backgroundModelStore: backgroundStore,
            now: { researchHistoryDate(day: 1) }
        )
        let project = try await projectStore.createProject(
            name: "Research history",
            defaultStorefront: "gb",
            defaultPlatform: .ipad
        )
        let addition = try await projectStore.addKeyword(
            to: project.revision,
            term: term,
            storefront: "gb",
            platform: .ipad
        )
        return ResearchHistoryFixture(
            container: container,
            backgroundStore: backgroundStore,
            projectStore: projectStore,
            reader: KeywordResearchHistoryReader(
                backgroundModelStore: backgroundStore
            ),
            project: addition.project,
            keyword: addition.keyword
        )
    }
}

@MainActor
private struct ResearchHistoryFixture {
    let container: ModelContainer
    let backgroundStore: BackgroundModelStore
    let projectStore: KeywordResearchProjectStore
    let reader: KeywordResearchHistoryReader
    let project: KeywordResearchProjectSnapshot
    let keyword: KeywordResearchKeywordSnapshot
}

private struct ObservationSeed: Sendable {
    let observedAt: Date
    let source: RankingSource
    let items: [RankingSeed]

    init(
        observedAt: Date,
        source: RankingSource,
        items: [RankingSeed] = []
    ) {
        self.observedAt = observedAt
        self.source = source
        self.items = items
    }
}

private struct RankingSeed: Sendable {
    let position: Int
    let appStoreID: Int64
    let name: String
}

private func seedObservations(
    _ seeds: [ObservationSeed],
    for keyword: KeywordResearchKeywordSnapshot,
    in store: BackgroundModelStore
) async throws -> [String] {
    try await store.write { modelContext in
        let targetQueryKey = keyword.queryKey
        var descriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == targetQueryKey
            }
        )
        descriptor.fetchLimit = 1
        guard let query = try modelContext.fetch(descriptor).first else {
            throw OpenASOError.unexpectedResponse
        }

        return seeds.map { seed in
            let observation = KeywordRankingCrawl(
                keyword: query.term,
                storefront: query.storefront,
                platform: query.platform,
                observedAt: seed.observedAt,
                source: seed.source,
                resultCount: seed.items.count,
                query: query
            )
            query.observations.append(observation)
            modelContext.insert(observation)

            for itemSeed in seed.items {
                let item = KeywordAppRanking(
                    position: itemSeed.position,
                    appStoreID: itemSeed.appStoreID,
                    bundleID: "com.example.\(itemSeed.appStoreID)",
                    name: itemSeed.name,
                    subtitle: "Subtitle \(itemSeed.appStoreID)",
                    sellerName: "Seller \(itemSeed.appStoreID)",
                    observation: observation
                )
                observation.items.append(item)
                modelContext.insert(item)
            }
            return observation.observationKey
        }
    }
}

private func researchHistoryDate(day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: day,
        hour: hour
    ))!
}
