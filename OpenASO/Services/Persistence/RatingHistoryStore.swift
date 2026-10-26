import CryptoKit
import Foundation
import SwiftData

/// The logical daily record is unchanged by archival. Keep the logical date
/// separate from observedAt, including imported dates and source evidence.
struct RatingHistoryRecord: Codable, Equatable, Sendable {
    var identityKey: String
    var appStoreID: Int64
    var storefront: String
    var ratingDate: String
    var ratingCount: Int?
    var averageRating: Double?
    var oneStarRatingCount: Int?
    var twoStarRatingCount: Int?
    var threeStarRatingCount: Int?
    var fourStarRatingCount: Int?
    var fiveStarRatingCount: Int?
    var observedAt: Date
    var submissionCount: Int
    var winningCount: Int
    var confidenceRaw: String?
    var sourceRaw: String
    var storeAppID: Int64?

    var source: AppStorefrontSource { AppStorefrontSource(rawValue: sourceRaw) ?? .appStorePage }
    var chunkKey: String {
        RatingHistoryChunk.key(appStoreID: appStoreID, storefront: storefront, year: String(ratingDate.prefix(4)))
    }

    init(_ value: AppDailyRating) {
        identityKey = value.identityKey
        appStoreID = value.appStoreID
        storefront = value.storefront
        ratingDate = value.ratingDate
        ratingCount = value.ratingCount
        averageRating = value.averageRating
        oneStarRatingCount = value.oneStarRatingCount
        twoStarRatingCount = value.twoStarRatingCount
        threeStarRatingCount = value.threeStarRatingCount
        fourStarRatingCount = value.fourStarRatingCount
        fiveStarRatingCount = value.fiveStarRatingCount
        observedAt = value.observedAt
        submissionCount = value.submissionCount
        winningCount = value.winningCount
        confidenceRaw = value.confidenceRaw
        sourceRaw = value.sourceRaw
        storeAppID = value.storeApp?.appStoreID
    }

    init(_ result: AppStorefrontRatingResult, ratingDate: String?, submissionCount: Int,
         winningCount: Int, confidence: String?) {
        appStoreID = result.appStoreID
        storefront = result.storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.ratingDate = ratingDate ?? LatestAppRating.ratingDateString(for: result.observedAt)
        identityKey = AppDailyRating.makeIdentityKey(appStoreID: appStoreID, storefront: storefront, ratingDate: self.ratingDate)
        ratingCount = result.ratingCount
        averageRating = result.averageRating
        oneStarRatingCount = result.ratingCounts?.oneStar
        twoStarRatingCount = result.ratingCounts?.twoStar
        threeStarRatingCount = result.ratingCounts?.threeStar
        fourStarRatingCount = result.ratingCounts?.fourStar
        fiveStarRatingCount = result.ratingCounts?.fiveStar
        observedAt = result.observedAt
        self.submissionCount = submissionCount
        self.winningCount = winningCount
        confidenceRaw = confidence
        sourceRaw = result.source.rawValue
        storeAppID = result.appStoreID
    }

    var scopeKey: String { LatestAppRating.makeIdentityKey(appStoreID: appStoreID, storefront: storefront) }

    mutating func retainStarCounts(from previous: RatingHistoryRecord) {
        oneStarRatingCount = previous.oneStarRatingCount
        twoStarRatingCount = previous.twoStarRatingCount
        threeStarRatingCount = previous.threeStarRatingCount
        fourStarRatingCount = previous.fourStarRatingCount
        fiveStarRatingCount = previous.fiveStarRatingCount
    }

    func apply(to model: AppDailyRating, storeApp: StoreApp?) {
        if model.identityKey != identityKey { model.identityKey = identityKey }
        if model.appStoreID != appStoreID { model.appStoreID = appStoreID }
        if model.storefront != storefront { model.storefront = storefront }
        if model.ratingCount != ratingCount { model.ratingCount = ratingCount }
        if model.averageRating != averageRating { model.averageRating = averageRating }
        if model.oneStarRatingCount != oneStarRatingCount { model.oneStarRatingCount = oneStarRatingCount }
        if model.twoStarRatingCount != twoStarRatingCount { model.twoStarRatingCount = twoStarRatingCount }
        if model.threeStarRatingCount != threeStarRatingCount { model.threeStarRatingCount = threeStarRatingCount }
        if model.fourStarRatingCount != fourStarRatingCount { model.fourStarRatingCount = fourStarRatingCount }
        if model.fiveStarRatingCount != fiveStarRatingCount { model.fiveStarRatingCount = fiveStarRatingCount }
        if model.ratingDate != ratingDate { model.ratingDate = ratingDate }
        if model.observedAt != observedAt { model.observedAt = observedAt }
        if model.submissionCount != submissionCount { model.submissionCount = submissionCount }
        if model.winningCount != winningCount { model.winningCount = winningCount }
        if model.confidenceRaw != confidenceRaw { model.confidenceRaw = confidenceRaw }
        if model.sourceRaw != sourceRaw { model.sourceRaw = sourceRaw }
        if model.storeApp !== storeApp { model.storeApp = storeApp }
    }

