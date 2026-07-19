import CryptoKit
import Foundation
import SwiftData

struct KeywordMarketInsightsRequest: Equatable, Sendable {
    static let defaultKeywordLimit = 25
    static let maximumKeywordLimit = 50
    static let defaultMarketEvidenceLimit = 500
    static let maximumMarketEvidenceLimit = 500
    static let maximumStorefrontCount = 250
    static let maximumStorefrontLength = 16
    static let maximumKeywordLength = 200
    static let maximumCursorLength = 4_096

    let appStoreID: Int64
    let storefronts: [String]
    let platform: AppPlatform
    let keyword: String?
    let limit: Int
    let marketEvidenceLimit: Int
    let cursor: String?

    init(
        appStoreID: Int64,
        storefronts: [String],
        platform: AppPlatform,
        keyword: String? = nil,
        limit: Int? = nil,
        marketEvidenceLimit: Int? = nil,
        cursor: String? = nil
    ) throws {
        guard appStoreID > 0 else { throw OpenASOError.invalidAppStoreID }
        guard !storefronts.isEmpty else {
            throw OpenASOError.providerUnavailable(
                "Market insights require at least one explicit storefront."
            )
        }
        guard storefronts.count <= Self.maximumStorefrontCount else {
            throw OpenASOError.providerUnavailable(
                "Select at most \(Self.maximumStorefrontCount) storefronts."
            )
        }

        let normalizedStorefronts = try Array(Set(storefronts.map { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else {
                throw OpenASOError.providerUnavailable(
                    "Storefronts must be non-empty country codes."
                )
            }
            guard normalized.utf8.count <= Self.maximumStorefrontLength else {
                throw OpenASOError.providerUnavailable(
                    "Storefront country codes must not exceed \(Self.maximumStorefrontLength) bytes."
                )
            }
            return normalized
        })).sorted()

        let normalizedKeyword: String?
        if let keyword {
            let normalized = Self.normalizeKeyword(keyword)
            guard !normalized.isEmpty else { throw OpenASOError.emptyQuery }
            guard normalized.utf8.count <= Self.maximumKeywordLength else {
                throw OpenASOError.providerUnavailable(
                    "Keyword must not exceed \(Self.maximumKeywordLength) bytes."
                )
            }
            normalizedKeyword = normalized
        } else {
            normalizedKeyword = nil
        }

        let resolvedLimit = limit ?? Self.defaultKeywordLimit
        guard (1 ... Self.maximumKeywordLimit).contains(resolvedLimit) else {
            throw OpenASOError.providerUnavailable(
                "Keyword limit must be between 1 and \(Self.maximumKeywordLimit)."
            )
        }
        let resolvedMarketEvidenceLimit = marketEvidenceLimit
            ?? Self.defaultMarketEvidenceLimit
        guard (1 ... Self.maximumMarketEvidenceLimit).contains(
            resolvedMarketEvidenceLimit
        ) else {
            throw OpenASOError.providerUnavailable(
                "Market evidence limit must be between 1 and \(Self.maximumMarketEvidenceLimit)."
            )
        }
        guard resolvedMarketEvidenceLimit >= normalizedStorefronts.count else {
            throw OpenASOError.providerUnavailable(
                "Market evidence limit must be at least the number of requested storefronts."
            )
        }
        if let cursor {
            guard normalizedKeyword == nil else {
                throw OpenASOError.providerUnavailable(
                    "Exact-keyword market insight requests do not accept a cursor."
                )
            }
            guard !cursor.isEmpty, cursor.utf8.count <= Self.maximumCursorLength else {
                throw OpenASOError.providerUnavailable(
                    "Market insights cursor is empty or exceeds the maximum encoded length."
                )
            }
        }

        self.appStoreID = appStoreID
        self.storefronts = normalizedStorefronts
        self.platform = platform
        self.keyword = normalizedKeyword
        self.limit = resolvedLimit
        self.marketEvidenceLimit = resolvedMarketEvidenceLimit
        self.cursor = cursor
    }

