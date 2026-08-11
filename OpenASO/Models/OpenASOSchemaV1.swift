import SwiftData

// Frozen after the v0.3.2 release. Do not edit these model definitions in place;
// add distinct model types in a new versioned schema and append that schema below.
enum OpenASOSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            AppFolder.self,
            AppKeywordStats.self,
            LatestAppRating.self,
            AppDailyRating.self,
            AppStorefrontReview.self,
            StoreApp.self,
            AppStorefrontMetadata.self,
            AppStoreScreenshot.self,
            KeywordQuery.self,
            KeywordDailyMetric.self,
            KeywordRankingCrawl.self,
            KeywordAppRanking.self,
            TrackedApp.self,
            TrackedAppKeyword.self,
            TrackedKeywordDailyRanking.self,
            TrackedKeywordRankedResult.self,
            Storefront.self
        ]
    }
}

enum OpenASOMigrationPlan: SchemaMigrationPlan {
    static var currentSchema: any VersionedSchema.Type {
        schemas.last!
    }

    static var schemas: [any VersionedSchema.Type] {
        [
            OpenASOSchemaV1.self,
            OpenASOSchemaV2.self,
            OpenASOSchemaV3.self,
            OpenASOSchemaV4.self,
            OpenASOSchemaV5.self,
            OpenASOSchemaV6.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: OpenASOSchemaV1.self,
                toVersion: OpenASOSchemaV2.self
            ),
            .custom(
                fromVersion: OpenASOSchemaV2.self,
                toVersion: OpenASOSchemaV3.self,
                willMigrate: nil,
                didMigrate: { modelContext in
                    try TrackedKeywordRefreshStatusStore.migrateLegacyStatuses(
                        in: modelContext
                    )
                }
            ),
            .lightweight(
                fromVersion: OpenASOSchemaV3.self,
                toVersion: OpenASOSchemaV4.self
            ),
            .lightweight(
                fromVersion: OpenASOSchemaV4.self,
                toVersion: OpenASOSchemaV5.self
            ),
            .lightweight(
                fromVersion: OpenASOSchemaV5.self,
                toVersion: OpenASOSchemaV6.self
            )
        ]
    }
}
