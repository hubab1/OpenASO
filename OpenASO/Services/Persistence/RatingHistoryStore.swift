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

    var errorDescription: String? {
        switch self {
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
        let legacy = try context.fetch(FetchDescriptor<AppDailyRating>(predicate: #Predicate {
            appStoreIDs.contains($0.appStoreID)
                && (!filtersStorefront || storefronts.contains($0.storefront))

        }))
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

    /// Restore an archived day before an existing write path changes it. Both
    /// removal from the chunk and the new row commit with the caller's save.
    static func restore(identityKey: String, in context: ModelContext) throws -> AppDailyRating? {
        try restore(identityKeys: [identityKey], in: context)[identityKey]
    }

    static func restore(identityKeys: [String], in context: ModelContext) throws -> [String: AppDailyRating] {
        guard !identityKeys.isEmpty else { return [:] }
        let existing = try context.fetch(FetchDescriptor<AppDailyRating>(predicate: #Predicate {
            identityKeys.contains($0.identityKey)
        }))
        var models = Dictionary(uniqueKeysWithValues: existing.map { ($0.identityKey, $0) })
        let missing = Set(identityKeys).subtracting(models.keys)
        let keys = Array(Set(missing.compactMap { key -> String? in
            let parts = key.components(separatedBy: "::")
            guard parts.count == 3, let appID = Int64(parts[0]) else { return nil }
            return RatingHistoryChunk.key(appStoreID: appID, storefront: parts[1], year: String(parts[2].prefix(4)))
        }))
        guard !keys.isEmpty else { return models }
        let chunks = try context.fetch(FetchDescriptor<RatingHistoryChunk>(predicate: #Predicate {
            keys.contains($0.identityKey)
        }))
        let decoded = try chunks.map { ($0, try records(in: $0)) }
        let storeIDs = Array(Set(decoded.flatMap { $0.1 }.compactMap(\.storeAppID)))
        let apps = try context.fetch(FetchDescriptor<StoreApp>(predicate: #Predicate { storeIDs.contains($0.appStoreID) }))
        let appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.appStoreID, $0) })
        for (chunk, values) in decoded {
            let restored = values.filter { missing.contains($0.identityKey) }
            guard !restored.isEmpty else { continue }
            for value in restored {
                let model = value.makeModel(storeApp: value.storeAppID.flatMap { appsByID[$0] })
                context.insert(model)
                models[value.identityKey] = model
            }
            let remaining = values.filter { !missing.contains($0.identityKey) }
            if remaining.isEmpty { context.delete(chunk) }
            else { try replace(remaining, in: chunk) }
        }
        return models
    }

    static func remove(appStoreID: Int64, storefront: String, in context: ModelContext) throws {
        let chunks = try context.fetch(FetchDescriptor<RatingHistoryChunk>(predicate: #Predicate {
            $0.appStoreID == appStoreID && $0.storefront == storefront
        }))
        for chunk in chunks { context.delete(chunk) }
    }
}
