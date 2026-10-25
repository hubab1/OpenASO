import Foundation
import SQLite3
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
            let archived = try #require(expected.first { $0.identityKey == key })
            #expect(archived.storeAppID == 42)
            #expect(archived.sourceRaw == "future-source")
            try RatingHistoryStore.ingest([.init(.init(
                appStoreID: 42, storefront: "gb", ratingCount: 999, averageRating: archived.averageRating,
                ratingCounts: nil, observedAt: archived.observedAt.addingTimeInterval(1), source: .iTunesSearch
            ), ratingDate: archived.ratingDate, submissionCount: 7, winningCount: 6, confidence: "correction")],
                storeApps: [42: try #require(migrated.fetch(FetchDescriptor<StoreApp>()).first)], in: migrated)
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
            // A completed upgrade never reruns. New observations archive on ingestion.
            let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
            let app = StoreApp(appStoreID: 84, bundleID: nil, name: "New app", sellerName: nil,
                               iconURLString: nil, defaultPlatform: .iphone)
            context.insert(app)
            let start = try Date("2026-02-01T15:00:00Z", strategy: .iso8601)
            try ingestRating(service, app: app, observedAt: start, count: 100, in: context)
            try ingestRating(service, app: app, observedAt: start.addingTimeInterval(86_400), count: 101, in: context)
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<RatingHistoryChunk>()) == 1)
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

    @Test
    func compactedPageLayoutReopensWithUnchangedHistoryAndWAL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-PageLayout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let expected = try autoreleasepool {
            let schema = ModelContainerFactory.schema
            let container = try ModelContainer(for: schema, migrationPlan: OpenASOMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(makeRating(day: "2026-01-01", observedAt: .now, app: nil))
            context.insert(makeRating(day: "2026-01-02", observedAt: .now, app: nil))
            try context.save()
            try PersistentHistoryMaintenance.prune(in: context)
            return try RatingHistoryStore.fetch(appStoreIDs: [42], in: context)
        }
        try PersistentStoreCompactor.compact(at: url)
        #expect(try databasePragma("page_size", at: url) == "16384")
        let actual = try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
            return try RatingHistoryStore.fetch(appStoreIDs: [42], in: ModelContext(container))
        }
        #expect(actual == expected)
        #expect(try databasePragma("page_size", at: url) == "16384")
        #expect(try databasePragma("journal_mode", at: url) == "wal")
    }

    private func databasePragma(_ name: String, at url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA " + name, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw CocoaError(.fileReadUnknown)
        }
        return String(cString: value)
    }

    @Test
    func ingestionKeepsOneLiveDayAndCorrectsArchivesWithoutMaintenance() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let app = StoreApp(appStoreID: 42, bundleID: "example", name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        context.insert(app)
        let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
        let start = try Date("2026-01-01T15:00:00Z", strategy: .iso8601)
        for offset in 0..<3 {
            try ingestRating(service, app: app, observedAt: start.addingTimeInterval(Double(offset) * 86_400),
                             count: offset == 0 ? 100 : 200, in: context)
            try context.save()
        }
        let expected = try RatingHistoryStore.fetch(appStoreIDs: [42], in: context)
        #expect(expected.count == 3) // Equal values on different days remain distinct history.
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
        let chunk = try #require(try context.fetch(FetchDescriptor<RatingHistoryChunk>()).first)
        #expect(chunk.recordCount == 2)
        #expect(expected.first { $0.ratingDate == "2026-01-01" }?.fiveStarRatingCount == 90)

        try ingestRating(service, app: app, observedAt: start.addingTimeInterval(3_600), count: 150, in: context)
        try context.save()
        let corrected = try RatingHistoryStore.fetch(appStoreIDs: [42], in: context)
        #expect(corrected.count == 3)
        #expect(corrected.first { $0.ratingDate == "2026-01-01" }?.ratingCount == 150)
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
        #expect(chunk.recordCount == 2)
        #expect(try context.fetch(FetchDescriptor<LatestAppRating>()).first?.ratingCount == 200)
        let digest = chunk.digest
        try ingestRating(service, app: app, observedAt: start, count: 99, in: context)
        #expect(!context.hasChanges)
        #expect(chunk.digest == digest)
        try ingestRating(service, app: app, observedAt: start.addingTimeInterval(3_600), count: 150, in: context)
        #expect(!context.hasChanges)
        #expect(chunk.digest == digest)
    }

    @Test
    func backfillAndYearRolloverStayCompactAndRollbackRetainsHistory() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        context.insert(app)
        let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
        let start = try Date("2026-12-31T15:00:00Z", strategy: .iso8601)
        for offset in [0, -1, 1, 2] {
            try ingestRating(service, app: app, observedAt: start.addingTimeInterval(Double(offset) * 86_400),
                             count: 100 + offset, in: context)
        }
        try context.save()
        let before = try RatingHistoryStore.fetch(appStoreIDs: [42], in: context)
        #expect(before.count == 4)
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
        let chunks = try context.fetch(FetchDescriptor<RatingHistoryChunk>())
        #expect(Set(chunks.map(\.year)) == ["2026", "2027"])
        #expect(chunks.reduce(0) { $0 + $1.recordCount } == 3)
        try ingestRating(service, app: app, observedAt: start.addingTimeInterval(3 * 86_400), count: 999, in: context)
        context.rollback()
        #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: context) == before)
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
    }

    @Test
    func completedMigrationNeverRestartsAnArchivalScan() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            context.insert(makeRating(day: "2026-01-01", observedAt: .now, app: nil))
            context.insert(makeRating(day: "2026-01-02", observedAt: .now, app: nil))
            try context.save()
            try StorageSchemaV7Migrator.migrateIfNeeded(at: url)
            let migrated = ModelContext(container)
            let state = try #require(try migrated.fetch(FetchDescriptor<StorageMigrationState>()).first)
            let completion = state.lastMaintenanceAt
            let cursor = state.lastIdentityKey
            let count = state.archivedRecordCount
            // A deliberately raw insert detects accidental rescanning, independently of ingestion.
            migrated.insert(makeRating(day: "2026-01-03", observedAt: .now, app: nil))
            try migrated.save()
            try StorageSchemaV7Migrator.migrateIfNeeded(at: url, now: .now.addingTimeInterval(366 * 86_400))
            let reread = ModelContext(container)
            let completed = try #require(try reread.fetch(FetchDescriptor<StorageMigrationState>()).first)
            #expect(completed.completed)
            #expect(completed.lastMaintenanceAt == completion)
            #expect(completed.lastIdentityKey == cursor)
            #expect(completed.archivedRecordCount == count)
            #expect(try reread.fetchCount(FetchDescriptor<AppDailyRating>()) == 2)
        }
    }

    @Test
    func ingestionPreservesLongHistoriesAndStorefrontIsolation() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        context.insert(app)
        let start = try Date("2024-01-01T15:00:00Z", strategy: .iso8601)
        var observations: [RatingHistoryStore.Observation] = []
        for day in 0..<800 {
            for storefront in ["gb", "us"] {
                observations.append(.init(.init(appStoreID: 42, storefront: storefront,
                    ratingCount: day, averageRating: 4.5, ratingCounts: nil,
                    observedAt: start.addingTimeInterval(Double(day) * 86_400), source: .iTunesSearch)))
            }
        }
        try RatingHistoryStore.ingest(observations, storeApps: [42: app], in: context)
        try context.save()
        let records = try RatingHistoryStore.fetch(appStoreIDs: [42], in: context)
        #expect(records.count == 1_600)
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 2)
        #expect(try context.fetch(FetchDescriptor<RatingHistoryChunk>()).reduce(0) { $0 + $1.recordCount } == 1_598)
        #expect(Set(records.filter { $0.storefront == "gb" }.compactMap(\.ratingCount)) == Set(0..<800))
        #expect(records.allSatisfy { $0.storeAppID == 42 && $0.sourceRaw == AppStorefrontSource.iTunesSearch.rawValue })
    }

    @Test
    func corruptArchiveRejectsRolloverBeforeReplacingLiveHistory() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        context.insert(app)
        let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
        let start = try Date("2026-01-01T15:00:00Z", strategy: .iso8601)
        try ingestRating(service, app: app, observedAt: start, count: 100, in: context)
        let corrupt = RatingHistoryChunk(appStoreID: 42, storefront: "gb", year: "2026")
        corrupt.recordCount = 1
        corrupt.payload = Data([1, 2, 3])
        context.insert(corrupt)
        try context.save()
        #expect(throws: (any Error).self) {
            try ingestRating(service, app: app, observedAt: start.addingTimeInterval(86_400), count: 200, in: context)
        }
        context.rollback()
        let live = try #require(try context.fetch(FetchDescriptor<AppDailyRating>()).first)
        #expect(live.ratingDate == "2026-01-01")
        #expect(live.ratingCount == 100)
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
        #expect(try context.fetch(FetchDescriptor<LatestAppRating>()).first?.observedAt == start)
    }

    @Test
    func reopeningCompletedUpgradeDoesNotScanEvenWithAnOldCompletionDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-NoRescan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
            let context = ModelContext(container)
            let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
            state.lastMaintenanceAt = .distantPast
            for day in ["2026-01-01", "2026-01-02"] {
                context.insert(makeRating(day: day, observedAt: .now, app: nil))
            }
            try context.save()
        }
        try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
            let context = ModelContext(container)
            let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
            #expect(state.lastMaintenanceAt == .distantPast)
            #expect(state.completed && !state.needsCompaction)
            #expect(try context.fetchCount(FetchDescriptor<RatingHistoryChunk>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 2)
        }
    }

    @Test
    func ingestionRejectsAnUnupgradedSchemaBeforeChangingRows() throws {
        let schema = Schema(versionedSchema: OpenASOSchemaV6.self)
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        context.insert(app)
        let original = makeRating(day: "2026-01-01", observedAt: .now, app: app)
        context.insert(original)
        try context.save()
        let before = RatingHistoryRecord(original)
        let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
        let nextDay = try Date("2026-01-02T15:00:00Z", strategy: .iso8601)
        #expect(throws: RatingHistoryError.self) {
            try ingestRating(service, app: app, observedAt: nextDay, count: 200, in: context)
        }
        #expect(!context.hasChanges)
        #expect(RatingHistoryRecord(original) == before)
    }

    @Test
    func independentWorkersPreserveOverlappingHistoricalCorrectionsAndRollover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-WriterRace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let container = try ModelContainerFactory.makePersistentModelContainer(at: url)
        let otherContainer = try ModelContainerFactory.makePersistentModelContainer(at: url)
        let seed = ModelContext(container)
        let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        seed.insert(app)
        let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
        let start = try Date("2026-01-01T15:00:00Z", strategy: .iso8601)
        for day in 0..<3 {
            try ingestRating(service, app: app, observedAt: start.addingTimeInterval(Double(day) * 86_400),
                             count: 100 + day, in: seed)
        }
        try seed.save()
        let first = BackgroundModelStore(modelContainer: container)
        let second = BackgroundModelStore(modelContainer: otherContainer)
        for _ in 0..<3 {
            async let firstWrite: Void = first.write { context in
                let app = try #require(try context.fetch(FetchDescriptor<StoreApp>()).first)
                try RatingHistoryStore.ingest([.init(.init(appStoreID: 42, storefront: "gb",
                    ratingCount: 111, averageRating: 4.5, ratingCounts: nil,
                    observedAt: start.addingTimeInterval(3_600), source: .iTunesSearch))],
                    storeApps: [42: app], in: context)
            }
            async let secondWrite: Void = second.write { context in
                let app = try #require(try context.fetch(FetchDescriptor<StoreApp>()).first)
                try RatingHistoryStore.ingest([
                    .init(.init(appStoreID: 42, storefront: "gb", ratingCount: 222, averageRating: 4.5,
                        ratingCounts: nil, observedAt: start.addingTimeInterval(86_400 + 3_600), source: .iTunesSearch)),
                    .init(.init(appStoreID: 42, storefront: "gb", ratingCount: 104, averageRating: 4.5,
                        ratingCounts: nil, observedAt: start.addingTimeInterval(3 * 86_400), source: .iTunesSearch))
                ], storeApps: [42: app], in: context)
            }
            _ = try await (firstWrite, secondWrite)
        }
        let history = try RatingHistoryStore.fetch(appStoreIDs: [42], in: ModelContext(container))
        #expect(history.count == 4)
        #expect(history.first { $0.ratingDate == "2026-01-01" }?.ratingCount == 111)
        #expect(history.first { $0.ratingDate == "2026-01-02" }?.ratingCount == 222)
        #expect(history.first { $0.ratingDate == "2026-01-03" }?.ratingCount == 102)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
    }

    @Test
    func explicitClearRemovesLiveAndArchivedRatingsTogether() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        context.insert(app)
        let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
        let start = try Date("2026-01-01T15:00:00Z", strategy: .iso8601)
        for day in 0..<3 {
            try ingestRating(service, app: app, observedAt: start.addingTimeInterval(Double(day) * 86_400),
                             count: 100 + day, in: context)
        }
        try context.save()
        try service.persist(.init(storefront: "gb", result: nil, error: nil, clearsStoredRatings: true),
                            for: app, in: context)
        try context.save()
        #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: context).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LatestAppRating>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RatingHistoryChunk>()) == 0)
    }

    @Test
    func migrationRejectsZeroCountExistingArchiveInsteadOfReplacingItsHistory() throws {
        try withTestStore { container, url in
            let context = ModelContext(container)
            let prior = makeRating(day: "2026-01-01", observedAt: Date(timeIntervalSince1970: 100), app: nil)
            let chunk = RatingHistoryChunk(appStoreID: 42, storefront: "gb", year: "2026")
            try RatingHistoryStore.replace([RatingHistoryRecord(prior)], in: chunk)
            let payload = chunk.payload
            chunk.recordCount = 0 // Corrupt metadata must never mean an existing archive is empty.
            context.insert(chunk)
            context.insert(makeRating(day: "2026-01-02", observedAt: .now, app: nil))
            context.insert(makeRating(day: "2026-01-03", observedAt: .now, app: nil))
            try context.save()
            #expect(throws: (any Error).self) { try StorageSchemaV7Migrator.migrateIfNeeded(at: url) }
            let reread = ModelContext(container)
            #expect(try reread.fetchCount(FetchDescriptor<AppDailyRating>()) == 2)
            #expect(try reread.fetch(FetchDescriptor<RatingHistoryChunk>()).first?.payload == payload)
        }
    }

    @Test
    func waitingClientRejectsAnUnfinishedUpgradeAndLaterResumePreservesHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-UnfinishedOwner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let expected = try autoreleasepool {
            let owner = try ModelContainerFactory.makePersistentModelContainer(at: url)
            let context = ModelContext(owner)
            let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
            state.completed = false
            state.needsCompaction = true
            let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
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
            #expect(try ModelContext(owner).fetch(FetchDescriptor<StorageMigrationState>()).first?.pendingDeletionPayload != nil)
            // Shared access must not turn an unfinished migration into a ready app.
            #expect(throws: PersistentStoreError.self) {
                _ = try ModelContainerFactory.makePersistentModelContainer(at: url)
            }
            return expected
        }
        let reopened = try ModelContainerFactory.makePersistentModelContainer(at: url)
        let context = ModelContext(reopened)
        #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: context) == expected)
        #expect(try context.fetch(FetchDescriptor<StorageMigrationState>()).first?.completed == true)
        #expect(try context.fetchCount(FetchDescriptor<AppDailyRating>()) == 1)
    }

    @Test(arguments: ["cocoa", "underlyingSQLite", "metadataSQLite"])
    func diskFullDuringOptionalCompactionStillOpensVerifiedHistoryAndRetriesLater(errorRepresentation: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-CompactionDiskFull-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let expected = try autoreleasepool {
            let schema = Schema(versionedSchema: OpenASOSchemaV6.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let records = [makeRating(day: "2026-01-01", observedAt: .now, app: nil),
                           makeRating(day: "2026-01-02", observedAt: .now, app: nil)]
            for record in records { context.insert(record) }
            try context.save()
            return records.map(RatingHistoryRecord.init).sorted { $0.identityKey < $1.identityKey }
        }
        let completion = try autoreleasepool {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: url, compactStore: { _ in
                if errorRepresentation == "metadataSQLite" {
                    throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                                  userInfo: ["NSSQLiteErrorDomain": Int(SQLITE_FULL)])
                }
                if errorRepresentation == "underlyingSQLite" {
                    throw NSError(domain: NSCocoaErrorDomain, code: 134070, userInfo: [
                        NSUnderlyingErrorKey: NSError(domain: "NSSQLiteErrorDomain", code: Int(SQLITE_FULL))
                    ])
                }
                throw CocoaError(.fileWriteOutOfSpace)
            })
            let context = ModelContext(container)
            #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: context).sorted { $0.identityKey < $1.identityKey } == expected)
            let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
            #expect(state.completed && state.needsCompaction)
            return state.lastMaintenanceAt
        }
        let reopened = try ModelContainerFactory.makePersistentModelContainer(at: url)
        let context = ModelContext(reopened)
        let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
        #expect(state.completed && !state.needsCompaction)
        #expect(state.lastMaintenanceAt == completion)
        #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: context).sorted { $0.identityKey < $1.identityKey } == expected)
    }

    @Test
    func longLivedReaderSeesAnotherWorkersHistoricalCorrectionAndRollover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-ReaderUpdates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let firstContainer = try ModelContainerFactory.makePersistentModelContainer(at: url)
        let secondContainer = try ModelContainerFactory.makePersistentModelContainer(at: url)
        let seed = ModelContext(firstContainer)
        let app = StoreApp(appStoreID: 42, bundleID: nil, name: "App", sellerName: nil,
                           iconURLString: nil, defaultPlatform: .iphone)
        seed.insert(app)
        let service = AppStorefrontRatingService(httpClient: PreviewHTTPClient())
        let start = try Date("2026-01-01T15:00:00Z", strategy: .iso8601)
        for day in 0..<3 {
            try ingestRating(service, app: app, observedAt: start.addingTimeInterval(Double(day) * 86_400),
                             count: 100 + day, in: seed)
        }
        try seed.save()
        let reader = BackgroundModelStore(modelContainer: firstContainer)
        let writer = BackgroundModelStore(modelContainer: secondContainer)
        let before = try await reader.read { try RatingHistoryStore.fetch(appStoreIDs: [42], in: $0) }
        #expect(before.count == 3)
        try await writer.write { context in
            let app = try #require(try context.fetch(FetchDescriptor<StoreApp>()).first)
            try RatingHistoryStore.ingest([
                .init(.init(appStoreID: 42, storefront: "gb", ratingCount: 111, averageRating: 4.5,
                    ratingCounts: nil, observedAt: start.addingTimeInterval(3_600), source: .iTunesSearch)),
                .init(.init(appStoreID: 42, storefront: "gb", ratingCount: 103, averageRating: 4.5,
                    ratingCounts: nil, observedAt: start.addingTimeInterval(3 * 86_400), source: .iTunesSearch))
            ], storeApps: [42: app], in: context)
        }
        let after = try await reader.read { try RatingHistoryStore.fetch(appStoreIDs: [42], in: $0) }
        #expect(after.count == 4)
        #expect(after.first { $0.ratingDate == "2026-01-01" }?.ratingCount == 111)
        #expect(after.first { $0.ratingDate == "2026-01-04" }?.ratingCount == 103)
        #expect(after.allSatisfy { $0.storeAppID == 42 })
    }

    @Test(arguments: [false, true])
    func optionalCompactionNeverSuppressesCorruptionErrors(sqliteMetadata: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenASO-CompactionCorruption-\(UUID())")
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
        #expect(throws: PersistentStoreError.self) {
            _ = try ModelContainerFactory.makePersistentModelContainer(at: url, compactStore: { _ in
                if sqliteMetadata {
                    throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                                  userInfo: ["NSSQLiteErrorDomain": Int(SQLITE_CORRUPT)])
                }
                throw CocoaError(.fileReadCorruptFile)
            })
        }
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        #expect(try RatingHistoryStore.fetch(appStoreIDs: [42], in: context).count == 2)
        let state = try #require(try context.fetch(FetchDescriptor<StorageMigrationState>()).first)
        #expect(state.completed && state.needsCompaction)
    }

    private func ingestRating(_ service: AppStorefrontRatingService, app: StoreApp, observedAt: Date,
                              count: Int, in context: ModelContext) throws {
        try service.persist(.init(storefront: "gb", result: .init(
            appStoreID: app.appStoreID, storefront: "gb", ratingCount: count, averageRating: 4.5,
            ratingCounts: .init(oneStar: 1, twoStar: 2, threeStar: 3, fourStar: 4, fiveStar: 90),
            observedAt: observedAt, source: .iTunesSearch), error: nil), for: app, in: context)
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
