import Foundation
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchHistoryModelTests {
    @Test
    func pagesSharedEvidenceAndPreservesItAcrossFailedReload() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project, term: "focus")
        let first = makeObservation(project: project, keyword: keyword, id: "first")
        let second = makeObservation(
            project: project,
            keyword: keyword,
            id: "second",
            observedAt: testDate.addingTimeInterval(-1)
        )
        let third = makeObservation(
            project: project,
            keyword: keyword,
            id: "third",
            observedAt: testDate.addingTimeInterval(-2)
        )
        let loader = ControlledOperation<KeywordResearchRankingHistoryPage>()
        let calls = Recorder<PageCall>()
        let model = KeywordResearchHistoryModel(
            projectGeneration: project.generation,
            keyword: keyword,
            pageSize: 2,
            dependencies: KeywordResearchHistoryDependencies { _, _, offset, limit in
                await calls.record(PageCall(offset: offset, limit: limit))
                return try await loader.call()
            }
        )

        let reload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [first, first, second],
                nextOffset: 14
            )
        )
        await reload.value
        #expect(model.observations.map(\.id) == [first.id, second.id])
        #expect(model.nextOffset == 14)

        let next = Task { @MainActor in await model.loadNextPage() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [second, third],
                nextOffset: 41
            )
        )
        await next.value
        #expect(model.observations.map(\.id) == [first.id, second.id, third.id])
        #expect(model.nextOffset == 41)

        let newest = makeObservation(
            project: project,
            keyword: keyword,
            id: "newest",
            observedAt: testDate.addingTimeInterval(1)
        )
        model.record(newest)
        #expect(model.observations.map(\.id) == [newest.id, first.id, second.id, third.id])
        #expect(model.nextOffset == 41)
        #expect(model.requiresReload)
        #expect(!model.hasMoreObservations)

        await model.loadNextPage()
        #expect(await calls.values.count == 2)
        #expect(model.accessibilitySummary.contains("shared search observations"))
        #expect(!model.accessibilitySummary.lowercased().contains("rank"))

        let failure = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(3)
        await loader.fail(at: 0, with: OpenASOError.unexpectedResponse)
        await failure.value
        #expect(model.observations.map(\.id) == [newest.id, first.id, second.id, third.id])
        #expect(model.requiresReload)
        #expect(await calls.values == [
            PageCall(offset: 0, limit: 2),
            PageCall(offset: 14, limit: 2),
            PageCall(offset: 0, limit: 2),
        ])
    }

    @Test
    func replacementRejectsLateOldMembershipPage() async {
        let oldProject = makeProject(name: "Old")
        let oldKeyword = makeKeyword(project: oldProject, term: "old")
        let newProject = makeProject(id: oldProject.id, name: "Replacement")
        let newKeyword = makeKeyword(id: oldKeyword.id, project: newProject, term: "new")
        let oldObservation = makeObservation(project: oldProject, keyword: oldKeyword)
        let freshObservation = makeObservation(project: newProject, keyword: newKeyword)
        let loader = ControlledOperation<KeywordResearchRankingHistoryPage>()
        let model = KeywordResearchHistoryModel(
            projectGeneration: oldProject.generation,
            keyword: oldKeyword,
            dependencies: KeywordResearchHistoryDependencies { _, _, _, _ in
                try await loader.call()
            }
        )

        let oldLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        model.replaceMembership(
            projectGeneration: newProject.generation,
            keyword: newKeyword
        )
        let newLoad = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)

        await loader.succeed(
            at: 1,
            with: KeywordResearchRankingHistoryPage(
                observations: [freshObservation],
                nextOffset: nil
            )
        )
        await newLoad.value
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [oldObservation],
                nextOffset: nil
            )
        )
        await oldLoad.value

        #expect(model.keyword == newKeyword)
        #expect(model.observations == [freshObservation])
    }

    @Test
    func canceledDependencyErrorsRestoreBothLoadStates() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project)
        let observation = makeObservation(project: project, keyword: keyword)
        let loader = ControlledOperation<KeywordResearchRankingHistoryPage>()
        let model = KeywordResearchHistoryModel(
            projectGeneration: project.generation,
            keyword: keyword,
            dependencies: KeywordResearchHistoryDependencies { _, _, _, _ in
                try await loader.call()
            }
        )

        let initial = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [observation],
                nextOffset: 1
            )
        )
        await initial.value

        let next = Task { @MainActor in await model.loadNextPage() }
        await loader.waitForCallCount(2)
        next.cancel()
        await loader.fail(at: 0, with: SecretTestError(message: "private next error"))
        await next.value
        #expect(model.loadState == .loaded)

        let reload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(3)
        reload.cancel()
        await loader.fail(at: 0, with: SecretTestError(message: "private reload error"))
        await reload.value
        #expect(model.loadState == .loaded)
        #expect(model.observations == [observation])
    }

    @Test
    func recordInvalidatesLateLoadAndRestoresStableOrdering() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project)
        let middle = makeObservation(
            project: project,
            keyword: keyword,
            id: "middle",
            observedAt: testDate.addingTimeInterval(-1)
        )
        let oldest = makeObservation(
            project: project,
            keyword: keyword,
            id: "oldest",
            observedAt: testDate.addingTimeInterval(-2)
        )
        let loader = ControlledOperation<KeywordResearchRankingHistoryPage>()
        let model = KeywordResearchHistoryModel(
            projectGeneration: project.generation,
            keyword: keyword,
            dependencies: KeywordResearchHistoryDependencies { _, _, _, _ in
                try await loader.call()
            }
        )

        let initial = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [middle, oldest],
                nextOffset: nil
            )
        )
        await initial.value

        let staleReload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(2)
        let refreshedOldest = makeObservation(
            project: project,
            keyword: keyword,
            id: oldest.id,
            observedAt: testDate.addingTimeInterval(1)
        )
        model.record(refreshedOldest)
        #expect(model.observations.map(\.id) == [oldest.id, middle.id])
        #expect(model.requiresReload)
        #expect(model.loadState == .loaded)

        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [middle],
                nextOffset: nil
            )
        )
        await staleReload.value
        #expect(model.observations == [refreshedOldest, middle])
        #expect(model.requiresReload)
    }

    @Test
    func recordBeforeInitialPageRequiresAuthoritativeReload() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project)
        let observation = makeObservation(project: project, keyword: keyword)
        let model = KeywordResearchHistoryModel(
            projectGeneration: project.generation,
            keyword: keyword,
            dependencies: KeywordResearchHistoryDependencies { _, _, _, _ in
                KeywordResearchRankingHistoryPage(observations: [], nextOffset: nil)
            }
        )

        model.record(observation)

        #expect(model.observations == [observation])
        #expect(model.requiresReload)
        #expect(!model.hasMoreObservations)
        #expect(model.loadState == .loaded)
    }
}
