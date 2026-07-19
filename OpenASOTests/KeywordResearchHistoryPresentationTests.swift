import Foundation
import Testing
@testable import OpenASO

struct KeywordResearchHistoryPresentationTests {
    @Test
    func historyContextIdentityUsesBothExactGenerations() {
        let project = makeProject()
        let keyword = makeKeyword(project: project)
        let reincarnatedProject = makeProject(id: project.id)
        let reincarnatedKeyword = makeKeyword(id: keyword.id, project: project)

        let original = KeywordResearchHistoryContext(
            projectGeneration: project.generation,
            keyword: keyword
        )
        let changedProject = KeywordResearchHistoryContext(
            projectGeneration: reincarnatedProject.generation,
            keyword: keyword
        )
        let changedKeyword = KeywordResearchHistoryContext(
            projectGeneration: project.generation,
            keyword: reincarnatedKeyword
        )

        #expect(original.id != changedProject.id)
        #expect(original.id != changedKeyword.id)
    }

    @Test
    func selectionUsesOnlyAnExactObservationIdentifier() {
        let project = makeProject()
        let keyword = makeKeyword(project: project)
        let first = makeObservation(project: project, keyword: keyword, id: "first")
        let second = makeObservation(project: project, keyword: keyword, id: "second")

        #expect(KeywordResearchHistorySelection.reconciled(
            nil,
            observations: [first, second]
        ) == first.id)
        #expect(KeywordResearchHistorySelection.reconciled(
            second.id,
            observations: [first, second]
        ) == second.id)
        #expect(KeywordResearchHistorySelection.reconciled(
            "missing",
            observations: [first, second]
        ) == nil)
        #expect(KeywordResearchHistorySelection.reconciled(
            first.id,
            observations: []
        ) == nil)
    }

    @Test
    func presentationSeparatesReportedResultsFromRetainedRows() {
        let project = makeProject()
        let keyword = makeKeyword(project: project, term: "focus timer")
        let observation = KeywordResearchRankingObservationSnapshot(
            id: "observation",
            projectGeneration: project.generation,
            keywordGeneration: keyword.generation,
            queryKey: keyword.queryKey,
            term: keyword.term,
            storefront: keyword.storefront,
            platform: keyword.platform,
            observedAt: testDate,
            observedHour: 12,
            source: .appStoreWeb,
            resultCount: 2,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source",
            items: [
                KeywordResearchRankingItemSnapshot(
                    id: "item",
                    position: 1,
                    appStoreID: 123,
                    bundleID: "com.example.app",
                    name: "Example",
                    subtitle: nil,
                    sellerName: "Seller"
                )
            ]
        )

        let label = KeywordResearchHistoryPresentation.accessibilityLabel(
            for: observation
        )
        #expect(label.contains("focus timer"))
        #expect(label.contains("2 reported results"))
        #expect(label.contains("1 retained result row"))
        #expect(label.contains("App Store Web"))
        #expect(!label.lowercased().contains("rank"))
        #expect(
            KeywordResearchHistoryPresentation.reportedResultsDescription(1)
                == "1 reported result"
        )
        #expect(
            KeywordResearchHistoryPresentation.retainedRowsDescription(0)
                == "0 retained result rows"
        )
        #expect(
            KeywordResearchHistoryPresentation.loadedObservationsDescription(1)
                == "1 shared observation loaded"
        )
    }
}
