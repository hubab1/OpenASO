import Foundation
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchProjectDetailModelTests {
    @Test
    func threadsReturnedRevisionAndSuppressesDuplicateKeywordMutation() async {
        let project = makeProject(name: "Project")
        let existing = makeKeyword(project: project, term: "existing")
        let draft = KeywordResearchKeywordDraft(id: UUID(), term: "new")
        let added = makeKeyword(
            id: draft.id,
            project: project,
            term: draft.term,
            createdAt: testDate.addingTimeInterval(1)
        )
        let projectAfterAdd = makeProject(
            id: project.id,
            incarnationID: project.incarnationID,
            name: project.name,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt.addingTimeInterval(1)
        )
        let projectAfterRemove = makeProject(
            id: project.id,
            incarnationID: project.incarnationID,
            name: project.name,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt.addingTimeInterval(2)
        )
        let addOperation = ControlledOperation<KeywordResearchKeywordAddition>()
        let addCalls = Recorder<KeywordAddCall>()
        let removeCalls = Recorder<KeywordRemoveCall>()
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in
                    KeywordResearchKeywordPresentationPage(
                        keywords: [existing],
                        nextOffset: 8
                    )
                },
                addKeyword: { revision, receivedDraft in
                    await addCalls.record(
                        KeywordAddCall(revision: revision, draft: receivedDraft)
                    )
                    return try await addOperation.call()
                },
                removeKeyword: { keywordRevision, projectRevision in
                    await removeCalls.record(
                        KeywordRemoveCall(
                            keywordRevision: keywordRevision,
                            projectRevision: projectRevision
                        )
                    )
                    return projectAfterRemove
                }
            )
        )
        await model.reload()

        let firstAdd = Task { @MainActor in await model.addKeyword(draft) }
        await addOperation.waitForCallCount(1)
        let duplicateAdd = Task { @MainActor in await model.addKeyword(draft) }
        #expect(await duplicateAdd.value == nil)
        #expect(await addOperation.callCount == 1)

        await addOperation.succeed(
            at: 0,
            with: KeywordResearchKeywordAddition(
                project: projectAfterAdd,
                keyword: added
            )
        )
        #expect(await firstAdd.value == added)
        #expect(model.project.revision == projectAfterAdd.revision)
        #expect(model.keywords.map(\.id) == [existing.id, added.id])
        #expect(model.nextOffset == 8)
        #expect(await addCalls.values.map(\.draft.id) == [draft.id])

        #expect(await model.removeKeyword(added))
        #expect(model.project.revision == projectAfterRemove.revision)
        #expect(model.keywords == [existing])
        #expect(model.nextOffset == 7)
        let recordedRemoveCalls = await removeCalls.values
        #expect(recordedRemoveCalls.first?.projectRevision == projectAfterAdd.revision)
        #expect(recordedRemoveCalls.first?.keywordRevision == added.revision)
    }

    @Test
    func publishesCommittedRefreshesSeparatelyAndKeepsStructuredMetricIssue() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project, term: "focus")
        let rankingOperation = ControlledOperation<KeywordResearchRankingObservationSnapshot>()
        let popularityOperation = ControlledOperation<KeywordResearchMetricsOutcome>()
        let ranking = makeObservation(project: project, keyword: keyword)
        let popularity = makeMetric(
            project: project,
            keyword: keyword,
            score: 51,
            issue: KeywordResearchMetricsIssue(
                code: .rateLimited,
                message: "provider-specific private message"
            )
        )
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in
                    KeywordResearchKeywordPresentationPage(
                        keywords: [keyword],
                        nextOffset: nil
                    )
                },
                refreshRanking: { _, _ in try await rankingOperation.call() },
                refreshPopularity: { _, _, _ in try await popularityOperation.call() }
            )
        )
        await model.reload()

        let rankingTask = Task { @MainActor in await model.refreshRanking(for: keyword) }
        let popularityTask = Task { @MainActor in await model.refreshPopularity(for: keyword) }
        await rankingOperation.waitForCallCount(1)
        await popularityOperation.waitForCallCount(1)

        let duplicateRanking = Task { @MainActor in await model.refreshRanking(for: keyword) }
        let duplicatePopularity = Task { @MainActor in await model.refreshPopularity(for: keyword) }
        await duplicateRanking.value
        await duplicatePopularity.value
        #expect(await rankingOperation.callCount == 1)
        #expect(await popularityOperation.callCount == 1)

        // Cancellation after the dependency has begun does not erase a
        // successful return that represents already-committed evidence.
        rankingTask.cancel()
        popularityTask.cancel()
        await rankingOperation.succeed(at: 0, with: ranking)
        await popularityOperation.succeed(at: 0, with: popularity)
        await rankingTask.value
        await popularityTask.value

        #expect(model.rankingState(for: keyword.id) == .current(ranking))
        #expect(model.popularityState(for: keyword.id) == .current(popularity))
        #expect(model.popularityState(for: keyword.id).value?.issue?.code == .rateLimited)

        let failingRanking = Task { @MainActor in await model.refreshRanking(for: keyword) }
        await rankingOperation.waitForCallCount(2)
        await rankingOperation.fail(at: 0, with: OpenASOError.networkUnavailable)
        await failingRanking.value

        guard case .failed(let previous, let issue) = model.rankingState(for: keyword.id) else {
            Issue.record("Expected a failed ranking refresh")
            return
        }
        #expect(previous == ranking)
        #expect(issue.kind == .networkUnavailable)
    }

    @Test
    func replacementLoadsImmediatelyWhileOldTargetFinishesLate() async {
        let oldProject = makeProject(name: "Old")
        let oldKeyword = makeKeyword(project: oldProject, term: "old")
        let newProject = makeProject(id: oldProject.id, name: "Replacement")
        let newKeyword = makeKeyword(project: newProject, term: "new")
        let loader = ControlledOperation<KeywordResearchKeywordPresentationPage>()
        let model = KeywordResearchProjectDetailModel(
            project: oldProject,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in try await loader.call() }
            )
        )

        let oldLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        model.replaceProject(newProject)
        let newLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)

        await loader.succeed(
            at: 1,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [newKeyword],
                nextOffset: nil
            )
        )
        await newLoad.value
        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [oldKeyword],
                nextOffset: nil
            )
        )
        await oldLoad.value

        #expect(model.project == newProject)
        #expect(model.keywords == [newKeyword])
    }

    @Test
    func mutationDuringInitialLoadRequiresRecoveryBeforeContinuationPaging() async {
        let project = makeProject(name: "Project")
        let existing = makeKeyword(project: project, term: "existing")
        let draft = KeywordResearchKeywordDraft(id: UUID(), term: "added")
        let updatedProject = makeProject(
            id: project.id,
            incarnationID: project.incarnationID,
            name: project.name,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt.addingTimeInterval(1)
        )
        let added = makeKeyword(id: draft.id, project: updatedProject, term: draft.term)
        let loader = ControlledOperation<KeywordResearchKeywordPresentationPage>()
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in try await loader.call() },
                addKeyword: { _, _ in
                    KeywordResearchKeywordAddition(
                        project: updatedProject,
                        keyword: added
                    )
                }
            )
        )

        let initialLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        #expect(await model.addKeyword(draft) == added)
        #expect(model.requiresReload)
        #expect(model.keywords == [added])

        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [existing],
                nextOffset: 20
            )
        )
        await initialLoad.value
        await model.loadNextPage()
        #expect(await loader.callCount == 1)

        let recovery = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [existing, added],
                nextOffset: 2
            )
        )
        await recovery.value

        #expect(Set(model.keywords.map(\.id)) == Set([existing.id, added.id]))
        #expect(model.nextOffset == 2)
        #expect(!model.requiresReload)
    }

    @Test
    func alreadyCancelledMutationsAndRefreshesNeverEnterDependencies() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project, term: "keyword")
        let calls = Recorder<String>()
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: KeywordResearchProjectDetailDependencies(
                loadKeywordsPage: { _, _, _ in
                    KeywordResearchKeywordPresentationPage(
                        keywords: [keyword],
                        nextOffset: nil
                    )
                },
                updateProject: { _, _ in
                    await calls.record("update")
                    return project
                },
                addKeyword: { _, draft in
                    await calls.record("add")
                    return KeywordResearchKeywordAddition(
                        project: project,
                        keyword: makeKeyword(id: draft.id, project: project)
                    )
                },
                removeKeyword: { _, _ in
                    await calls.record("remove")
                    return project
                },
                refreshRanking: { _, _ in
                    await calls.record("ranking")
                    return makeObservation(project: project, keyword: keyword)
                },
                refreshPopularity: { _, _, _ in
                    await calls.record("popularity")
                    return makeMetric(project: project, keyword: keyword, score: 50)
                }
            )
        )
        await model.reload()

        let update = Task { @MainActor in
            await model.updateProject(with: KeywordResearchProjectDraft(project: project))
        }
        update.cancel()
        #expect(await update.value == nil)

        let add = Task { @MainActor in
            await model.addKeyword(KeywordResearchKeywordDraft())
        }
        add.cancel()
        #expect(await add.value == nil)

        let remove = Task { @MainActor in await model.removeKeyword(keyword) }
        remove.cancel()
        #expect(!(await remove.value))

        let ranking = Task { @MainActor in await model.refreshRanking(for: keyword) }
        ranking.cancel()
        await ranking.value

        let popularity = Task { @MainActor in await model.refreshPopularity(for: keyword) }
        popularity.cancel()
        await popularity.value

        #expect(await calls.values.isEmpty)
        #expect(model.mutationState == .idle)
        #expect(model.rankingState(for: keyword.id) == .idle)
        #expect(model.popularityState(for: keyword.id) == .idle)
    }

    @Test
    func addingBeforeInitialLoadRequiresReconciliation() async {
        let project = makeProject(name: "Project")
        let existing = makeKeyword(project: project, term: "existing")
        let draft = KeywordResearchKeywordDraft(id: UUID(), term: "added")
        let updatedProject = makeProject(
            id: project.id,
            incarnationID: project.incarnationID,
            name: project.name,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt.addingTimeInterval(1)
        )
        let added = makeKeyword(id: draft.id, project: updatedProject, term: draft.term)
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in
                    KeywordResearchKeywordPresentationPage(
                        keywords: [existing, added],
                        nextOffset: nil
                    )
                },
                addKeyword: { _, _ in
                    KeywordResearchKeywordAddition(
                        project: updatedProject,
                        keyword: added
                    )
                }
            )
        )

        #expect(await model.addKeyword(draft) == added)
        #expect(model.keywords == [added])
        #expect(model.requiresReload)

        await model.reload()
        #expect(Set(model.keywords.map(\.id)) == Set([existing.id, added.id]))
        #expect(!model.requiresReload)
    }

    @Test
    func reincarnatedKeywordStartsWithFreshRefreshLanes() async {
        let project = makeProject(name: "Project")
        let keywordID = UUID()
        let original = makeKeyword(id: keywordID, project: project, term: "original")
        let replacement = makeKeyword(id: keywordID, project: project, term: "replacement")
        let loader = ControlledOperation<KeywordResearchKeywordPresentationPage>()
        let rankingOperation = ControlledOperation<KeywordResearchRankingObservationSnapshot>()
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in try await loader.call() },
                refreshRanking: { _, _ in try await rankingOperation.call() }
            )
        )

        let originalLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [original],
                nextOffset: nil
            )
        )
        await originalLoad.value

        let oldRefresh = Task { @MainActor in await model.refreshRanking(for: original) }
        await rankingOperation.waitForCallCount(1)
        #expect(model.rankingState(for: original).isRefreshing)

        let replacementLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [replacement],
                nextOffset: nil
            )
        )
        await replacementLoad.value

        #expect(original.generation != replacement.generation)
        #expect(model.rankingState(for: replacement) == .idle)
        await rankingOperation.succeed(
            at: 0,
            with: makeObservation(project: project, keyword: original)
        )
        await oldRefresh.value
        #expect(model.rankingState(for: replacement) == .idle)
    }

    @Test
    func cancelledNonCancellationErrorsRestoreLoadAndRefreshStates() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project, term: "keyword")
        let loader = ControlledOperation<KeywordResearchKeywordPresentationPage>()
        let rankingOperation = ControlledOperation<KeywordResearchRankingObservationSnapshot>()
        let popularityOperation = ControlledOperation<KeywordResearchMetricsOutcome>()
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in try await loader.call() },
                refreshRanking: { _, _ in try await rankingOperation.call() },
                refreshPopularity: { _, _, _ in try await popularityOperation.call() }
            )
        )

        let cancelledLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        cancelledLoad.cancel()
        await loader.fail(at: 0, with: OpenASOError.networkUnavailable)
        await cancelledLoad.value
        #expect(model.loadState == .idle)

        let successfulLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [keyword],
                nextOffset: nil
            )
        )
        await successfulLoad.value

        let ranking = Task { @MainActor in await model.refreshRanking(for: keyword) }
        await rankingOperation.waitForCallCount(1)
        ranking.cancel()
        await rankingOperation.fail(at: 0, with: OpenASOError.networkUnavailable)
        await ranking.value
        #expect(model.rankingState(for: keyword) == .idle)

        let popularity = Task { @MainActor in await model.refreshPopularity(for: keyword) }
        await popularityOperation.waitForCallCount(1)
        popularity.cancel()
        await popularityOperation.fail(at: 0, with: OpenASOError.networkUnavailable)
        await popularity.value
        #expect(model.popularityState(for: keyword) == .idle)
    }

    @Test
    func sameGenerationReplacementEndsObsoleteLoadingState() async {
        let project = makeProject(name: "Project")
        let updated = makeProject(
            id: project.id,
            incarnationID: project.incarnationID,
            name: "Updated",
            createdAt: project.createdAt,
            updatedAt: project.updatedAt.addingTimeInterval(1)
        )
        let loader = ControlledOperation<KeywordResearchKeywordPresentationPage>()
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in try await loader.call() }
            )
        )

        let obsoleteLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        model.replaceProject(updated)

        #expect(model.project == updated)
        #expect(model.requiresReload)
        #expect(model.loadState == .idle)

        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [],
                nextOffset: nil
            )
        )
        await obsoleteLoad.value
        #expect(model.loadState == .idle)
    }

    @Test
    func explicitLoadCancellationHidesInvalidContinuationCursor() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project)
        let loader = ControlledOperation<KeywordResearchKeywordPresentationPage>()
        let model = KeywordResearchProjectDetailModel(
            project: project,
            dependencies: detailDependencies(
                loadKeywordsPage: { _, _, _ in try await loader.call() }
            )
        )

        let initial = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [keyword],
                nextOffset: 8
            )
        )
        await initial.value
        #expect(model.hasMoreKeywords)

        let continuation = Task { @MainActor in await model.loadNextPage() }
        await loader.waitForCallCount(2)
        model.cancelLoading()

        #expect(model.requiresReload)
        #expect(model.nextOffset == 8)
        #expect(!model.hasMoreKeywords)
        #expect(model.loadState == .loaded)

        await loader.succeed(
            at: 0,
            with: KeywordResearchKeywordPresentationPage(
                keywords: [],
                nextOffset: nil
            )
        )
        await continuation.value
        #expect(model.nextOffset == 8)
        #expect(!model.hasMoreKeywords)
    }
}

