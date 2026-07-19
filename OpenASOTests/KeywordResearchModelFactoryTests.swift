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

    @Test
    func projectCopyAdapterPersistsTrackAndMarksBackgroundStoreChanged() async throws {
        let modelContainer = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let services = AppServices.mocked(
            httpClient: PreviewHTTPClient(),
            modelContainer: modelContainer
        )
        let backgroundModelStore = try #require(services.backgroundModelStore)
        let factory = try #require(KeywordResearchModelFactory(services: services))

        let projectsModel = factory.makeProjectsModel()
        await projectsModel.reload()
        let project = try #require(await projectsModel.create(
            KeywordResearchProjectDraft(
                name: "Copy Source",
                bundleID: "com.example.copy-target",
                defaultStorefront: "us",
                defaultPlatform: .iphone,
                notes: ""
            )
        ))

        let detailModel = factory.makeProjectDetailModel(project: project)
        await detailModel.reload()
        let keyword = try #require(await detailModel.addKeyword(
            KeywordResearchKeywordDraft(
                term: "focus timer",
                storefront: "us",
                platform: .iphone,
                notes: "Research note"
            )
        ))

        let targetAppStoreID: Int64 = 8_765_432
        let targetCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await backgroundModelStore.write { modelContext in
            let storeApp = StoreApp(
                appStoreID: targetAppStoreID,
                bundleID: "com.example.copy-target",
                name: "Copy Target",
                subtitle: "Target subtitle",
                sellerName: "Example Seller",
                iconURLString: nil,
                defaultPlatform: .iphone,
                lastMetadataRefreshAt: targetCreatedAt
            )
            let trackedApp = TrackedApp(
                appStoreID: targetAppStoreID,
                storeApp: storeApp,
                createdAt: targetCreatedAt
            )
            modelContext.insert(storeApp)
            modelContext.insert(trackedApp)
        }

        let revisionBeforeCopy = services.backgroundModelStoreRevision
        let copyModel = factory.makeProjectCopyModel(project: detailModel.project)
        await copyModel.reloadTargets()

        let target = try #require(copyModel.targets.first)
        #expect(target.appStoreID == targetAppStoreID)
        copyModel.selectTarget(target.generation)
        await copyModel.reviewSelectedTarget()

        let preview = try #require(copyModel.workflowState.reviewablePreview)
        let expectedIdentityKey = TrackedAppKeyword.makeIdentityKey(
            appStoreID: targetAppStoreID,
            term: keyword.term,
            storefront: keyword.storefront,
            platform: keyword.platform
        )
        #expect(preview.project == detailModel.project)
        #expect(preview.trackIdentityKeys == [expectedIdentityKey])
        #expect(preview.additionCount == 1)
        #expect(services.backgroundModelStoreRevision == revisionBeforeCopy)

        await copyModel.confirmCopy()

        let result = try #require(copyModel.workflowState.result)
        #expect(result.insertedTrackIdentityKeys == [expectedIdentityKey])
        #expect(result.insertedCount == 1)
        #expect(services.backgroundModelStoreRevision == revisionBeforeCopy + 1)

        let persistedIdentityKeys = try await backgroundModelStore.read { modelContext in
            try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
                .map(\.identityKey)
                .sorted()
        }
        #expect(persistedIdentityKeys == [expectedIdentityKey])

        await copyModel.confirmCopy()
        #expect(services.backgroundModelStoreRevision == revisionBeforeCopy + 1)
    }
}
