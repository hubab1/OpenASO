import CryptoKit
import Darwin
import Foundation
import ObjectiveC
import SwiftData

enum PersistentStoreError: LocalizedError, Sendable {
    case locationUnavailable(diagnosticDescription: String)
    case openFailed(storeURL: URL, diagnosticDescription: String)
    case unexpected(diagnosticDescription: String)

    var storeURL: URL? {
        guard case .openFailed(let storeURL, _) = self else {
            return nil
        }
        return storeURL
    }

    var diagnosticDescription: String {
        switch self {
        case .locationUnavailable(let diagnosticDescription),
             .openFailed(_, let diagnosticDescription),
             .unexpected(let diagnosticDescription):
            diagnosticDescription
        }
    }

    var errorDescription: String? {
        switch self {
        case .locationUnavailable:
            "OpenASO couldn’t access its local data folder."
        case .openFailed:
            "OpenASO couldn’t open its local database."
        case .unexpected:
            "OpenASO couldn’t prepare its local database."
        }
    }

    var recoverySuggestion: String? {
        "OpenASO did not delete or replace your database files. Quit OpenASO before changing them, and copy the entire data folder before attempting recovery."
    }

    var diagnosticReport: String {
        var lines = [
            errorDescription ?? "OpenASO couldn’t prepare its local database.",
            recoverySuggestion ?? "No database files were removed."
        ]
        if let storeURL {
            lines.append("Database: \(storeURL.path(percentEncoded: false))")
        }
        lines.append("Details: \(diagnosticDescription)")
        return lines.joined(separator: "\n")
    }
}

enum ModelContainerFactory {
    typealias ContainerOpener = (Schema, ModelConfiguration) throws -> ModelContainer

    static var schema: Schema {
        Schema(versionedSchema: OpenASOMigrationPlan.currentSchema)
    }

    static func makeModelContainer(
        isStoredInMemoryOnly: Bool,
        namespace: AppNamespace = .current,
        opener: ContainerOpener = openModelContainer
    ) throws -> ModelContainer {
        let schema = Self.schema
        if isStoredInMemoryOnly {
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            return try opener(schema, configuration)
        }

        let persistentStoreURL: URL
        do {
            persistentStoreURL = try storeURL(namespace: namespace)
        } catch {
            throw PersistentStoreError.locationUnavailable(
                diagnosticDescription: String(reflecting: error)
            )
        }

        return try makePersistentModelContainer(
            at: persistentStoreURL,
            opener: opener
        )
    }

    static func makePersistentModelContainer(
        at storeURL: URL,
        opener: ContainerOpener = openModelContainer,
        compactStore: (URL) throws -> Void = PersistentStoreCompactor.compactIfNeeded
    ) throws -> ModelContainer {
        let schema = Self.schema
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try withMigrationAccess(for: storeURL) { canMigrate in
                guard canMigrate else {
                    let container = try opener(schema, configuration)
                    let state = try ModelContext(container).fetch(FetchDescriptor<StorageMigrationState>()).first
                    // A failed migration owner also releases its lock. Shared
                    // access alone does not prove that the upgrade finished.
                    guard state?.completed == true, state?.pendingDeletionPayload == nil else {
                        throw NSError(domain: "OpenASO.StorageMigration", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "The database upgrade is unfinished. Quit other OpenASO, refresh, or MCP processes and reopen to resume it."
                        ])
                    }
                    return container
                }
                let prepared: ModelContainer? = try autoreleasepool {
                    let container = try opener(schema, configuration)
                    try RankingSchemaV6Migrator.migrateIfNeeded(in: container)
                    let context = ModelContext(container)
                    let prior = try context.fetch(FetchDescriptor<StorageMigrationState>()).first
                    let needsUpgrade = prior?.completed != true || prior?.needsCompaction != false
                    guard needsUpgrade else { return container }
                    // No app consumer persists SwiftData history tokens. Research
                    // observations live in model entities, not this change log.
                    try PersistentHistoryMaintenance.prune(in: context)
                    return nil
                }
                if let prepared { return prepared }
                try StorageSchemaV7Migrator.migrateIfNeeded(at: storeURL)
                var compactionFinished = false
                do {
                    try compactStore(storeURL)
                    compactionFinished = true
                } catch {
                    guard PersistentStoreCompactor.canRetryLater(error) else { throw error }
                    // Logical migration has already verified all research data.
                    // Reopening still has to succeed before returning a usable store.
                    OpenASOLog.rankingMigration.error("Optional storage compaction deferred: \(String(reflecting: error), privacy: .public)")
                }
                let container = try opener(schema, configuration)
                let context = ModelContext(container)
                if let state = try context.fetch(FetchDescriptor<StorageMigrationState>()).first {
                    if compactionFinished {
                        state.needsCompaction = false
                        try context.save()
                    }
                }
                return container
            }
        } catch {
            throw PersistentStoreError.openFailed(
                storeURL: storeURL,
                diagnosticDescription: String(reflecting: error)
            )
        }
    }

    /// Serialize complete worker transactions across app, MCP, and refresh
    /// processes. Fresh contexts prevent cached chunks from overwriting a
    /// different writer's committed days. No network await occurs under this lock.
    static func withWriteTransaction<Value>(
        in container: ModelContainer, _ operation: (ModelContext) throws -> Value
    ) throws -> Value {
        let configuration = container.configurations.first!
        let identity = configuration.isStoredInMemoryOnly
            ? "memory:\(ObjectIdentifier(container))"
            : configuration.url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-Writes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(digest).lock")
        let descriptor = url.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileLocking) }
        }
        defer { flock(descriptor, LOCK_UN) }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let result = try operation(context)
            if context.hasChanges { try context.save() }
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func storeURL(namespace: AppNamespace) throws -> URL {
        let storeDirectoryURL = try namespace.applicationSupportDirectoryURL()
            .appendingPathComponent("SwiftData", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true)
        return storeDirectoryURL.appendingPathComponent("default.store", isDirectory: false)
    }

    private static func openModelContainer(
        schema: Schema,
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: OpenASOMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static func withMigrationAccess(
        for storeURL: URL,
        _ operation: (Bool) throws -> ModelContainer
    ) throws -> ModelContainer {
        let lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenASO-Migrations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )
        let digest = SHA256.hash(data: Data(storeURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let lockURL = lockDirectory.appendingPathComponent("\(digest).lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let lease = PersistentStoreLease(descriptor: descriptor)
        let exclusive = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        if !exclusive {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw CocoaError(.fileLocking) }
            while flock(descriptor, LOCK_SH) != 0 {
                guard errno == EINTR else { throw CocoaError(.fileLocking) }
            }
        } else if FileManager.default.fileExists(atPath: storeURL.path) {
            try PersistentStoreCompactor.requireNoOlderClients(at: storeURL)
        }
        let container = try operation(exclusive)
        if exclusive, flock(descriptor, LOCK_SH) != 0 { throw CocoaError(.fileLocking) }
        // Hold shared access for the container's lifetime. Another app, MCP,
        // or refresh process can read/write, but cannot compact a live store.
        let key = UnsafeRawPointer(bitPattern: UInt(bitPattern: ObjectIdentifier(PersistentStoreLease.self)))!
        objc_setAssociatedObject(container, key, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return container
    }
}

private final class PersistentStoreLease: Sendable {
    let descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