    var effectiveKeywordLimit: Int {
        min(limit, marketEvidenceLimit / storefronts.count)
    }

    static func normalizeKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum KeywordMarketInsightsStableIdentity {
    static func keywordDigest(_ normalizedKeyword: String) -> String {
        SHA256.hash(data: Data(normalizedKeyword.utf8))
            .map { String(format: "%02x", Int($0)) }
            .joined()
    }
}

struct KeywordMarketInsightsScope: Codable, Equatable, Sendable {
    let appStoreID: Int64
    let storefronts: [String]
    let platform: AppPlatform
    let keyword: String?
}

enum KeywordMarketInsightState: String, Codable, CaseIterable, Sendable {
    case notTracked = "not_tracked"
    case neverRefreshed = "never_refreshed"
    case ranked
    case notRanked = "not_ranked"
    case failedWithCachedEvidence = "failed_with_cached_evidence"
    case failedWithoutEvidence = "failed_without_evidence"
    case unavailable
}

enum KeywordMarketInsightsPartialReason: String, Codable, CaseIterable, Sendable {
    case notTracked = "not_tracked"
    case neverRefreshed = "never_refreshed"
    case rankingRefreshFailed = "ranking_refresh_failed"
    case staleRankingEvidence = "stale_ranking_evidence"
    case snapshotScanCapped = "snapshot_scan_capped"
    case statusScanCapped = "status_scan_capped"
}

struct KeywordMarketInsightRankingEvidence: Codable, Equatable, Sendable {
    let rank: Int?
    let searchedAt: Date
    let source: RankingSource
    let resultCount: Int
    let snapshotKey: String
}

struct KeywordMarketInsightRankingFailure: Codable, Equatable, Sendable {
    let message: String
    let updatedAt: Date
}

struct KeywordMarketInsightDifficulty: Codable, Equatable, Sendable {
    let state: String
    let score: Int?
    let confidenceScore: Int?
    let confidence: String?
    let unavailableReason: String?
    let estimationSource: String
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let rankingSource: String
    let rankingFetchedAt: Date
    let computedAt: Date
    let isStale: Bool
}

struct KeywordMarketInsightMarket: Codable, Equatable, Identifiable, Sendable {
    var id: String { storefront }

    let storefront: String
    let trackIdentityKey: String?
    let state: KeywordMarketInsightState
    let rankingEvidence: KeywordMarketInsightRankingEvidence?
    let rankingFailure: KeywordMarketInsightRankingFailure?
    let estimatedDifficulty: KeywordMarketInsightDifficulty?
    let isStale: Bool
    let isPartial: Bool
}

struct KeywordMarketInsightRankSummary: Codable, Equatable, Sendable {
    let storefront: String
    let rank: Int
    let searchedAt: Date
    let source: RankingSource
    let state: KeywordMarketInsightState
    let isStale: Bool
}

struct KeywordMarketInsightSummary: Codable, Equatable, Sendable {
    let requestedMarketCount: Int
    let trackedMarketCount: Int
    let availableRankingEvidenceCount: Int
    let rankedEvidenceMarketCount: Int
    let freshRankedMarketCount: Int
    let notRankedMarketCount: Int
    let neverRefreshedMarketCount: Int
    let failedWithCachedEvidenceMarketCount: Int
    let failedWithoutEvidenceMarketCount: Int
    let notTrackedMarketCount: Int
    let unavailableMarketCount: Int
    let staleMarketCount: Int
    let bestMarket: KeywordMarketInsightRankSummary?
    let worstMarket: KeywordMarketInsightRankSummary?
    let averageRank: Double?
    let rankSpread: Int?
}

struct KeywordMarketInsight: Codable, Equatable, Identifiable, Sendable {
    var id: String { [normalizedKeyword, platform.rawValue].joined(separator: "::") }

