import CoreData
import Foundation
import SQLite3
import SwiftData

enum PersistentStoreCompactor {
    static func compactIfNeeded(at storeURL: URL) throws {
        if try shouldCompact(at: storeURL) { try compact(at: storeURL) }
    }

    /// Only storage-capacity/access failures are optional. Archive validation,
    /// schema incompatibility, and corruption errors must still stop startup.
    static func canRetryLater(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            if error.code == CocoaError.fileReadCorruptFile.rawValue { return false }
            if [CocoaError.fileWriteOutOfSpace.rawValue, CocoaError.fileWriteNoPermission.rawValue,
                CocoaError.fileLocking.rawValue].contains(error.code) { return true }
        }
        // Core Data may attach the SQLite code directly to a Cocoa error
        // instead of wrapping an underlying NSSQLiteErrorDomain error.
        let sqliteCode = error.domain == "NSSQLiteErrorDomain"
            ? error.code : (error.userInfo["NSSQLiteErrorDomain"] as? NSNumber)?.intValue
        if let sqliteCode {
            // Extended SQLite errors keep the primary code in the low byte.
            return [SQLITE_FULL, SQLITE_BUSY, SQLITE_LOCKED, SQLITE_READONLY, SQLITE_PERM]
                .contains(Int32(sqliteCode & 0xff))
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return canRetryLater(underlying)
        }
        if let details = error.userInfo[NSDetailedErrorsKey] as? [NSError], !details.isEmpty {
            return details.allSatisfy(canRetryLater)
        }
        return false
    }

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
        let pageSize = try pragma("page_size")
        let freeBytes = freePages * pageSize
        // Avoid a full-file rewrite on daily launches when pages can be reused.
        return (pageSize != 16_384 && pageCount * pageSize >= 256 * 1_024 * 1_024)
            || freeBytes >= 64 * 1_024 * 1_024
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
        // SQLite cannot change page size in WAL mode. All clients are closed
        // under the migration lease; checkpoint before the framework rebuild.
        // SwiftData restores WAL when the completed store is reopened.
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 5_000)
            guard sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(database, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
                throw CocoaError(.fileLocking)
            }
        }
        try autoreleasepool {
            guard let model = NSManagedObjectModel.makeManagedObjectModel(
                for: OpenASOMigrationPlan.currentSchema.models
            ) else { throw CocoaError(.persistentStoreInvalidType) }
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(
                type: .sqlite, at: storeURL,
                options: [NSSQLiteManualVacuumOption: true, NSPersistentHistoryTrackingKey: false,
                          NSPersistentStoreTimeoutOption: 5,
                          NSSQLitePragmasOption: ["journal_mode": "DELETE", "page_size": "16384"]]
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
