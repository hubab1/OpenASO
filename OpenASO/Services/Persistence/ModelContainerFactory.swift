import CryptoKit
import Darwin
import Foundation
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
        opener: ContainerOpener = openModelContainer
    ) throws -> ModelContainer {
        let schema = Self.schema
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try withExclusiveMigrationLock(for: storeURL) {
                let container = try opener(schema, configuration)
                try RankingSchemaV6Migrator.migrateIfNeeded(in: container)
                return container
            }
        } catch {
            throw PersistentStoreError.openFailed(
                storeURL: storeURL,
                diagnosticDescription: String(reflecting: error)
            )
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

    private static func withExclusiveMigrationLock<Value>(
        for storeURL: URL,
        _ operation: () throws -> Value
    ) throws -> Value {
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
        defer { Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw CocoaError(.fileLocking)
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
