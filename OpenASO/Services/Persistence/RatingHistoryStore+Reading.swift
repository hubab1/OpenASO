import Foundation
import SwiftData

extension RatingHistoryStore {
    struct Cursor: Sendable {
        let observedAt: Date
        let identityKey: String
    }

    struct Page: Sendable {
        let records: [RatingHistoryRecord]
        let total: Int
    }

    enum RecentOrder: Sendable {
        case observationDate
        case ratingDate

        func precedes(_ lhs: RatingHistoryRecord, _ rhs: RatingHistoryRecord) -> Bool {
            if self == .ratingDate, lhs.ratingDate != rhs.ratingDate { return lhs.ratingDate > rhs.ratingDate }
            return lhs.observedAt == rhs.observedAt
                ? lhs.identityKey < rhs.identityKey : lhs.observedAt > rhs.observedAt
        }
    }

    /// Counts complete chunks from metadata and only decodes payloads that can
    /// contribute to this page. Date ranges cutting through chunks require
    /// decoding those boundary chunks to retain exact totals.
    static func page(appStoreID: Int64, storefronts: [String] = [],
                     from: Date = .distantPast, to: Date = .distantFuture,
                     after cursor: Cursor? = nil, limit: Int, in context: ModelContext) throws -> Page {
        try ModelContainerFactory.withReadTransaction(in: context) { context in
            precondition(limit > 0)
            let reader = try BoundedReader(appStoreIDs: [appStoreID], storefronts: storefronts,
                                           from: from, to: to, in: context)
            guard reader.isCompact else {
                let all = try fetch(appStoreIDs: [appStoreID], storefronts: storefronts, from: from, to: to, in: context)
                return Page(records: Array(all.filter { isAfter($0, cursor: cursor) }.prefix(limit)), total: all.count)
            }
            var selection = Selection(limit: limit, order: .observationDate, cursor: cursor, from: from, to: to)
            selection.add(reader.live)
            var total = reader.live.filter { $0.observedAt >= from && $0.observedAt <= to }.count
            var complete: [RatingHistoryChunk] = []
            for chunk in reader.chunks {
                if chunk.firstObservedAt >= from && chunk.lastObservedAt <= to {
                    total += chunk.recordCount
                    complete.append(chunk)
                } else {
                    let values = try records(in: chunk)
                    total += values.filter { $0.observedAt >= from && $0.observedAt <= to }.count
                    selection.add(values)
                }
            }
            try selection.read(complete)
            return Page(records: selection.values, total: total)
        }
    }

    /// Returns at most limitPerApp records for each app, retaining the requested
    /// logical-date or observation-time ordering without hydrating lifetime history.
    static func recent(appStoreIDs: [Int64], storefronts: [String] = [], limitPerApp: Int,
                       order: RecentOrder = .observationDate, requiresRatingCount: Bool = false,
                       in context: ModelContext) throws -> [RatingHistoryRecord] {
        try ModelContainerFactory.withReadTransaction(in: context) { context in
            guard !appStoreIDs.isEmpty, limitPerApp > 0 else { return [] }
            let reader = try BoundedReader(appStoreIDs: appStoreIDs, storefronts: storefronts, in: context)
            guard reader.isCompact else {
                let all = try fetch(appStoreIDs: appStoreIDs, storefronts: storefronts, in: context)
                    .filter { !requiresRatingCount || $0.ratingCount != nil }
                return Dictionary(grouping: all, by: \.appStoreID).values.flatMap {
                    $0.sorted(by: order.precedes).prefix(limitPerApp)
                }.sorted(by: order.precedes)
            }
            let live = Dictionary(grouping: reader.live, by: \.appStoreID)
            let chunks = Dictionary(grouping: reader.chunks, by: \.appStoreID)
            var result: [RatingHistoryRecord] = []
            for appID in Set(appStoreIDs).sorted() {
                var selection = Selection(limit: limitPerApp, order: order, requiresRatingCount: requiresRatingCount)
                selection.add(live[appID] ?? [])
                try selection.read(chunks[appID] ?? [])
                result.append(contentsOf: selection.values)
            }
            return result.sorted(by: order.precedes)
        }
    }

