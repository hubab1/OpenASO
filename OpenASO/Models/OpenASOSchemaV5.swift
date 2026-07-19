import SwiftData

/// Adds UUID-based pre-live research projects and their project-owned keyword
/// memberships without changing any V1-V4 persistent model definition.
enum OpenASOSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(5, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        OpenASOSchemaV4.models + [
            KeywordResearchProject.self,
            KeywordResearchKeyword.self
        ]
    }
}
