import Foundation
import SwiftData

final class KeywordSuggestionService: Sendable {
    private static let targetItemFetchLimit = 2_000
    private static let competitorItemFetchLimit = 1_000
    private static let maximumSuggestionAge: TimeInterval = 180 * 24 * 60 * 60
    private static let strongSuggestionAge: TimeInterval = 90 * 24 * 60 * 60
    fileprivate static let scoringVersion = 2

    private let cache: KeywordSuggestionCache
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date

    init(
        cacheTTL: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = KeywordSuggestionCache()
        self.cacheTTL = cacheTTL
        self.now = now
    }

    func suggestions(
        for request: KeywordSuggestionRequest,
        using backgroundModelStore: BackgroundModelStore
    ) async throws -> AppSuggestions {
        let now = now()
        let watermark = try await backgroundModelStore.read { modelContext in
            try Self.watermark(for: request, cutoffDate: now.addingTimeInterval(-Self.maximumSuggestionAge), in: modelContext)
        }
        let cacheKey = KeywordSuggestionCacheKey(request: request, watermark: watermark)

        if let cachedSuggestions = await cache.value(for: cacheKey, now: now) {
            return cachedSuggestions
        }

        let registered = await cache.task(for: cacheKey) {
            Task(priority: .utility) {
                try await backgroundModelStore.read { modelContext in
                    try Self.suggestions(for: request, now: now, in: modelContext)
                }
            }
        }
        if registered.started {
            do {
                let suggestions = try await registered.task.value
                await cache.store(suggestions, for: cacheKey, now: now, ttl: cacheTTL)
                return suggestions
            } catch {
                await cache.removeInFlight(for: cacheKey)
                throw error
            }
        } else {
            return try await registered.task.value
        }
    }

    func suggestions(for trackedApp: TrackedApp, in modelContext: ModelContext) throws -> AppSuggestions {
        let trackedKeywords = try Self.trackedKeywords(for: trackedApp.appStoreID, in: modelContext)
        let request = KeywordSuggestionRequest(
            appStoreID: trackedApp.appStoreID,
            trackedIdentityKeys: Set(trackedKeywords.map(\.identityKey)),
            trackedQueryKeys: Set(trackedKeywords.map(\.queryKey))
        )
        return try Self.suggestions(for: request, now: now(), in: modelContext)
    }

    private static func trackedKeywords(for appStoreID: Int64, in modelContext: ModelContext) throws -> [TrackedAppKeyword] {
        let targetAppStoreID = appStoreID
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { keyword in
                keyword.appStoreID == targetAppStoreID
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private static func suggestions(
        for request: KeywordSuggestionRequest,
        now: Date,
        in modelContext: ModelContext
    ) throws -> AppSuggestions {
        var keywordEvidenceByIdentity: [String: KeywordSuggestionEvidence] = [:]
        let targetAppStoreID = request.appStoreID
        let maximumCutoffDate = now.addingTimeInterval(-maximumSuggestionAge)
        let strongCutoffDate = now.addingTimeInterval(-strongSuggestionAge)
        var targetItemDescriptor = FetchDescriptor<KeywordAppRanking>(
            predicate: #Predicate { item in
                item.appStoreID == targetAppStoreID
            },
            sortBy: [
                SortDescriptor(\.observedAt, order: .reverse),
                SortDescriptor(\.position, order: .forward)
            ]
        )
        targetItemDescriptor.fetchLimit = Self.targetItemFetchLimit

        for item in try modelContext.fetch(targetItemDescriptor) {
            guard
                !item.queryKey.isEmpty,
                !item.storefront.isEmpty,
                let platform = AppPlatform(rawValue: item.platformRaw),
                let keyword = keyword(from: item, queryKey: item.queryKey)
            else {
                continue
            }

            let identityKey = TrackedAppKeyword.makeIdentityKey(
                appStoreID: request.appStoreID,
                term: keyword,
                storefront: item.storefront,
                platform: platform
            )

            guard !request.trackedIdentityKeys.contains(identityKey) else {
                continue
            }

            let observedAt = item.observedAt
            guard observedAt >= maximumCutoffDate else { continue }
            guard observedAt >= strongCutoffDate || item.position <= 5 else { continue }

            keywordEvidenceByIdentity[identityKey, default: KeywordSuggestionEvidence(
                keyword: keyword,
                storefront: item.storefront,
                platform: platform
            )].add(item: item, observedAt: observedAt)
        }

        var appEvidenceByID: [Int64: AppSuggestionEvidence] = [:]

        for queryKey in request.trackedQueryKeys {
            var competitorDescriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { item in
                    item.queryKey == queryKey
                    && item.appStoreID != targetAppStoreID
                    && item.position <= 10
                },
                sortBy: [
                    SortDescriptor(\.observedAt, order: .reverse),
                    SortDescriptor(\.position, order: .forward)
                ]
            )
            competitorDescriptor.fetchLimit = Self.competitorItemFetchLimit

            for item in try modelContext.fetch(competitorDescriptor) {
                let observedAt = item.observedAt
                guard observedAt >= maximumCutoffDate else { continue }
                guard observedAt >= strongCutoffDate || item.position <= 5 else { continue }

                appEvidenceByID[item.appStoreID, default: AppSuggestionEvidence(
                    appStoreID: item.appStoreID,
                    name: item.name,
                    sellerName: item.sellerName
                )].add(item: item, queryKey: queryKey, observedAt: observedAt)
            }
        }

        let keywordSuggestions = keywordEvidenceByIdentity.values
            .map { ScoredKeywordSuggestion(evidence: $0, now: now) }
            .sorted {
                if $0.score == $1.score {
                    if $0.suggestion.bestObservedRank == $1.suggestion.bestObservedRank {
                        return $0.suggestion.latestObservedAt > $1.suggestion.latestObservedAt
                    }
                    return $0.suggestion.bestObservedRank < $1.suggestion.bestObservedRank
                }
                return $0.score > $1.score
            }
            .map(\.suggestion)

        let appSuggestions = appEvidenceByID.values
            .map { ScoredAppSuggestion(evidence: $0, now: now, trackedAppStoreIDs: request.trackedAppStoreIDs) }
            .sorted {
                if $0.isTracked != $1.isTracked {
                    return !$0.isTracked
                }
                if $0.score == $1.score {
                    if $0.suggestion.occurrenceCount == $1.suggestion.occurrenceCount {
                        return $0.suggestion.averagePosition < $1.suggestion.averagePosition
                    }
                    return $0.suggestion.occurrenceCount > $1.suggestion.occurrenceCount
                }
                return $0.score > $1.score
            }
            .map(\.suggestion)

        return AppSuggestions(
            keywordSuggestions: Array(keywordSuggestions.prefix(12)),
            appSuggestions: Array(appSuggestions.prefix(12))
        )
    }

