import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchProjectCopyServiceTests {
    private let projectDate = Date(timeIntervalSinceReferenceDate: 806_400_000)
    private let targetDate = Date(timeIntervalSinceReferenceDate: 806_400_100)
    private let copyDate = Date(timeIntervalSinceReferenceDate: 806_400_200)

    @Test
    func targetPagesValidateBoundsAndPreviewReportsCompatibilityAndDuplicates() async throws {
        let fixture = try makeFixture()
        let seeded = try await seedProject(
            in: fixture,
            bundleID: "Com.Example.Match",
            keywords: [
                KeywordSeed(term: "focus timer", notes: "keep focus"),
                KeywordSeed(term: "deep work", storefront: "gb", platform: .ipad)
            ]
        )
        try await seedTarget(
            appStoreID: 102,
            bundleID: "com.example.match",
            name: "Matching",
            createdAt: targetDate,
            in: fixture.backgroundStore
        )
        try await seedTarget(
            appStoreID: 101,
            bundleID: "com.example.other",
            name: "Mismatch",
            createdAt: targetDate,
            in: fixture.backgroundStore
        )
        try await seedTarget(
            appStoreID: 103,
            bundleID: nil,
            name: "Unavailable",
            createdAt: targetDate.addingTimeInterval(1),
            in: fixture.backgroundStore
        )
        _ = try await seedExistingTrack(
            targetAppStoreID: 102,
            keyword: seeded.keywords[0],
            createdAt: targetDate.addingTimeInterval(10),
            in: fixture.backgroundStore
        )

        let firstPage = try await fixture.service.listTargets(offset: 0, limit: 2)
        let finalPage = try await fixture.service.listTargets(
            offset: try #require(firstPage.nextOffset),
            limit: 2
        )
        #expect(firstPage.items.map(\.appStoreID) == [101, 102])
        #expect(firstPage.nextOffset == 2)
        #expect(finalPage.items.map(\.appStoreID) == [103])
        #expect(finalPage.nextOffset == nil)

        await #expect(throws: KeywordResearchProjectCopyError.invalidOffset) {
            _ = try await fixture.service.listTargets(offset: -1, limit: 1)
        }
        await #expect(throws: KeywordResearchProjectCopyError.invalidOffset) {
            _ = try await fixture.service.listTargets(offset: Int.max, limit: 1)
        }
        for invalidLimit in [0, KeywordResearchProjectCopyService.maximumTargetPageLimit + 1] {
            await #expect(throws: KeywordResearchProjectCopyError.invalidLimit) {
                _ = try await fixture.service.listTargets(offset: 0, limit: invalidLimit)
            }
        }
        await #expect(throws: KeywordResearchProjectCopyError.targetNotFound(999)) {
            _ = try await fixture.service.preview(
                projectRevision: seeded.project.revision,
                targetAppStoreID: 999
            )
        }

        let matching = try await fixture.service.preview(
            projectRevision: seeded.project.revision,
            targetAppStoreID: 102
        )
        let mismatch = try await fixture.service.preview(
            projectRevision: seeded.project.revision,
            targetAppStoreID: 101
        )
        let unavailable = try await fixture.service.preview(
            projectRevision: seeded.project.revision,
            targetAppStoreID: 103
        )

        #expect(matching.bundleCompatibility == .matches)
        #expect(matching.totalKeywordCount == 2)
        #expect(matching.additionCount == 1)
        #expect(matching.duplicateCount == 1)
        #expect(matching.items.map(\.disposition) == [.alreadyPresent, .add])
        #expect(mismatch.bundleCompatibility == .mismatch)
        #expect(unavailable.bundleCompatibility == .unavailable)
    }

    @Test
    func maximumSizedProjectCopiesAllFiveHundredMemberships() async throws {
        let fixture = try makeFixture()
        let generation = try await seedMaximumSizedProject(in: fixture.backgroundStore)
        let project = try await fixture.projectStore.loadProject(generation: generation)
        try await seedTarget(
            appStoreID: 149,
            createdAt: targetDate,
            in: fixture.backgroundStore
        )

        let preview = try await fixture.service.preview(
            projectRevision: project.revision,
            targetAppStoreID: 149
        )
        #expect(preview.totalKeywordCount == 500)
        #expect(preview.additionCount == 500)

        let result = try await fixture.service.copy(preview: preview)
        #expect(result.insertedCount == 500)
        #expect(result.alreadyPresentCount == 0)
        #expect(try await trackCount(in: fixture.backgroundStore) == 500)
        #expect(try await targetTrackIdentities(
            appStoreID: 149,
            in: fixture.backgroundStore
        ).count == 500)
    }

    @Test
    func invalidSharedQueriesFailBeforeCopyAndAppServicesWireTheExactService() async throws {
        let missingFixture = try makeFixture()
        let missingSeed = try await seedProject(
            in: missingFixture,
            keywords: [KeywordSeed(term: "missing query")]
        )
        try await seedTarget(
            appStoreID: 150,
            createdAt: targetDate,
            in: missingFixture.backgroundStore
        )
        try await deleteQuery(
            queryKey: missingSeed.keywords[0].queryKey,
            in: missingFixture.backgroundStore
        )
        await #expect(throws: KeywordResearchProjectCopyError.sharedQueryNotFound(
            missingSeed.keywords[0].queryKey
        )) {
            _ = try await missingFixture.service.preview(
                projectRevision: missingSeed.project.revision,
                targetAppStoreID: 150
            )
        }
        #expect(try await trackCount(in: missingFixture.backgroundStore) == 0)

        let mismatchFixture = try makeFixture()
        let mismatchSeed = try await seedProject(
            in: mismatchFixture,
            keywords: [KeywordSeed(term: "mismatched query")]
        )
        try await seedTarget(
            appStoreID: 151,
            createdAt: targetDate,
            in: mismatchFixture.backgroundStore
        )
        try await mutateQueryTerm(
            queryKey: mismatchSeed.keywords[0].queryKey,
            term: "corrupted term",
            in: mismatchFixture.backgroundStore
        )
        await #expect(throws: KeywordResearchProjectCopyError.sharedQueryMismatch(
            mismatchSeed.keywords[0].queryKey
        )) {
            _ = try await mismatchFixture.service.preview(
                projectRevision: mismatchSeed.project.revision,
                targetAppStoreID: 151
            )
        }
        #expect(try await trackCount(in: mismatchFixture.backgroundStore) == 0)

        let injectedService = KeywordResearchProjectCopyService(
            backgroundModelStore: mismatchFixture.backgroundStore
        )
        let client = MockHTTPClient { request in
            throw OpenASOError.providerUnavailable(
                "Unexpected request to \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        let injectedServices = AppServices(
            httpClient: client,
            defaults: UserDefaults(
                suiteName: "OpenASO-Research-Copy-Injected-\(UUID().uuidString)"
            ) ?? .standard,
            keychain: InMemoryKeychainService(),
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false,
            keywordResearchProjectCopyService: injectedService,
            providerRequestGateMode: .disabled
        )
        #expect(injectedServices.keywordResearchProjectCopyService === injectedService)

        let automaticServices = AppServices(
            httpClient: client,
            defaults: UserDefaults(
                suiteName: "OpenASO-Research-Copy-Automatic-\(UUID().uuidString)"
            ) ?? .standard,
            keychain: InMemoryKeychainService(),
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false,
            backgroundModelStore: mismatchFixture.backgroundStore,
            providerRequestGateMode: .disabled
        )
        #expect(automaticServices.keywordResearchProjectCopyService != nil)
    }

    @Test
    func copyPreservesProjectDuplicateAndSharedEvidenceWithoutCreatingTrackedState() async throws {
        let fixture = try makeFixture()
        let seeded = try await seedProject(
            in: fixture,
            bundleID: "com.example.target",
            keywords: [
                KeywordSeed(term: "existing", notes: "project duplicate notes"),
                KeywordSeed(term: "new keyword", notes: "copied notes")
            ]
        )
        try await seedTarget(
            appStoreID: 200,
            bundleID: "com.example.target",
            name: "Target",
            createdAt: targetDate,
            in: fixture.backgroundStore
        )
        let existingIdentity = try await seedExistingTrack(
            targetAppStoreID: 200,
            keyword: seeded.keywords[0],
            createdAt: targetDate.addingTimeInterval(10),
            populated: true,
            in: fixture.backgroundStore
        )
        try await seedSharedEvidence(
            queryKey: seeded.keywords[1].queryKey,
            in: fixture.backgroundStore
        )
        let projectBefore = try await fixture.projectStore.loadProject(
            generation: seeded.project.generation
        )
        let keywordsBefore = try await fixture.projectStore.listKeywords(
            in: seeded.project.generation
        )
        let evidenceBefore = try await evidenceState(in: fixture.backgroundStore)
        let graphBefore = try await trackedState(in: fixture.backgroundStore)

        let preview = try await fixture.service.preview(
            projectRevision: seeded.project.revision,
            targetAppStoreID: 200
        )
        let result = try await fixture.service.copy(preview: preview)

        #expect(result.totalKeywordCount == 2)
        #expect(result.insertedCount == 1)
        #expect(result.alreadyPresentCount == 1)
        #expect(result.alreadyPresentTrackIdentityKeys == [existingIdentity])
        #expect(result.convergedCompletedCopy == false)
        #expect(try await fixture.projectStore.loadProject(
            generation: seeded.project.generation
        ) == projectBefore)
        #expect(try await fixture.projectStore.listKeywords(
            in: seeded.project.generation
        ) == keywordsBefore)
        #expect(try await evidenceState(in: fixture.backgroundStore) == evidenceBefore)

        let graphAfter = try await trackedState(in: fixture.backgroundStore)
        #expect(graphAfter.trackIdentityKeys.count == graphBefore.trackIdentityKeys.count + 1)
        #expect(graphAfter.snapshotKeys == graphBefore.snapshotKeys)
        #expect(graphAfter.statusTrackKeys == graphBefore.statusTrackKeys)
        #expect(graphAfter.attemptTrackKeys == graphBefore.attemptTrackKeys)
        #expect(graphAfter.legacyStatusByTrack[existingIdentity] == "existing legacy status")

        let newIdentity = try #require(result.insertedTrackIdentityKeys.first)
        #expect(graphAfter.notesByTrack[newIdentity] == "copied notes")
        #expect(graphAfter.createdAtByTrack[newIdentity] == copyDate)
        #expect(graphAfter.queryKeyByTrack[newIdentity] == seeded.keywords[1].queryKey)
        #expect(graphAfter.rankingCountByTrack[newIdentity] == nil)
        #expect(graphAfter.lastRefreshByTrack[newIdentity] == nil)
        #expect(graphAfter.legacyStatusByTrack[newIdentity] == nil)
    }

    @Test
    func staleProjectTargetAndPartialDestinationChangesAreRejectedWithoutExtraWrites() async throws {
        let projectFixture = try makeFixture()
        let projectSeed = try await seedProject(
            in: projectFixture,
            keywords: [KeywordSeed(term: "stale project")]
        )
        try await seedTarget(appStoreID: 300, createdAt: targetDate, in: projectFixture.backgroundStore)
        let projectPreview = try await projectFixture.service.preview(
            projectRevision: projectSeed.project.revision,
            targetAppStoreID: 300
        )
        _ = try await projectFixture.projectStore.updateProject(
            revision: projectSeed.project.revision,
            name: "Changed",
            defaultStorefront: "us",
            defaultPlatform: .iphone
        )
        await #expect(throws: KeywordResearchProjectStoreError.staleProjectRevision(
            projectSeed.project.id
        )) {
            _ = try await projectFixture.service.copy(preview: projectPreview)
        }
        #expect(try await trackCount(in: projectFixture.backgroundStore) == 0)

        let targetFixture = try makeFixture()
        let targetSeed = try await seedProject(
            in: targetFixture,
            keywords: [KeywordSeed(term: "stale target")]
        )
        try await seedTarget(appStoreID: 301, name: "Before", createdAt: targetDate, in: targetFixture.backgroundStore)
        let targetPreview = try await targetFixture.service.preview(
            projectRevision: targetSeed.project.revision,
            targetAppStoreID: 301
        )
        try await mutateTargetName(appStoreID: 301, name: "After", in: targetFixture.backgroundStore)
        await #expect(throws: KeywordResearchProjectCopyError.staleTarget(301)) {
            _ = try await targetFixture.service.copy(preview: targetPreview)
        }
        #expect(try await trackCount(in: targetFixture.backgroundStore) == 0)

        let destinationFixture = try makeFixture()
        let destinationSeed = try await seedProject(
            in: destinationFixture,
            keywords: [KeywordSeed(term: "one"), KeywordSeed(term: "two")]
        )
        try await seedTarget(appStoreID: 302, createdAt: targetDate, in: destinationFixture.backgroundStore)
        let destinationPreview = try await destinationFixture.service.preview(
            projectRevision: destinationSeed.project.revision,
            targetAppStoreID: 302
        )
        let externalIdentity = try await seedExistingTrack(
            targetAppStoreID: 302,
            keyword: destinationSeed.keywords[0],
            createdAt: targetDate.addingTimeInterval(10),
            in: destinationFixture.backgroundStore
        )
        await #expect(throws: KeywordResearchProjectCopyError.stalePreview) {
            _ = try await destinationFixture.service.copy(preview: destinationPreview)
        }
        #expect(try await trackIdentities(in: destinationFixture.backgroundStore) == [externalIdentity])

        let convergedFixture = try makeFixture()
        let convergedSeed = try await seedProject(
            in: convergedFixture,
            keywords: [KeywordSeed(term: "foreign one"), KeywordSeed(term: "foreign two")]
        )
        try await seedTarget(
            appStoreID: 303,
            createdAt: targetDate,
            in: convergedFixture.backgroundStore
        )
        let convergedPreview = try await convergedFixture.service.preview(
            projectRevision: convergedSeed.project.revision,
            targetAppStoreID: 303
        )
        for keyword in convergedSeed.keywords {
            _ = try await seedExistingTrack(
                targetAppStoreID: 303,
                keyword: keyword,
                createdAt: targetDate.addingTimeInterval(10),
                in: convergedFixture.backgroundStore
            )
        }
        await #expect(throws: KeywordResearchProjectCopyError.stalePreview) {
            _ = try await convergedFixture.service.copy(preview: convergedPreview)
        }
        #expect(try await trackCount(in: convergedFixture.backgroundStore) == 2)

        let reincarnationFixture = try makeFixture()
        let reincarnationSeed = try await seedProject(
            in: reincarnationFixture,
            keywords: [KeywordSeed(term: "same timestamp replacement")]
        )
        try await seedTarget(
            appStoreID: 304,
            createdAt: targetDate,
            in: reincarnationFixture.backgroundStore
        )
        let reincarnationPreview = try await reincarnationFixture.service.preview(
            projectRevision: reincarnationSeed.project.revision,
            targetAppStoreID: 304
        )
        try await reincarnateTarget(
            appStoreID: 304,
            createdAt: targetDate,
            in: reincarnationFixture.backgroundStore
        )
        await #expect(throws: KeywordResearchProjectCopyError.staleTarget(304)) {
            _ = try await reincarnationFixture.service.copy(preview: reincarnationPreview)
        }
        #expect(try await trackCount(in: reincarnationFixture.backgroundStore) == 0)

        let metadataFixture = try makeFixture()
        let metadataSeed = try await seedProject(
            in: metadataFixture,
            keywords: [KeywordSeed(term: "metadata only")]
        )
        try await seedTarget(
            appStoreID: 305,
            createdAt: targetDate,
            in: metadataFixture.backgroundStore
        )
        let metadataPreview = try await metadataFixture.service.preview(
            projectRevision: metadataSeed.project.revision,
            targetAppStoreID: 305
        )
        try await mutateTargetMetadataTimestamp(
            appStoreID: 305,
            date: targetDate.addingTimeInterval(500),
            in: metadataFixture.backgroundStore
        )
        let metadataResult = try await metadataFixture.service.copy(preview: metadataPreview)
        #expect(metadataResult.insertedCount == 1)
    }

    @Test
    func rollbackCancellationAndConcurrentReplayRemainAtomicAndIdempotent() async throws {
        let rollbackFixture = try makeFixture { insertedCount in
            if insertedCount == 1 { throw CopyServiceTestError.injected }
        }
        let rollbackSeed = try await seedProject(
            in: rollbackFixture,
            keywords: [KeywordSeed(term: "rollback one"), KeywordSeed(term: "rollback two")]
        )
        try await seedTarget(appStoreID: 400, createdAt: targetDate, in: rollbackFixture.backgroundStore)
        let rollbackPreview = try await rollbackFixture.service.preview(
            projectRevision: rollbackSeed.project.revision,
            targetAppStoreID: 400
        )
        await #expect(throws: CopyServiceTestError.injected) {
            _ = try await rollbackFixture.service.copy(preview: rollbackPreview)
        }
        #expect(try await trackCount(in: rollbackFixture.backgroundStore) == 0)
        let recoveryCopyDate = copyDate.addingTimeInterval(1)
        let recoveryService = KeywordResearchProjectCopyService(
            backgroundModelStore: rollbackFixture.backgroundStore,
            now: { recoveryCopyDate }
        )
        let recovered = try await recoveryService.copy(preview: rollbackPreview)
        #expect(recovered.insertedCount == 2)
        #expect(try await trackIdentities(in: rollbackFixture.backgroundStore)
            == recovered.trackIdentityKeys.sorted())
        #expect(try await targetTrackIdentities(
            appStoreID: 400,
            in: rollbackFixture.backgroundStore
        ) == recovered.trackIdentityKeys.sorted())

        let cancellationFixture = try makeFixture { insertedCount in
            guard insertedCount == 1 else { return }
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        let cancellationSeed = try await seedProject(
            in: cancellationFixture,
            keywords: [KeywordSeed(term: "cancel only")]
        )
        try await seedTarget(appStoreID: 401, createdAt: targetDate, in: cancellationFixture.backgroundStore)
        let cancellationPreview = try await cancellationFixture.service.preview(
            projectRevision: cancellationSeed.project.revision,
            targetAppStoreID: 401
        )
        let cancellationService = cancellationFixture.service
        let cancellationTask = Task {
            try await cancellationService.copy(preview: cancellationPreview)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancellationTask.value }
        #expect(try await trackCount(in: cancellationFixture.backgroundStore) == 0)

        let replayFixture = try makeFixture()
        let replaySeed = try await seedProject(
            in: replayFixture,
            keywords: [KeywordSeed(term: "parallel one"), KeywordSeed(term: "parallel two")]
        )
        try await seedTarget(appStoreID: 402, createdAt: targetDate, in: replayFixture.backgroundStore)
        let replayPreview = try await replayFixture.service.preview(
            projectRevision: replaySeed.project.revision,
            targetAppStoreID: 402
        )
        let service = replayFixture.service
        let results = try await withThrowingTaskGroup(
            of: KeywordResearchProjectCopyResult.self,
            returning: [KeywordResearchProjectCopyResult].self
        ) { group in
            for _ in 0..<2 {
                group.addTask { try await service.copy(preview: replayPreview) }
            }
            var values: [KeywordResearchProjectCopyResult] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.count == 2)
        #expect(results.map(\.insertedCount).sorted() == [0, 2])
        #expect(results.filter(\.convergedCompletedCopy).count == 1)
        #expect(try await trackCount(in: replayFixture.backgroundStore) == 2)
    }

    @Test
    func completedPreviewReplaysIdempotentlyAfterPersistentStoreReopen() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenASO-Research-Copy-Reopen-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)
        let projectDate = projectDate
        let copyDate = copyDate
        var savedPreview: KeywordResearchProjectCopyPreview?

        do {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let backgroundStore = BackgroundModelStore(modelContainer: container)
            let fixture = CopyFixture(
                container: container,
                backgroundStore: backgroundStore,
                projectStore: KeywordResearchProjectStore(
                    backgroundModelStore: backgroundStore,
                    now: { projectDate }
                ),
                service: KeywordResearchProjectCopyService(
                    backgroundModelStore: backgroundStore,
                    now: { copyDate }
                )
            )
            let seeded = try await seedProject(
                in: fixture,
                keywords: [KeywordSeed(term: "persistent copy", notes: "persisted")]
            )
            try await seedTarget(
                appStoreID: 500,
                createdAt: targetDate,
                in: backgroundStore
            )
            let preview = try await fixture.service.preview(
                projectRevision: seeded.project.revision,
                targetAppStoreID: 500
            )
            let first = try await fixture.service.copy(preview: preview)
            #expect(first.insertedCount == 1)
            #expect(first.convergedCompletedCopy == false)
            savedPreview = preview
        }

        do {
            let container = try ModelContainerFactory.makePersistentModelContainer(at: storeURL)
            let backgroundStore = BackgroundModelStore(modelContainer: container)
            let service = KeywordResearchProjectCopyService(
                backgroundModelStore: backgroundStore,
                now: { copyDate.addingTimeInterval(1) }
            )
            let preview = try #require(savedPreview)
            let replay = try await service.copy(preview: preview)

            #expect(replay.insertedCount == 0)
            #expect(replay.alreadyPresentCount == 1)
            #expect(replay.convergedCompletedCopy)
            #expect(try await trackCount(in: backgroundStore) == 1)

            let refreshedPreview = try await service.preview(
                projectRevision: preview.project.revision,
                targetAppStoreID: 500
            )
            #expect(refreshedPreview.additionCount == 0)
            #expect(refreshedPreview.duplicateCount == 1)
            let currentNoOp = try await service.copy(preview: refreshedPreview)
            #expect(currentNoOp.insertedCount == 0)
            #expect(currentNoOp.alreadyPresentCount == 1)
            #expect(currentNoOp.convergedCompletedCopy == false)
            #expect(try await trackCount(in: backgroundStore) == 1)
        }
    }

    private func makeFixture(
        mutationCheckpoint: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) throws -> CopyFixture {
        let projectDate = projectDate
        let copyDate = copyDate
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        return CopyFixture(
            container: container,
            backgroundStore: backgroundStore,
            projectStore: KeywordResearchProjectStore(
                backgroundModelStore: backgroundStore,
                now: { projectDate }
            ),
            service: KeywordResearchProjectCopyService(
                backgroundModelStore: backgroundStore,
                now: { copyDate },
                mutationCheckpoint: mutationCheckpoint
            )
        )
    }

    private func seedProject(
        in fixture: CopyFixture,
        bundleID: String? = nil,
        keywords: [KeywordSeed]
    ) async throws -> SeededProject {
        var project = try await fixture.projectStore.createProject(
            name: "Research",
            bundleID: bundleID
        )
        var snapshots: [KeywordResearchKeywordSnapshot] = []
        for (index, seed) in keywords.enumerated() {
            let keywordID = UUID(
                uuidString: "34000000-0000-4000-8000-00000000000\(index + 1)"
            )!
            let addition = try await fixture.projectStore.addKeyword(
                id: keywordID,
                to: project.revision,
                term: seed.term,
                storefront: seed.storefront,
                platform: seed.platform,
                notes: seed.notes
            )
            project = addition.project
            snapshots.append(addition.keyword)
        }
        return SeededProject(project: project, keywords: snapshots)
    }

    private func seedMaximumSizedProject(
        in store: BackgroundModelStore
    ) async throws -> KeywordResearchProjectGeneration {
        let createdAt = projectDate
        return try await store.write { modelContext in
            let project = KeywordResearchProject(
                name: "Maximum Research",
                createdAt: createdAt
            )
            modelContext.insert(project)

            for index in 0..<KeywordResearchProjectStore.maximumKeywordCountPerProject {
                let term = String(format: "maximum keyword %03d", index)
                let query = KeywordQuery(
                    term: term,
                    storefront: "us",
                    platform: .iphone
                )
                let membership = KeywordResearchKeyword(
                    term: term,
                    storefront: "us",
                    platform: .iphone,
                    project: project,
                    notes: "note \(index)",
                    createdAt: createdAt.addingTimeInterval(Double(index))
                )
                modelContext.insert(query)
                modelContext.insert(membership)
                project.attachKeyword(membership)
            }
            return project.generation
        }
    }
}

