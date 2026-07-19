import Foundation
import SwiftData

enum KeywordRefreshStatusDomain: String, Codable, CaseIterable, Sendable {
    case ranking
    case popularity
}

/// Independently persisted status events per tracked keyword and refresh domain.
///
/// Each write leaves a timestamped value or resolved watermark. Normally old
/// events are compacted immediately, while concurrent contexts may temporarily
/// leave contenders; readers deterministically choose the newest event. This
/// prevents a delayed failure from replacing a newer success without coupling
/// ranking and Apple Ads refreshes to one model context.
@Model
final class TrackedKeywordRefreshStatus {
    #Index<TrackedKeywordRefreshStatus>(
        [\.trackIdentityKey],
        [\.appStoreID],
        [\.trackIdentityKey, \.domainRaw]
    )

    @Attribute(.unique) var statusKey: String
    var trackIdentityKey: String
    var appStoreID: Int64
    var domainRaw: String
    var message: String?
    var updatedAt: Date

    init(
        trackIdentityKey: String,
        appStoreID: Int64,
        domain: KeywordRefreshStatusDomain,
        message: String?,
        updatedAt: Date
    ) {
        self.statusKey = Self.makeEventKey(
            trackIdentityKey: trackIdentityKey,
            domain: domain
        )
        self.trackIdentityKey = trackIdentityKey
        self.appStoreID = appStoreID
        self.domainRaw = domain.rawValue
        self.message = message
        self.updatedAt = updatedAt
    }

    static func makeEventKey(
        trackIdentityKey: String,
        domain: KeywordRefreshStatusDomain
    ) -> String {
        [
            trackIdentityKey,
            "refresh-status",
            domain.rawValue,
            UUID().uuidString.lowercased()
        ].joined(separator: "::")
    }

    var domain: KeywordRefreshStatusDomain? {
        KeywordRefreshStatusDomain(rawValue: domainRaw)
    }
}

struct KeywordRefreshStatusSnapshot: Equatable, Hashable, Sendable {
    let rankingMessage: String?
    let rankingUpdatedAt: Date?
    let popularityMessage: String?
    let popularityUpdatedAt: Date?

    static let empty = KeywordRefreshStatusSnapshot(
        rankingMessage: nil,
        rankingUpdatedAt: nil,
        popularityMessage: nil,
        popularityUpdatedAt: nil
    )

    var preferredMessage: String? {
        rankingMessage ?? popularityMessage
    }

    var displayMessage: String? {
        let messages: [String] = [popularityMessage, rankingMessage].compactMap { message -> String? in
            guard let message, !message.isEmpty else { return nil }
            return message
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

enum TrackedKeywordRefreshStatusStore {
    static func snapshot(
        for track: TrackedAppKeyword,
        in modelContext: ModelContext
    ) throws -> KeywordRefreshStatusSnapshot {
        let snapshots = try snapshots(
            for: [track.identityKey],
            in: modelContext
        )
        return snapshot(for: track, persisted: snapshots[track.identityKey])
    }

    static func snapshot(
        for track: TrackedAppKeyword,
        persisted: KeywordRefreshStatusSnapshot?
    ) -> KeywordRefreshStatusSnapshot {
        persisted
            ?? snapshot(fromLegacyMessage: track.statusMessage, timestamp: legacyTimestamp(for: track))
            ?? .empty
    }

    static func snapshots(
        for trackIdentityKeys: [String],
        in modelContext: ModelContext
    ) throws -> [String: KeywordRefreshStatusSnapshot] {
        let identityKeys = Array(Set(trackIdentityKeys))
        guard !identityKeys.isEmpty else { return [:] }

        let descriptor = FetchDescriptor<TrackedKeywordRefreshStatus>(
            predicate: #Predicate { status in
                identityKeys.contains(status.trackIdentityKey)
            }
        )
        return snapshots(from: try modelContext.fetch(descriptor))
    }

    static func snapshots(
        from records: [TrackedKeywordRefreshStatus]
    ) -> [String: KeywordRefreshStatusSnapshot] {
        let grouped = Dictionary(grouping: records, by: \.trackIdentityKey)
        return grouped.mapValues(snapshot(from:))
    }

    static func set(
        _ message: String?,
        domain: KeywordRefreshStatusDomain,
        for track: TrackedAppKeyword,
        updatedAt: Date = .now,
        in modelContext: ModelContext
    ) throws {
        try migrateLegacyStatusIfNeeded(
            for: track,
            migratedAt: updatedAt,
            in: modelContext
        )

        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMessage = normalizedMessage.flatMap { $0.isEmpty ? nil : $0 }
        let trackIdentityKey = track.identityKey
        let domainRaw = domain.rawValue
        let descriptor = FetchDescriptor<TrackedKeywordRefreshStatus>(
            predicate: #Predicate { status in
                status.trackIdentityKey == trackIdentityKey
                    && status.domainRaw == domainRaw
            }
        )
        let existingRecords = try modelContext.fetch(descriptor)
        if let latest = latestRecord(for: domain, in: existingRecords) {
            guard latest.updatedAt <= updatedAt else { return }
            if latest.updatedAt == updatedAt {
                if latest.message == resolvedMessage { return }
                // A resolved watermark wins an otherwise ambiguous timestamp.
                if latest.message == nil, resolvedMessage != nil { return }
            }
        }

        modelContext.insert(TrackedKeywordRefreshStatus(
            trackIdentityKey: track.identityKey,
            appStoreID: track.appStoreID,
            domain: domain,
            message: resolvedMessage,
            updatedAt: updatedAt
        ))
        for existing in existingRecords where existing.updatedAt <= updatedAt {
            modelContext.delete(existing)
        }
    }

    static func deleteStatuses(
        for trackIdentityKeys: [String],
        in modelContext: ModelContext
    ) throws {
        let identityKeys = Array(Set(trackIdentityKeys))
        guard !identityKeys.isEmpty else { return }

        let descriptor = FetchDescriptor<TrackedKeywordRefreshStatus>(
            predicate: #Predicate { status in
                identityKeys.contains(status.trackIdentityKey)
            }
        )
        for status in try modelContext.fetch(descriptor) {
            modelContext.delete(status)
        }
    }

