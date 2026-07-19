import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchPersistenceTests {
    @Test
    func duplicateProjectNamesAndDelimiterKeywordsRoundTripByUUIDGeneration() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenASO-Research-V5-RoundTrip-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)

        let firstProjectID = UUID(uuidString: "32000000-0000-4000-8000-000000000001")!
        let secondProjectID = UUID(uuidString: "32000000-0000-4000-8000-000000000002")!
        let firstKeywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000101")!
        let secondKeywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000102")!
        var firstProjectIncarnationID: UUID?
        var secondProjectIncarnationID: UUID?
        var firstKeywordIncarnationID: UUID?
        var secondKeywordIncarnationID: UUID?
        let createdAt = Date(timeIntervalSinceReferenceDate: 805_500_000)
        let updatedAt = createdAt.addingTimeInterval(120)
        let expectedQueryKey = KeywordQuery.makeQueryKey(
            term: "launch::planner",
            storefront: "gb",
            platform: .ipad
        )

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let context = ModelContext(container)
            let firstProject = KeywordResearchProject(
                id: firstProjectID,
                name: "  Launch Research  ",
                bundleID: "  com.example.launch  ",
                defaultStorefront: " GB ",
                defaultPlatform: .ipad,
                notes: "first project",
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            let secondProject = KeywordResearchProject(
                id: secondProjectID,
                name: "Launch Research",
                bundleID: "   ",
                defaultStorefront: "gb",
                defaultPlatform: .ipad,
                createdAt: createdAt.addingTimeInterval(1)
            )
            let firstKeyword = KeywordResearchKeyword(
                id: firstKeywordID,
                term: "  launch::planner  ",
                storefront: " GB ",
                platform: .ipad,
                project: firstProject,
                notes: "primary",
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            let secondKeyword = KeywordResearchKeyword(
                id: secondKeywordID,
                term: "launch::planner",
                storefront: "gb",
                platform: .ipad,
                project: secondProject,
                createdAt: createdAt.addingTimeInterval(1)
            )
            firstProject.attachKeyword(firstKeyword)
            secondProject.attachKeyword(secondKeyword)
            firstProjectIncarnationID = firstProject.incarnationID
            secondProjectIncarnationID = secondProject.incarnationID
            firstKeywordIncarnationID = firstKeyword.incarnationID
            secondKeywordIncarnationID = secondKeyword.incarnationID
            context.insert(firstProject)
            context.insert(secondProject)
            context.insert(firstKeyword)
            context.insert(secondKeyword)
            try context.save()
        }

        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let context = ModelContext(container)
            let projects = try context.fetch(FetchDescriptor<KeywordResearchProject>())
            let keywords = try context.fetch(FetchDescriptor<KeywordResearchKeyword>())
            let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            let keywordsByID = Dictionary(uniqueKeysWithValues: keywords.map { ($0.id, $0) })
            let firstProject = try #require(projectsByID[firstProjectID])
            let secondProject = try #require(projectsByID[secondProjectID])
            let firstKeyword = try #require(keywordsByID[firstKeywordID])
            let firstProjectIncarnationID = try #require(firstProjectIncarnationID)
            let secondProjectIncarnationID = try #require(secondProjectIncarnationID)
            let firstKeywordIncarnationID = try #require(firstKeywordIncarnationID)
            let secondKeywordIncarnationID = try #require(secondKeywordIncarnationID)

            #expect(projects.count == 2)
            #expect(projects.allSatisfy { $0.name == "Launch Research" })
            #expect(Set(projects.map(\.id)) == [firstProjectID, secondProjectID])
            #expect(firstProject.bundleID == "com.example.launch")
            #expect(secondProject.bundleID == nil)
            #expect(firstProject.defaultStorefront == "gb")
            #expect(firstProject.defaultPlatform == .ipad)
            #expect(firstProject.incarnationID == firstProjectIncarnationID)
            #expect(secondProject.incarnationID == secondProjectIncarnationID)
            #expect(firstProject.generation == KeywordResearchProjectGeneration(
                id: firstProjectID,
                incarnationID: firstProjectIncarnationID
            ))

            #expect(keywords.count == 2)
            #expect(keywords.allSatisfy { $0.queryKey == expectedQueryKey })
            #expect(keywords.allSatisfy { $0.term == "launch::planner" })
            #expect(keywords.allSatisfy { $0.storefront == "gb" })
            #expect(keywords.allSatisfy { $0.platform == .ipad })
            #expect(Set(keywords.map(\.projectID)) == [firstProjectID, secondProjectID])
            #expect(Set(keywords.map(\.membershipKey)).count == 2)
            #expect(firstKeyword.membershipKey == KeywordResearchKeyword.makeMembershipKey(
                projectID: firstKeyword.projectID,
                queryKey: expectedQueryKey
            ))
            #expect(firstKeyword.incarnationID == firstKeywordIncarnationID)
            #expect(keywordsByID[secondKeywordID]?.incarnationID == secondKeywordIncarnationID)
            #expect(firstKeyword.generation == KeywordResearchKeywordGeneration(
                id: firstKeywordID,
                incarnationID: firstKeywordIncarnationID
            ))
            #expect(firstKeyword.project.id == firstProjectID)
            #expect(firstProject.keywords.map(\.id) == [firstKeywordID])

            #expect(try context.fetch(FetchDescriptor<TrackedApp>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<StoreApp>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<KeywordQuery>()).isEmpty)
        }
    }

    @Test
    func deleteAndRecreateAtSameIDAndTimestampRotatesGenerationIncarnations() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let projectID = UUID(uuidString: "32000000-0000-4000-8000-000000000030")!
        let keywordID = UUID(uuidString: "32000000-0000-4000-8000-000000000130")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 805_650_000)

        let originalProject = KeywordResearchProject(
            id: projectID,
            name: "Original",
            createdAt: createdAt
        )
        let originalKeyword = KeywordResearchKeyword(
            id: keywordID,
            term: "same public identity",
            storefront: "us",
            platform: .iphone,
            project: originalProject,
            createdAt: createdAt
        )
        originalProject.attachKeyword(originalKeyword)
        context.insert(originalProject)
        context.insert(originalKeyword)
        try context.save()

        let staleProjectGeneration = originalProject.generation
        let staleKeywordGeneration = originalKeyword.generation
        context.delete(originalProject)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<KeywordResearchProject>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<KeywordResearchKeyword>()).isEmpty)

        let replacementProject = KeywordResearchProject(
            id: projectID,
            name: "Replacement",
            createdAt: createdAt
        )
        let replacementKeyword = KeywordResearchKeyword(
            id: keywordID,
            term: "same public identity",
            storefront: "us",
            platform: .iphone,
            project: replacementProject,
            createdAt: createdAt
        )
        replacementProject.attachKeyword(replacementKeyword)
        context.insert(replacementProject)
        context.insert(replacementKeyword)
        try context.save()

        #expect(replacementProject.id == staleProjectGeneration.id)
        #expect(replacementProject.incarnationID != staleProjectGeneration.incarnationID)
        #expect(replacementProject.generation != staleProjectGeneration)
        #expect(replacementKeyword.id == staleKeywordGeneration.id)
        #expect(replacementKeyword.incarnationID != staleKeywordGeneration.incarnationID)
        #expect(replacementKeyword.generation != staleKeywordGeneration)
        #expect(replacementProject.createdAt == createdAt)
        #expect(replacementKeyword.createdAt == createdAt)
    }

    @Test
    func deletingProjectCascadesMembershipButPreservesSharedQueryData() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let project = KeywordResearchProject(
            id: UUID(uuidString: "32000000-0000-4000-8000-000000000010")!,
            name: "Project",
            defaultStorefront: "us",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(
            term: "shared keyword",
            storefront: "us",
            platform: .iphone
        )
        let metrics = KeywordDailyMetric(
            queryKey: query.queryKey,
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            popularityScore: 55,
            difficultyScore: nil,
            source: .appleAdsPopularity
        )
        let observedAt = Date(timeIntervalSinceReferenceDate: 805_700_000)
        let crawl = KeywordRankingCrawl(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: observedAt,
            source: .appStoreWeb,
            resultCount: 1,
            query: query
        )
        let crawlItem = KeywordAppRanking(
            position: 1,
            appStoreID: 320_000_001,
            bundleID: "com.example.shared",
            name: "Shared Result",
            sellerName: "Example",
            observation: crawl
        )
        let calculationID = UUID(uuidString: "32000000-0000-4000-8000-000000000210")!
        let difficulty = EstimatedKeywordDifficultyMetric(
            queryKey: query.queryKey,
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
            rankingFetchedAt: observedAt,
            computedAt: observedAt.addingTimeInterval(1),
            fallbackProviderRaw: nil,
            fallbackCategoryRaw: nil,
            fallbackTransportCode: nil,
            fallbackHTTPStatus: nil,
            fallbackResponseFailureRaw: nil,
            notes: ["Shared query evidence"]
        )
        let evidence = EstimatedKeywordDifficultyResultEvidenceRecord(
            queryKey: query.queryKey,
            calculationID: calculationID,
            position: 1,
            appStoreID: crawlItem.appStoreID,
            title: crawlItem.name,
            subtitle: crawlItem.subtitle,
            ratingCount: 1_000,
            ratingAuthorityScore: 70,
            titleTokenCoveragePercentage: 100,
            combinedTokenCoveragePercentage: 100,
            metadataMatchScore: 85,
            exactTitlePhraseMatch: true,
            exactSubtitlePhraseMatch: false
        )
        let keyword = KeywordResearchKeyword(
            id: UUID(uuidString: "32000000-0000-4000-8000-000000000110")!,
            term: query.term,
            storefront: query.storefront,
            platform: query.platform,
            project: project
        )
        project.attachKeyword(keyword)
        query.observations.append(crawl)
        crawl.items.append(crawlItem)
        context.insert(query)
        context.insert(metrics)
        context.insert(crawl)
        context.insert(crawlItem)
        context.insert(difficulty)
        context.insert(evidence)
        context.insert(project)
        context.insert(keyword)
        try context.save()

        context.delete(project)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<KeywordResearchProject>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<KeywordResearchKeyword>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<KeywordQuery>()).map(\.queryKey) == [query.queryKey])
        #expect(try context.fetch(FetchDescriptor<KeywordDailyMetric>()).map(\.queryKey) == [query.queryKey])
        #expect(try context.fetch(FetchDescriptor<KeywordRankingCrawl>()).map(\.queryKey) == [query.queryKey])
        #expect(try context.fetch(FetchDescriptor<KeywordAppRanking>()).map(\.queryKey) == [query.queryKey])
        #expect(try context.fetch(FetchDescriptor<EstimatedKeywordDifficultyMetric>()).map(\.queryKey) == [query.queryKey])
        #expect(try context.fetch(
            FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>()
        ).map(\.queryKey) == [query.queryKey])
    }

    @Test
    func creationTimestampsClampUpdatedGenerationAndMembershipKeyNeverParsesQuery() {
        let projectID = UUID(uuidString: "32000000-0000-4000-8000-000000000020")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 805_600_000)
        let project = KeywordResearchProject(
            id: projectID,
            name: "  Project  ",
            bundleID: " \n ",
            defaultStorefront: " US ",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(-1)
        )
        let keyword = KeywordResearchKeyword(
            term: "one::two::three",
            storefront: " US ",
            platform: .mac,
            project: project,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(-1)
        )

        #expect(project.name == "Project")
        #expect(project.bundleID == nil)
        #expect(project.defaultStorefront == "us")
        #expect(project.updatedAt == createdAt)
        #expect(keyword.updatedAt == createdAt)
        #expect(keyword.queryKey == "one::two::three::us::mac")
        #expect(keyword.membershipKey == projectID.uuidString.lowercased() + "::" + keyword.queryKey)
    }

    @Test
    func attachingCanonicalMembershipIsIdempotent() {
        let project = KeywordResearchProject(name: "Project")
        let keyword = KeywordResearchKeyword(
            term: "immutable scope",
            storefront: "us",
            platform: .iphone,
            project: project
        )
        project.attachKeyword(keyword)
        project.attachKeyword(keyword)

        #expect(project.keywords.map(\.id) == [keyword.id])
    }
}
