import Observation

@Observable
@MainActor
final class KeywordRankingListModel {
    enum State: Sendable {
        case idle
        case loading(previous: KeywordRankingListLoader.Snapshot?)
        case loaded(KeywordRankingListLoader.Snapshot)
        case failed(message: String, previous: KeywordRankingListLoader.Snapshot?)
    }

    struct RequestID: Hashable, Sendable {
        let loadID: KeywordRankingListLoader.LoadID
        let retryToken: Int
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var requestGeneration = 0

    var snapshot: KeywordRankingListLoader.Snapshot? {
        switch state {
        case .idle:
            nil
        case .loading(let previous), .failed(_, let previous):
            previous
        case .loaded(let snapshot):
            snapshot
        }
    }

    var errorMessage: String? {
        guard case let .failed(message, _) = state else { return nil }
        return message
    }

    var isLoading: Bool {
        guard case .loading = state else { return false }
        return true
    }

    var includesScreenshots: Bool {
        snapshot?.includesScreenshots == true
    }

    func load(
        request: KeywordRankingListLoader.LoadID,
        fallbackItems: [KeywordRankingListItem],
        using dataSource: KeywordRankingListDataSource
    ) async {
        guard !Task.isCancelled else { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        let previous = snapshot
        state = .loading(previous: previous)

        do {
            let snapshot = try await dataSource.load(
                crawlKey: request.crawlKey,
                fallbackItems: fallbackItems,
                storefrontCode: request.storefrontCode,
                includesScreenshots: request.includesScreenshots
            )
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            state = .loaded(snapshot)
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            restore(previous)
        } catch {
            guard generation == requestGeneration else { return }
            guard !Task.isCancelled else {
                restore(previous)
                return
            }
            state = .failed(
                message: OpenASOError.map(error).localizedDescription,
                previous: previous
            )
        }
    }

    private func restore(_ previous: KeywordRankingListLoader.Snapshot?) {
        if let previous {
            state = .loaded(previous)
        } else {
            state = .idle
        }
    }
}
