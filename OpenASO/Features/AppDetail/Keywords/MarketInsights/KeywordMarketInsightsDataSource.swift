struct KeywordMarketInsightsDataSource: Sendable {
    typealias LoadOperation = @Sendable (
        _ request: KeywordMarketInsightsRequest
    ) async throws -> KeywordMarketInsightsPage

    private let loadOperation: LoadOperation

    init(load: @escaping LoadOperation) {
        self.loadOperation = load
    }

    func load(
        scope: KeywordMarketInsightsViewScope,
        cursor: String?
    ) async throws -> KeywordMarketInsightsPage {
        try Task.checkCancellation()
        let page = try await loadOperation(scope.request(cursor: cursor))
        try Task.checkCancellation()
        return page
    }

    static func production(
        backgroundModelStore: BackgroundModelStore?
    ) -> KeywordMarketInsightsDataSource {
        KeywordMarketInsightsDataSource { request in
            guard let backgroundModelStore else {
                throw OpenASOError.providerUnavailable(
                    "The background model store is unavailable."
                )
            }
            return try await KeywordMarketInsightsService(
                backgroundModelStore: backgroundModelStore
            ).insights(for: request)
        }
    }
}
