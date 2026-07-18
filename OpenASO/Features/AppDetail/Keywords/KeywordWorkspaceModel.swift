import Observation

@Observable
@MainActor
final class KeywordWorkspaceModel {
    typealias MaterializationOperation = @MainActor () async throws -> [KeywordWorkspaceRow]
    typealias FilterOperation = @MainActor (
        _ rows: [KeywordWorkspaceRow],
        _ filters: KeywordWorkspaceProjection.Filters
    ) async throws -> [KeywordWorkspaceRow]

    private struct Publication {
        let materializedRows: [KeywordWorkspaceRow]
        let rows: [KeywordWorkspaceRow]
        let completedMaterializationID: KeywordWorkspaceProjection.MaterializationID?
        let materializationGeneration: Int
        let appliedFilterID: KeywordWorkspaceProjection.FilterID?

    }

    private var publication = Publication(
        materializedRows: [],
        rows: [],
        completedMaterializationID: nil,
        materializationGeneration: 0,
        appliedFilterID: nil
    )
    @ObservationIgnored private var desiredFilters: KeywordWorkspaceProjection.Filters?
    @ObservationIgnored private var materializationRequestGeneration = 0
    @ObservationIgnored private var pendingMaterializationRequestGeneration: Int?
    @ObservationIgnored private var filterRequestGeneration = 0

    var rows: [KeywordWorkspaceRow] { publication.rows }
    var materializationGeneration: Int { publication.materializationGeneration }

    func isLoading(for materializationID: KeywordWorkspaceProjection.MaterializationID) -> Bool {
        publication.completedMaterializationID != materializationID
    }

    func materialize(
        id: KeywordWorkspaceProjection.MaterializationID,
        initialFilters: KeywordWorkspaceProjection.Filters,
        using operation: MaterializationOperation
    ) async -> String? {
        guard !Task.isCancelled else { return nil }

        materializationRequestGeneration &+= 1
        let requestGeneration = materializationRequestGeneration
        pendingMaterializationRequestGeneration = requestGeneration
        filterRequestGeneration &+= 1
        desiredFilters = initialFilters

        do {
            let materializedRows = try await operation()
            try Task.checkCancellation()
            guard requestGeneration == materializationRequestGeneration else { return nil }

            let filters = desiredFilters ?? initialFilters
            let rows = KeywordWorkspaceProjection.filteredRows(
                materializedRows,
                filters: filters
            )
            try Task.checkCancellation()
            guard requestGeneration == materializationRequestGeneration else { return nil }

            pendingMaterializationRequestGeneration = nil
            publish(
                materializedRows: materializedRows,
                rows: rows,
                completedMaterializationID: id,
                filters: filters
            )
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard requestGeneration == materializationRequestGeneration else { return nil }
            guard !Task.isCancelled else { return nil }

            let filters = desiredFilters ?? initialFilters
            pendingMaterializationRequestGeneration = nil
            publish(
                materializedRows: [],
                rows: [],
                completedMaterializationID: id,
                filters: filters
            )
            return OpenASOError.map(error).localizedDescription
        }
    }

    func updateFilter(
        id: KeywordWorkspaceProjection.FilterID,
        using operation: FilterOperation
    ) async {
        guard !Task.isCancelled else { return }

        desiredFilters = id.filters
        guard pendingMaterializationRequestGeneration == nil else { return }
        guard id.materializationGeneration == publication.materializationGeneration else { return }
        guard id != publication.appliedFilterID else { return }

        filterRequestGeneration &+= 1
        let requestGeneration = filterRequestGeneration
        let materializedRows = publication.materializedRows

        do {
            let rows = try await operation(materializedRows, id.filters)
            try Task.checkCancellation()
            guard requestGeneration == filterRequestGeneration else { return }
            guard id.materializationGeneration == publication.materializationGeneration else { return }

            publication = Publication(
                materializedRows: materializedRows,
                rows: rows,
                completedMaterializationID: publication.completedMaterializationID,
                materializationGeneration: publication.materializationGeneration,
                appliedFilterID: id
            )
        } catch {
            return
        }
    }

    private func publish(
        materializedRows: [KeywordWorkspaceRow],
        rows: [KeywordWorkspaceRow],
        completedMaterializationID: KeywordWorkspaceProjection.MaterializationID,
        filters: KeywordWorkspaceProjection.Filters
    ) {
        let nextGeneration = publication.materializationGeneration &+ 1
        publication = Publication(
            materializedRows: materializedRows,
            rows: rows,
            completedMaterializationID: completedMaterializationID,
            materializationGeneration: nextGeneration,
            appliedFilterID: KeywordWorkspaceProjection.FilterID(
                materializationGeneration: nextGeneration,
                filters: filters
            )
        )
    }
}