@MainActor
private struct CopyFixture {
    let container: ModelContainer
    let backgroundStore: BackgroundModelStore
    let projectStore: KeywordResearchProjectStore
    let service: KeywordResearchProjectCopyService
}

private struct SeededProject: Sendable {
    let project: KeywordResearchProjectSnapshot
    let keywords: [KeywordResearchKeywordSnapshot]
}

private struct KeywordSeed: Sendable {
    let term: String
    let storefront: String
    let platform: AppPlatform
    let notes: String

    init(
        term: String,
        storefront: String = "us",
        platform: AppPlatform = .iphone,
        notes: String = ""
    ) {
        self.term = term
        self.storefront = storefront
        self.platform = platform
        self.notes = notes
    }
}

private enum CopyServiceTestError: Error, Equatable {
    case injected
}

private struct EvidenceState: Equatable, Sendable {
    let queryKeys: [String]
    let observationKeys: [String]
    let metricQueryKeys: [String]
}

private struct TrackedState: Equatable, Sendable {
    let trackIdentityKeys: [String]
    let notesByTrack: [String: String]
    let createdAtByTrack: [String: Date]
    let queryKeyByTrack: [String: String]
    let rankingCountByTrack: [String: Int]
    let lastRefreshByTrack: [String: Date]
    let legacyStatusByTrack: [String: String]
    let snapshotKeys: [String]
    let statusTrackKeys: [String]
    let attemptTrackKeys: [String]
}

