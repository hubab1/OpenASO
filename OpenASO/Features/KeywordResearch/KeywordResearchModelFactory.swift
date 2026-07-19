import Foundation

/// Builds UI-facing research models from the app's actor-isolated services.
/// SwiftData models never cross this boundary; every closure returns immutable
/// snapshots owned by the presentation layer.
@MainActor
struct KeywordResearchModelFactory {
    private let projectStore: KeywordResearchProjectStore
    private let projectCopyService: KeywordResearchProjectCopyService
    private let rankingWorkflow: KeywordResearchRankingWorkflow
    private let metricsWorkflow: KeywordResearchMetricsWorkflow
    private let historyReader: KeywordResearchHistoryReader
    private let refreshCopiedKeywords: @MainActor @Sendable (
        KeywordResearchPostCopyRefreshPlan
    ) async throws -> KeywordResearchPostCopyRefreshSummary
    private let markBackgroundStoreChanged: @MainActor @Sendable () -> Void

    init?(services: AppServices) {
        guard let projectStore = services.keywordResearchProjectStore,
              let projectCopyService = services.keywordResearchProjectCopyService,
              let rankingWorkflow = services.keywordResearchRankingWorkflow,
              let metricsWorkflow = services.keywordResearchMetricsWorkflow,
              let backgroundModelStore = services.backgroundModelStore
        else { return nil }

        self.init(
            projectStore: projectStore,
            projectCopyService: projectCopyService,
            rankingWorkflow: rankingWorkflow,
            metricsWorkflow: metricsWorkflow,
            historyReader: KeywordResearchHistoryReader(
                backgroundModelStore: backgroundModelStore
            ),
            refreshCopiedKeywords: { plan in
                guard let refreshService = services.appDetailRefreshService else {
                    throw OpenASOError.providerUnavailable(
                        "Tracked keyword refresh is unavailable."
                    )
                }
                let request = AppDetailRefreshRequest(
                    app: AppDetailRefreshAppSnapshot(
                        appStoreID: plan.target.appStoreID,
                        bundleID: plan.target.bundleID,
                        name: plan.target.name,
                        subtitle: plan.target.subtitle,
                        sellerName: plan.target.sellerName,
                        defaultPlatform: plan.target.defaultPlatform
                    ),
                    workspace: .keywords,
                    storefrontSelection: .all(codes: plan.storefronts),
                    trackIdentityKeys: plan.trackIdentityKeys,
                    trigger: "after_research_project_copy",
                    refreshRatings: false,
                    refreshReviews: false,
                    recordsRatingsReviewsRefresh: false,
                    popularityContextAppStoreID: services.settingsStore.popularityContextAppStoreID,
                    appleAdsWebSession: services.appleAdsWebSessionStore.session,
                    appStoreConnectCredentials: services.appStoreConnectCredentialStore.credentials
                )
                let result = await refreshService.refresh(request)
                services.markBackgroundModelStoreChanged()
                return KeywordResearchPostCopyRefreshSummary(
                    requestedTrackCount: plan.trackIdentityKeys.count,
                    completedTrackCount: result.keywordOutcomes.count,
                    failedTrackCount: result.keywordOutcomes.filter {
                        $0.error != nil
                    }.count,
                    issue: result.firstError.map {
                        KeywordResearchErrorPresentation.presenting($0)
                    }
                )
            },
            markBackgroundStoreChanged: {
                services.markBackgroundModelStoreChanged()
            }
        )
    }

    init(
        projectStore: KeywordResearchProjectStore,
        projectCopyService: KeywordResearchProjectCopyService,
        rankingWorkflow: KeywordResearchRankingWorkflow,
        metricsWorkflow: KeywordResearchMetricsWorkflow,
        historyReader: KeywordResearchHistoryReader,
        refreshCopiedKeywords: @escaping @MainActor @Sendable (
            KeywordResearchPostCopyRefreshPlan
        ) async throws -> KeywordResearchPostCopyRefreshSummary,
        markBackgroundStoreChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.projectStore = projectStore
        self.projectCopyService = projectCopyService
        self.rankingWorkflow = rankingWorkflow
        self.metricsWorkflow = metricsWorkflow
        self.historyReader = historyReader
        self.refreshCopiedKeywords = refreshCopiedKeywords
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

    func makeProjectCopyModel(
        project: KeywordResearchProjectSnapshot,
        pageSize: Int = 50
    ) -> KeywordResearchProjectCopyModel {
        let projectStore = projectStore
        let projectCopyService = projectCopyService
        let refreshCopiedKeywords = refreshCopiedKeywords
        let markChanged = markBackgroundStoreChanged
        return KeywordResearchProjectCopyModel(
            project: project,
            pageSize: pageSize,
            dependencies: KeywordResearchProjectCopyDependencies(
                loadTargetsPage: { offset, limit in
                    try await projectCopyService.listTargets(
                        offset: offset,
                        limit: limit
                    )
                },
                loadAuthoritativeProject: { generation in
                    try await projectStore.loadProject(generation: generation)
                },
                preview: { revision, targetAppStoreID in
                    try await projectCopyService.preview(
                        projectRevision: revision,
                        targetAppStoreID: targetAppStoreID
                    )
                },
                copy: { preview in
                    let result = try await projectCopyService.copy(preview: preview)
                    if result.insertedCount > 0 || result.convergedCompletedCopy {
                        await markChanged()
                    }
                    return result
                },
                refreshCopiedKeywords: { plan in
                    try await refreshCopiedKeywords(plan)
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
                cursor,
                limit in
                try await historyReader.page(
                    projectGeneration: projectGeneration,
                    keywordGeneration: keywordGeneration,
                    after: cursor,
                    limit: limit
                )
            }
        )
    }
}
