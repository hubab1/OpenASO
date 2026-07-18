import SwiftData

@MainActor
struct KeywordRankingListDataSource {
    typealias LoadOperation = @MainActor (
        _ crawlKey: String?,
        _ fallbackItems: [KeywordRankingListItem],
        _ storefrontCode: String,
        _ includesScreenshots: Bool
    ) async throws -> KeywordRankingListLoader.Snapshot

    private let loadOperation: LoadOperation

    init(load: @escaping LoadOperation) {
        self.loadOperation = load
    }

    func load(
        crawlKey: String?,
        fallbackItems: [KeywordRankingListItem],
        storefrontCode: String,
        includesScreenshots: Bool
    ) async throws -> KeywordRankingListLoader.Snapshot {
        try await loadOperation(crawlKey, fallbackItems, storefrontCode, includesScreenshots)
    }

    static func production(
        backgroundModelStore: BackgroundModelStore?,
        fallbackModelContext: ModelContext
    ) -> KeywordRankingListDataSource {
        KeywordRankingListDataSource { crawlKey, fallbackItems, storefrontCode, includesScreenshots in
            try Task.checkCancellation()

            if let backgroundModelStore {
                let snapshot = try await backgroundModelStore.read { modelContext in
                    try KeywordRankingListLoader.load(
                        crawlKey: crawlKey,
                        fallbackItems: fallbackItems,
                        storefrontCode: storefrontCode,
                        includesScreenshots: includesScreenshots,
                        in: modelContext
                    )
                }
                try Task.checkCancellation()
                return snapshot
            }

            return try KeywordRankingListLoader.load(
                crawlKey: crawlKey,
                fallbackItems: fallbackItems,
                storefrontCode: storefrontCode,
                includesScreenshots: includesScreenshots,
                in: fallbackModelContext
            )
        }
    }
}