    let keyword: String
    let normalizedKeyword: String
    let platform: AppPlatform
    let markets: [KeywordMarketInsightMarket]
    let summary: KeywordMarketInsightSummary
    let isPartial: Bool
    let partialReasons: [KeywordMarketInsightsPartialReason]
}

struct KeywordMarketInsightsPage: Codable, Equatable, Sendable {
    let scope: KeywordMarketInsightsScope
    let items: [KeywordMarketInsight]
    let nextCursor: String?
    let requestedKeywordLimit: Int
    let effectiveKeywordLimit: Int
    let marketEvidenceLimit: Int
    let returnedMarketEvidenceCount: Int
    let isPartial: Bool
    let partialReasons: [KeywordMarketInsightsPartialReason]
    let staleMarketCount: Int
}

struct KeywordMarketInsightsService: Sendable {
    private static let rankingFreshnessInterval: TimeInterval = 24 * 60 * 60

    private let backgroundModelStore: BackgroundModelStore
    private let now: @Sendable () -> Date
    private let maximumTrackScanCount: Int
    private let maximumSnapshotScanCount: Int
    private let maximumStatusScanCount: Int

    init(
        backgroundModelStore: BackgroundModelStore,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumTrackScanCount: Int = 10_000,
        maximumSnapshotScanCount: Int = 10_000,
        maximumStatusScanCount: Int = 10_000
    ) {
        precondition(maximumTrackScanCount > 0)
        precondition(maximumSnapshotScanCount > 0)
        precondition(maximumStatusScanCount > 0)
        self.backgroundModelStore = backgroundModelStore
        self.now = now
        self.maximumTrackScanCount = maximumTrackScanCount
        self.maximumSnapshotScanCount = maximumSnapshotScanCount
        self.maximumStatusScanCount = maximumStatusScanCount
    }

