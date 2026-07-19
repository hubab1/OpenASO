import SwiftData

/// Separates ranking and popularity refresh status without changing any
/// released V1 model definition or the V2 refresh-attempt entity.
enum OpenASOSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(3, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        OpenASOSchemaV2.models + [
            TrackedKeywordRefreshStatus.self
        ]
    }
}