    func apply(to model: LatestAppRating, storeApp: StoreApp?) {
        if model.ratingCount != ratingCount { model.ratingCount = ratingCount }
        if model.averageRating != averageRating { model.averageRating = averageRating }
        if model.oneStarRatingCount != oneStarRatingCount { model.oneStarRatingCount = oneStarRatingCount }
        if model.twoStarRatingCount != twoStarRatingCount { model.twoStarRatingCount = twoStarRatingCount }
        if model.threeStarRatingCount != threeStarRatingCount { model.threeStarRatingCount = threeStarRatingCount }
        if model.fourStarRatingCount != fourStarRatingCount { model.fourStarRatingCount = fourStarRatingCount }
        if model.fiveStarRatingCount != fiveStarRatingCount { model.fiveStarRatingCount = fiveStarRatingCount }
        if model.ratingDate != ratingDate { model.ratingDate = ratingDate }
        if model.observedAt != observedAt { model.observedAt = observedAt }
        if model.submissionCount != submissionCount { model.submissionCount = submissionCount }
        if model.winningCount != winningCount { model.winningCount = winningCount }
        if model.confidenceRaw != confidenceRaw { model.confidenceRaw = confidenceRaw }
        if model.sourceRaw != sourceRaw { model.sourceRaw = sourceRaw }
        if model.storeApp !== storeApp { model.storeApp = storeApp }
    }

    // A versioned positional payload avoids repeating property names and
    // binary-plist offset tables in each small archive. Nulls keep their slots.
    init(from decoder: any Decoder) throws {
        var fields = try decoder.unkeyedContainer()
        identityKey = try fields.decode(String.self)
        appStoreID = try fields.decode(Int64.self)
        storefront = try fields.decode(String.self)
        ratingDate = try fields.decode(String.self)
        ratingCount = try fields.decode(Int?.self)
        averageRating = try fields.decode(Double?.self)
        oneStarRatingCount = try fields.decode(Int?.self)
        twoStarRatingCount = try fields.decode(Int?.self)
        threeStarRatingCount = try fields.decode(Int?.self)
        fourStarRatingCount = try fields.decode(Int?.self)
        fiveStarRatingCount = try fields.decode(Int?.self)
        observedAt = try fields.decode(Date.self)
        submissionCount = try fields.decode(Int.self)
        winningCount = try fields.decode(Int.self)
        confidenceRaw = try fields.decode(String?.self)
        sourceRaw = try fields.decode(String.self)
        storeAppID = try fields.decode(Int64?.self)
        guard fields.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: fields, debugDescription: "Unknown rating history fields")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.unkeyedContainer()
        try fields.encode(identityKey)
        try fields.encode(appStoreID)
        try fields.encode(storefront)
        try fields.encode(ratingDate)
        try fields.encode(ratingCount)
        try fields.encode(averageRating)
        try fields.encode(oneStarRatingCount)
        try fields.encode(twoStarRatingCount)
        try fields.encode(threeStarRatingCount)
        try fields.encode(fourStarRatingCount)
        try fields.encode(fiveStarRatingCount)
        try fields.encode(observedAt)
        try fields.encode(submissionCount)
        try fields.encode(winningCount)
        try fields.encode(confidenceRaw)
        try fields.encode(sourceRaw)
        try fields.encode(storeAppID)
    }

    func makeModel(storeApp: StoreApp?) -> AppDailyRating {
        let model = AppDailyRating(
            appStoreID: appStoreID, storefront: storefront,
            ratingCount: ratingCount, averageRating: averageRating,
            oneStarRatingCount: oneStarRatingCount, twoStarRatingCount: twoStarRatingCount,
            threeStarRatingCount: threeStarRatingCount, fourStarRatingCount: fourStarRatingCount,
            fiveStarRatingCount: fiveStarRatingCount, ratingDate: ratingDate,
            observedAt: observedAt, submissionCount: submissionCount,
            winningCount: winningCount, confidence: confidenceRaw, source: source,
            storeApp: storeApp
        )
        model.identityKey = identityKey
        model.sourceRaw = sourceRaw
        return model
    }
}

