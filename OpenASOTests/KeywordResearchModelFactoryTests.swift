import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchModelFactoryTests {
    @Test
    func adaptersPersistProjectAndMembershipSnapshots() async throws {
        let modelContainer = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let services = AppServices.mocked(
            httpClient: PreviewHTTPClient(),
            modelContainer: modelContainer
        )
        let factory = try #require(KeywordResearchModelFactory(services: services))
        let projectsModel = factory.makeProjectsModel(pageSize: 2)

        await projectsModel.reload()
        #expect(projectsModel.projects.isEmpty)

        let projectDraft = KeywordResearchProjectDraft(
            name: "  Launch Lab  ",
            bundleID: "  ",
            defaultStorefront: "GB",
            defaultPlatform: .iphone,
            notes: "Before launch"
        )
        let project = try #require(await projectsModel.create(projectDraft))
        #expect(project.id == projectDraft.id)
        #expect(project.name == "Launch Lab")
        #expect(project.bundleID == nil)
        #expect(project.defaultStorefront == "gb")
        #expect(services.backgroundModelStoreRevision == 2)
        #expect(try await factory.loadProject(generation: project.generation) == project)

        let detailModel = factory.makeProjectDetailModel(project: project, pageSize: 2)
        await detailModel.reload()
        let keywordDraft = KeywordResearchKeywordDraft(
            term: "  focus timer  ",
            storefront: "US",
            platform: .ipad,
            notes: "Shared evidence only"
        )
        let keyword = try #require(await detailModel.addKeyword(keywordDraft))
        #expect(keyword.id == keywordDraft.id)
        #expect(keyword.term == "focus timer")
        #expect(keyword.storefront == "us")
        #expect(services.backgroundModelStoreRevision == 3)

        let historyModel = factory.makeHistoryModel(
            projectGeneration: detailModel.project.generation,
            keyword: keyword,
            pageSize: 2
        )
        await historyModel.reload()
        #expect(historyModel.observations.isEmpty)
        #expect(historyModel.loadState == .loaded)
    }
}
