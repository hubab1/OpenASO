import Foundation
import SwiftData

struct TrackedKeywordDeletionRequest: Hashable, Sendable {
    let identityKey: String
    let trackCreatedAt: Date

    init(identityKey: String, trackCreatedAt: Date) {
        self.identityKey = identityKey
        self.trackCreatedAt = trackCreatedAt
    }

    init(track: TrackedAppKeyword) {
        self.init(
            identityKey: track.identityKey,
            trackCreatedAt: track.createdAt
        )
    }
}

struct TrackedAppDeletionRequest: Hashable, Sendable {
    let appStoreID: Int64
    let appCreatedAt: Date

    init(appStoreID: Int64, appCreatedAt: Date) {
        self.appStoreID = appStoreID
        self.appCreatedAt = appCreatedAt
    }

    init(app: TrackedApp) {
        self.init(
            appStoreID: app.appStoreID,
            appCreatedAt: app.createdAt
        )
    }
}

struct TrackedKeywordDeletionResult: Equatable, Sendable {
    let deletedIdentityKeys: [String]
    let deletedQueryKeys: [String]

    var deletedTrackCount: Int {
        deletedIdentityKeys.count
    }
}

struct TrackedAppDeletionResult: Equatable, Sendable {
    let deletedApp: Bool
    let keywordDeletion: TrackedKeywordDeletionResult

    var deletedTrackCount: Int {
        keywordDeletion.deletedTrackCount
    }
}

/// Coordinates destructive keyword changes through the process-wide model-store
/// actor and verifies model generations again inside the write transaction.
/// Provider work that finishes later is rejected by the matching generation
/// checks in the ranking persistence path.
enum TrackedKeywordDeletionService {
    @discardableResult
    static func deleteTracks(
        _ requests: [TrackedKeywordDeletionRequest],
        using store: BackgroundModelStore
    ) async throws -> TrackedKeywordDeletionResult {
        try await store.write { modelContext in
            try deleteTracks(requests, in: modelContext)
        }
    }

    @discardableResult
    static func deleteApp(
        _ request: TrackedAppDeletionRequest,
        using store: BackgroundModelStore
    ) async throws -> TrackedAppDeletionResult {
        try await store.write { modelContext in
            try deleteApp(request, in: modelContext)
        }
    }

    @discardableResult
    static func deleteTracks(
        _ requests: [TrackedKeywordDeletionRequest],
        in modelContext: ModelContext
    ) throws -> TrackedKeywordDeletionResult {
        let requestSet = Set(requests)
        let identityKeys = Array(Set(requests.map(\.identityKey)))
        guard !identityKeys.isEmpty else {
            return TrackedKeywordDeletionResult(
                deletedIdentityKeys: [],
                deletedQueryKeys: []
            )
        }

        let trackDescriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                identityKeys.contains(track.identityKey)
            }
        )
        let tracks = try modelContext.fetch(trackDescriptor).filter { track in
            requestSet.contains(TrackedKeywordDeletionRequest(track: track))
        }
        guard !tracks.isEmpty else {
            return TrackedKeywordDeletionResult(
                deletedIdentityKeys: [],
                deletedQueryKeys: []
            )
        }

        let deletedIdentityKeys = Set(tracks.map(\.identityKey))
        let affectedQueryKeys = Set(tracks.map(\.queryKey))
        let allTracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
        let remainingQueryKeys = Set(
            allTracks.lazy
                .filter { !deletedIdentityKeys.contains($0.identityKey) }
                .map(\.queryKey)
        )
        let orphanedQueryKeys = affectedQueryKeys.subtracting(remainingQueryKeys)

        try deleteRefreshState(
            trackIdentityKeys: Array(deletedIdentityKeys),
            in: modelContext
        )
        try deleteTrackRankings(
            trackIdentityKeys: Array(deletedIdentityKeys),
            in: modelContext
        )
        for track in tracks {
            modelContext.delete(track)
        }

        if !orphanedQueryKeys.isEmpty {
            try deleteOrphanedEstimatedDifficulty(
                queryKeys: Array(orphanedQueryKeys),
                in: modelContext
            )
        }

        return TrackedKeywordDeletionResult(
            deletedIdentityKeys: deletedIdentityKeys.sorted(),
            deletedQueryKeys: orphanedQueryKeys.sorted()
        )
    }

    @discardableResult
    static func deleteApp(
        _ request: TrackedAppDeletionRequest,
        in modelContext: ModelContext
    ) throws -> TrackedAppDeletionResult {
        let appStoreID = request.appStoreID
        var appDescriptor = FetchDescriptor<TrackedApp>(
            predicate: #Predicate { app in
                app.appStoreID == appStoreID
            }
        )
        appDescriptor.fetchLimit = 1
        guard let app = try modelContext.fetch(appDescriptor).first,
              app.createdAt == request.appCreatedAt
        else {
            return TrackedAppDeletionResult(
                deletedApp: false,
                keywordDeletion: TrackedKeywordDeletionResult(
                    deletedIdentityKeys: [],
                    deletedQueryKeys: []
                )
            )
        }

        let trackDescriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.appStoreID == appStoreID
            }
        )
        let keywordDeletion = try deleteTracks(
            try modelContext.fetch(trackDescriptor).map(TrackedKeywordDeletionRequest.init(track:)),
            in: modelContext
        )
        modelContext.delete(app)

        return TrackedAppDeletionResult(
            deletedApp: true,
            keywordDeletion: keywordDeletion
        )
    }

    private static func deleteRefreshState(
        trackIdentityKeys: [String],
        in modelContext: ModelContext
    ) throws {
        try TrackedKeywordRefreshStatusStore.deleteStatuses(
            for: trackIdentityKeys,
            in: modelContext
        )

        let attemptDescriptor = FetchDescriptor<TrackedAppKeywordRefreshAttempt>(
            predicate: #Predicate { attempt in
                trackIdentityKeys.contains(attempt.trackIdentityKey)
            }
        )
        for attempt in try modelContext.fetch(attemptDescriptor) {
            modelContext.delete(attempt)
        }
    }

    private static func deleteTrackRankings(
        trackIdentityKeys: [String],
        in modelContext: ModelContext
    ) throws {
        let snapshotDescriptor = FetchDescriptor<TrackedKeywordDailyRanking>(
            predicate: #Predicate { snapshot in
                trackIdentityKeys.contains(snapshot.trackIdentityKey)
            }
        )
        let snapshots = try modelContext.fetch(snapshotDescriptor)
        let snapshotKeys = snapshots.map(\.snapshotKey)
        if !snapshotKeys.isEmpty {
            let resultDescriptor = FetchDescriptor<TrackedKeywordRankedResult>(
                predicate: #Predicate { result in
                    snapshotKeys.contains(result.snapshotKey)
                }
            )
            for result in try modelContext.fetch(resultDescriptor) {
                modelContext.delete(result)
            }
        }
        for snapshot in snapshots {
            modelContext.delete(snapshot)
        }
    }

    /// Ranking history, popularity metrics, and the normalized query remain
    /// available for audit/history views. Only the current estimated heuristic
    /// is invalid once no active track owns its generation.
    private static func deleteOrphanedEstimatedDifficulty(
        queryKeys: [String],
        in modelContext: ModelContext
    ) throws {
        try EstimatedKeywordDifficultyStore.delete(
            queryKeys: queryKeys,
            in: modelContext
        )
    }
}