enum RatingHistoryError: LocalizedError {
    case invalidArchive(String)
    case schemaUpgradeRequired

    var errorDescription: String? {
        switch self {
        case .schemaUpgradeRequired: "Upgrade this database before writing compressed rating history."
        case .invalidArchive(let key): "Rating history failed validation: \(key). No unvalidated source rows were removed."
        }
    }
}

enum RatingHistoryStore {
    static func records(in chunk: RatingHistoryChunk) throws -> [RatingHistoryRecord] {
        guard chunk.formatVersion == 1, chunk.uncompressedByteCount > 0,
              chunk.uncompressedByteCount <= 8 * 1_024 * 1_024 else {
            throw RatingHistoryError.invalidArchive(chunk.identityKey)
        }
        let data = try (chunk.payload as NSData).decompressed(using: .zlib) as Data
        guard data.count == chunk.uncompressedByteCount,
              Data(SHA256.hash(data: data)) == chunk.digest else {
            throw RatingHistoryError.invalidArchive(chunk.identityKey)
        }
        let values = try JSONDecoder().decode([RatingHistoryRecord].self, from: data)
        guard values.count == chunk.recordCount,
              Set(values.map(\.identityKey)).count == values.count,
              values.allSatisfy({ $0.chunkKey == chunk.identityKey }),
              values.map(\.observedAt).min() == chunk.firstObservedAt,
              values.map(\.observedAt).max() == chunk.lastObservedAt else {
            throw RatingHistoryError.invalidArchive(chunk.identityKey)
        }
        return values
    }

    static func replace(_ records: [RatingHistoryRecord], in chunk: RatingHistoryChunk) throws {
        let sorted = records.sorted { $0.identityKey < $1.identityKey }
        guard !sorted.isEmpty, sorted.count <= 512,
              Set(sorted.map(\.identityKey)).count == sorted.count,
              sorted.allSatisfy({ $0.chunkKey == chunk.identityKey }) else {
            throw RatingHistoryError.invalidArchive(chunk.identityKey)
        }
        let data = try JSONEncoder().encode(sorted)
        guard data.count <= 8 * 1_024 * 1_024 else {
            throw RatingHistoryError.invalidArchive(chunk.identityKey)
        }
        let compressed = try (data as NSData).compressed(using: .zlib) as Data
        guard try JSONDecoder().decode([RatingHistoryRecord].self,
            from: (compressed as NSData).decompressed(using: .zlib) as Data) == sorted else {
            throw RatingHistoryError.invalidArchive(chunk.identityKey)
        }
        chunk.payload = compressed
        chunk.digest = Data(SHA256.hash(data: data))
        chunk.uncompressedByteCount = data.count
        chunk.recordCount = sorted.count
        chunk.firstObservedAt = sorted.map(\.observedAt).min()!
        chunk.lastObservedAt = sorted.map(\.observedAt).max()!
    }

