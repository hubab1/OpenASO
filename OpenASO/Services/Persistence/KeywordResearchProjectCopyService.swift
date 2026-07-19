import Foundation
import SwiftData

struct KeywordResearchCopyTargetSnapshot: Equatable, Hashable, Identifiable, Sendable {
    /// Canonically encoded store-row identity. Direct `PersistentIdentifier`
    /// equality is container-instance-sensitive even when its durable Core
    /// Data URI is unchanged after reopening the same store.
    let persistentIdentifierToken: Data
    let appStoreID: Int64
    let createdAt: Date
    let name: String
    let bundleID: String?
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let defaultPlatform: AppPlatform

    var id: Int64 { appStoreID }
}

enum KeywordResearchBundleCompatibility: Equatable, Hashable, Sendable {
    case matches
    case mismatch
    case unavailable
}

enum KeywordResearchProjectCopyDisposition: Equatable, Hashable, Sendable {
    case add
    case alreadyPresent
}

struct KeywordResearchProjectCopyItem: Equatable, Hashable, Identifiable, Sendable {
    let keyword: KeywordResearchKeywordSnapshot
    let trackIdentityKey: String
    let disposition: KeywordResearchProjectCopyDisposition

    var id: KeywordResearchKeywordGeneration { keyword.generation }
}

struct KeywordResearchProjectCopyPreview: Equatable, Hashable, Sendable {
    let project: KeywordResearchProjectSnapshot
    let target: KeywordResearchCopyTargetSnapshot
    let bundleCompatibility: KeywordResearchBundleCompatibility
    let items: [KeywordResearchProjectCopyItem]

    var totalKeywordCount: Int { items.count }
    var additionCount: Int { items.lazy.filter { $0.disposition == .add }.count }
    var duplicateCount: Int { items.count - additionCount }
    var trackIdentityKeys: [String] { items.map(\.trackIdentityKey) }
}

struct KeywordResearchProjectCopyResult: Equatable, Sendable {
    let project: KeywordResearchProjectSnapshot
    let target: KeywordResearchCopyTargetSnapshot
    let trackIdentityKeys: [String]
    let insertedTrackIdentityKeys: [String]
    let alreadyPresentTrackIdentityKeys: [String]
    /// True when every formerly missing track already satisfied the copy
    /// postcondition before this attempt. This is semantic convergence, not a
    /// claim that a particular earlier process executed the operation.
    let convergedCompletedCopy: Bool

    var totalKeywordCount: Int { trackIdentityKeys.count }
    var insertedCount: Int { insertedTrackIdentityKeys.count }
    var alreadyPresentCount: Int { alreadyPresentTrackIdentityKeys.count }
}

enum KeywordResearchProjectCopyError: Error, Equatable, Sendable {
    case invalidOffset
    case invalidLimit
    case targetNotFound(Int64)
    case staleTarget(Int64)
    case stalePreview
    case projectKeywordLimitExceeded(maximum: Int)
    case sharedQueryNotFound(String)
    case sharedQueryMismatch(String)
    case targetTrackMismatch(String)
}

