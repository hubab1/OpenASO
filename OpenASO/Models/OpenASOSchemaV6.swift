import SwiftData

/// Adds a normalized ranking store alongside the frozen V1 ranking entities.
/// A resumable post-open migration copies and validates legacy ranking data
/// before the redundant V1 rows are removed.
enum OpenASOSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(6, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        OpenASOSchemaV5.models + [
            RankingAppRevision.self,
            RankingCrawlRecord.self,
            RankingFact.self,
            TrackedRankingCrawlLink.self,
            RankingMigrationState.self
        ]
    }
}