private struct KeywordAddCall: Equatable, Sendable {
    let revision: KeywordResearchProjectRevision
    let draft: KeywordResearchKeywordDraft
}

private struct KeywordRemoveCall: Equatable, Sendable {
    let keywordRevision: KeywordResearchKeywordRevision
    let projectRevision: KeywordResearchProjectRevision
}

private func detailDependencies(
    loadKeywordsPage: @escaping @Sendable (
        KeywordResearchProjectGeneration,
        Int,
        Int
    ) async throws -> KeywordResearchKeywordPresentationPage,
    addKeyword: @escaping @Sendable (
        KeywordResearchProjectRevision,
        KeywordResearchKeywordDraft
    ) async throws -> KeywordResearchKeywordAddition = { revision, draft in
        let project = makeProject(
            id: revision.generation.id,
            incarnationID: revision.generation.incarnationID,
            updatedAt: revision.updatedAt.addingTimeInterval(1)
        )
        return KeywordResearchKeywordAddition(
            project: project,
            keyword: makeKeyword(id: draft.id, project: project, term: draft.term)
        )
    },
    removeKeyword: @escaping @Sendable (
        KeywordResearchKeywordRevision,
        KeywordResearchProjectRevision
    ) async throws -> KeywordResearchProjectSnapshot = { _, revision in
        makeProject(
            id: revision.generation.id,
            incarnationID: revision.generation.incarnationID,
            updatedAt: revision.updatedAt.addingTimeInterval(1)
        )
    },
    refreshRanking: @escaping @Sendable (
        KeywordResearchProjectGeneration,
        KeywordResearchKeywordGeneration
    ) async throws -> KeywordResearchRankingObservationSnapshot = { project, keyword in
        let projectSnapshot = makeProject(
            id: project.id,
            incarnationID: project.incarnationID
        )
        let keywordSnapshot = makeKeyword(
            id: keyword.id,
            incarnationID: keyword.incarnationID,
            project: projectSnapshot
        )
        return makeObservation(project: projectSnapshot, keyword: keywordSnapshot)
    },
    refreshPopularity: @escaping @Sendable (
        KeywordResearchProjectGeneration,
        KeywordResearchKeywordGeneration,
        KeywordResearchMetricsRefreshPolicy
    ) async throws -> KeywordResearchMetricsOutcome = { project, keyword, _ in
        let projectSnapshot = makeProject(
            id: project.id,
            incarnationID: project.incarnationID
        )
        let keywordSnapshot = makeKeyword(
            id: keyword.id,
            incarnationID: keyword.incarnationID,
            project: projectSnapshot
        )
        return makeMetric(project: projectSnapshot, keyword: keywordSnapshot, score: 50)
    }
) -> KeywordResearchProjectDetailDependencies {
    KeywordResearchProjectDetailDependencies(
        loadKeywordsPage: loadKeywordsPage,
        updateProject: { revision, draft in
            makeProject(
                id: revision.generation.id,
                incarnationID: revision.generation.incarnationID,
                name: draft.name,
                updatedAt: revision.updatedAt.addingTimeInterval(1)
            )
        },
        addKeyword: addKeyword,
        removeKeyword: removeKeyword,
        refreshRanking: refreshRanking,
        refreshPopularity: refreshPopularity
    )
}
