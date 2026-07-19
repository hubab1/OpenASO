import SwiftData

@MainActor
struct EstimatedKeywordDifficultyDetailDataSource {
    typealias LoadOperation = @MainActor (
        _ queryKey: String
    ) async throws -> EstimatedKeywordDifficultySnapshot?

    private let loadOperation: LoadOperation

    init(load: @escaping LoadOperation) {
        self.loadOperation = load
    }

    func load(queryKey: String) async throws -> EstimatedKeywordDifficultySnapshot? {
        try await loadOperation(queryKey)
    }

    static func production(
        backgroundModelStore: BackgroundModelStore?,
        fallbackModelContext: ModelContext
    ) -> EstimatedKeywordDifficultyDetailDataSource {
        EstimatedKeywordDifficultyDetailDataSource { queryKey in
            try Task.checkCancellation()

            if let backgroundModelStore {
                let snapshot = try await backgroundModelStore.read { modelContext in
                    try EstimatedKeywordDifficultyStore.snapshot(
                        queryKey: queryKey,
                        in: modelContext
                    )
                }
                try Task.checkCancellation()
                return snapshot
            }

            let snapshot = try EstimatedKeywordDifficultyStore.snapshot(
                queryKey: queryKey,
                in: fallbackModelContext
            )
            try Task.checkCancellation()
            return snapshot
        }
    }
}
