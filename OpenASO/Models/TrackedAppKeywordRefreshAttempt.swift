import Foundation
import SwiftData

/// Durable scheduling state for ranking refresh attempts.
///
/// A reserved refresh batch is recorded transactionally before provider I/O so
/// a persistence failure cannot produce an untracked external request.
///
/// This intentionally has no relationship to `TrackedAppKeyword`: keeping the
/// attempt row standalone makes the V1 -> V2 migration additive, and stale rows
/// are removed explicitly when ranking-refresh candidates are reconciled.
@Model
final class TrackedAppKeywordRefreshAttempt {
    #Index<TrackedAppKeywordRefreshAttempt>(
        [\.appStoreID]
    )

    @Attribute(.unique) var trackIdentityKey: String
    var appStoreID: Int64
    var lastRankingRefreshAttemptAt: Date

    init(
        trackIdentityKey: String,
        appStoreID: Int64,
        lastRankingRefreshAttemptAt: Date
    ) {
        self.trackIdentityKey = trackIdentityKey
        self.appStoreID = appStoreID
        self.lastRankingRefreshAttemptAt = lastRankingRefreshAttemptAt
    }
}