    func insights(
        for request: KeywordMarketInsightsRequest
    ) async throws -> KeywordMarketInsightsPage {
        try Task.checkCancellation()
        let scope = KeywordMarketInsightsScope(
            appStoreID: request.appStoreID,
            storefronts: request.storefronts,
            platform: request.platform,
            keyword: request.keyword
        )
        let cursor = try KeywordMarketInsightsCursorCodec.decode(
            request.cursor,
            expectedScope: KeywordMarketInsightsCursorScope(request: request)
        )
        let asOf = now()

        return try await backgroundModelStore.read { modelContext in
            try Task.checkCancellation()
            let scopedTracks = try Self.fetchScopedTracks(
                request: request,
                maximumScanCount: maximumTrackScanCount,
                in: modelContext
            )
            try Task.checkCancellation()

            let groupedTracks = Dictionary(grouping: scopedTracks) {
                KeywordMarketInsightsRequest.normalizeKeyword($0.term)
            }
            let allKeywordKeys = groupedTracks.keys.sorted()
            let orderedKeywordKeys: [String]
            if let cursor {
                guard let cursorIndex = allKeywordKeys.firstIndex(where: {
                    KeywordMarketInsightsStableIdentity.keywordDigest($0)
                        == cursor.lastKeywordDigest
                }) else {
                    throw OpenASOError.providerUnavailable(
                        "Market insights cursor no longer matches the stored keyword scope. Restart pagination."
                    )
                }
                orderedKeywordKeys = Array(allKeywordKeys.dropFirst(cursorIndex + 1))
            } else {
                orderedKeywordKeys = allKeywordKeys
            }
            let pageKeywordKeys: [String]
            let hasMore: Bool
            if request.keyword != nil {
                pageKeywordKeys = [request.keyword!]
                hasMore = false
            } else {
                pageKeywordKeys = Array(
                    orderedKeywordKeys.prefix(request.effectiveKeywordLimit)
                )
                hasMore = orderedKeywordKeys.count > request.effectiveKeywordLimit
            }
            guard !pageKeywordKeys.isEmpty else {
                return KeywordMarketInsightsPage(
                    scope: scope,
                    items: [],
                    nextCursor: nil,
                    requestedKeywordLimit: request.limit,
                    effectiveKeywordLimit: request.effectiveKeywordLimit,
                    marketEvidenceLimit: request.marketEvidenceLimit,
                    returnedMarketEvidenceCount: 0,
                    isPartial: false,
                    partialReasons: [],
                    staleMarketCount: 0
                )
            }

            let pageTracks = pageKeywordKeys.flatMap { groupedTracks[$0] ?? [] }
            let identityKeys = pageTracks.map(\.identityKey)
            let queryKeys = Array(Set(pageTracks.map(\.queryKey)))
            let snapshotLoad = try Self.latestSnapshots(
                trackIdentityKeys: identityKeys,
                maximumScanCount: maximumSnapshotScanCount,
                in: modelContext
            )
            try Task.checkCancellation()
            let statusLoad = try Self.rankingStatuses(
                trackIdentityKeys: identityKeys,
                maximumScanCount: maximumStatusScanCount,
                in: modelContext
            )
            try Task.checkCancellation()
            let difficulties = try EstimatedKeywordDifficultyStore.summaries(
                queryKeys: queryKeys,
                in: modelContext
            )

            let items = try pageKeywordKeys.map { normalizedKeyword in
                try Task.checkCancellation()
                return Self.makeInsight(
                    normalizedKeyword: normalizedKeyword,
                    tracks: groupedTracks[normalizedKeyword] ?? [],
                    request: request,
                    snapshots: snapshotLoad.snapshots,
                    snapshotScanCapped: snapshotLoad.wasCapped,
                    persistedStatuses: statusLoad.statuses,
                    statusScanCutoff: statusLoad.firstOmittedUpdatedAt,
                    difficulties: difficulties,
                    asOf: asOf
                )
            }
            let pageReasons = Self.sortedReasons(
                Set(items.flatMap(\.partialReasons))
            )
            let nextCursor: String?
            if hasMore, let lastKeyword = items.last?.normalizedKeyword {
                nextCursor = try KeywordMarketInsightsCursorCodec.encode(
                    scope: KeywordMarketInsightsCursorScope(request: request),
                    lastNormalizedKeyword: lastKeyword
                )
            } else {
                nextCursor = nil
            }

            return KeywordMarketInsightsPage(
                scope: scope,
                items: items,
                nextCursor: nextCursor,
                requestedKeywordLimit: request.limit,
                effectiveKeywordLimit: request.effectiveKeywordLimit,
                marketEvidenceLimit: request.marketEvidenceLimit,
                returnedMarketEvidenceCount: items.reduce(0) { $0 + $1.markets.count },
                isPartial: !pageReasons.isEmpty,
                partialReasons: pageReasons,
                staleMarketCount: items.reduce(0) {
                    $0 + $1.summary.staleMarketCount
                }
            )
        }
    }

    private static func fetchScopedTracks(
        request: KeywordMarketInsightsRequest,
        maximumScanCount: Int,
        in modelContext: ModelContext
    ) throws -> [TrackedAppKeyword] {
        let appStoreID = request.appStoreID
        let storefronts = request.storefronts
        let platformRaw = request.platform.rawValue

        if let keyword = request.keyword {
            let identityKeys = storefronts.map { storefront in
                TrackedAppKeyword.makeIdentityKey(
                    appStoreID: appStoreID,
                    term: keyword,
                    storefront: storefront,
                    platform: request.platform
                )
            }
            var descriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    identityKeys.contains(track.identityKey)
                },
                sortBy: [
                    SortDescriptor(\.identityKey, comparator: .lexical, order: .forward)
                ]
            )
            descriptor.fetchLimit = storefronts.count
            return try modelContext.fetch(descriptor)
        }