    private static func watermark(
        for request: KeywordSuggestionRequest,
        cutoffDate: Date,
        in modelContext: ModelContext
    ) throws -> Date? {
        let targetAppStoreID = request.appStoreID
        var latestDate: Date?

        var targetDescriptor = FetchDescriptor<KeywordAppRanking>(
            predicate: #Predicate { item in
                item.appStoreID == targetAppStoreID
            },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        targetDescriptor.fetchLimit = 1
        if let observedAt = try modelContext.fetch(targetDescriptor).first?.observedAt, observedAt >= cutoffDate {
            latestDate = observedAt
        }

        for queryKey in request.trackedQueryKeys {
            var competitorDescriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { item in
                    item.queryKey == queryKey
                    && item.appStoreID != targetAppStoreID
                    && item.position <= 10
                },
                sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
            )
            competitorDescriptor.fetchLimit = 1

            if let observedAt = try modelContext.fetch(competitorDescriptor).first?.observedAt, observedAt >= cutoffDate {
                latestDate = max(latestDate ?? observedAt, observedAt)
            }
        }

        return latestDate
    }

    private static func keyword(from item: KeywordAppRanking, queryKey: String) -> String? {
        let suffix = "::\(item.storefront.lowercased())::\(item.platformRaw)"
        guard queryKey.hasSuffix(suffix) else {
            return queryKey
        }

        let keyword = String(queryKey.dropLast(suffix.count))
        return keyword.isEmpty ? nil : keyword
    }
}

struct KeywordSuggestionRequest: Sendable {
    let appStoreID: Int64
    let trackedIdentityKeys: Set<String>
    let trackedQueryKeys: Set<String>
    let trackedAppStoreIDs: Set<Int64>

    init(
        appStoreID: Int64,
        trackedIdentityKeys: Set<String>,
        trackedQueryKeys: Set<String>,
        trackedAppStoreIDs: Set<Int64> = []
    ) {
        self.appStoreID = appStoreID
        self.trackedIdentityKeys = trackedIdentityKeys
        self.trackedQueryKeys = trackedQueryKeys
        self.trackedAppStoreIDs = trackedAppStoreIDs
    }
}

struct AppSuggestions: Sendable {
    let keywordSuggestions: [SuggestedKeyword]
    let appSuggestions: [SuggestedApp]

    static let empty = AppSuggestions(keywordSuggestions: [], appSuggestions: [])

    func removingKeyword(id: SuggestedKeyword.ID) -> AppSuggestions {
        AppSuggestions(
            keywordSuggestions: keywordSuggestions.filter { $0.id != id },
            appSuggestions: appSuggestions
        )
    }

    func removingApp(appStoreID: SuggestedApp.ID) -> AppSuggestions {
        AppSuggestions(
            keywordSuggestions: keywordSuggestions,
            appSuggestions: appSuggestions.filter { $0.appStoreID != appStoreID }
        )
    }
}

