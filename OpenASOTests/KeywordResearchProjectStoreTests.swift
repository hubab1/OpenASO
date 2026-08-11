import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchProjectStoreTests {
    private let baseDate = Date(timeIntervalSinceReferenceDate: 806_000_000)

    @Test
    func projectCRUDIsIdempotentRevisionCheckedAndDeterministicallyPaged() async throws {
        let fixture = try makeFixture()
        let lowerID = UUID(uuidString: "32000000-0000-4000-8000-000000000001")!
        let higherID = UUID(uuidString: "32000000-0000-4000-8000-000000000002")!

        let higher = try await fixture.store.createProject(
            id: higherID,
            name: "  Launch Research  ",
            bundleID: "  com.example.launch  ",
            defaultStorefront: " GB ",
            defaultPlatform: .ipad,
            notes: "first"
        )
        let lower = try await fixture.store.createProject(
            id: lowerID,
            name: "Launch Research",
            defaultStorefront: "gb",
            defaultPlatform: .ipad,
            notes: "second"
        )

        #expect(higher.name == "Launch Research")
        #expect(higher.bundleID == "com.example.launch")
        #expect(higher.defaultStorefront == "gb")
        #expect(higher.createdAt == baseDate)
        #expect(higher.updatedAt == baseDate)
        #expect(lower.name == higher.name)

        let firstPage = try await fixture.store.listProjects(offset: 0, limit: 1)
        let secondPage = try await fixture.store.listProjects(offset: 1, limit: 1)
        #expect(firstPage.map(\.id) == [lowerID])
        #expect(secondPage.map(\.id) == [higherID])

        let retry = try await fixture.store.createProject(
            id: higherID,
            name: "Launch Research",
            bundleID: "com.example.launch",
            defaultStorefront: "gb",
            defaultPlatform: .ipad,
            notes: "first"
        )
        #expect(retry == higher)
        let changedPayloadRetry = try await fixture.store.createProject(
            id: higherID,
            name: "Different valid name",
            bundleID: "com.example.different",
            defaultStorefront: "fr",
            defaultPlatform: .iphone,
            notes: "different valid payload"
        )
        #expect(changedPayloadRetry == higher)

        await #expect(throws: KeywordResearchProjectStoreError.invalidName) {
            _ = try await fixture.store.createProject(
                id: higherID,
                name: " \n "
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidBundleID) {
            _ = try await fixture.store.createProject(
                id: higherID,
                name: "Valid",
                bundleID: String(repeating: "b", count: 256)
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidStorefront) {
            _ = try await fixture.store.createProject(
                id: higherID,
                name: "Valid",
                defaultStorefront: "invalid"
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidNotes) {
            _ = try await fixture.store.createProject(
                id: higherID,
                name: "Valid",
                notes: String(repeating: "n", count: 10_001)
            )
        }

        let updated = try await fixture.store.updateProject(
            revision: higher.revision,
            name: " Updated Launch ",
            bundleID: "   ",
            defaultStorefront: " US ",
            defaultPlatform: .mac,
            notes: "updated"
        )
        #expect(updated.name == "Updated Launch")
        #expect(updated.bundleID == nil)
        #expect(updated.defaultStorefront == "us")
        #expect(updated.defaultPlatform == .mac)
        #expect(updated.generation == higher.generation)
        #expect(updated.updatedAt.timeIntervalSince(higher.updatedAt) >= 0.001)

        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(higherID)) {
            _ = try await fixture.store.updateProject(
                revision: higher.revision,
                name: "stale",
                defaultStorefront: "us",
                defaultPlatform: .iphone
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(higherID)) {
            try await fixture.store.deleteProject(revision: higher.revision)
        }

        try await fixture.store.deleteProject(revision: updated.revision)
        #expect(try await fixture.store.listProjects().map(\.id) == [lowerID])

        let replacement = try await fixture.store.createProject(
            id: higherID,
            name: "Replacement",
            defaultStorefront: "us"
        )
        #expect(replacement.id == higher.id)
        #expect(replacement.createdAt == higher.createdAt)
        #expect(replacement.generation != higher.generation)
        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(higherID)) {
            _ = try await fixture.store.updateProject(
                revision: updated.revision,
                name: "must not mutate replacement",
                defaultStorefront: "us",
                defaultPlatform: .iphone
            )
        }
    }

    @Test
    func pageReadsProbePastTheBoundaryAndReturnExactContinuationOffsets() async throws {
        let projectFixture = try makeFixture()
        let lowerProjectID = UUID(uuidString: "32000000-0000-4000-8000-000000000011")!
        let middleProjectID = UUID(uuidString: "32000000-0000-4000-8000-000000000012")!
        let higherProjectID = UUID(uuidString: "32000000-0000-4000-8000-000000000013")!

        for (id, name) in [
            (higherProjectID, "Higher"),
            (lowerProjectID, "Lower"),
            (middleProjectID, "Middle")
        ] {
            _ = try await projectFixture.store.createProject(id: id, name: name)
        }

        let firstProjectPage = try await projectFixture.store.listProjectsPage(
            offset: 0,
            limit: 2
        )
        let finalProjectPage = try await projectFixture.store.listProjectsPage(
            offset: try #require(firstProjectPage.nextOffset),
            limit: 2
        )
        let pastProjectEnd = try await projectFixture.store.listProjectsPage(
            offset: 3,
            limit: 2
        )

        #expect(firstProjectPage.items.map(\.id) == [lowerProjectID, middleProjectID])
        #expect(firstProjectPage.nextOffset == 2)
        #expect(finalProjectPage.items.map(\.id) == [higherProjectID])
        #expect(finalProjectPage.nextOffset == nil)
        #expect(pastProjectEnd.items.isEmpty)
        #expect(pastProjectEnd.nextOffset == nil)
        #expect(
            try await projectFixture.store.listProjects(offset: 0, limit: 2)
                == firstProjectPage.items
        )

        let exactProjectFixture = try makeFixture()
        _ = try await exactProjectFixture.store.createProject(
            id: lowerProjectID,
            name: "Lower"
        )
        _ = try await exactProjectFixture.store.createProject(
            id: higherProjectID,
            name: "Higher"
        )
        let exactProjectPage = try await exactProjectFixture.store.listProjectsPage(
            offset: 0,
            limit: 2
        )
        #expect(exactProjectPage.items.map(\.id) == [lowerProjectID, higherProjectID])
        #expect(exactProjectPage.nextOffset == nil)

        let keywordFixture = try makeFixture()
        var project = try await keywordFixture.store.createProject(name: "Keyword pages")
        let lowerKeywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000021")!
        let middleKeywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000022")!
        let higherKeywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000023")!

        for (id, term) in [
            (higherKeywordID, "higher"),
            (lowerKeywordID, "lower"),
            (middleKeywordID, "middle")
        ] {
            let addition = try await keywordFixture.store.addKeyword(
                id: id,
                to: project.revision,
                term: term,
                storefront: "us",
                platform: .iphone
            )
            project = addition.project
        }

        let firstKeywordPage = try await keywordFixture.store.listKeywordsPage(
            in: project.generation,
            offset: 0,
            limit: 2
        )
        let finalKeywordPage = try await keywordFixture.store.listKeywordsPage(
            in: project.generation,
            offset: try #require(firstKeywordPage.nextOffset),
            limit: 2
        )
        let exactKeywordPage = try await keywordFixture.store.listKeywordsPage(
            in: project.generation,
            offset: 0,
            limit: 3
        )
        let pastKeywordEnd = try await keywordFixture.store.listKeywordsPage(
            in: project.generation,
            offset: 3,
            limit: 2
        )

        #expect(firstKeywordPage.items.map(\.id) == [lowerKeywordID, middleKeywordID])
        #expect(firstKeywordPage.nextOffset == 2)
        #expect(finalKeywordPage.items.map(\.id) == [higherKeywordID])
        #expect(finalKeywordPage.nextOffset == nil)
        #expect(exactKeywordPage.items.map(\.id) == [
            lowerKeywordID,
            middleKeywordID,
            higherKeywordID
        ])
        #expect(exactKeywordPage.nextOffset == nil)
        #expect(pastKeywordEnd.items.isEmpty)
        #expect(pastKeywordEnd.nextOffset == nil)
        #expect(
            try await keywordFixture.store.listKeywords(
                in: project.generation,
                offset: 0,
                limit: 2
            ) == firstKeywordPage.items
        )
        #expect(Set([firstKeywordPage, firstKeywordPage]).count == 1)
    }

    @Test
    func pageReadsValidateBoundsBeforeAccessingPersistentGenerations() async throws {
        let fixture = try makeFixture()
        let missingGeneration = KeywordResearchProjectGeneration(
            id: UUID(uuidString: "32000000-0000-4000-8000-000000000031")!,
            incarnationID: UUID(uuidString: "32000000-0000-4000-8000-000000000032")!
        )

        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listProjectsPage(offset: -1, limit: 1)
        }
        for invalidLimit in [0, KeywordResearchProjectStore.maximumPageLimit + 1] {
            await #expect(throws: KeywordResearchProjectStoreError.invalidLimit) {
                _ = try await fixture.store.listProjectsPage(offset: 0, limit: invalidLimit)
            }
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listProjects(offset: Int.max, limit: 1)
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listProjectsPage(offset: Int.max, limit: 1)
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listKeywordsPage(
                in: missingGeneration,
                offset: -1,
                limit: 1
            )
        }
        for invalidLimit in [0, KeywordResearchProjectStore.maximumPageLimit + 1] {
            await #expect(throws: KeywordResearchProjectStoreError.invalidLimit) {
                _ = try await fixture.store.listKeywordsPage(
                    in: missingGeneration,
                    offset: 0,
                    limit: invalidLimit
                )
            }
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listKeywords(
                in: missingGeneration,
                offset: Int.max,
                limit: 1
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listKeywordsPage(
                in: missingGeneration,
                offset: Int.max,
                limit: 1
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.projectNotFound(
            missingGeneration.id
        )) {
            _ = try await fixture.store.listKeywordsPage(
                in: missingGeneration,
                offset: 0,
                limit: 1
            )
        }
    }

    @Test
    func exactProjectReloadAndKeywordPagesRejectDeletedOrReincarnatedGenerations() async throws {
        let fixture = try makeFixture()
        let projectID = UUID(uuidString: "32000000-0000-4000-8000-000000000041")!
        let original = try await fixture.store.createProject(
            id: projectID,
            name: "Original"
        )

        #expect(try await fixture.store.loadProject(generation: original.generation) == original)

        let updated = try await fixture.store.updateProject(
            revision: original.revision,
            name: "Updated",
            defaultStorefront: "gb",
            defaultPlatform: .ipad
        )
        #expect(updated.generation == original.generation)
        #expect(try await fixture.store.loadProject(generation: original.generation) == updated)

        try await fixture.store.deleteProject(revision: updated.revision)
        await #expect(throws: KeywordResearchProjectStoreError.projectNotFound(projectID)) {
            _ = try await fixture.store.loadProject(generation: original.generation)
        }
        await #expect(throws: KeywordResearchProjectStoreError.projectNotFound(projectID)) {
            _ = try await fixture.store.listKeywordsPage(
                in: original.generation,
                offset: 0,
                limit: 50
            )
        }

        let replacement = try await fixture.store.createProject(
            id: projectID,
            name: "Replacement"
        )
        #expect(replacement.generation != original.generation)
        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(projectID)) {
            _ = try await fixture.store.loadProject(generation: original.generation)
        }
        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(projectID)) {
            _ = try await fixture.store.listKeywordsPage(
                in: original.generation,
                offset: 0,
                limit: 50
            )
        }
        #expect(
            try await fixture.store.loadProject(generation: replacement.generation)
                == replacement
        )
        #expect(
            try await fixture.store.listKeywordsPage(
                in: replacement.generation,
                offset: 0,
                limit: 50
            ) == KeywordResearchPage<KeywordResearchKeywordSnapshot>(
                items: [],
                nextOffset: nil
            )
        )
    }

    @Test
    func validationUsesNormalizedUTF8BoundsAndStrictPagination() async throws {
        let fixture = try makeFixture()

        await #expect(throws: KeywordResearchProjectStoreError.invalidName) {
            _ = try await fixture.store.createProject(name: " \n ")
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidName) {
            _ = try await fixture.store.createProject(name: String(repeating: "é", count: 101))
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidBundleID) {
            _ = try await fixture.store.createProject(
                name: "Project",
                bundleID: String(repeating: "b", count: 256)
            )
        }
        for invalidStorefront in ["u", "usa", "u1", "éé"] {
            await #expect(throws: KeywordResearchProjectStoreError.invalidStorefront) {
                _ = try await fixture.store.createProject(
                    name: "Project",
                    defaultStorefront: invalidStorefront
                )
            }
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidNotes) {
            _ = try await fixture.store.createProject(
                name: "Project",
                notes: String(repeating: "n", count: 10_001)
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listProjects(offset: -1, limit: 1)
        }
        for invalidLimit in [0, 201] {
            await #expect(throws: KeywordResearchProjectStoreError.invalidLimit) {
                _ = try await fixture.store.listProjects(limit: invalidLimit)
            }
        }

        let project = try await fixture.store.createProject(
            name: String(repeating: "é", count: 100),
            bundleID: "   ",
            defaultStorefront: " GB ",
            notes: String(repeating: "é", count: 5_000)
        )
        #expect(project.name.utf8.count == 200)
        #expect(project.bundleID == nil)
        #expect(project.notes.utf8.count == 10_000)

        await #expect(throws: KeywordResearchProjectStoreError.invalidTerm) {
            _ = try await fixture.store.addKeyword(
                to: project.revision,
                term: " \n ",
                storefront: "us",
                platform: .iphone
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidTerm) {
            _ = try await fixture.store.addKeyword(
                to: project.revision,
                term: String(repeating: "é", count: 101),
                storefront: "us",
                platform: .iphone
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidNotes) {
            _ = try await fixture.store.addKeyword(
                to: project.revision,
                term: "valid",
                storefront: "us",
                platform: .iphone,
                notes: String(repeating: "é", count: 5_001)
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidStorefront) {
            _ = try await fixture.store.addKeyword(
                to: project.revision,
                term: "valid",
                storefront: "USA",
                platform: .iphone
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidOffset) {
            _ = try await fixture.store.listKeywords(
                in: project.generation,
                offset: -1,
                limit: 1
            )
        }
        await #expect(throws: KeywordResearchProjectStoreError.invalidLimit) {
            _ = try await fixture.store.listKeywords(
                in: project.generation,
                limit: 201
            )
        }

        let boundary = try await fixture.store.addKeyword(
            to: project.revision,
            term: "  " + String(repeating: "é", count: 100) + "  ",
            storefront: " US ",
            platform: .iphone,
            notes: String(repeating: "é", count: 5_000)
        )
        #expect(boundary.keyword.term.utf8.count == 200)
        #expect(boundary.keyword.storefront == "us")
        #expect(boundary.keyword.notes.utf8.count == 10_000)
    }

    @Test
    func hardQuotasAreAtomicWhileIdempotentReplaysStillSucceed() async throws {
        let fixture = try makeFixture(projectLimit: 2, keywordLimitPerProject: 2)
        let firstProjectID = UUID(uuidString: "32000000-0000-4000-8000-000000000081")!
        let secondProjectID = UUID(uuidString: "32000000-0000-4000-8000-000000000082")!
        let firstProject = try await fixture.store.createProject(
            id: firstProjectID,
            name: "First"
        )
        _ = try await fixture.store.createProject(
            id: secondProjectID,
            name: "Second"
        )

        let replayedProject = try await fixture.store.createProject(
            id: firstProjectID,
            name: "A different but valid retry payload",
            defaultStorefront: "gb"
        )
        #expect(replayedProject == firstProject)
        await #expect(throws: KeywordResearchProjectStoreError.projectLimitReached(maximum: 2)) {
            _ = try await fixture.store.createProject(name: "Third")
        }
        #expect(try await fixture.store.listProjects().count == 2)

        let firstKeywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000083")!
        let firstKeyword = try await fixture.store.addKeyword(
            id: firstKeywordID,
            to: firstProject.revision,
            term: "first keyword",
            storefront: "us",
            platform: .iphone
        )
        let secondKeyword = try await fixture.store.addKeyword(
            to: firstKeyword.project.revision,
            term: "second keyword",
            storefront: "us",
            platform: .iphone
        )

        let replayedKeyword = try await fixture.store.addKeyword(
            id: firstKeywordID,
            to: firstProject.revision,
            term: "first keyword",
            storefront: "us",
            platform: .iphone,
            notes: "ignored on replay"
        )
        #expect(replayedKeyword.keyword == firstKeyword.keyword)
        #expect(replayedKeyword.project.revision == secondKeyword.project.revision)
        await #expect(throws: KeywordResearchProjectStoreError.keywordLimitReached(
            projectID: firstProjectID,
            maximum: 2
        )) {
            _ = try await fixture.store.addKeyword(
                to: secondKeyword.project.revision,
                term: "third keyword",
                storefront: "us",
                platform: .iphone
            )
        }
        #expect(try await fixture.store.listKeywords(in: firstProject.generation).count == 2)
        let keywordAndQueryCounts = try await fixture.backgroundModelStore.read { modelContext in
            [
                try modelContext.fetchCount(FetchDescriptor<KeywordResearchKeyword>()),
                try modelContext.fetchCount(FetchDescriptor<KeywordQuery>())
            ]
        }
        #expect(keywordAndQueryCounts == [2, 2])
    }

    @Test
    func membershipAddDeduplicatesOpaqueQueryAndIdempotentRetriesDoNotAdvanceRevisions() async throws {
        let fixture = try makeFixture()
        let project = try await fixture.store.createProject(name: "Research")
        let firstID = UUID(uuidString: "32000000-0000-4000-8000-000000000101")!
        let duplicateID = UUID(uuidString: "32000000-0000-4000-8000-000000000102")!
        let secondID = UUID(uuidString: "32000000-0000-4000-8000-000000000103")!

        let first = try await fixture.store.addKeyword(
            id: firstID,
            to: project.revision,
            term: "  launch::planner  ",
            storefront: " GB ",
            platform: .mac,
            notes: "primary"
        )
        #expect(first.keyword.queryKey == KeywordQuery.makeQueryKey(
            term: "launch::planner",
            storefront: "gb",
            platform: .mac
        ))
        #expect(first.project.updatedAt.timeIntervalSince(project.updatedAt) >= 0.001)

        let exactRetry = try await fixture.store.addKeyword(
            id: firstID,
            to: project.revision,
            term: "launch::planner",
            storefront: "gb",
            platform: .mac,
            notes: "a retry does not overwrite membership notes"
        )
        let semanticRetry = try await fixture.store.addKeyword(
            id: duplicateID,
            to: project.revision,
            term: "LAUNCH::PLANNER",
            storefront: "gb",
            platform: .mac,
            notes: "ignored on duplicate membership"
        )
        #expect(exactRetry == first)
        #expect(semanticRetry.keyword == first.keyword)
        #expect(semanticRetry.project.revision == first.project.revision)

        await #expect(throws: KeywordResearchProjectStoreError.keywordIdentifierConflict(firstID)) {
            _ = try await fixture.store.addKeyword(
                id: firstID,
                to: first.project.revision,
                term: "different keyword",
                storefront: "gb",
                platform: .mac,
                notes: "primary"
            )
        }
        let countsAfterConflict = try await fixture.backgroundModelStore.read { modelContext in
            [
                try modelContext.fetchCount(FetchDescriptor<KeywordResearchKeyword>()),
                try modelContext.fetchCount(FetchDescriptor<KeywordQuery>())
            ]
        }
        #expect(countsAfterConflict == [1, 1])

        let second = try await fixture.store.addKeyword(
            id: secondID,
            to: first.project.revision,
            term: "second",
            storefront: "us",
            platform: .iphone
        )
        let listed = try await fixture.store.listKeywords(
            in: project.generation,
            offset: 0,
            limit: 2
        )
        #expect(listed.map(\.id) == [firstID, secondID])

        let afterRemoval = try await fixture.store.removeKeyword(
            revision: second.keyword.revision,
            from: second.project.revision
        )
        #expect(afterRemoval.updatedAt.timeIntervalSince(second.project.updatedAt) >= 0.001)
        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(project.id)) {
            _ = try await fixture.store.removeKeyword(
                revision: first.keyword.revision,
                from: second.project.revision
            )
        }
        let forgedRevision = KeywordResearchKeywordRevision(
            generation: first.keyword.generation,
            updatedAt: first.keyword.updatedAt.addingTimeInterval(1)
        )
        await #expect(throws: KeywordResearchProjectStoreError.staleKeywordRevision(firstID)) {
            _ = try await fixture.store.removeKeyword(
                revision: forgedRevision,
                from: afterRemoval.revision
            )
        }

        let emptyProject = try await fixture.store.removeKeyword(
            revision: first.keyword.revision,
            from: afterRemoval.revision
        )
        #expect(try await fixture.store.listKeywords(in: project.generation).isEmpty)
        #expect(try await fixture.backgroundModelStore.fetchCount(
            FetchDescriptor<KeywordQuery>()
        ) == 2)
        #expect(emptyProject.updatedAt > afterRemoval.updatedAt)

        let replacement = try await fixture.store.addKeyword(
            id: firstID,
            to: emptyProject.revision,
            term: "launch::planner",
            storefront: "gb",
            platform: .mac
        )
        #expect(replacement.keyword.id == first.keyword.id)
        #expect(replacement.keyword.createdAt == first.keyword.createdAt)
        #expect(replacement.keyword.generation != first.keyword.generation)
        await #expect(throws: KeywordResearchProjectStoreError.staleKeywordRevision(firstID)) {
            _ = try await fixture.store.removeKeyword(
                revision: first.keyword.revision,
                from: replacement.project.revision
            )
        }
    }

    @Test
    func projectDeletionCascadesOnlyMembershipAndPreservesSharedQueryData() async throws {
        let fixture = try makeFixture()
        let project = try await fixture.store.createProject(name: "Shared data")
        let addition = try await fixture.store.addKeyword(
            to: project.revision,
            term: "shared keyword",
            storefront: "us",
            platform: .iphone
        )
        let queryKey = addition.keyword.queryKey
        let calculationID = UUID(uuidString: "32000000-0000-4000-8000-000000000210")!
        let baseDate = baseDate

        try await fixture.backgroundModelStore.write { modelContext in
            let targetQueryKey = queryKey
            guard let query = try modelContext.fetch(FetchDescriptor<KeywordQuery>(
                predicate: #Predicate { query in
                    query.queryKey == targetQueryKey
                }
            )).first else {
                throw ResearchStoreTestError.missingQuery
            }
            let metric = KeywordDailyMetric(
                queryKey: queryKey,
                keyword: query.term,
                storefront: query.storefront,
                platform: query.platform,
                popularityScore: 55,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                updatedAt: baseDate
            )
            let crawl = RankingCrawlRecord(
                keyword: query.term,
                storefront: query.storefront,
                platform: query.platform,
                observedAt: baseDate,
                source: .appStoreWeb,
                resultCount: 1,
                query: query
            )
            let ranking = makeRankingFact(
                position: 1,
                appStoreID: 320_000_001,
                bundleID: "com.example.shared",
                name: "Shared Result",
                sellerName: "Example",
                observation: crawl,
                in: modelContext
            )
            let difficulty = EstimatedKeywordDifficultyMetric(
                queryKey: queryKey,
                calculationID: calculationID,
                keyword: query.term,
                storefront: query.storefront,
                platformRaw: query.platformRaw,
                stateRaw: EstimatedKeywordDifficultyState.estimated.rawValue,
                score: 61,
                confidenceScore: 78,
                confidenceRaw: EstimatedKeywordDifficultyConfidence.high.rawValue,
                unavailableReasonRaw: nil,
                estimationSourceRaw: EstimatedKeywordDifficultySource.topResultsHeuristic.rawValue,
                algorithmIdentifier: "openaso.keyword-difficulty.top-results",
                algorithmVersion: 1,
                requestedResultLimit: 100,
                providerResultCount: 1,
                consideredResultCount: 1,
                ratedResultCount: 1,
                weightedRatingCoveragePercentage: 100,
                maximumRatingCount: 1_000,
                medianRatingCount: 1_000,
                ratingAuthorityScore: 70,
                metadataSaturationScore: 52,
                exactTitlePhraseMatchCount: 1,
                exactSubtitlePhraseMatchCount: 0,
                rankingSourceRaw: RankingSource.appStoreWeb.rawValue,
                rankingFetchedAt: baseDate,
                computedAt: baseDate.addingTimeInterval(1),
                fallbackProviderRaw: nil,
                fallbackCategoryRaw: nil,
                fallbackTransportCode: nil,
                fallbackHTTPStatus: nil,
                fallbackResponseFailureRaw: nil,
                notes: ["Shared query evidence"]
            )
            let evidence = EstimatedKeywordDifficultyResultEvidenceRecord(
                queryKey: queryKey,
                calculationID: calculationID,
                position: 1,
                appStoreID: ranking.appStoreID,
                title: ranking.name,
                subtitle: nil,
                ratingCount: 1_000,
                ratingAuthorityScore: 70,
                titleTokenCoveragePercentage: 100,
                combinedTokenCoveragePercentage: 100,
                metadataMatchScore: 85,
                exactTitlePhraseMatch: true,
                exactSubtitlePhraseMatch: false
            )
            modelContext.insert(metric)
            modelContext.insert(crawl)
            modelContext.insert(ranking)
            modelContext.insert(difficulty)
            modelContext.insert(evidence)
        }

        try await fixture.store.deleteProject(revision: addition.project.revision)

        let counts = try await fixture.backgroundModelStore.read { modelContext in
            [
                try modelContext.fetchCount(FetchDescriptor<KeywordResearchProject>()),
                try modelContext.fetchCount(FetchDescriptor<KeywordResearchKeyword>()),
                try modelContext.fetchCount(FetchDescriptor<KeywordQuery>()),
                try modelContext.fetchCount(FetchDescriptor<KeywordDailyMetric>()),
                try modelContext.fetchCount(FetchDescriptor<RankingCrawlRecord>()),
                try modelContext.fetchCount(FetchDescriptor<RankingFact>()),
                try modelContext.fetchCount(FetchDescriptor<EstimatedKeywordDifficultyMetric>()),
                try modelContext.fetchCount(FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>())
            ]
        }
        #expect(counts == [0, 0, 1, 1, 1, 1, 1, 1])
    }

    @Test
    func snapshotsPersistAcrossContainerReopen() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenASO-Research-Store-Reopen-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)
        let projectID = UUID(uuidString: "32000000-0000-4000-8000-000000000301")!
        let keywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000302")!
        let baseDate = baseDate
        var expectedProject: KeywordResearchProjectSnapshot?
        var expectedKeyword: KeywordResearchKeywordSnapshot?

        do {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let backgroundStore = BackgroundModelStore(modelContainer: container)
            let store = KeywordResearchProjectStore(
                backgroundModelStore: backgroundStore,
                now: { baseDate }
            )
            let project = try await store.createProject(
                id: projectID,
                name: "Persistent",
                defaultStorefront: "gb"
            )
            let addition = try await store.addKeyword(
                id: keywordID,
                to: project.revision,
                term: "persist me",
                storefront: "gb",
                platform: .ipad
            )
            expectedProject = addition.project
            expectedKeyword = addition.keyword
        }

        do {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let backgroundStore = BackgroundModelStore(modelContainer: container)
            let store = KeywordResearchProjectStore(backgroundModelStore: backgroundStore)
            let projects = try await store.listProjects()
            let project = try #require(projects.first)
            let keywords = try await store.listKeywords(in: project.generation)
            let expectedProject = try #require(expectedProject)
            let expectedKeyword = try #require(expectedKeyword)

            #expect(projects == [expectedProject])
            #expect(keywords == [expectedKeyword])
        }
    }

    @Test
    func concurrentIdenticalAddsConvergeOnOneMembershipAndOneRevision() async throws {
        let fixture = try makeFixture()
        let project = try await fixture.store.createProject(name: "Concurrent")
        let keywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000401")!
        let store = fixture.store

        let additions = try await withThrowingTaskGroup(
            of: KeywordResearchKeywordAddition.self,
            returning: [KeywordResearchKeywordAddition].self
        ) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await store.addKeyword(
                        id: keywordID,
                        to: project.revision,
                        term: "actor safe",
                        storefront: "us",
                        platform: .iphone
                    )
                }
            }

            var values: [KeywordResearchKeywordAddition] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        let first = try #require(additions.first)
        #expect(additions.count == 24)
        #expect(additions.allSatisfy { $0 == first })
        #expect(try await fixture.store.listKeywords(in: project.generation) == [first.keyword])
        let counts = try await fixture.backgroundModelStore.read { modelContext in
            [
                try modelContext.fetchCount(FetchDescriptor<KeywordResearchKeyword>()),
                try modelContext.fetchCount(FetchDescriptor<KeywordQuery>())
            ]
        }
        #expect(counts == [1, 1])
    }

    @Test
    func appAndMCPDependenciesBuildAndAcceptProductionStores() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let researchStore = KeywordResearchProjectStore(backgroundModelStore: backgroundStore)
        let httpClient = MockHTTPClient { request in
            throw OpenASOError.providerUnavailable(
                "Unexpected request to \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        let resolver = DefaultAppResolver(httpClient: httpClient)
        let appServices = AppServices(
            httpClient: httpClient,
            defaults: UserDefaults(suiteName: "OpenASO-Research-Store-\(UUID().uuidString)") ?? .standard,
            keychain: InMemoryKeychainService(),
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false,
            backgroundModelStore: backgroundStore,
            keywordResearchProjectStore: researchStore,
            providerRequestGateMode: .disabled
        )
        let mcpService = OpenASOMCPService(
            backgroundModelStore: backgroundStore,
            keywordResearchProjectStore: researchStore,
            appResolver: resolver,
            appCatalogService: AppCatalogService(appResolver: resolver),
            httpClient: httpClient
        )

        #expect(appServices.keywordResearchProjectStore === researchStore)
        #expect(appServices.keywordResearchRankingWorkflow != nil)
        let sharedProject = try await researchStore.createProject(name: "Shared MCP reader")
        let mcpReader = try #require(mcpService.keywordResearchProjectStore)
        #expect(try await mcpReader.listProjects(offset: 0, limit: 50) == [sharedProject])

        let autoContainer = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let autoBackgroundStore = BackgroundModelStore(modelContainer: autoContainer)
        let autoAppServices = AppServices(
            httpClient: httpClient,
            defaults: UserDefaults(suiteName: "OpenASO-Research-Store-Auto-\(UUID().uuidString)") ?? .standard,
            keychain: InMemoryKeychainService(),
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false,
            backgroundModelStore: autoBackgroundStore,
            providerRequestGateMode: .disabled
        )
        let autoStore = try #require(autoAppServices.keywordResearchProjectStore)
        #expect(autoAppServices.keywordResearchRankingWorkflow != nil)
        let autoProject = try await autoStore.createProject(name: "Auto-wired app store")
        #expect(try await autoStore.listProjects() == [autoProject])

        let runtimeContainer = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let runtimeContext = ModelContext(runtimeContainer)
        runtimeContext.insert(KeywordResearchProject(name: "Standalone MCP store"))
        try runtimeContext.save()
        let runtimeService = await OpenASOMCPRuntime.makeService(
            modelContainer: runtimeContainer,
            httpClient: httpClient
        )
        let runtimeReader = try #require(runtimeService.keywordResearchProjectStore)
        #expect(try await runtimeReader.listProjects(offset: 0, limit: 50).map(\.name) == [
            "Standalone MCP store"
        ])
    }

    private func makeFixture(
        projectLimit: Int = KeywordResearchProjectStore.maximumProjectCount,
        keywordLimitPerProject: Int = KeywordResearchProjectStore.maximumKeywordCountPerProject
    ) throws -> Fixture {
        let baseDate = baseDate
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        return Fixture(
            container: container,
            backgroundModelStore: backgroundModelStore,
            store: KeywordResearchProjectStore(
                backgroundModelStore: backgroundModelStore,
                now: { baseDate },
                projectLimit: projectLimit,
                keywordLimitPerProject: keywordLimitPerProject
            )
        )
    }
}

@MainActor
private struct Fixture {
    let container: ModelContainer
    let backgroundModelStore: BackgroundModelStore
    let store: KeywordResearchProjectStore
}

private enum ResearchStoreTestError: Error {
    case missingQuery
}
