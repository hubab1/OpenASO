import CoreData
import Foundation
import SwiftData

/// Copy and validate persisted archives before removing source rows. The
/// cursor advances with removal, so interrupted batches can safely repeat.
enum StorageSchemaV7Migrator {
    static let batchSize = 5_000

    private struct PendingDeletion: Codable {
        let keys: [String]
        let chunkKeys: [String]
        let nextCursor: String
    }

    /// The persistent path uses the public Core Data model bridge. SwiftData's
    /// object deletion walks inverse arrays for every row in a large store.
    /// Core Data performs the same bounded, validated transactions without
    /// materializing those SwiftData arrays. No private SQLite tables are used.
    @discardableResult
    static func migrateIfNeeded(
        at storeURL: URL, now: Date = .now, batchLimit: Int? = nil,
        beforeDeletion: (@Sendable () throws -> Void)? = nil
    ) throws -> Bool {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: OpenASOMigrationPlan.currentSchema.models) else {
            throw CocoaError(.persistentStoreInvalidType)
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: storeURL,
            options: [NSPersistentHistoryTrackingKey: true, NSSQLitePragmasOption: ["cache_size": "-65536"]])
        defer { try? coordinator.remove(store) }
        var batches = 0
        while batchLimit == nil || batches < batchLimit! {
            let done = try autoreleasepool {
                let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                context.persistentStoreCoordinator = coordinator
                context.undoManager = nil
                return try context.performAndWait {
                    try migratePersistentBatch(in: context, coordinator: coordinator, now: now, beforeDeletion: beforeDeletion)
                }
            }
            if done { return true }
            batches += 1
        }
        return false
    }

    private static func migratePersistentBatch(
        in context: NSManagedObjectContext, coordinator: NSPersistentStoreCoordinator, now: Date,
        beforeDeletion: (@Sendable () throws -> Void)?
    ) throws -> Bool {
        let stateRequest = NSFetchRequest<NSManagedObject>(entityName: "StorageMigrationState")
        stateRequest.predicate = NSPredicate(format: "migrationKey == %@", "storage-v7")
        stateRequest.fetchLimit = 1
        let state: NSManagedObject
        if let existing = try context.fetch(stateRequest).first { state = existing }
        else {
            state = NSEntityDescription.insertNewObject(forEntityName: "StorageMigrationState", into: context)
            state.setValue("storage-v7", forKey: "migrationKey")
            state.setValue(0, forKey: "archivedRecordCount")
            state.setValue(false, forKey: "completed")
            state.setValue(true, forKey: "needsCompaction")
            try context.save()
        }
        if state.value(forKey: "completed") as? Bool == true { return true }
        if let pending = state.value(forKey: "pendingDeletionPayload") as? Data {
            try finishDeletion(JSONDecoder().decode(PendingDeletion.self, from: pending), state: state, in: context)
            return false
        }
        let cursor = state.value(forKey: "lastIdentityKey") as? String ?? ""
        let request = NSFetchRequest<NSManagedObject>(entityName: "AppDailyRating")
        request.predicate = NSPredicate(format: "identityKey > %@", cursor)
        request.sortDescriptors = [NSSortDescriptor(key: "identityKey", ascending: true)]
        request.fetchLimit = batchSize + 1
        request.returnsObjectsAsFaults = false
        request.relationshipKeyPathsForPrefetching = ["storeApp"]
        let candidates = try context.fetch(request)
        let batch = Array(candidates.prefix(batchSize))
        guard let last = batch.last else {
            state.setValue(true, forKey: "completed")
            state.setValue(now, forKey: "lastMaintenanceAt")
            try context.save()
            try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.now))
            return true
        }
        let nextCursor = try RatingHistoryRecord(last).identityKey
        let records = try batch.map(RatingHistoryRecord.init)
        let nextRecord = try candidates.dropFirst(batch.count).first.map(RatingHistoryRecord.init)
        let following = Array(records.dropFirst()) + [nextRecord].compactMap { $0 }
        var sourceObjects: [NSManagedObject] = []
        var originals: [RatingHistoryRecord] = []
        for (index, record) in records.enumerated() where index < following.count {
            let next = following[index]
            if next.appStoreID == record.appStoreID && next.storefront == record.storefront {
                sourceObjects.append(batch[index])
                originals.append(record)
            }
        }
        let groups = Dictionary(grouping: originals, by: \.chunkKey)
        let keys = Array(groups.keys)
        let chunkRequest = NSFetchRequest<NSManagedObject>(entityName: "RatingHistoryChunk")
        chunkRequest.predicate = NSPredicate(format: "identityKey IN %@", keys)
        let existing = try context.fetch(chunkRequest)
        var chunks = Dictionary(uniqueKeysWithValues: existing.compactMap { row -> (String, NSManagedObject)? in
            (row.value(forKey: "identityKey") as? String).map { ($0, row) }
        })
        for (key, values) in groups {
            let first = values[0]
            let archived: RatingHistoryChunk
            if let existing = chunks[key] { archived = try archiveValue(existing) }
            else { archived = RatingHistoryChunk(appStoreID: first.appStoreID, storefront: first.storefront, year: String(first.ratingDate.prefix(4))) }
            var merged = archived.recordCount == 0 ? [:] : Dictionary(uniqueKeysWithValues: try RatingHistoryStore.records(in: archived).map { ($0.identityKey, $0) })
            for record in values { merged[record.identityKey] = record }
            try RatingHistoryStore.replace(Array(merged.values), in: archived)
            let row = chunks[key] ?? NSEntityDescription.insertNewObject(forEntityName: "RatingHistoryChunk", into: context)
            row.setValue(archived.identityKey, forKey: "identityKey")
            row.setValue(archived.appStoreID, forKey: "appStoreID")
            row.setValue(archived.storefront, forKey: "storefront")
            row.setValue(archived.year, forKey: "year")
            row.setValue(archived.firstObservedAt, forKey: "firstObservedAt")
            row.setValue(archived.lastObservedAt, forKey: "lastObservedAt")
            row.setValue(archived.recordCount, forKey: "recordCount")
            row.setValue(archived.formatVersion, forKey: "formatVersion")
            row.setValue(archived.uncompressedByteCount, forKey: "uncompressedByteCount")
            row.setValue(archived.digest, forKey: "digest")
            row.setValue(archived.payload, forKey: "payload")
            chunks[key] = row
        }
        try context.save()
        let expectedRecords = originals
        let verification = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        verification.persistentStoreCoordinator = coordinator
        try verification.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RatingHistoryChunk")
            request.predicate = NSPredicate(format: "identityKey IN %@", keys)
            let persisted = try verification.fetch(request)
            let decoded = try persisted.flatMap { try RatingHistoryStore.records(in: archiveValue($0)) }
            let byKey = Dictionary(uniqueKeysWithValues: decoded.map { ($0.identityKey, $0) })
            for original in expectedRecords where byKey[original.identityKey] != original {
                throw RatingHistoryError.invalidArchive(original.identityKey)
            }
        }
        // Persist detachment and a recovery marker together. Batch deletion
        // then satisfies the frozen model's inverse-relationship constraint.
        // After interruption, the validated archives remain authoritative for
        // their original links until the pending deletion finishes.
        let pending = PendingDeletion(keys: originals.map(\.identityKey), chunkKeys: keys, nextCursor: nextCursor)
        for row in sourceObjects { row.setValue(nil, forKey: "storeApp") }
        state.setValue(try JSONEncoder().encode(pending), forKey: "pendingDeletionPayload")
        try context.save()
        try beforeDeletion?()
        try finishDeletion(pending, state: state, in: context)
        return false
    }

    private static func finishDeletion(
        _ pending: PendingDeletion, state: NSManagedObject, in context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "RatingHistoryChunk")
        request.predicate = NSPredicate(format: "identityKey IN %@", pending.chunkKeys)
        let archived = try context.fetch(request).flatMap { try RatingHistoryStore.records(in: archiveValue($0)) }
        let archivedKeys = Set(archived.map(\.identityKey))
        guard pending.keys.allSatisfy({ archivedKeys.contains($0) }) else {
            throw RatingHistoryError.invalidArchive("Pending source deletion")
        }
        if !pending.keys.isEmpty {
            let source = NSFetchRequest<NSFetchRequestResult>(entityName: "AppDailyRating")
            source.predicate = NSPredicate(format: "identityKey IN %@", pending.keys)
            try context.execute(NSBatchDeleteRequest(fetchRequest: source))
        }
        let previousCount = (state.value(forKey: "archivedRecordCount") as? NSNumber)?.intValue ?? 0
        state.setValue(previousCount + pending.keys.count, forKey: "archivedRecordCount")
        state.setValue(pending.nextCursor, forKey: "lastIdentityKey")
        state.setValue(nil, forKey: "pendingDeletionPayload")
        try context.save()
        if previousCount / 100_000 != (previousCount + pending.keys.count) / 100_000 {
            try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: Date.now))
        }
    }

    private static func archiveValue(_ row: NSManagedObject) throws -> RatingHistoryChunk {
        guard let appID = row.value(forKey: "appStoreID") as? NSNumber,
              let storefront = row.value(forKey: "storefront") as? String,
              let year = row.value(forKey: "year") as? String,
              let key = row.value(forKey: "identityKey") as? String,
              let first = row.value(forKey: "firstObservedAt") as? Date,
              let last = row.value(forKey: "lastObservedAt") as? Date,
              let count = row.value(forKey: "recordCount") as? NSNumber,
              let version = row.value(forKey: "formatVersion") as? NSNumber,
              let size = row.value(forKey: "uncompressedByteCount") as? NSNumber,
              let digest = row.value(forKey: "digest") as? Data,
              let payload = row.value(forKey: "payload") as? Data else {
            throw RatingHistoryError.invalidArchive("Persistent archive attributes")
        }
        let value = RatingHistoryChunk(appStoreID: appID.int64Value, storefront: storefront, year: year)
        value.identityKey = key
        value.firstObservedAt = first
        value.lastObservedAt = last
        value.recordCount = count.intValue
        value.formatVersion = version.intValue
        value.uncompressedByteCount = size.intValue
        value.digest = digest
        value.payload = payload
        return value
    }

}