struct SuggestedKeyword: Identifiable, Hashable, Sendable {
    let keyword: String
    let storefront: String
    let platform: AppPlatform
    let bestObservedRank: Int
    let currentObservedRank: Int
    let latestObservedAt: Date
    let source: RankingSource

    var id: String {
        TrackedAppKeyword.makeQueryKey(term: keyword, storefront: storefront, platform: platform)
    }

    fileprivate func merged(with other: SuggestedKeyword) -> SuggestedKeyword {
        SuggestedKeyword(
            keyword: keyword,
            storefront: storefront,
            platform: platform,
            bestObservedRank: min(bestObservedRank, other.bestObservedRank),
            currentObservedRank: latestObservedAt >= other.latestObservedAt ? currentObservedRank : other.currentObservedRank,
            latestObservedAt: max(latestObservedAt, other.latestObservedAt),
            source: latestObservedAt >= other.latestObservedAt ? source : other.source
        )
    }
}

struct SuggestedApp: Identifiable, Hashable, Sendable {
    let appStoreID: Int64
    let name: String
    let sellerName: String?
    let iconURLString: String?
    let averagePosition: Double
    let occurrenceCount: Int

    var id: Int64 { appStoreID }

    fileprivate func merged(with other: SuggestedApp) -> SuggestedApp {
        let combinedOccurrenceCount = occurrenceCount + other.occurrenceCount
        let combinedAveragePosition = (
            (averagePosition * Double(occurrenceCount))
            + (other.averagePosition * Double(other.occurrenceCount))
        ) / Double(combinedOccurrenceCount)

        return SuggestedApp(
            appStoreID: appStoreID,
            name: name,
            sellerName: sellerName ?? other.sellerName,
            iconURLString: iconURLString ?? other.iconURLString,
            averagePosition: combinedAveragePosition,
            occurrenceCount: combinedOccurrenceCount
        )
    }
}

private struct KeywordSuggestionCacheKey: Hashable, Sendable {
    let appStoreID: Int64
    let trackedIdentitySignature: String
    let trackedQuerySignature: String
    let trackedAppSignature: String
    let watermark: TimeInterval?
    let scoringVersion: Int

    init(request: KeywordSuggestionRequest, watermark: Date?) {
        self.appStoreID = request.appStoreID
        self.trackedIdentitySignature = request.trackedIdentityKeys.sorted().joined(separator: "|")
        self.trackedQuerySignature = request.trackedQueryKeys.sorted().joined(separator: "|")
        self.trackedAppSignature = request.trackedAppStoreIDs.sorted().map(String.init).joined(separator: "|")
        self.watermark = watermark?.timeIntervalSince1970
        self.scoringVersion = KeywordSuggestionService.scoringVersion
    }
}

