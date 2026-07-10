import Foundation
import SwiftData

enum ModelContainerFactory {
    static var schema: Schema {
        Schema(OpenASOSchemaV2.models)
    }

    static func makeModelContainer(
        isStoredInMemoryOnly: Bool,
        namespace: AppNamespace = .current
    ) throws -> ModelContainer {
        let schema = Self.schema
        let configuration: ModelConfiguration
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                url: try storeURL(namespace: namespace)
            )
        }
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: OpenASOMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            guard !isStoredInMemoryOnly else {
                throw error
            }
            try deletePersistentStore(namespace: namespace)
            return try ModelContainer(
                for: schema,
                migrationPlan: OpenASOMigrationPlan.self,
                configurations: [configuration]
            )
        }
    }

    private static func storeURL(namespace: AppNamespace) throws -> URL {
        let storeDirectoryURL = try namespace.applicationSupportDirectoryURL()
            .appendingPathComponent("SwiftData", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true)
        return storeDirectoryURL.appendingPathComponent("default.store", isDirectory: false)
    }

    private static func deletePersistentStore(namespace: AppNamespace) throws {
        let storeURL = try storeURL(namespace: namespace)
        let fileManager = FileManager.default
        for url in [
            storeURL,
            storeURL.deletingPathExtension().appendingPathExtension("store-shm"),
            storeURL.deletingPathExtension().appendingPathExtension("store-wal")
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
