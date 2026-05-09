import SwiftData

@MainActor
struct KeywordRankingHistoryDataSource {
    typealias LoadOperation = @MainActor (
        _ queryKey: String,
        _ appStoreID: Int64
    ) async throws -> [KeywordRankingCrawlSummary]

    private let loadOperation: LoadOperation

    init(load: @escaping LoadOperation) {
        self.loadOperation = load
    }

    func load(
        queryKey: String,
        appStoreID: Int64
    ) async throws -> [KeywordRankingCrawlSummary] {
        try await loadOperation(queryKey, appStoreID)
    }

    static func production(
        backgroundModelStore: BackgroundModelStore?,
        fallbackModelContext: ModelContext
    ) -> KeywordRankingHistoryDataSource {
        KeywordRankingHistoryDataSource { queryKey, appStoreID in
            try Task.checkCancellation()

            if let backgroundModelStore {
                let observations = try await backgroundModelStore.read { modelContext in
                    try KeywordRankingHistoryLoader.load(
                        queryKey: queryKey,
                        appStoreID: appStoreID,
                        in: modelContext
                    )
                }
                try Task.checkCancellation()
                return observations
            }

            return try KeywordRankingHistoryLoader.load(
                queryKey: queryKey,
                appStoreID: appStoreID,
                in: fallbackModelContext
            )
        }
    }
}