private func seedTarget(
    appStoreID: Int64,
    bundleID: String? = "com.example.target",
    name: String = "Target",
    createdAt: Date,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let storeApp = StoreApp(
            appStoreID: appStoreID,
            bundleID: bundleID,
            name: name,
            subtitle: "Subtitle",
            sellerName: "Seller",
            iconURLString: "https://example.com/icon.png",
            defaultPlatform: .iphone,
            lastMetadataRefreshAt: createdAt
        )
        let trackedApp = TrackedApp(
            appStoreID: appStoreID,
            storeApp: storeApp,
            createdAt: createdAt
        )
        modelContext.insert(storeApp)
        modelContext.insert(trackedApp)
    }
}

private func seedExistingTrack(
    targetAppStoreID: Int64,
    keyword: KeywordResearchKeywordSnapshot,
    createdAt: Date,
    populated: Bool = false,
    in store: BackgroundModelStore
) async throws -> String {
    try await store.write { modelContext in
        let targetID = targetAppStoreID
        let queryKey = keyword.queryKey
        guard let target = try modelContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { target in
                target.appStoreID == targetID
            }
        )).first,
        let query = try modelContext.fetch(FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == queryKey
            }
        )).first else {
            throw CopyServiceTestError.injected
        }
        let track = TrackedAppKeyword(
            term: keyword.term,
            storefront: keyword.storefront,
            platform: keyword.platform,
            trackedApp: target,
            query: query,
            createdAt: createdAt
        )
        track.notes = "existing track notes"
        target.keywordTracks.append(track)
        modelContext.insert(track)
        if populated {
            track.rankingAppCount = 77
            track.lastRefreshAt = createdAt.addingTimeInterval(1)
            let snapshot = TrackedKeywordDailyRanking(
                rank: 4,
                searchedAt: createdAt.addingTimeInterval(2),
                source: .appStoreWeb,
                resultCount: 77,
                keywordTrack: track
            )
            track.snapshots.append(snapshot)
            modelContext.insert(snapshot)
            try TrackedKeywordRefreshStatusStore.set(
                "existing ranking status",
                domain: .ranking,
                for: track,
                updatedAt: createdAt.addingTimeInterval(3),
                in: modelContext
            )
            track.statusMessage = "existing legacy status"
            modelContext.insert(TrackedAppKeywordRefreshAttempt(
                trackIdentityKey: track.identityKey,
                appStoreID: targetAppStoreID,
                lastRankingRefreshAttemptAt: createdAt.addingTimeInterval(4)
            ))
        }
        return track.identityKey
    }
}