    private static func isAfter(_ value: RatingHistoryRecord, cursor: Cursor?) -> Bool {
        guard let cursor else { return true }
        return value.observedAt < cursor.observedAt
            || (value.observedAt == cursor.observedAt && value.identityKey > cursor.identityKey)
    }

    private struct BoundedReader {
        let live: [RatingHistoryRecord]
        let chunks: [RatingHistoryChunk]
        let isCompact: Bool

        init(appStoreIDs: [Int64], storefronts: [String], from: Date = .distantPast,
             to: Date = .distantFuture, in context: ModelContext) throws {
            let filtersStorefront = !storefronts.isEmpty
            var raw = FetchDescriptor<AppDailyRating>(predicate: #Predicate {
                appStoreIDs.contains($0.appStoreID) && (!filtersStorefront || storefronts.contains($0.storefront))
            })
            raw.relationshipKeyPathsForPrefetching = [\.storeApp]
            live = try context.fetch(raw).map(RatingHistoryRecord.init)
            var descriptor = FetchDescriptor<RatingHistoryChunk>(predicate: #Predicate {
                appStoreIDs.contains($0.appStoreID) && (!filtersStorefront || storefronts.contains($0.storefront))
                    && $0.firstObservedAt <= to && $0.lastObservedAt >= from
            })
            // Accessing payload/digest later faults them only for selected chunks.
            descriptor.propertiesToFetch = [\.identityKey, \.appStoreID, \.storefront, \.year,
                \.firstObservedAt, \.lastObservedAt, \.recordCount, \.formatVersion, \.uncompressedByteCount]
            chunks = try context.fetch(descriptor)
            for chunk in chunks {
                guard chunk.recordCount > 0, chunk.recordCount <= 512,
                      chunk.formatVersion == 1, chunk.uncompressedByteCount > 0,
                      chunk.uncompressedByteCount <= 8 * 1_024 * 1_024 else {
                    throw RatingHistoryError.invalidArchive(chunk.identityKey)
                }
            }
            var stateRequest = FetchDescriptor<StorageMigrationState>(predicate: #Predicate { $0.migrationKey == "storage-v7" })
            stateRequest.fetchLimit = 1
            let state = try context.fetch(stateRequest).first
            // A completed upgrade plus compact ingestion guarantees disjoint
            // archives and one hot day per scope. Legacy/partial fixtures use the
            // full reader's overlap reconciliation instead of metadata counts.
            isCompact = !context.hasChanges && (live.isEmpty || (state?.completed == true && state?.pendingDeletionPayload == nil
                && Dictionary(grouping: live, by: \.scopeKey).values.allSatisfy { $0.count == 1 }))
        }
    }

    private struct Selection {
        let limit: Int
        let order: RecentOrder
        var requiresRatingCount = false
        var cursor: Cursor? = nil
        var from: Date = .distantPast
        var to: Date = .distantFuture
        private(set) var values: [RatingHistoryRecord] = []

        mutating func add(_ records: [RatingHistoryRecord]) {
            var byKey = Dictionary(uniqueKeysWithValues: values.map { ($0.identityKey, $0) })
            for record in records where record.observedAt >= from && record.observedAt <= to
                && (!requiresRatingCount || record.ratingCount != nil) && isAfter(record, cursor: cursor) {
                if let prior = byKey[record.identityKey], prior.observedAt > record.observedAt { continue }
                byKey[record.identityKey] = record
            }
            values = Array(byKey.values.sorted(by: order.precedes).prefix(limit))
        }

        mutating func read(_ chunks: [RatingHistoryChunk]) throws {
            let ordered = chunks.sorted {
                if order == .ratingDate, $0.year != $1.year { return $0.year > $1.year }
                return $0.lastObservedAt > $1.lastObservedAt
            }
            for chunk in ordered {
                try Task.checkCancellation()
                if let cursor, chunk.firstObservedAt > cursor.observedAt { continue }
                if values.count == limit, let cutoff = values.last {
                    if order == .ratingDate {
                        if chunk.year < String(cutoff.ratingDate.prefix(4)) { continue }
                    } else if chunk.lastObservedAt < cutoff.observedAt { continue }
                }
                add(try records(in: chunk))
            }
        }
    }
}
