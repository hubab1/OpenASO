import Testing
@testable import OpenASO

struct KeywordResearchKeywordSelectionTests {
    @Test
    func selectsFirstKeywordOnlyWithoutAnExistingSelection() {
        let project = makeProject()
        let first = makeKeyword(project: project, term: "first")
        let second = makeKeyword(project: project, term: "second")

        #expect(KeywordResearchKeywordSelection.reconciled(
            nil,
            keywords: [first, second]
        ) == first.generation)
    }

    @Test
    func preservesOnlyTheExactKeywordGeneration() {
        let project = makeProject()
        let selected = makeKeyword(project: project, term: "selected")
        let reincarnated = makeKeyword(
            id: selected.id,
            project: project,
            term: "replacement"
        )

        #expect(KeywordResearchKeywordSelection.reconciled(
            selected.generation,
            keywords: [selected]
        ) == selected.generation)
        #expect(KeywordResearchKeywordSelection.reconciled(
            selected.generation,
            keywords: [reincarnated]
        ) == nil)
        #expect(KeywordResearchKeywordSelection.reconciled(
            selected.generation,
            keywords: []
        ) == nil)
    }

    @Test
    func recognizesOnlyAVisiblePublishedAddition() {
        let project = makeProject()
        let added = makeKeyword(project: project, term: "added")

        #expect(KeywordResearchKeywordMutationPublication.additionWasPublished(
            state: .succeeded(.addKeyword(added.id)),
            draftID: added.id,
            keyword: added,
            keywords: [added]
        ))
        #expect(!KeywordResearchKeywordMutationPublication.additionWasPublished(
            state: .idle,
            draftID: added.id,
            keyword: added,
            keywords: [added]
        ))
        #expect(!KeywordResearchKeywordMutationPublication.additionWasPublished(
            state: .succeeded(.addKeyword(added.id)),
            draftID: added.id,
            keyword: added,
            keywords: []
        ))
    }

    @Test
    func recognizesOnlyAnAbsentPublishedRemoval() {
        let project = makeProject()
        let removed = makeKeyword(project: project, term: "removed")

        #expect(KeywordResearchKeywordMutationPublication.removalWasPublished(
            state: .succeeded(.removeKeyword(removed.id)),
            keyword: removed,
            keywords: []
        ))
        #expect(!KeywordResearchKeywordMutationPublication.removalWasPublished(
            state: .idle,
            keyword: removed,
            keywords: []
        ))
        #expect(!KeywordResearchKeywordMutationPublication.removalWasPublished(
            state: .succeeded(.removeKeyword(removed.id)),
            keyword: removed,
            keywords: [removed]
        ))
    }

    @Test @MainActor
    func cachesDetailModelsByExactProjectGeneration() {
        let original = makeProject(name: "Original")
        let updated = makeProject(
            id: original.id,
            incarnationID: original.incarnationID,
            name: "Updated",
            createdAt: original.createdAt,
            updatedAt: original.updatedAt.addingTimeInterval(1)
        )
        let reincarnated = makeProject(id: original.id, name: "Reincarnated")
        let cache = KeywordResearchProjectDetailModelCache()
        let first = cache.model(for: original) {
            makeDetailModel(project: original)
        }
        let retained = cache.model(for: updated) {
            makeDetailModel(project: updated)
        }
        cache.reconcile(with: [updated])
        let replacement = cache.model(for: reincarnated) {
            makeDetailModel(project: reincarnated)
        }

        #expect(first === retained)
        #expect(first.project == updated)
        #expect(first !== replacement)
    }
}

@MainActor
private func makeDetailModel(
    project: KeywordResearchProjectSnapshot
) -> KeywordResearchProjectDetailModel {
    KeywordResearchProjectDetailModel(
        project: project,
        dependencies: KeywordResearchProjectDetailDependencies(
            loadKeywordsPage: { _, _, _ in
                KeywordResearchKeywordPresentationPage(
                    keywords: [],
                    nextOffset: nil
                )
            },
            updateProject: { _, _ in project },
            addKeyword: { _, draft in
                KeywordResearchKeywordAddition(
                    project: project,
                    keyword: makeKeyword(
                        id: draft.id,
                        project: project,
                        term: draft.term
                    )
                )
            },
            removeKeyword: { _, _ in project },
            refreshRanking: { _, _ in
                throw OpenASOError.unexpectedResponse
            },
            refreshPopularity: { _, _, _ in
                throw OpenASOError.unexpectedResponse
            }
        )
    )
}