    static func migrateLegacyStatuses(in modelContext: ModelContext) throws {
        let tracks = try modelContext.fetch(FetchDescriptor<TrackedAppKeyword>())
        let migratedAt = Date.now
        for track in tracks {
            try migrateLegacyStatusIfNeeded(
                for: track,
                migratedAt: migratedAt,
                in: modelContext
            )
        }
        try modelContext.save()
    }

    static func migrateLegacyStatusIfNeeded(
        for track: TrackedAppKeyword,
        migratedAt: Date = .now,
        in modelContext: ModelContext
    ) throws {
        guard track.statusMessage != nil else { return }
        guard let legacyMessage = normalized(track.statusMessage) else {
            track.statusMessage = nil
            return
        }
        let domain = domain(forLegacyMessage: legacyMessage)
        let trackIdentityKey = track.identityKey
        let domainRaw = domain.rawValue
        var descriptor = FetchDescriptor<TrackedKeywordRefreshStatus>(
            predicate: #Predicate { status in
                status.trackIdentityKey == trackIdentityKey
                    && status.domainRaw == domainRaw
            }
        )
        descriptor.fetchLimit = 1

        if try modelContext.fetch(descriptor).isEmpty {
            modelContext.insert(TrackedKeywordRefreshStatus(
                trackIdentityKey: track.identityKey,
                appStoreID: track.appStoreID,
                domain: domain,
                message: legacyMessage,
                updatedAt: migratedAt
            ))
        }
        track.statusMessage = nil
    }

    static func domain(forLegacyMessage message: String) -> KeywordRefreshStatusDomain {
        if message.hasPrefix("Popularity failed to fetch.")
            || message.hasPrefix("Popularity unavailable.")
        {
            return .popularity
        }
        return .ranking
    }

    private static func snapshot(
        from records: [TrackedKeywordRefreshStatus]
    ) -> KeywordRefreshStatusSnapshot {
        let ranking = latestRecord(for: .ranking, in: records)
        let popularity = latestRecord(for: .popularity, in: records)
        return KeywordRefreshStatusSnapshot(
            rankingMessage: ranking?.message,
            rankingUpdatedAt: ranking?.updatedAt,
            popularityMessage: popularity?.message,
            popularityUpdatedAt: popularity?.updatedAt
        )
    }

    private static func latestRecord(
        for domain: KeywordRefreshStatusDomain,
        in records: [TrackedKeywordRefreshStatus]
    ) -> TrackedKeywordRefreshStatus? {
        records
            .filter { $0.domain == domain }
            .max { left, right in
                if left.updatedAt != right.updatedAt {
                    return left.updatedAt < right.updatedAt
                }
                if (left.message == nil) != (right.message == nil) {
                    return left.message != nil
                }
                if left.message != right.message {
                    return (left.message ?? "") < (right.message ?? "")
                }
                return left.statusKey < right.statusKey
            }
    }

    private static func snapshot(
        fromLegacyMessage message: String?,
        timestamp: Date
    ) -> KeywordRefreshStatusSnapshot? {
        guard let message = normalized(message) else { return nil }
        switch domain(forLegacyMessage: message) {
        case .ranking:
            return KeywordRefreshStatusSnapshot(
                rankingMessage: message,
                rankingUpdatedAt: timestamp,
                popularityMessage: nil,
                popularityUpdatedAt: nil
            )
        case .popularity:
            return KeywordRefreshStatusSnapshot(
                rankingMessage: nil,
                rankingUpdatedAt: nil,
                popularityMessage: message,
                popularityUpdatedAt: timestamp
            )
        }
    }

    private static func normalized(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : message
    }

    private static func legacyTimestamp(for track: TrackedAppKeyword) -> Date {
        track.lastRefreshAt ?? track.createdAt
    }
}
