import Foundation

/// Builds UI-facing research models from the app's actor-isolated services.
/// SwiftData models never cross this boundary; every closure returns immutable
/// snapshots owned by the presentation layer.
@MainActor
struct KeywordResearchModelFactory {
    private let projectStore: KeywordResearchProjectStore
    private let rankingWorkflow: KeywordResearchRankingWorkflow
    private let metricsWorkflow: KeywordResearchMetricsWorkflow
    private let historyReader: KeywordResearchHistoryReader
    private let markBackgroundStoreChanged: @MainActor @Sendable () -> Void

    init?(services: AppServices) {
        guard let projectStore = services.keywordResearchProjectStore,
              let rankingWorkflow = services.keywordResearchRankingWorkflow,
              let metricsWorkflow = services.keywordResearchMetricsWorkflow,
              let backgroundModelStore = services.backgroundModelStore
        else { return nil }

        self.init(
            projectStore: projectStore,
            rankingWorkflow: rankingWorkflow,
            metricsWorkflow: metricsWorkflow,
            historyReader: KeywordResearchHistoryReader(
                backgroundModelStore: backgroundModelStore
            ),
            markBackgroundStoreChanged: {
                services.markBackgroundModelStoreChanged()
            }
        )
    }

    init(
        projectStore: KeywordResearchProjectStore,
        rankingWorkflow: KeywordResearchRankingWorkflow,
        metricsWorkflow: KeywordResearchMetricsWorkflow,
        historyReader: KeywordResearchHistoryReader,
        markBackgroundStoreChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.projectStore = projectStore
        self.rankingWorkflow = rankingWorkflow
        self.metricsWorkflow = metricsWorkflow
        self.historyReader = historyReader
        self.markBackgroundStoreChanged = markBackgroundStoreChanged
    }

    func makeProjectsModel(pageSize: Int = 50) -> KeywordResearchProjectsModel {
        let projectStore = projectStore
        let markChanged = markBackgroundStoreChanged
        return KeywordResearchProjectsModel(
            pageSize: pageSize,
            dependencies: KeywordResearchProjectsDependencies(
                loadPage: { offset, limit in
                    let page = try await projectStore.listProjectsPage(
                        offset: offset,
                        limit: limit
                    )
                    return KeywordResearchProjectPresentationPage(
                        projects: page.items,
                        nextOffset: page.nextOffset
                    )
                },
                createProject: { draft in
                    let project = try await projectStore.createProject(
                        id: draft.id,
                        name: draft.name,
                        bundleID: draft.bundleID,
                        defaultStorefront: draft.defaultStorefront,
                        defaultPlatform: draft.defaultPlatform,
                        notes: draft.notes
                    )
                    await markChanged()
                    return project
                },
                updateProject: { revision, draft in
                    let project = try await projectStore.updateProject(
                        revision: revision,
                        name: draft.name,
                        bundleID: draft.bundleID,
                        defaultStorefront: draft.defaultStorefront,
                        defaultPlatform: draft.defaultPlatform,
                        notes: draft.notes
                    )
                    await markChanged()
                    return project
                },
                deleteProject: { revision in
                    try await projectStore.deleteProject(revision: revision)
                    await markChanged()
                }
            )
        )
    }

    func loadProject(
        generation: KeywordResearchProjectGeneration
    ) async throws -> KeywordResearchProjectSnapshot {
        try await projectStore.loadProject(generation: generation)
    }

    func makeProjectDetailModel(
        project: KeywordResearchProjectSnapshot,
        pageSize: Int = 50
    ) -> KeywordResearchProjectDetailModel {
        let projectStore = projectStore
        let rankingWorkflow = rankingWorkflow
        let metricsWorkflow = metricsWorkflow
        let markChanged = markBackgroundStoreChanged
        return KeywordResearchProjectDetailModel(
            project: project,
            pageSize: pageSize,
            dependencies: KeywordResearchProjectDetailDependencies(
                loadKeywordsPage: { generation, offset, limit in
                    let page = try await projectStore.listKeywordsPage(
                        in: generation,
                        offset: offset,
                        limit: limit
                    )
                    return KeywordResearchKeywordPresentationPage(
                        keywords: page.items,
                        nextOffset: page.nextOffset
                    )
                },
                updateProject: { revision, draft in
                    let project = try await projectStore.updateProject(
                        revision: revision,
                        name: draft.name,
                        bundleID: draft.bundleID,
                        defaultStorefront: draft.defaultStorefront,
                        defaultPlatform: draft.defaultPlatform,
                        notes: draft.notes
                    )
                    await markChanged()
                    return project
                },
                addKeyword: { revision, draft in
                    let addition = try await projectStore.addKeyword(
                        id: draft.id,
                        to: revision,
                        term: draft.term,
                        storefront: draft.storefront,
                        platform: draft.platform,
                        notes: draft.notes
                    )
                    await markChanged()
                    return addition
                },
                removeKeyword: { keywordRevision, projectRevision in
                    let project = try await projectStore.removeKeyword(
                        revision: keywordRevision,
                        from: projectRevision
                    )
                    await markChanged()
                    return project
                },
                refreshRanking: { projectGeneration, keywordGeneration in
                    let observation = try await rankingWorkflow.refresh(
                        projectGeneration: projectGeneration,
                        keywordGeneration: keywordGeneration
                    )
                    await markChanged()
                    return observation
                },
                refreshPopularity: { projectGeneration, keywordGeneration, policy in
                    let outcome = try await metricsWorkflow.refresh(
                        projectGeneration: projectGeneration,
                        keywordGeneration: keywordGeneration,
                        policy: policy
                    )
                    await markChanged()
                    return outcome
                }
            )
        )
    }

    func makeHistoryModel(
        projectGeneration: KeywordResearchProjectGeneration,
        keyword: KeywordResearchKeywordSnapshot,
        pageSize: Int = 50
    ) -> KeywordResearchHistoryModel {
        let historyReader = historyReader
        return KeywordResearchHistoryModel(
            projectGeneration: projectGeneration,
            keyword: keyword,
            pageSize: pageSize,
            dependencies: KeywordResearchHistoryDependencies {
                projectGeneration,
                keywordGeneration,
                offset,
                limit in
                try await historyReader.page(
                    projectGeneration: projectGeneration,
                    keywordGeneration: keywordGeneration,
                    offset: offset,
                    limit: limit
                )
            }
        )
    }
}
