import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct StorageSchemaV7MigrationTests {
    @Test
    func archivePreservesEveryValueAndHistoricalCorrectionsCanBeWritten() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            let app = StoreApp(appStoreID: 42, bundleID: "example", name: "App", sellerName: nil,
                               iconURLString: nil, defaultPlatform: .iphone)
            context.insert(app)
            let old = makeRating(day: "2026-01-01", observedAt: Date(timeIntervalSince1970: 1_700_000_000), app: app)
            let latest = makeRating(day: "2026-01-02", observedAt: old.observedAt.addingTimeInterval(1), app: app)
            old.sourceRaw = "future-source"
            context.insert(old); context.insert(latest)
            try context.save()
            let expected = try RatingHistoryStore.fetch(appStoreIDs: [42], in: context)

            try StorageSchemaV7Migrator.migrateIfNeeded(at: url)
            let migrated = ModelContext(container)
            #expect(try migrated.fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
            #expect(try migrated.fetchCount(FetchDescriptor<RatingHistoryChunk>()) == 1)
            #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: migrated) == expected)

            let key = "42::gb::2026-01-01"
            let restored = try #require(try RatingHistoryStore.restore(identityKey: key, in: migrated))
            #expect(restored.storeApp?.appStoreID == 42)
            #expect(restored.sourceRaw == "future-source")
            restored.ratingCount = 999
            try migrated.save()
            let reread = try RatingHistoryStore.fetch(appStoreIDs: [42], in: ModelContext(container))
            #expect(reread.count == 2)
            #expect(reread.first { $0.identityKey == key }?.ratingCount == 999)
        }
    }

    @Test
    func interruptedBatchesResumeAndSecondRunDoesNotDuplicateDays() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            for appID in 1...60 {
                for day in 1...100 {
                    let value = makeRating(day: String(format: "2026-%02d-%02d", 1 + (day - 1) / 28, 1 + (day - 1) % 28),
                                           observedAt: Date(timeIntervalSince1970: Double(day)), app: nil)
                    value.appStoreID = Int64(appID)
                    value.identityKey = AppDailyRating.makeIdentityKey(appStoreID: Int64(appID), storefront: "gb", ratingDate: value.ratingDate)
                    context.insert(value)
                }
            }
            try context.save()
            let ids = (1...60).map(Int64.init)
            let expected = try RatingHistoryStore.fetch(appStoreIDs: ids, in: context)
            #expect(try !StorageSchemaV7Migrator.migrateIfNeeded(at: url, batchLimit: 1))
            #expect(try RatingHistoryStore.fetch(appStoreIDs: ids, in: ModelContext(container)) == expected)
            #expect(try StorageSchemaV7Migrator.migrateIfNeeded(at: url))
            #expect(try RatingHistoryStore.fetch(appStoreIDs: ids, in: ModelContext(container)) == expected)
            #expect(try StorageSchemaV7Migrator.migrateIfNeeded(at: url))
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<AppDailyRating>()) == 60)
            #expect(try RatingHistoryStore.fetch(appStoreIDs: ids, in: ModelContext(container)) == expected)
        }
    }

    @Test
    func corruptArchiveStopsMigrationBeforeSourceDeletion() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            for day in ["2026-01-01", "2026-01-02"] {
                context.insert(makeRating(day: day, observedAt: .now, app: nil))
            }
            let corrupt = RatingHistoryChunk(appStoreID: 42, storefront: "gb", year: "2026")
            corrupt.recordCount = 1
            corrupt.payload = Data([1, 2, 3])
            context.insert(corrupt)
            try context.save()
            #expect(throws: (any Error).self) { try StorageSchemaV7Migrator.migrateIfNeeded(at: url) }
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<AppDailyRating>()) == 2)
        }
    }

    @Test
    func observationDateFiltersRemainIndependentOfLogicalRatingDate() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            let observed = Date(timeIntervalSince1970: 100)
            context.insert(makeRating(day: "2025-12-31", observedAt: observed, app: nil))
            context.insert(makeRating(day: "2026-01-01", observedAt: observed.addingTimeInterval(100), app: nil))
            try context.save()
            try StorageSchemaV7Migrator.migrateIfNeeded(at: url)
            let values = try RatingHistoryStore.fetch(appStoreIDs: [42], storefronts: ["gb"], from: observed,
                                                    to: observed, in: ModelContext(container))
            #expect(values.map(\.ratingDate) == ["2025-12-31"])
        }
    }

    @Test
    func releasedV6StoreCompactsAutomaticallyAndReopens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-V7-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try autoreleasepool {
            let schema = Schema(versionedSchema: OpenASOSchemaV6.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(makeRating(day: "2026-01-01", observedAt: .now, app: nil))
            context.insert(makeRating(day: "2026-01-02", observedAt: .now, app: nil))
            try context.save()
        }
        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
            let context = ModelContext(container)
            #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: context).count == 2)
            let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
            #expect(state.completed)
            #expect(!state.needsCompaction)
        }
        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
            #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: ModelContext(container)).count == 2)
        }
    }

    @Test
    func anotherLiveContainerDefersPhysicalMaintenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-V7-Lease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try autoreleasepool {
            let first = try ModelContainerFactory.makePersistentModelContainer(at: url)
            let context = ModelContext(first)
            let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
            state.lastMaintenanceAt = .distantPast
            try context.save()
            let second = try ModelContainerFactory.makePersistentModelContainer(at: url)
            let otherState = try #require(try ModelContext(second).fetch(FetchDescriptor<StorageMigrationState>()).first)
            #expect(otherState.lastMaintenanceAt == .distantPast)
        }
    }

    @Test
    func newerLiveCopySupersedesAnArchivedDayBeforeDateFiltering() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            let old = makeRating(day: "2026-01-01", observedAt: Date(timeIntervalSince1970: 100), app: nil)
            let chunk = RatingHistoryChunk(appStoreID: 42, storefront: "gb", year: "2026")
            try RatingHistoryStore.replace([RatingHistoryRecord(old)], in: chunk)
            context.insert(chunk)
            old.observedAt = Date(timeIntervalSince1970: 200)
            context.insert(old)
            try context.save()
            let values = try RatingHistoryStore.fetch(appStoreIDs: [42],
                from: Date(timeIntervalSince1970: 50), to: Date(timeIntervalSince1970: 150), in: context)
            #expect(values.isEmpty)
        }
    }

    @Test
    func preLeaseClientPreventsAnUpgrade() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-LegacyLease-\(UUID())")
        try Data(repeating: 7, count: 256 * 1_024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        _ = output.fileHandleForReading.readData(ofLength: 1)
        #expect(throws: (any Error).self) { try PersistentStoreCompactor.requireNoOlderClients(at: url) }
    }

    @Test
    func releasedV6ClientCannotDowngradeAnArchivedStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-V7-Downgrade-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
            let context = ModelContext(container)
            context.insert(makeRating(day: "2026-01-01", observedAt: .now, app: nil))
            context.insert(makeRating(day: "2026-01-02", observedAt: .now, app: nil))
            try context.save()
            // Run a later maintenance pass on this private test store.
            try StorageSchemaV7Migrator.migrateIfNeeded(at: url, now: .now.addingTimeInterval(86_401))
        }
        #expect(throws: (any Error).self) {
            try autoreleasepool {
                let schema = Schema(versionedSchema: OpenASOSchemaV6.self)
                _ = try ModelContainer(for: schema, migrationPlan: ReleasedV6StoragePlan.self,
                    configurations: ModelConfiguration(schema: schema, url: url))
            }
        }
        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
            #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: ModelContext(container)).count == 2)
        }
    }

    @Test
    func interruptedAfterDetachmentResumesWithoutLosingOriginalLinks() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            let app = StoreApp(appStoreID: 42, bundleID: "example", name: "App", sellerName: nil,
                iconURLString: nil, defaultPlatform: .iphone)
            context.insert(app)
            context.insert(makeRating(day: "2026-01-01", observedAt: .now, app: app))
            context.insert(makeRating(day: "2026-01-02", observedAt: .now, app: app))
            try context.save()
            let expected = try RatingHistoryStore.fetch(appStoreIDs: [42], in: context)
            #expect(throws: InjectedStorageInterruption.self) {
                try StorageSchemaV7Migrator.migrateIfNeeded(at: url, beforeDeletion: {
                    throw InjectedStorageInterruption.stop
                })
            }
            let state = try #require(try ModelContext(container).fetch(FetchDescriptor<StorageMigrationState>()).first)
            #expect(state.pendingDeletionPayload != nil)
            try StorageSchemaV7Migrator.migrateIfNeeded(at: url)
            #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: ModelContext(container)) == expected)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
        }
    }

    private func withTestStore(_ body: (ModelContainer, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-Archive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try autoreleasepool {
            let schema = ModelContainerFactory.schema
            let url = root.appendingPathComponent("default.store")
            let container = try ModelContainer(for: schema, migrationPlan: OpenASOMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url))
            try body(container, url)
        }
    }

    private func makeRating(day: String, observedAt: Date, app: StoreApp?) -> AppDailyRating {
        AppDailyRating(appStoreID: 42, storefront: "gb", ratingCount: 123, averageRating: 4.625,
                       oneStarRatingCount: 1, twoStarRatingCount: 2, threeStarRatingCount: 3,
                       fourStarRatingCount: 4, fiveStarRatingCount: 113, ratingDate: day,
                       observedAt: observedAt, submissionCount: 5, winningCount: 4,
                       confidence: "evidence", source: .iTunesSearch, storeApp: app)
    }
}

private enum ReleasedV6StoragePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { Array(OpenASOMigrationPlan.schemas.prefix(6)) }
    static var stages: [MigrationStage] { Array(OpenASOMigrationPlan.stages.prefix(5)) }
}

private enum InjectedStorageInterruption: Error { case stop }
