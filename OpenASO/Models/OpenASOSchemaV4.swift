import SwiftData

/// Adds independently sourced estimated-difficulty provenance and its bounded
/// current evidence set without changing or reinterpreting released models.
enum OpenASOSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(4, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        OpenASOSchemaV3.models + [
            EstimatedKeywordDifficultyMetric.self,
            EstimatedKeywordDifficultyResultEvidenceRecord.self
        ]
    }
}