    static func fetch(
        appStoreIDs: [Int64], storefronts: [String] = [],
        from: Date = .distantPast, to: Date = .distantFuture,
        in context: ModelContext
    ) throws -> [RatingHistoryRecord] {
        guard !appStoreIDs.isEmpty else { return [] }
        let filtersStorefront = !storefronts.isEmpty
        var legacyDescriptor = FetchDescriptor<AppDailyRating>(predicate: #Predicate {
            appStoreIDs.contains($0.appStoreID)
                && (!filtersStorefront || storefronts.contains($0.storefront))
        })
        legacyDescriptor.relationshipKeyPathsForPrefetching = [\.storeApp]
        let legacy = try context.fetch(legacyDescriptor)
        let chunks = try context.fetch(FetchDescriptor<RatingHistoryChunk>(predicate: #Predicate {
            appStoreIDs.contains($0.appStoreID)
                && (!filtersStorefront || storefronts.contains($0.storefront))
                && $0.firstObservedAt <= to && $0.lastObservedAt >= from
        }))
        var byKey: [String: RatingHistoryRecord] = [:]
        for chunk in chunks {
            for record in try records(in: chunk) where record.observedAt >= from && record.observedAt <= to {
                byKey[record.identityKey] = record
            }
        }
        for record in legacy.map(RatingHistoryRecord.init) {
            if let archived = byKey[record.identityKey], archived.observedAt > record.observedAt { continue }
            byKey[record.identityKey] = record
        }
        return byKey.values.filter { $0.observedAt >= from && $0.observedAt <= to }.sorted {
            $0.observedAt == $1.observedAt ? $0.identityKey < $1.identityKey : $0.observedAt > $1.observedAt
        }
    }

    struct Observation: Sendable {
        let record: RatingHistoryRecord
        let replacesStarCounts: Bool

        init(_ result: AppStorefrontRatingResult, ratingDate: String? = nil,
             submissionCount: Int = 1, winningCount: Int = 1, confidence: String? = "single_source") {
            record = RatingHistoryRecord(result, ratingDate: ratingDate, submissionCount: submissionCount,
                                         winningCount: winningCount, confidence: confidence)
            replacesStarCounts = result.ratingCounts != nil
        }
    }

    /// Mutate only the caller's transaction. One live logical day per scope;
    /// rollover and historical corrections update only the affected archives.
    /// The caller commits or rolls back these changes with its other work.
    /// Shared stores use BackgroundModelStore.write for transaction-wide access.
    static func ingest(
        _ observations: [Observation], storeApps: [Int64: StoreApp],
        acceptsEqualTimestamps: Bool = true, in context: ModelContext
    ) throws {
        guard !observations.isEmpty else { return }
        guard context.container.schema.entities.contains(where: { $0.name == "RatingHistoryChunk" }) else {
            throw RatingHistoryError.schemaUpgradeRequired
        }
        let scopes = Dictionary(grouping: observations, by: { $0.record.scopeKey })
        let appIDs = Array(Set(observations.map { $0.record.appStoreID }))
        let storefronts = Array(Set(observations.map { $0.record.storefront }))
        var descriptor = FetchDescriptor<AppDailyRating>(predicate: #Predicate {
            appIDs.contains($0.appStoreID) && storefronts.contains($0.storefront)
        })
        descriptor.relationshipKeyPathsForPrefetching = [\.storeApp]
        let live = try context.fetch(descriptor).filter { scopes[LatestAppRating.makeIdentityKey(
            appStoreID: $0.appStoreID, storefront: $0.storefront)] != nil }
        let liveByScope = Dictionary(grouping: live, by: {
            LatestAppRating.makeIdentityKey(appStoreID: $0.appStoreID, storefront: $0.storefront)
        })
        let chunkKeys = Array(Set(observations.map { $0.record.chunkKey } + live.map { RatingHistoryRecord($0).chunkKey }))
        let archives = ArchiveEdits(keys: chunkKeys, in: context)
        let latestValues = try context.fetch(FetchDescriptor<LatestAppRating>(predicate: #Predicate {
            appIDs.contains($0.appStoreID) && storefronts.contains($0.storefront)
        }))
        let latestByScope = Dictionary(uniqueKeysWithValues: latestValues.map { ($0.identityKey, $0) })
        var hotUpdates: [(RatingHistoryRecord, AppDailyRating?)] = []
        var obsolete: [AppDailyRating] = []
        var latestUpdates: [String: RatingHistoryRecord] = [:]

        for (scope, incoming) in scopes {
            let rows = liveByScope[scope] ?? []
            let hotRow = rows.max { $0.ratingDate < $1.ratingDate }
            var hot = hotRow.map(RatingHistoryRecord.init)
            // Covers raw legacy rows in a caller's existing transaction without
            // scanning any app/storefront outside this ingestion batch.
            for row in rows where row !== hotRow {
                try archives.merge(RatingHistoryRecord(row))
                obsolete.append(row)
            }
            for observation in incoming {
                var record = observation.record
                let previous = hot?.identityKey == record.identityKey ? hot : try archives.record(record)
                if let previous {
                    guard record.observedAt > previous.observedAt
                        || (acceptsEqualTimestamps && record.observedAt == previous.observedAt) else { continue }
                    if !observation.replacesStarCounts { record.retainStarCounts(from: previous) }
                }
                if let previous = hot, record.ratingDate > previous.ratingDate {
                    try archives.merge(previous)
                }
                if hot == nil || record.ratingDate >= hot!.ratingDate {
                    hot = record
                } else {
                    try archives.merge(record, replacesEqual: acceptsEqualTimestamps)
                }
                let latest = latestByScope[scope]
                let previousDate = latestUpdates[scope]?.observedAt ?? latest?.observedAt
                if let previousDate, record.observedAt < previousDate
                    || (!acceptsEqualTimestamps && record.observedAt == previousDate) { continue }
                var latestRecord = observation.record
                if !observation.replacesStarCounts {
                    if let previous = latestUpdates[scope] { latestRecord.retainStarCounts(from: previous) }
                    else if let latest {
                        latestRecord.oneStarRatingCount = latest.oneStarRatingCount
                        latestRecord.twoStarRatingCount = latest.twoStarRatingCount
                        latestRecord.threeStarRatingCount = latest.threeStarRatingCount
                        latestRecord.fourStarRatingCount = latest.fourStarRatingCount
                        latestRecord.fiveStarRatingCount = latest.fiveStarRatingCount
                    }
                }
                latestUpdates[scope] = latestRecord
            }
            if let hot { hotUpdates.append((hot, hotRow)) }
        }
        // Validate every compressed update before changing or removing live rows.
        try archives.apply(in: context)
        for (record, row) in hotUpdates {
            let app = record.storeAppID.flatMap { storeApps[$0] } ?? row?.storeApp
            if let row { record.apply(to: row, storeApp: app) }
            else { context.insert(record.makeModel(storeApp: app)) }
        }
        for row in obsolete { context.delete(row) }
        for (scope, record) in latestUpdates {
            let app = record.storeAppID.flatMap { storeApps[$0] }
            let latest = latestByScope[scope] ?? LatestAppRating(
                appStoreID: record.appStoreID, storefront: record.storefront,
                ratingCount: record.ratingCount, averageRating: record.averageRating, storeApp: app
            )
            if latest.modelContext == nil { context.insert(latest) }
            record.apply(to: latest, storeApp: app)
        }
    }

    private final class ArchiveEdits {
        private var chunks: [String: RatingHistoryChunk]?
        private let keys: [String]
        private let context: ModelContext
        private var decoded: [String: [String: RatingHistoryRecord]] = [:]
        private var changed = Set<String>()

        init(keys: [String], in context: ModelContext) {
            self.keys = keys
            self.context = context
        }

        private func values(for key: String) throws -> [String: RatingHistoryRecord] {
            if let values = decoded[key] { return values }
            if chunks == nil {
                let requestedKeys = keys
                chunks = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<RatingHistoryChunk>(
                    predicate: #Predicate { requestedKeys.contains($0.identityKey) }
                )).map { ($0.identityKey, $0) })
            }
            let values = try chunks?[key].map { chunk in
                Dictionary(uniqueKeysWithValues: try records(in: chunk).map { ($0.identityKey, $0) })
            } ?? [:]
            decoded[key] = values
            return values
        }

        func record(_ record: RatingHistoryRecord) throws -> RatingHistoryRecord? {
            try values(for: record.chunkKey)[record.identityKey]
        }

        func merge(_ record: RatingHistoryRecord, replacesEqual: Bool = true) throws {
            var values = try values(for: record.chunkKey)
            if let previous = values[record.identityKey] {
                guard record != previous, record.observedAt > previous.observedAt
                    || (replacesEqual && record.observedAt == previous.observedAt) else { return }
            }
            values[record.identityKey] = record
            decoded[record.chunkKey] = values
            changed.insert(record.chunkKey)
        }

        func apply(in context: ModelContext) throws {
            for key in changed.sorted() {
                let values = Array(decoded[key]!.values)
                let first = values[0]
                let chunk = chunks?[key] ?? RatingHistoryChunk(appStoreID: first.appStoreID,
                    storefront: first.storefront, year: String(first.ratingDate.prefix(4)))
                try replace(values, in: chunk)
                if chunk.modelContext == nil { context.insert(chunk) }
            }
        }
    }

    /// Explicit scope clearing only; provider unavailability must preserve history.
    static func remove(appStoreID: Int64, storefront: String, in context: ModelContext) throws {
        let chunks = try context.fetch(FetchDescriptor<RatingHistoryChunk>(predicate: #Predicate {
            $0.appStoreID == appStoreID && $0.storefront == storefront
        }))
        let live = try context.fetch(FetchDescriptor<AppDailyRating>(predicate: #Predicate {
            $0.appStoreID == appStoreID && $0.storefront == storefront
        }))
        let latest = try context.fetch(FetchDescriptor<LatestAppRating>(predicate: #Predicate {
            $0.appStoreID == appStoreID && $0.storefront == storefront
        }))
        // Fetch every representation before staging changes. The caller owns
        // the save/rollback, just as with ingestion.
        for chunk in chunks { context.delete(chunk) }
        for value in live { context.delete(value) }
        for value in latest { context.delete(value) }
    }
}