private extension RatingHistoryRecord {
    init(_ row: NSManagedObject) throws {
        guard let key = row.value(forKey: "identityKey") as? String,
              let appID = row.value(forKey: "appStoreID") as? NSNumber,
              let store = row.value(forKey: "storefront") as? String,
              let day = row.value(forKey: "ratingDate") as? String,
              let observed = row.value(forKey: "observedAt") as? Date,
              let submissions = row.value(forKey: "submissionCount") as? NSNumber,
              let winners = row.value(forKey: "winningCount") as? NSNumber,
              let source = row.value(forKey: "sourceRaw") as? String else {
            throw RatingHistoryError.invalidArchive("Persistent rating attributes")
        }
        identityKey = key
        appStoreID = appID.int64Value
        storefront = store
        ratingDate = day
        observedAt = observed
        submissionCount = submissions.intValue
        winningCount = winners.intValue
        sourceRaw = source
        ratingCount = (row.value(forKey: "ratingCount") as? NSNumber)?.intValue
        averageRating = (row.value(forKey: "averageRating") as? NSNumber)?.doubleValue
        oneStarRatingCount = (row.value(forKey: "oneStarRatingCount") as? NSNumber)?.intValue
        twoStarRatingCount = (row.value(forKey: "twoStarRatingCount") as? NSNumber)?.intValue
        threeStarRatingCount = (row.value(forKey: "threeStarRatingCount") as? NSNumber)?.intValue
        fourStarRatingCount = (row.value(forKey: "fourStarRatingCount") as? NSNumber)?.intValue
        fiveStarRatingCount = (row.value(forKey: "fiveStarRatingCount") as? NSNumber)?.intValue
        confidenceRaw = row.value(forKey: "confidenceRaw") as? String
        let parent = row.value(forKey: "storeApp") as? NSManagedObject
        storeAppID = (parent?.value(forKey: "appStoreID") as? NSNumber)?.int64Value
    }
}