private func seedSharedEvidence(
    queryKey: String,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        guard let query = try modelContext.fetch(FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == queryKey
            }
        )).first else {
            throw CopyServiceTestError.injected
        }
        let observedAt = Date(timeIntervalSinceReferenceDate: 806_400_150)
        let crawl = RankingCrawlRecord(
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            observedAt: observedAt,
            source: .appStoreWeb,
            resultCount: 1,
            query: query
        )
        modelContext.insert(crawl)
        modelContext.insert(KeywordDailyMetric(
            queryKey: query.queryKey,
            keyword: query.term,
            storefront: query.storefront,
            platform: query.platform,
            popularityScore: 44,
            difficultyScore: nil,
            source: .appleAdsPopularity,
            updatedAt: observedAt
        ))
    }
}

private func mutateTargetName(
    appStoreID: Int64,
    name: String,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let targetID = appStoreID
        guard let target = try modelContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { target in
                target.appStoreID == targetID
            }
        )).first else { throw CopyServiceTestError.injected }
        target.name = name
    }
}

private func deleteQuery(
    queryKey: String,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let key = queryKey
        guard let query = try modelContext.fetch(FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == key
            }
        )).first else { throw CopyServiceTestError.injected }
        modelContext.delete(query)
    }
}

private func mutateQueryTerm(
    queryKey: String,
    term: String,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let key = queryKey
        guard let query = try modelContext.fetch(FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == key
            }
        )).first else { throw CopyServiceTestError.injected }
        query.term = term
    }
}