/// Previews and atomically copies a research project's current memberships to
/// one existing tracked App Store app.
///
/// The copy creates only missing `TrackedAppKeyword` rows. It keeps the
/// research project, never overwrites an existing track, points new tracks at
/// the existing shared `KeywordQuery`, and deliberately creates no tracked
/// ranking, refresh-status, or refresh-attempt history.
actor KeywordResearchProjectCopyService {
    static let maximumTargetPageLimit = 200

    private let modelStore: BackgroundModelStore
    private let now: @Sendable () -> Date
    private let mutationCheckpoint: @Sendable (_ insertedCount: Int) throws -> Void

    init(
        backgroundModelStore: BackgroundModelStore,
        now: @escaping @Sendable () -> Date = { Date() },
        mutationCheckpoint: @escaping @Sendable (_ insertedCount: Int) throws -> Void = { _ in }
    ) {
        self.modelStore = backgroundModelStore
        self.now = now
        self.mutationCheckpoint = mutationCheckpoint
    }

    func listTargets(
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> KeywordResearchPage<KeywordResearchCopyTargetSnapshot> {
        try Self.validatePagination(offset: offset, limit: limit)

        return try await modelStore.read { modelContext in
            var descriptor = FetchDescriptor<TrackedApp>(sortBy: [
                SortDescriptor(\TrackedApp.createdAt, order: .forward),
                SortDescriptor(\TrackedApp.appStoreID, order: .forward)
            ])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit + 1
            let targets = try modelContext.fetch(descriptor).map { target in
                guard target.storeApp.appStoreID == target.appStoreID else {
                    throw KeywordResearchProjectCopyError.staleTarget(target.appStoreID)
                }
                return try Self.targetSnapshot(target)
            }
            let hasMore = targets.count > limit
            let pageItems = Array(targets.prefix(limit))
            return KeywordResearchPage(
                items: pageItems,
                nextOffset: hasMore ? offset + pageItems.count : nil
            )
        }
    }

    func preview(
        projectRevision: KeywordResearchProjectRevision,
        targetAppStoreID: Int64
    ) async throws -> KeywordResearchProjectCopyPreview {
        try Task.checkCancellation()

        return try await modelStore.read { modelContext in
            try Task.checkCancellation()
            let project = try Self.requireProject(
                revision: projectRevision,
                in: modelContext
            )
            let target = try Self.requireTarget(
                appStoreID: targetAppStoreID,
                in: modelContext
            )
            let keywords = try Self.requireBoundedKeywords(
                projectID: project.id,
                in: modelContext
            )
            _ = try Self.requireQueries(for: keywords, in: modelContext)

            let identityKeys = keywords.map {
                TrackedAppKeyword.makeIdentityKey(
                    appStoreID: target.appStoreID,
                    term: $0.term,
                    storefront: $0.storefront,
                    platform: $0.platform
                )
            }
            let existingTracks = try Self.requireTargetTracks(
                target: target,
                identityKeys: identityKeys,
                in: modelContext
            )
            let existingIdentityKeys = Set(existingTracks.map(\.identityKey))
            let projectSnapshot = Self.projectSnapshot(project)
            let targetSnapshot = try Self.targetSnapshot(target)

            return KeywordResearchProjectCopyPreview(
                project: projectSnapshot,
                target: targetSnapshot,
                bundleCompatibility: Self.bundleCompatibility(
                    projectBundleID: projectSnapshot.bundleID,
                    targetBundleID: targetSnapshot.bundleID
                ),
                items: zip(keywords, identityKeys).map { keyword, identityKey in
                    KeywordResearchProjectCopyItem(
                        keyword: Self.keywordSnapshot(keyword),
                        trackIdentityKey: identityKey,
                        disposition: existingIdentityKeys.contains(identityKey)
                            ? .alreadyPresent
                            : .add
                    )
                }
            )
        }
    }

    func copy(
        preview: KeywordResearchProjectCopyPreview
    ) async throws -> KeywordResearchProjectCopyResult {
        try Task.checkCancellation()
        let now = now
        let mutationCheckpoint = mutationCheckpoint

        return try await modelStore.write { modelContext in
            try Task.checkCancellation()
            let project = try Self.requireProject(
                revision: preview.project.revision,
                in: modelContext
            )
            guard Self.projectSnapshot(project) == preview.project else {
                throw KeywordResearchProjectCopyError.stalePreview
            }

            let target = try Self.requireTarget(
                appStoreID: preview.target.appStoreID,
                in: modelContext
            )
            let currentTargetSnapshot = try Self.targetSnapshot(target)
            guard Self.sameTargetGeneration(currentTargetSnapshot, preview.target) else {
                throw KeywordResearchProjectCopyError.staleTarget(target.appStoreID)
            }

            let keywords = try Self.requireBoundedKeywords(
                projectID: project.id,
                in: modelContext
            )
            guard Self.matchesPreview(keywords: keywords, preview: preview) else {
                throw KeywordResearchProjectCopyError.stalePreview
            }
            let queries = try Self.requireQueries(for: keywords, in: modelContext)
            let allIdentityKeys = preview.trackIdentityKeys
            let currentTracks = try Self.requireTargetTracks(
                target: target,
                identityKeys: allIdentityKeys,
                in: modelContext
            )
            let currentIdentityKeys = Set(currentTracks.map(\.identityKey))
            let expectedIdentityKeys = Set(
                preview.items.lazy
                    .filter { $0.disposition == .alreadyPresent }
                    .map(\.trackIdentityKey)
            )
            let completeIdentityKeys = Set(allIdentityKeys)

            if currentIdentityKeys == completeIdentityKeys,
               currentIdentityKeys != expectedIdentityKeys {
                guard try Self.hasConvergedCopyPostcondition(
                    tracks: currentTracks,
                    preview: preview,
                    in: modelContext
                ) else {
                    throw KeywordResearchProjectCopyError.stalePreview
                }
                return KeywordResearchProjectCopyResult(
                    project: preview.project,
                    target: currentTargetSnapshot,
                    trackIdentityKeys: allIdentityKeys,
                    insertedTrackIdentityKeys: [],
                    alreadyPresentTrackIdentityKeys: allIdentityKeys,
                    convergedCompletedCopy: true
                )
            }
            guard currentTargetSnapshot == preview.target else {
                throw KeywordResearchProjectCopyError.staleTarget(target.appStoreID)
            }
            guard currentIdentityKeys == expectedIdentityKeys else {
                throw KeywordResearchProjectCopyError.stalePreview
            }

            var insertedIdentityKeys: [String] = []
            for item in preview.items where item.disposition == .add {
                try Task.checkCancellation()
                guard let query = queries[item.keyword.queryKey] else {
                    throw KeywordResearchProjectCopyError.sharedQueryNotFound(
                        item.keyword.queryKey
                    )
                }

                let track = TrackedAppKeyword(
                    term: item.keyword.term,
                    storefront: item.keyword.storefront,
                    platform: item.keyword.platform,
                    trackedApp: target,
                    query: query,
                    createdAt: now()
                )
                guard track.identityKey == item.trackIdentityKey else {
                    throw KeywordResearchProjectCopyError.stalePreview
                }
                track.notes = item.keyword.notes
                target.keywordTracks.append(track)
                modelContext.insert(track)
                insertedIdentityKeys.append(track.identityKey)
                try mutationCheckpoint(insertedIdentityKeys.count)
            }
            try Task.checkCancellation()

            return KeywordResearchProjectCopyResult(
                project: preview.project,
                target: preview.target,
                trackIdentityKeys: allIdentityKeys,
                insertedTrackIdentityKeys: insertedIdentityKeys,
                alreadyPresentTrackIdentityKeys: preview.items.compactMap { item in
                    item.disposition == .alreadyPresent ? item.trackIdentityKey : nil
                },
                convergedCompletedCopy: false
            )
        }
    }
}

private extension KeywordResearchProjectCopyService {
    static func validatePagination(offset: Int, limit: Int) throws {
        guard (1...maximumTargetPageLimit).contains(limit) else {
            throw KeywordResearchProjectCopyError.invalidLimit
        }
        guard offset >= 0, offset <= Int.max - limit else {
            throw KeywordResearchProjectCopyError.invalidOffset
        }
    }

    static func requireProject(
        revision: KeywordResearchProjectRevision,
        in modelContext: ModelContext
    ) throws -> KeywordResearchProject {
        let projectID = revision.generation.id
        var descriptor = FetchDescriptor<KeywordResearchProject>(
            predicate: #Predicate { project in
                project.id == projectID
            }
        )
        descriptor.fetchLimit = 1
        guard let project = try modelContext.fetch(descriptor).first else {
            throw KeywordResearchProjectStoreError.projectNotFound(projectID)
        }
        guard project.incarnationID == revision.generation.incarnationID,
              project.updatedAt == revision.updatedAt
        else {
            throw KeywordResearchProjectStoreError.staleProjectRevision(projectID)
        }
        return project
    }

    static func requireTarget(
        appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> TrackedApp {
        let targetAppStoreID = appStoreID
        var descriptor = FetchDescriptor<TrackedApp>(
            predicate: #Predicate { app in
                app.appStoreID == targetAppStoreID
            }
        )
        descriptor.fetchLimit = 1
        guard let target = try modelContext.fetch(descriptor).first else {
            throw KeywordResearchProjectCopyError.targetNotFound(appStoreID)
        }
        guard target.storeApp.appStoreID == appStoreID else {
            throw KeywordResearchProjectCopyError.staleTarget(appStoreID)
        }
        return target
    }

    static func requireBoundedKeywords(
        projectID: UUID,
        in modelContext: ModelContext
    ) throws -> [KeywordResearchKeyword] {
        let targetProjectID = projectID
        var descriptor = FetchDescriptor<KeywordResearchKeyword>(
            predicate: #Predicate { keyword in
                keyword.projectID == targetProjectID
            },
            sortBy: [
                SortDescriptor(\KeywordResearchKeyword.createdAt, order: .forward),
                SortDescriptor(\KeywordResearchKeyword.id, order: .forward)
            ]
        )
        descriptor.fetchLimit = KeywordResearchProjectStore.maximumKeywordCountPerProject + 1
        let keywords = try modelContext.fetch(descriptor)
        guard keywords.count <= KeywordResearchProjectStore.maximumKeywordCountPerProject else {
            throw KeywordResearchProjectCopyError.projectKeywordLimitExceeded(
                maximum: KeywordResearchProjectStore.maximumKeywordCountPerProject
            )
        }
        return keywords
    }

    static func requireQueries(
        for keywords: [KeywordResearchKeyword],
        in modelContext: ModelContext
    ) throws -> [String: KeywordQuery] {
        let queryKeys = Array(Set(keywords.map(\.queryKey)))
        guard !queryKeys.isEmpty else { return [:] }

        let descriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                queryKeys.contains(query.queryKey)
            }
        )
        let queries = try modelContext.fetch(descriptor)
        let queriesByKey = Dictionary(uniqueKeysWithValues: queries.map { ($0.queryKey, $0) })
        for keyword in keywords {
            guard let query = queriesByKey[keyword.queryKey] else {
                throw KeywordResearchProjectCopyError.sharedQueryNotFound(keyword.queryKey)
            }
            guard query.queryKey == keyword.queryKey,
                  query.term == keyword.term,
                  query.storefront == keyword.storefront,
                  query.platform == keyword.platform
            else {
                throw KeywordResearchProjectCopyError.sharedQueryMismatch(keyword.queryKey)
            }
        }
        return queriesByKey
    }

    static func requireTargetTracks(
        target: TrackedApp,
        identityKeys: [String],
        in modelContext: ModelContext
    ) throws -> [TrackedAppKeyword] {
        let boundedIdentityKeys = Array(Set(identityKeys))
        guard !boundedIdentityKeys.isEmpty else { return [] }
        let targetAppStoreID = target.appStoreID
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                boundedIdentityKeys.contains(track.identityKey)
            }
        )
        let tracks = try modelContext.fetch(descriptor)
        for track in tracks {
            guard track.appStoreID == targetAppStoreID,
                  track.trackedApp === target,
                  track.trackedApp.appStoreID == target.appStoreID,
                  track.query.queryKey == track.queryKey,
                  track.query.queryKey == KeywordQuery.makeQueryKey(
                    term: track.query.term,
                    storefront: track.query.storefront,
                    platform: track.query.platform
                  ),
                  track.identityKey == TrackedAppKeyword.makeIdentityKey(
                    appStoreID: target.appStoreID,
                    term: track.term,
                    storefront: track.storefront,
                    platform: track.platform
                  )
            else {
                throw KeywordResearchProjectCopyError.targetTrackMismatch(track.identityKey)
            }
        }
        return tracks
    }

    static func matchesPreview(
        keywords: [KeywordResearchKeyword],
        preview: KeywordResearchProjectCopyPreview
    ) -> Bool {
        guard keywords.count == preview.items.count else { return false }
        return zip(keywords, preview.items).allSatisfy { keyword, item in
            keywordSnapshot(keyword) == item.keyword
                && item.trackIdentityKey == TrackedAppKeyword.makeIdentityKey(
                    appStoreID: preview.target.appStoreID,
                    term: keyword.term,
                    storefront: keyword.storefront,
                    platform: keyword.platform
                )
        }
    }

    static func hasConvergedCopyPostcondition(
        tracks: [TrackedAppKeyword],
        preview: KeywordResearchProjectCopyPreview,
        in modelContext: ModelContext
    ) throws -> Bool {
        let plannedItems = preview.items.filter { $0.disposition == .add }
        let tracksByIdentity = Dictionary(
            uniqueKeysWithValues: tracks.map { ($0.identityKey, $0) }
        )
        for item in plannedItems {
            guard let track = tracksByIdentity[item.trackIdentityKey],
                  track.notes == item.keyword.notes,
                  track.rankingAppCount == nil,
                  track.lastRefreshAt == nil,
                  track.statusMessage == nil,
                  track.snapshots.isEmpty
            else { return false }
        }

        let plannedIdentityKeys = plannedItems.map(\.trackIdentityKey)
        guard !plannedIdentityKeys.isEmpty else { return true }
        let snapshotCount = try modelContext.fetchCount(
            FetchDescriptor<TrackedKeywordDailyRanking>(
                predicate: #Predicate { snapshot in
                    plannedIdentityKeys.contains(snapshot.trackIdentityKey)
                }
            )
        )
        let statusCount = try modelContext.fetchCount(
            FetchDescriptor<TrackedKeywordRefreshStatus>(
                predicate: #Predicate { status in
                    plannedIdentityKeys.contains(status.trackIdentityKey)
                }
            )
        )
        let attemptCount = try modelContext.fetchCount(
            FetchDescriptor<TrackedAppKeywordRefreshAttempt>(
                predicate: #Predicate { attempt in
                    plannedIdentityKeys.contains(attempt.trackIdentityKey)
                }
            )
        )
        return snapshotCount == 0 && statusCount == 0 && attemptCount == 0
    }

    static func bundleCompatibility(
        projectBundleID: String?,
        targetBundleID: String?
    ) -> KeywordResearchBundleCompatibility {
        guard let projectBundleID = normalizedBundleID(projectBundleID),
              let targetBundleID = normalizedBundleID(targetBundleID)
        else { return .unavailable }
        return projectBundleID == targetBundleID ? .matches : .mismatch
    }

    static func normalizedBundleID(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func sameTargetGeneration(
        _ lhs: KeywordResearchCopyTargetSnapshot,
        _ rhs: KeywordResearchCopyTargetSnapshot
    ) -> Bool {
        lhs.persistentIdentifierToken == rhs.persistentIdentifierToken
            && lhs.appStoreID == rhs.appStoreID
            && lhs.createdAt == rhs.createdAt
    }

    static func targetSnapshot(
        _ target: TrackedApp
    ) throws -> KeywordResearchCopyTargetSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return KeywordResearchCopyTargetSnapshot(
            persistentIdentifierToken: try encoder.encode(target.persistentModelID),
            appStoreID: target.appStoreID,
            createdAt: target.createdAt,
            name: target.name,
            bundleID: target.bundleID,
            subtitle: target.subtitle,
            sellerName: target.sellerName,
            iconURLString: target.storeApp.iconURLString,
            defaultPlatform: target.defaultPlatform
        )
    }

    static func projectSnapshot(
        _ project: KeywordResearchProject
    ) -> KeywordResearchProjectSnapshot {
        KeywordResearchProjectSnapshot(
            id: project.id,
            incarnationID: project.incarnationID,
            name: project.name,
            bundleID: project.bundleID,
            defaultStorefront: project.defaultStorefront,
            defaultPlatform: project.defaultPlatform,
            notes: project.notes,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    static func keywordSnapshot(
        _ keyword: KeywordResearchKeyword
    ) -> KeywordResearchKeywordSnapshot {
        KeywordResearchKeywordSnapshot(
            id: keyword.id,
            incarnationID: keyword.incarnationID,
            projectID: keyword.projectID,
            queryKey: keyword.queryKey,
            term: keyword.term,
            storefront: keyword.storefront,
            platform: keyword.platform,
            notes: keyword.notes,
            createdAt: keyword.createdAt,
            updatedAt: keyword.updatedAt
        )
    }
}
