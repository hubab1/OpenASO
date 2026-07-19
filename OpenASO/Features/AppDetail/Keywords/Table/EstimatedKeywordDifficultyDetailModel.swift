import Observation

@Observable
@MainActor
final class EstimatedKeywordDifficultyDetailModel {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case missing
        case loaded(EstimatedKeywordDifficultySnapshot)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var requestGeneration = 0

    var snapshot: EstimatedKeywordDifficultySnapshot? {
        guard case let .loaded(snapshot) = state else { return nil }
        return snapshot
    }

    var errorMessage: String? {
        guard case let .failed(message) = state else { return nil }
        return message
    }

    func load(
        queryKey: String,
        using dataSource: EstimatedKeywordDifficultyDetailDataSource
    ) async {
        guard !Task.isCancelled else { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        state = .loading

        do {
            let snapshot = try await dataSource.load(queryKey: queryKey)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            if let snapshot {
                state = .loaded(snapshot)
            } else {
                state = .missing
            }
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            state = .idle
        } catch {
            guard generation == requestGeneration else { return }
            guard !Task.isCancelled else {
                state = .idle
                return
            }
            state = .failed(
                "OpenASO couldn’t load the saved estimated-difficulty details. Try again."
            )
        }
    }
}