        var descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.appStoreID == appStoreID
                    && track.platformRaw == platformRaw
                    && storefronts.contains(track.storefront)
            },
            sortBy: [
                SortDescriptor(\.identityKey, comparator: .lexical, order: .forward)
            ]
        )
        descriptor.fetchLimit = maximumScanCount + 1
        let tracks = try modelContext.fetch(descriptor)
        guard tracks.count <= maximumScanCount else {
            throw OpenASOError.providerUnavailable(
                "Market insights scope exceeds the bounded track scan. Narrow the storefronts or request an exact keyword."
            )
        }
        return tracks
    }

    private struct SnapshotLoad {
        let snapshots: [String: TrackedKeywordDailyRanking]
        let wasCapped: Bool
    }

    private static func latestSnapshots(
        trackIdentityKeys: [String],
        maximumScanCount: Int,
        in modelContext: ModelContext
    ) throws -> SnapshotLoad {
        guard !trackIdentityKeys.isEmpty else {
            return SnapshotLoad(snapshots: [:], wasCapped: false)
        }
        var descriptor = FetchDescriptor<TrackedKeywordDailyRanking>(
            predicate: #Predicate { snapshot in
                trackIdentityKeys.contains(snapshot.trackIdentityKey)
            },
            sortBy: [
                SortDescriptor(\.searchedAt, order: .reverse),
                SortDescriptor(\.snapshotKey, comparator: .lexical, order: .forward)
            ]
        )
        descriptor.fetchLimit = maximumScanCount + 1
        let rows = try modelContext.fetch(descriptor)
        let wasCapped = rows.count > maximumScanCount
        var snapshots: [String: TrackedKeywordDailyRanking] = [:]
        for snapshot in rows.prefix(maximumScanCount)
            where snapshots[snapshot.trackIdentityKey] == nil
        {
            snapshots[snapshot.trackIdentityKey] = snapshot
        }
        return SnapshotLoad(snapshots: snapshots, wasCapped: wasCapped)
    }

    private struct StatusLoad {
        let statuses: [String: KeywordRefreshStatusSnapshot]
        let firstOmittedUpdatedAt: Date?
    }

    private static func rankingStatuses(
        trackIdentityKeys: [String],
        maximumScanCount: Int,
        in modelContext: ModelContext
    ) throws -> StatusLoad {
        guard !trackIdentityKeys.isEmpty else {
            return StatusLoad(statuses: [:], firstOmittedUpdatedAt: nil)
        }
        var descriptor = FetchDescriptor<TrackedKeywordRefreshStatus>(
            predicate: #Predicate { status in
                trackIdentityKeys.contains(status.trackIdentityKey)
            },
            sortBy: [
                SortDescriptor(\.updatedAt, order: .reverse),
                SortDescriptor(\.statusKey, comparator: .lexical, order: .forward)
            ]
        )
        descriptor.fetchLimit = maximumScanCount + 1
        let rows = try modelContext.fetch(descriptor)
        let firstOmittedUpdatedAt = rows.count > maximumScanCount
            ? rows[maximumScanCount].updatedAt
            : nil
        let statuses = TrackedKeywordRefreshStatusStore.snapshots(
            from: Array(rows.prefix(maximumScanCount))
        )
        return StatusLoad(
            statuses: statuses,
            firstOmittedUpdatedAt: firstOmittedUpdatedAt
        )
    }

    private static func makeInsight(
        normalizedKeyword: String,
        tracks: [TrackedAppKeyword],
        request: KeywordMarketInsightsRequest,
        snapshots: [String: TrackedKeywordDailyRanking],
        snapshotScanCapped: Bool,
        persistedStatuses: [String: KeywordRefreshStatusSnapshot],
        statusScanCutoff: Date?,
        difficulties: [String: EstimatedKeywordDifficultySummary],
        asOf: Date
    ) -> KeywordMarketInsight {
        let tracksByStorefront = Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.storefront, $0)
        })
        let displayKeyword = tracks
            .map(\.term)
            .sorted { left, right in
                let insensitive = left.localizedCaseInsensitiveCompare(right)
                if insensitive != .orderedSame { return insensitive == .orderedAscending }
                return left < right
            }
            .first ?? normalizedKeyword
        let snapshotCoverageIncomplete = snapshotScanCapped
            && tracks.contains { snapshots[$0.identityKey] == nil }
        let statusCoverageIncomplete = statusScanCutoff != nil
            && tracks.contains {
                statusCoverageIsUnknown(
                    for: $0,
                    persistedStatus: persistedStatuses[$0.identityKey],
                    latestSnapshotSearchedAt: snapshots[$0.identityKey]?.searchedAt,
                    firstOmittedUpdatedAt: statusScanCutoff
                )
            }

        let markets = request.storefronts.map { storefront in
            guard let track = tracksByStorefront[storefront] else {
                return KeywordMarketInsightMarket(
                    storefront: storefront,
                    trackIdentityKey: nil,
                    state: .notTracked,
                    rankingEvidence: nil,
                    rankingFailure: nil,
                    estimatedDifficulty: nil,
                    isStale: false,
                    isPartial: true
                )
            }

            let snapshot = snapshots[track.identityKey]
            let persistedStatus = persistedStatuses[track.identityKey]
            let status = TrackedKeywordRefreshStatusStore.snapshot(
                for: track,
                persisted: persistedStatus
            )
            let statusCoverageUnknown = statusCoverageIsUnknown(
                for: track,
                persistedStatus: persistedStatus,
                latestSnapshotSearchedAt: snapshot?.searchedAt,
                firstOmittedUpdatedAt: statusScanCutoff
            )
            let snapshotCoverageUnknown = snapshotScanCapped && snapshot == nil
            let evidence = snapshot.map {
                KeywordMarketInsightRankingEvidence(
                    rank: $0.rank,
                    searchedAt: $0.searchedAt,
                    source: $0.source,
                    resultCount: $0.resultCount,
                    snapshotKey: $0.snapshotKey
                )
            }
            let failureIsLatest = !statusCoverageUnknown
                && status.rankingMessage != nil
                && status.rankingUpdatedAt != nil
                && (snapshot == nil || status.rankingUpdatedAt! >= snapshot!.searchedAt)
            let failure: KeywordMarketInsightRankingFailure?
            if failureIsLatest,
               let message = status.rankingMessage,
               let updatedAt = status.rankingUpdatedAt {
                failure = KeywordMarketInsightRankingFailure(
                    message: message,
                    updatedAt: updatedAt
                )
            } else {
                failure = nil
            }

            let state: KeywordMarketInsightState
            if snapshotCoverageUnknown || statusCoverageUnknown {
                state = .unavailable
            } else if failure != nil {
                state = snapshot == nil
                    ? .failedWithoutEvidence
                    : .failedWithCachedEvidence
            } else if let snapshot {
                state = snapshot.rank == nil ? .notRanked : .ranked
            } else {
                state = .neverRefreshed
            }

            let isStale = snapshot.map {
                asOf.timeIntervalSince($0.searchedAt) >= rankingFreshnessInterval
            } ?? false
            let difficulty = difficulties[track.queryKey].map {
                KeywordMarketInsightDifficulty(
                    state: $0.stateRaw,
                    score: $0.score,
                    confidenceScore: $0.confidenceScore,
                    confidence: $0.confidenceRaw,
                    unavailableReason: $0.unavailableReasonRaw,
                    estimationSource: $0.estimationSourceRaw,
                    algorithmIdentifier: $0.algorithmIdentifier,
                    algorithmVersion: $0.algorithmVersion,
                    rankingSource: $0.rankingSourceRaw,
                    rankingFetchedAt: $0.rankingFetchedAt,
                    computedAt: $0.computedAt,
                    isStale: $0.isStale(asOf: asOf)
                )
            }
            let isPartial = state == .notTracked
                || state == .neverRefreshed
                || state == .failedWithCachedEvidence
                || state == .failedWithoutEvidence
                || state == .unavailable
                || isStale
            return KeywordMarketInsightMarket(
                storefront: storefront,
                trackIdentityKey: track.identityKey,
                state: state,
                rankingEvidence: evidence,
                rankingFailure: failure,
                estimatedDifficulty: difficulty,
                isStale: isStale,
                isPartial: isPartial
            )
        }

        let reasons = partialReasons(
            for: markets,
            snapshotCoverageIncomplete: snapshotCoverageIncomplete,
            statusCoverageIncomplete: statusCoverageIncomplete
        )
        return KeywordMarketInsight(
            keyword: displayKeyword,
            normalizedKeyword: normalizedKeyword,
            platform: request.platform,
            markets: markets,
            summary: summary(for: markets),
            isPartial: !reasons.isEmpty,
            partialReasons: reasons
        )
    }

    private static func partialReasons(
        for markets: [KeywordMarketInsightMarket],
        snapshotCoverageIncomplete: Bool,
        statusCoverageIncomplete: Bool
    ) -> [KeywordMarketInsightsPartialReason] {
        var reasons: Set<KeywordMarketInsightsPartialReason> = []
        for market in markets {
            switch market.state {
            case .notTracked:
                reasons.insert(.notTracked)
            case .neverRefreshed:
                reasons.insert(.neverRefreshed)
            case .failedWithCachedEvidence, .failedWithoutEvidence:
                reasons.insert(.rankingRefreshFailed)
            case .ranked, .notRanked, .unavailable:
                break
            }
            if market.isStale {
                reasons.insert(.staleRankingEvidence)
            }
        }
        if snapshotCoverageIncomplete { reasons.insert(.snapshotScanCapped) }
        if statusCoverageIncomplete { reasons.insert(.statusScanCapped) }
        return sortedReasons(reasons)
    }

    private static func statusCoverageIsUnknown(
        for track: TrackedAppKeyword,
        persistedStatus: KeywordRefreshStatusSnapshot?,
        latestSnapshotSearchedAt: Date?,
        firstOmittedUpdatedAt: Date?
    ) -> Bool {
        guard let firstOmittedUpdatedAt else { return false }
        if let latestSnapshotSearchedAt,
           latestSnapshotSearchedAt > firstOmittedUpdatedAt {
            return false
        }
        guard
            persistedStatus?.trackCreatedAt == track.createdAt,
            let rankingUpdatedAt = persistedStatus?.rankingUpdatedAt
        else {
            return true
        }
        // Equal-time contenders may be split across the scan boundary. Coverage
        // is only conclusive when the retained ranking event is strictly newer.
        return rankingUpdatedAt <= firstOmittedUpdatedAt
    }

    private static func summary(
        for markets: [KeywordMarketInsightMarket]
    ) -> KeywordMarketInsightSummary {
        let rankedMarkets = markets.compactMap { market -> KeywordMarketInsightRankSummary? in
            guard let evidence = market.rankingEvidence, let rank = evidence.rank else {
                return nil
            }
            return KeywordMarketInsightRankSummary(
                storefront: market.storefront,
                rank: rank,
                searchedAt: evidence.searchedAt,
                source: evidence.source,
                state: market.state,
                isStale: market.isStale
            )
        }.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.storefront < right.storefront
        }
        let rankValues = rankedMarkets.map(\.rank)
        let averageRank = rankValues.isEmpty
            ? nil
            : Double(rankValues.reduce(0, +)) / Double(rankValues.count)
        let bestMarket = rankedMarkets.first
        let worstMarket = rankedMarkets.sorted { left, right in
            if left.rank != right.rank { return left.rank > right.rank }
            return left.storefront < right.storefront
        }.first

        return KeywordMarketInsightSummary(
            requestedMarketCount: markets.count,
            trackedMarketCount: markets.count { $0.state != .notTracked },
            availableRankingEvidenceCount: markets.count { $0.rankingEvidence != nil },
            rankedEvidenceMarketCount: rankedMarkets.count,
            freshRankedMarketCount: markets.count {
                $0.state == .ranked && !$0.isStale
            },
            notRankedMarketCount: markets.count { $0.state == .notRanked },
            neverRefreshedMarketCount: markets.count { $0.state == .neverRefreshed },
            failedWithCachedEvidenceMarketCount: markets.count {
                $0.state == .failedWithCachedEvidence
            },
            failedWithoutEvidenceMarketCount: markets.count {
                $0.state == .failedWithoutEvidence
            },
            notTrackedMarketCount: markets.count { $0.state == .notTracked },
            unavailableMarketCount: markets.count { $0.state == .unavailable },
            staleMarketCount: markets.count(where: \.isStale),
            bestMarket: bestMarket,
            worstMarket: worstMarket,
            averageRank: averageRank,
            rankSpread: bestMarket.flatMap { best in
                worstMarket.map { $0.rank - best.rank }
            }
        )
    }

    private static func sortedReasons(
        _ reasons: Set<KeywordMarketInsightsPartialReason>
    ) -> [KeywordMarketInsightsPartialReason] {
        reasons.sorted { $0.rawValue < $1.rawValue }
    }
}

