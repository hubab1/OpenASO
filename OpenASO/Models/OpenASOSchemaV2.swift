import SwiftData

/// Adds durable ranking-refresh attempt recency without changing any released
/// V1 model definition.
enum OpenASOSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        OpenASOSchemaV1.models + [
            TrackedAppKeywordRefreshAttempt.self
        ]
    }
}
