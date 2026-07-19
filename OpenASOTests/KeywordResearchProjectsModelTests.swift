import Foundation
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchProjectsModelTests {
    @Test
    func draftsKeepCallerOwnedIDsAndErrorsAreRedacted() {
        let projectID = UUID()
        var projectDraft = KeywordResearchProjectDraft(id: projectID, name: "Launch")
        projectDraft.name = "Launch edited"
        #expect(projectDraft.id == projectID)

        let keywordID = UUID()
        var keywordDraft = KeywordResearchKeywordDraft(id: keywordID, term: "focus")
        keywordDraft.term = "focus timer"
        #expect(keywordDraft.id == keywordID)

        let providerError = KeywordResearchErrorPresentation.presenting(
            OpenASOError.providerUnavailable("session=super-secret")
        )
        #expect(providerError.kind == .providerUnavailable)
        #expect(!providerError.accessibilityLabel.contains("super-secret"))

        let unknownError = KeywordResearchErrorPresentation.presenting(
            SecretTestError(message: "token=also-secret")
        )
        #expect(unknownError.kind == .unexpected)
        #expect(!unknownError.accessibilityLabel.contains("also-secret"))

        let stale = KeywordResearchErrorPresentation.presenting(
            KeywordResearchProjectStoreError.staleProjectRevision(projectID)
        )
        #expect(stale.kind == .conflict)
        #expect(!stale.message.contains(projectID.uuidString))

        for code in KeywordResearchMetricsIssueCode.allPresentationTestCases {
            let issue = KeywordResearchErrorPresentation.presenting(
                KeywordResearchMetricsIssue(code: code, message: "secret provider payload")
            )
            #expect(!issue.accessibilityLabel.contains("secret provider payload"))
        }
    }

    @Test
    func accessibilityDescribesSharedEvidenceWithoutPreLiveRankClaim() {
        let project = makeProject(name: "Launch Research")
        let keyword = makeKeyword(project: project, term: "focus timer")
        let observation = makeObservation(project: project, keyword: keyword)
        let metric = makeMetric(project: project, keyword: keyword, score: 72)

        #expect(project.keywordResearchAccessibilityLabel.contains("Launch Research"))
        #expect(keyword.keywordResearchAccessibilityLabel.contains("focus timer"))
        #expect(observation.keywordResearchAccessibilityLabel.contains("Shared search evidence"))
        #expect(!observation.keywordResearchAccessibilityLabel.lowercased().contains("rank"))
        #expect(metric.keywordResearchAccessibilityLabel.contains("score 72"))
    }

    @Test
    func projectsPagingUsesExactOffsetsDeduplicatesAndPreservesValuesOnFailure() async {
        let loader = ControlledOperation<KeywordResearchProjectPresentationPage>()
        let calls = Recorder<PageCall>()
        let first = makeProject(name: "First", createdAt: testDate)
        let second = makeProject(name: "Second", createdAt: testDate.addingTimeInterval(1))
        let third = makeProject(name: "Third", createdAt: testDate.addingTimeInterval(2))
        let model = KeywordResearchProjectsModel(
            pageSize: 2,
            dependencies: projectsDependencies { offset, limit in
                await calls.record(PageCall(offset: offset, limit: limit))
                return try await loader.call()
            }
        )

        let reload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        let duplicateReload = Task { @MainActor in await model.reload() }
        await duplicateReload.value
        #expect(await loader.callCount == 1)

        await loader.succeed(
            at: 0,
            with: KeywordResearchProjectPresentationPage(
                projects: [first, first, second],
                nextOffset: 17
            )
        )
        await reload.value
        #expect(model.projects.map(\.id) == [first.id, second.id])
        #expect(model.nextOffset == 17)

        let next = Task { @MainActor in await model.loadNextPage() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchProjectPresentationPage(
                projects: [second, third],
                nextOffset: 99
            )
        )
        await next.value
        #expect(model.projects.map(\.id) == [first.id, second.id, third.id])
        #expect(model.nextOffset == 99)

        let failingReload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(3)
        await loader.fail(at: 0, with: OpenASOError.providerUnavailable("private payload"))
        await failingReload.value

        #expect(model.projects.map(\.id) == [first.id, second.id, third.id])
        guard case .failed(let issue) = model.loadState else {
            Issue.record("Expected a failed reload state")
            return
        }
        #expect(issue.kind == .providerUnavailable)
        #expect(!issue.message.contains("private payload"))
        #expect(await calls.values == [
            PageCall(offset: 0, limit: 2),
            PageCall(offset: 17, limit: 2),
            PageCall(offset: 0, limit: 2),
        ])
    }

    @Test
    func projectMutationInvalidatesDelayedLoadAndRequiresRecoveryReload() async {
        let loader = ControlledOperation<KeywordResearchProjectPresentationPage>()
        let createdDrafts = Recorder<KeywordResearchProjectDraft>()
        let updatedRevisions = Recorder<KeywordResearchProjectRevision>()
        let deletedRevisions = Recorder<KeywordResearchProjectRevision>()
        let draft = KeywordResearchProjectDraft(id: UUID(), name: "Created")
        let created = makeProject(id: draft.id, name: draft.name)
        let updated = makeProject(
            id: created.id,
            incarnationID: created.incarnationID,
            name: "Updated",
            createdAt: created.createdAt,
            updatedAt: created.updatedAt.addingTimeInterval(1)
        )
        let existing = makeProject(name: "Existing")
        let model = KeywordResearchProjectsModel(
            dependencies: KeywordResearchProjectsDependencies(
                loadPage: { _, _ in try await loader.call() },
                createProject: { draft in
                    await createdDrafts.record(draft)
                    return created
                },
                updateProject: { revision, _ in
                    await updatedRevisions.record(revision)
                    return updated
                },
                deleteProject: { revision in
                    await deletedRevisions.record(revision)
                    throw KeywordResearchProjectStoreError.staleProjectRevision(
                        revision.generation.id
                    )
                }
            )
        )

        let delayedReload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        #expect(await model.create(draft) == created)
        await loader.succeed(
            at: 0,
            with: KeywordResearchProjectPresentationPage(
                projects: [existing],
                nextOffset: nil
            )
        )
        await delayedReload.value

        #expect(model.projects == [created])
        #expect(model.requiresReload)
        #expect(await createdDrafts.values.map(\.id) == [draft.id])

        let recoveryReload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchProjectPresentationPage(
                projects: [existing, created],
                nextOffset: nil
            )
        )
        await recoveryReload.value
        #expect(Set(model.projects.map(\.id)) == Set([existing.id, created.id]))
        #expect(!model.requiresReload)

        let edit = KeywordResearchProjectDraft(project: created)
        #expect(await model.update(revision: created.revision, with: edit) == updated)
        #expect(Set(model.projects.map(\.id)) == Set([existing.id, updated.id]))
        #expect(await updatedRevisions.values == [created.revision])

        #expect(!(await model.delete(updated)))
        #expect(await deletedRevisions.values == [updated.revision])
        guard case .failed(.deleteProject(let id), let issue) = model.mutationState else {
            Issue.record("Expected one surfaced delete conflict")
            return
        }
        #expect(id == updated.id)
        #expect(issue.kind == .conflict)
    }

    @Test
    func alreadyCancelledMutationsNeverEnterPersistence() async {
        let calls = Recorder<KeywordResearchMutationAction>()
        let project = makeProject()
        let model = KeywordResearchProjectsModel(
            dependencies: KeywordResearchProjectsDependencies(
                loadPage: { _, _ in
                    KeywordResearchProjectPresentationPage(projects: [project], nextOffset: nil)
                },
                createProject: { draft in
                    await calls.record(.createProject(draft.id))
                    return project
                },
                updateProject: { revision, _ in
                    await calls.record(.updateProject(revision.generation.id))
                    return project
                },
                deleteProject: { revision in
                    await calls.record(.deleteProject(revision.generation.id))
                }
            )
        )

        let create = Task { @MainActor in
            await model.create(KeywordResearchProjectDraft())
        }
        create.cancel()
        #expect(await create.value == nil)

        let update = Task { @MainActor in
            await model.update(
                revision: project.revision,
                with: KeywordResearchProjectDraft(project: project)
            )
        }
        update.cancel()
        #expect(await update.value == nil)

        let delete = Task { @MainActor in await model.delete(project) }
        delete.cancel()
        #expect(!(await delete.value))

        #expect(await calls.values.isEmpty)
        #expect(model.mutationState == .idle)
    }

    @Test
    func cancelLoadingAllowsImmediateReplacementLoadAndRejectsOldCompletion() async {
        let loader = ControlledOperation<KeywordResearchProjectPresentationPage>()
        let old = makeProject(name: "Old")
        let fresh = makeProject(name: "Fresh")
        let model = KeywordResearchProjectsModel(
            dependencies: projectsDependencies { _, _ in try await loader.call() }
        )

        let oldLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        model.cancelLoading()
        let freshLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)

        await loader.succeed(
            at: 1,
            with: KeywordResearchProjectPresentationPage(projects: [fresh], nextOffset: nil)
        )
        await freshLoad.value
        await loader.succeed(
            at: 0,
            with: KeywordResearchProjectPresentationPage(projects: [old], nextOffset: nil)
        )
        await oldLoad.value

        #expect(model.projects == [fresh])
        #expect(model.loadState == .loaded)
        #expect(!model.requiresReload)
    }

    @Test
    func deletingLoadedProjectAdjustsOffsetWithoutHidingRemainingPages() async {
        let first = makeProject(name: "First", createdAt: testDate)
        let second = makeProject(name: "Second", createdAt: testDate.addingTimeInterval(1))
        let created = makeProject(name: "Created", createdAt: testDate.addingTimeInterval(2))
        let model = KeywordResearchProjectsModel(
            dependencies: KeywordResearchProjectsDependencies(
                loadPage: { _, _ in
                    KeywordResearchProjectPresentationPage(
                        projects: [first, second],
                        nextOffset: 12
                    )
                },
                createProject: { _ in created },
                updateProject: { _, _ in first },
                deleteProject: { _ in }
            )
        )
        await model.reload()

        #expect(await model.create(KeywordResearchProjectDraft(id: created.id)) == created)
        #expect(model.nextOffset == 12)
        #expect(await model.delete(first))
        #expect(model.projects == [second, created])
        #expect(model.nextOffset == 11)
        #expect(model.hasMoreProjects)
    }
}

private func projectsDependencies(
    loadPage: @escaping @Sendable (
        Int,
        Int
    ) async throws -> KeywordResearchProjectPresentationPage
) -> KeywordResearchProjectsDependencies {
    KeywordResearchProjectsDependencies(
        loadPage: loadPage,
        createProject: { draft in
            makeProject(id: draft.id, name: draft.name)
        },
        updateProject: { revision, draft in
            makeProject(
                id: revision.generation.id,
                incarnationID: revision.generation.incarnationID,
                name: draft.name,
                updatedAt: revision.updatedAt.addingTimeInterval(1)
            )
        },
        deleteProject: { _ in }
    )
}