private struct KeywordMarketInsightsCursorScope: Codable, Sendable {
    let appStoreID: Int64
    let storefronts: [String]
    let platform: String
    let keyword: String?
    let keywordLimit: Int
    let marketEvidenceLimit: Int

    init(request: KeywordMarketInsightsRequest) {
        appStoreID = request.appStoreID
        storefronts = request.storefronts
        platform = request.platform.rawValue
        keyword = request.keyword
        keywordLimit = request.limit
        marketEvidenceLimit = request.marketEvidenceLimit
    }
}

private struct KeywordMarketInsightsCursor: Codable, Sendable {
    let version: Int
    let scopeDigest: String
    let lastKeywordDigest: String
}

private enum KeywordMarketInsightsCursorCodec {
    private static let version = 3

    static func decode(
        _ value: String?,
        expectedScope: KeywordMarketInsightsCursorScope
    ) throws -> KeywordMarketInsightsCursor? {
        guard let value else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard
            let data = Data(base64Encoded: base64),
            let cursor = try? JSONDecoder().decode(
                KeywordMarketInsightsCursor.self,
                from: data
            ),
            cursor.version == version,
            cursor.scopeDigest == (try scopeDigest(expectedScope)),
            cursor.scopeDigest.count == 64,
            isSHA256HexDigest(cursor.lastKeywordDigest)
        else {
            throw OpenASOError.providerUnavailable(
                "Market insights cursor is invalid or does not match this filter scope."
            )
        }
        return cursor
    }

    static func encode(
        scope: KeywordMarketInsightsCursorScope,
        lastNormalizedKeyword: String
    ) throws -> String {
        let cursor = KeywordMarketInsightsCursor(
            version: version,
            scopeDigest: try scopeDigest(scope),
            lastKeywordDigest: KeywordMarketInsightsStableIdentity.keywordDigest(
                lastNormalizedKeyword
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = try encoder.encode(cursor).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard value.utf8.count <= KeywordMarketInsightsRequest.maximumCursorLength else {
            throw OpenASOError.providerUnavailable(
                "Market insights cursor exceeds the maximum encoded length."
            )
        }
        return value
    }

    private static func scopeDigest(
        _ scope: KeywordMarketInsightsCursorScope
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(scope)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", Int($0)) }
            .joined()
    }

    private static func isSHA256HexDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            }
    }
}
