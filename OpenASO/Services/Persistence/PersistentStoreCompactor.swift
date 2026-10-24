import CoreData
import Foundation
import SQLite3
import SwiftData

enum PersistentStoreCompactor {
    static func shouldCompact(at storeURL: URL) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        func pragma(_ name: String) throws -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            return sqlite3_column_int64(statement, 0)
        }
        let freePages = try pragma("freelist_count")
        let pageCount = try pragma("page_count")
        let freeBytes = try freePages * pragma("page_size")
        // Avoid a full-file rewrite on daily launches when pages can be reused.
        return freeBytes >= 64 * 1_024 * 1_024
            || (freeBytes >= 8 * 1_024 * 1_024 && freePages >= pageCount / 5)
    }

    // Older releases do not take the new lifetime lease. Refuse an upgrade
    // while any other process still has this exact store open.
    static func requireNoOlderClients(at storeURL: URL) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-F", "p", "--", storeURL.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw CocoaError(.fileLocking)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherPIDs = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .compactMap { $0.first == "p" ? Int32($0.dropFirst()) : nil }
            .filter { $0 != ownPID }
        guard otherPIDs.isEmpty else {
            throw NSError(domain: "OpenASO.StorageMigration", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Quit other OpenASO, refresh, or MCP processes before upgrading this database."
            ])
        }
    }

    /// Use Core Data's supported SQLite maintenance option. Never edit its
    /// private history tables or replace a live SQLite file behind a container.
    static func compact(at storeURL: URL) throws {
        try autoreleasepool {
            guard let model = NSManagedObjectModel.makeManagedObjectModel(
                for: OpenASOMigrationPlan.currentSchema.models
            ) else { throw CocoaError(.persistentStoreInvalidType) }
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(
                type: .sqlite, at: storeURL,
                options: [NSSQLiteManualVacuumOption: true, NSPersistentHistoryTrackingKey: true,
                          NSPersistentStoreTimeoutOption: 5]
            )
            try coordinator.remove(store)
        }
    }
}

// Research observations are ordinary models. This log is only SwiftData's
// internal change stream; no app consumer currently stores history tokens.
enum PersistentHistoryMaintenance {
    static func prune(in context: ModelContext) throws {
        try context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>())
    }
}