private actor KeywordSuggestionCache {
    private struct Entry {
        let suggestions: AppSuggestions
        let expiresAt: Date
    }

    private var entries: [KeywordSuggestionCacheKey: Entry] = [:]
    private var inFlightTasks: [KeywordSuggestionCacheKey: Task<AppSuggestions, Error>] = [:]

    func value(for key: KeywordSuggestionCacheKey, now: Date) -> AppSuggestions? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries[key] = nil
            return nil
        }
        return entry.suggestions
    }

    func task(
        for key: KeywordSuggestionCacheKey,
        create: @Sendable () -> Task<AppSuggestions, Error>
    ) -> (task: Task<AppSuggestions, Error>, started: Bool) {
        if let inFlightTask = inFlightTasks[key] {
            return (inFlightTask, false)
        }

        let task = create()
        inFlightTasks[key] = task
        return (task, true)
    }

    func store(
        _ suggestions: AppSuggestions,
        for key: KeywordSuggestionCacheKey,
        now: Date,
        ttl: TimeInterval
    ) {
        inFlightTasks[key] = nil
        entries[key] = Entry(
            suggestions: suggestions,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    func removeInFlight(for key: KeywordSuggestionCacheKey) {
        inFlightTasks[key] = nil
    }
}

private struct KeywordSuggestionEvidence {
    let keyword: String
    let storefront: String
    let platform: AppPlatform
    private(set) var bestObservedRank = Int.max
    private(set) var currentObservedRank = Int.max
    private(set) var latestObservedAt = Date.distantPast
    private(set) var source: RankingSource = .iTunesFallback
    private(set) var observationCount = 0
    private(set) var observedDays: Set<Int> = []
    private var collapsedEvidenceKeys: Set<String> = []

    init(keyword: String, storefront: String, platform: AppPlatform) {
        self.keyword = keyword
        self.storefront = storefront
        self.platform = platform
    }

    mutating func add(item: KeywordAppRanking, observedAt: Date) {
        let day = KeywordRankingCrawl.utcDayBucket(for: observedAt)
        let evidenceKey = "\(item.queryKey)|\(day)"
        guard collapsedEvidenceKeys.insert(evidenceKey).inserted else {
            if item.position < bestObservedRank {
                bestObservedRank = item.position
            }
            if observedAt > latestObservedAt || (observedAt == latestObservedAt && item.position < currentObservedRank) {
                latestObservedAt = observedAt
                currentObservedRank = item.position
                source = item.observation.source
            }
            return
        }

        bestObservedRank = min(bestObservedRank, item.position)
        if observedAt > latestObservedAt || (observedAt == latestObservedAt && item.position < currentObservedRank) {
            latestObservedAt = observedAt
            currentObservedRank = item.position
            source = item.observation.source
        }
        observationCount += 1
        observedDays.insert(day)
    }
}

private struct AppSuggestionEvidence {
    let appStoreID: Int64
    private(set) var name: String
    private(set) var sellerName: String?
    private(set) var bestObservedRank = Int.max
    private(set) var latestObservedAt = Date.distantPast
    private(set) var positionSum = 0
    private(set) var observationCount = 0
    private(set) var queryKeys: Set<String> = []
    private(set) var observedDays: Set<Int> = []
    private var collapsedEvidenceKeys: Set<String> = []

    init(appStoreID: Int64, name: String, sellerName: String?) {
        self.appStoreID = appStoreID
        self.name = name
        self.sellerName = sellerName
    }

    mutating func add(item: KeywordAppRanking, queryKey: String, observedAt: Date) {
        let day = KeywordRankingCrawl.utcDayBucket(for: observedAt)
        let evidenceKey = "\(queryKey)|\(day)"
        guard collapsedEvidenceKeys.insert(evidenceKey).inserted else {
            if item.position < bestObservedRank {
                bestObservedRank = item.position
            }
            if observedAt > latestObservedAt {
                latestObservedAt = observedAt
                name = item.name
                sellerName = item.sellerName ?? sellerName
            }
            return
        }

        bestObservedRank = min(bestObservedRank, item.position)
        latestObservedAt = max(latestObservedAt, observedAt)
        positionSum += item.position
        observationCount += 1
        queryKeys.insert(queryKey)
        observedDays.insert(day)

        if observedAt >= latestObservedAt {
            name = item.name
            sellerName = item.sellerName ?? sellerName
        }
    }
}

private struct ScoredKeywordSuggestion {
    let suggestion: SuggestedKeyword
    let score: Double

    init(evidence: KeywordSuggestionEvidence, now: Date) {
        let recency = Self.recencyScore(latestObservedAt: evidence.latestObservedAt, now: now)
        let rankScore = max(0, 11 - evidence.bestObservedRank)
        let frequencyScore = min(Double(evidence.observationCount), 5)
        let dayScore = min(Double(evidence.observedDays.count), 4)

        self.score = (Double(rankScore) * 2.0) + (recency * 10.0) + (frequencyScore * 1.5) + dayScore
        self.suggestion = SuggestedKeyword(
            keyword: evidence.keyword,
            storefront: evidence.storefront,
            platform: evidence.platform,
            bestObservedRank: evidence.bestObservedRank,
            currentObservedRank: evidence.currentObservedRank,
            latestObservedAt: evidence.latestObservedAt,
            source: evidence.source
        )
    }

    private static func recencyScore(latestObservedAt: Date, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(latestObservedAt) / 86_400)
        return max(0, 1 - (ageDays / 90))
    }
}

private struct ScoredAppSuggestion {
    let suggestion: SuggestedApp
    let score: Double
    let isTracked: Bool

    init(evidence: AppSuggestionEvidence, now: Date, trackedAppStoreIDs: Set<Int64> = []) {
        let averagePosition = evidence.observationCount == 0
            ? 0
            : Double(evidence.positionSum) / Double(evidence.observationCount)
        let rankScore = max(0, 11 - averagePosition)
        let queryScore = min(Double(evidence.queryKeys.count), 8)
        let dayScore = min(Double(evidence.observedDays.count), 5)
        let recency = Self.recencyScore(latestObservedAt: evidence.latestObservedAt, now: now)

        self.score = (queryScore * 7.0) + (rankScore * 1.5) + (dayScore * 1.5) + (recency * 8.0)
        self.isTracked = trackedAppStoreIDs.contains(evidence.appStoreID)
        self.suggestion = SuggestedApp(
            appStoreID: evidence.appStoreID,
            name: evidence.name,
            sellerName: evidence.sellerName,
            iconURLString: nil,
            averagePosition: averagePosition,
            occurrenceCount: evidence.observationCount
        )
    }

    private static func recencyScore(latestObservedAt: Date, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(latestObservedAt) / 86_400)
        return max(0, 1 - (ageDays / 90))
    }
}
