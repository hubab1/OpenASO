import Testing
@testable import OpenASO

struct KeywordResearchWorkspaceSelectionTests {
    @Test
    func selectsFirstProjectOnlyWhenThereIsNoExistingSelection() {
        let first = makeProject(name: "First")
        let second = makeProject(name: "Second")

        #expect(KeywordResearchWorkspaceSelection.reconciled(
            nil,
            projects: [first, second]
        ) == first.generation)
    }

    @Test
    func preservesOnlyTheExactSelectedGeneration() {
        let selected = makeProject(name: "Selected")
        let updated = makeProject(
            id: selected.id,
            incarnationID: selected.incarnationID,
            name: "Updated",
            createdAt: selected.createdAt,
            updatedAt: selected.updatedAt.addingTimeInterval(1)
        )
        let reincarnated = makeProject(id: selected.id, name: "Reincarnated")

        #expect(KeywordResearchWorkspaceSelection.reconciled(
            selected.generation,
            projects: [updated]
        ) == selected.generation)
        #expect(KeywordResearchWorkspaceSelection.reconciled(
            selected.generation,
            projects: [reincarnated]
        ) == nil)
        #expect(KeywordResearchWorkspaceSelection.reconciled(
            selected.generation,
            projects: []
        ) == nil)
    }
}
