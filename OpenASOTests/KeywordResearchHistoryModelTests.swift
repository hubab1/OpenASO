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
        let firstCursor = historyCursor(second)
        let finalCursor = historyCursor(third)
        let calls = Recorder<HistoryPageCall>()
        let model = KeywordResearchHistoryModel(
            projectGeneration: project.generation,
            keyword: keyword,
            pageSize: 2,
            dependencies: KeywordResearchHistoryDependencies { _, _, cursor, limit in
                await calls.record(HistoryPageCall(cursor: cursor, limit: limit))
                return try await loader.call()
            }
        )

        let reload = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [first, first, second],
                nextCursor: firstCursor
            )
        )
        await reload.value
        #expect(model.observations.map(\.id) == [first.id, second.id])
        #expect(model.nextCursor == firstCursor)

        let next = Task { @MainActor in await model.loadNextPage() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [second, third],
                nextCursor: finalCursor
            )
        )
        await next.value
        #expect(model.observations.map(\.id) == [first.id, second.id, third.id])
        #expect(model.nextCursor == finalCursor)

        let newest = makeObservation(
            project: project,
            keyword: keyword,
            id: "newest",
            observedAt: testDate.addingTimeInterval(1)
        )
        model.record(newest)
        #expect(model.observations.map(\.id) == [newest.id, first.id, second.id, third.id])
        #expect(model.nextCursor == finalCursor)
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
        #expect(model.failedOperation == .reload)
        #expect(await calls.values == [
            HistoryPageCall(cursor: nil, limit: 2),
            HistoryPageCall(cursor: firstCursor, limit: 2),
            HistoryPageCall(cursor: nil, limit: 2),
        ])
    }

    @Test
    func retriesFailedContinuationWithoutDiscardingLoadedPages() async {
        let project = makeProject(name: "Project")
        let keyword = makeKeyword(project: project)
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
        let firstCursor = historyCursor(first)
        let secondCursor = historyCursor(second)
        let loader = ControlledOperation<KeywordResearchRankingHistoryPage>()
        let calls = Recorder<HistoryPageCall>()
        let model = KeywordResearchHistoryModel(
            projectGeneration: project.generation,
            keyword: keyword,
            pageSize: 1,
            dependencies: KeywordResearchHistoryDependencies { _, _, cursor, limit in
                await calls.record(HistoryPageCall(cursor: cursor, limit: limit))
                return try await loader.call()
            }
        )

        let initial = Task { @MainActor in await model.reload() }
        await loader.waitForCallCount(1)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [first],
                nextCursor: firstCursor
            )
        )
        await initial.value

        let secondPage = Task { @MainActor in await model.loadNextPage() }
        await loader.waitForCallCount(2)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [second],
                nextCursor: secondCursor
            )
        )
        await secondPage.value

        let failedPage = Task { @MainActor in await model.loadNextPage() }
        await loader.waitForCallCount(3)
        await loader.fail(at: 0, with: OpenASOError.networkUnavailable)
        await failedPage.value
        #expect(model.failedOperation == .nextPage)
        #expect(model.observations == [first, second])
        #expect(model.nextCursor == secondCursor)

        let retry = Task { @MainActor in await model.retryFailedLoad() }
        await loader.waitForCallCount(4)
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [third],
                nextCursor: nil
            )
        )
        await retry.value

        #expect(model.observations == [first, second, third])
        #expect(model.failedOperation == nil)
        #expect(await calls.values == [
            HistoryPageCall(cursor: nil, limit: 1),
            HistoryPageCall(cursor: firstCursor, limit: 1),
            HistoryPageCall(cursor: secondCursor, limit: 1),
            HistoryPageCall(cursor: secondCursor, limit: 1),
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
                nextCursor: nil
            )
        )
        await newLoad.value
        await loader.succeed(
            at: 0,
            with: KeywordResearchRankingHistoryPage(
                observations: [oldObservation],
                nextCursor: nil
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
                nextCursor: historyCursor(observation)
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
                nextCursor: nil
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
                nextCursor: nil
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
                KeywordResearchRankingHistoryPage(observations: [], nextCursor: nil)
            }
        )

        model.record(observation)

        #expect(model.observations == [observation])
        #expect(model.requiresReload)
        #expect(!model.hasMoreObservations)
        #expect(model.loadState == .loaded)
    }
}

private struct HistoryPageCall: Equatable, Sendable {
    let cursor: KeywordResearchRankingHistoryCursor?
    let limit: Int
}

private func historyCursor(
    _ observation: KeywordResearchRankingObservationSnapshot
) -> KeywordResearchRankingHistoryCursor {
    KeywordResearchRankingHistoryCursor(
        dayBucket: RankingCrawlRecord.utcDayBucket(
            for: observation.observedAt
        ),
        consumedSourceIDs: [observation.source.rawValue]
    )
}