private func mutateTargetMetadataTimestamp(
    appStoreID: Int64,
    date: Date,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let targetID = appStoreID
        guard let target = try modelContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { target in
                target.appStoreID == targetID
            }
        )).first else { throw CopyServiceTestError.injected }
        target.storeApp.lastMetadataRefreshAt = date
    }
}

private func reincarnateTarget(
    appStoreID: Int64,
    createdAt: Date,
    in store: BackgroundModelStore
) async throws {
    try await store.write { modelContext in
        let targetID = appStoreID
        guard let target = try modelContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { target in
                target.appStoreID == targetID
            }
        )).first else { throw CopyServiceTestError.injected }
        modelContext.delete(target)
    }
    try await store.write { modelContext in
        let targetID = appStoreID
        guard let storeApp = try modelContext.fetch(FetchDescriptor<StoreApp>(
            predicate: #Predicate { storeApp in
                storeApp.appStoreID == targetID
            }
        )).first else { throw CopyServiceTestError.injected }
        modelContext.insert(TrackedApp(
            appStoreID: appStoreID,
            storeApp: storeApp,
            createdAt: createdAt
        ))
    }
}

private func evidenceState(in store: BackgroundModelStore) async throws -> EvidenceState {
    try await store.read { modelContext in
        EvidenceState(
            queryKeys: try modelContext.fetch(FetchDescriptor<KeywordQuery>()).map(\.queryKey).sorted(),
            observationKeys: try modelContext.fetch(FetchDescriptor<RankingCrawlRecord>())
                .map(\.observationKey).sorted(),
            metricQueryKeys: try modelContext.fetch(FetchDescriptor<KeywordDailyMetric>())
                .map(\.queryKey).sorted()
        )
    }
}

