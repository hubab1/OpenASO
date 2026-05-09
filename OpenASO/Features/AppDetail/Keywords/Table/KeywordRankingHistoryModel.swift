import Observation

@Observable
@MainActor
final class KeywordRankingHistoryModel {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded([KeywordRankingCrawlSummary])
        case failed(String)
    }

    private(set) var state: State = .idle
    private var requestGeneration = 0

    var observations: [KeywordRankingCrawlSummary]? {
        guard case let .loaded(observations) = state else { return nil }
        return observations
    }

    var errorMessage: String? {
        guard case let .failed(message) = state else { return nil }
        return message
    }

    func load(
        queryKey: String,
        appStoreID: Int64,
        using dataSource: KeywordRankingHistoryDataSource
    ) async {
        requestGeneration &+= 1
        let generation = requestGeneration
        state = .loading

        do {
            let observations = try await dataSource.load(
                queryKey: queryKey,
                appStoreID: appStoreID
            )
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            state = .loaded(observations)
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            state = .idle
        } catch {
            guard generation == requestGeneration else { return }
            guard !Task.isCancelled else {
                state = .idle
                return
            }
            state = .failed(OpenASOError.map(error).localizedDescription)
        }
    }
}
