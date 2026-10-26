import Foundation
import SwiftData

// V1–V6 remain frozen. Keep their rating entity for current writes and add
// lossless, independently readable archives for older daily observations.
enum OpenASOSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

    static var models: [any PersistentModel.Type] {
        OpenASOSchemaV6.models + [RatingHistoryChunk.self, StorageMigrationState.self]
    }

    @Model
    final class RatingHistoryChunk {
        #Index<RatingHistoryChunk>([\.appStoreID], [\.appStoreID, \.storefront])
        @Attribute(.unique) var identityKey: String
        var appStoreID: Int64
        var storefront: String
        var year: String
        var firstObservedAt: Date
        var lastObservedAt: Date
        var recordCount: Int
        var formatVersion: Int
        var uncompressedByteCount: Int
        var digest: Data
        var payload: Data

        init(appStoreID: Int64, storefront: String, year: String) {
            self.identityKey = Self.key(appStoreID: appStoreID, storefront: storefront, year: year)
            self.appStoreID = appStoreID
            self.storefront = storefront
            self.year = year
            self.firstObservedAt = .distantFuture
            self.lastObservedAt = .distantPast
            self.recordCount = 0
            self.formatVersion = 1
            self.uncompressedByteCount = 0
            self.digest = Data()
            self.payload = Data()
        }

        static func key(appStoreID: Int64, storefront: String, year: String) -> String {
            "\(appStoreID)::\(storefront)::\(year)"
        }
    }

    @Model
    final class StorageMigrationState {
        @Attribute(.unique) var migrationKey: String
        var lastIdentityKey: String?
        var pendingDeletionPayload: Data?
        var archivedRecordCount: Int
        var completed: Bool
        var needsCompaction: Bool
        // Completion timestamp retained by the one-time upgrade; never a scan trigger.
        var lastMaintenanceAt: Date?

        init() {
            self.migrationKey = "storage-v7"
            self.archivedRecordCount = 0
            self.completed = false
            self.needsCompaction = true
        }
    }
}

typealias RatingHistoryChunk = OpenASOSchemaV7.RatingHistoryChunk
typealias StorageMigrationState = OpenASOSchemaV7.StorageMigrationState