private func trackedState(in store: BackgroundModelStore) async throws -> TrackedState {
    try await store.read { modelContext in
        let tracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
        return TrackedState(
            trackIdentityKeys: tracks.map(\.identityKey).sorted(),
            notesByTrack: Dictionary(uniqueKeysWithValues: tracks.map { ($0.identityKey, $0.notes) }),
            createdAtByTrack: Dictionary(uniqueKeysWithValues: tracks.map { ($0.identityKey, $0.createdAt) }),
            queryKeyByTrack: Dictionary(uniqueKeysWithValues: tracks.map { ($0.identityKey, $0.query.queryKey) }),
            rankingCountByTrack: Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                track.rankingAppCount.map { (track.identityKey, $0) }
            }),
            lastRefreshByTrack: Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                track.lastRefreshAt.map { (track.identityKey, $0) }
            }),
            legacyStatusByTrack: Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                track.statusMessage.map { (track.identityKey, $0) }
            }),
            snapshotKeys: try modelContext.fetch(FetchDescriptor<TrackedKeywordDailyRanking>())
                .map(\.snapshotKey).sorted(),
            statusTrackKeys: try modelContext.fetch(FetchDescriptor<TrackedKeywordRefreshStatus>())
                .map(\.trackIdentityKey).sorted(),
            attemptTrackKeys: try modelContext.fetch(FetchDescriptor<TrackedAppKeywordRefreshAttempt>())
                .map(\.trackIdentityKey).sorted()
        )
    }
}

private func trackCount(in store: BackgroundModelStore) async throws -> Int {
    try await store.fetchCount(FetchDescriptor<TrackedAppKeyword>())
}

private func trackIdentities(in store: BackgroundModelStore) async throws -> [String] {
    try await store.read { modelContext in
        try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>()).map(\.identityKey).sorted()
    }
}

private func targetTrackIdentities(
    appStoreID: Int64,
    in store: BackgroundModelStore
) async throws -> [String] {
    try await store.read { modelContext in
        let targetID = appStoreID
        guard let target = try modelContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { target in
                target.appStoreID == targetID
            }
        )).first else { throw CopyServiceTestError.injected }
        return target.keywordTracks.map(\.identityKey).sorted()
    }
}
