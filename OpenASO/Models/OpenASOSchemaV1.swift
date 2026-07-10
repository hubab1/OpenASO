import SwiftData

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

enum OpenASOSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 1, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            AppFolder.self,
            AppKeywordStats.self,
            AppPricingSnapshot.self,
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
    static var schemas: [any VersionedSchema.Type] {
        [
            OpenASOSchemaV1.self,
            OpenASOSchemaV2.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: OpenASOSchemaV1.self,
                toVersion: OpenASOSchemaV2.self
            )
        ]
    }
}
