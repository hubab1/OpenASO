import Foundation
import SwiftData

@MainActor
final class KeywordInsightsService {
    struct Workspace: Sendable {
        struct Row: Sendable {
            let metrics: KeywordMetricsSnapshot?
            let refreshStatus: KeywordRefreshStatusSnapshot
            let latestSnapshot: KeywordRankingCrawlSummary?
            let trendSnapshots: [KeywordRankingCrawlSummary]
            let rankingApps: [KeywordRankingAppSummary]
        }

        let rowsByIdentityKey: [String: Row]
    }

    private struct TrackRequest: Sendable {
        let identityKey: String
        let queryKey: String
        let createdAt: Date
        let lastRefreshAt: Date?
        let legacyStatusMessage: String?

        init(_ track: TrackedAppKeyword) {
            identityKey = track.identityKey
            queryKey = track.queryKey
            createdAt = track.createdAt
            lastRefreshAt = track.lastRefreshAt
            legacyStatusMessage = track.statusMessage
        }
    }

    private struct CrawlRecord: Sendable {
        let queryKey: String
        let observationKey: String
        let observedAt: Date
        let source: RankingSource
        let resultCount: Int

        func summary(rank: Int?) -> KeywordRankingCrawlSummary {
            KeywordRankingCrawlSummary(
                id: observationKey,
                rank: rank,
                searchedAt: observedAt,
                source: source,
                resultCount: resultCount
            )
        }
    }

    private struct RankingRecord: Sendable {
        let crawlKey: String
        let position: Int
    }

    // A workspace can retain ranking history and top-app summaries for hundreds of
    // keywords. Keeping the current view plus two recent variants is enough for
    // fast navigation without allowing filter/date changes to retain eight copies.
    private static let cacheLimit = 3

    private var cachedWorkspaces: [KeywordWorkspaceProjection.MaterializationID: Workspace] = [:]
    private var cacheOrder: [KeywordWorkspaceProjection.MaterializationID] = []

    func cachedWorkspace(
        for materializationID: KeywordWorkspaceProjection.MaterializationID
    ) -> Workspace? {
        cachedWorkspaces[materializationID]
    }

    func workspace(
        for materializationID: KeywordWorkspaceProjection.MaterializationID,
        tracks: [TrackedAppKeyword],
        appStoreID: Int64,
        dateRange: TrendDateRange,
        using backgroundModelStore: BackgroundModelStore?,
        fallbackModelContext: ModelContext
    ) async throws -> Workspace {
        if let cachedWorkspace = cachedWorkspace(for: materializationID) {
            touch(materializationID)
            return cachedWorkspace
        }

        let requestTracks = tracks.map(TrackRequest.init)
        let cutoffDate = dateRange.cutoffDate
        let workspace: Workspace

        if let backgroundModelStore {
            workspace = try await backgroundModelStore.read { modelContext in
                try Self.loadWorkspace(
                    tracks: requestTracks,
                    appStoreID: appStoreID,
                    cutoffDate: cutoffDate,
                    in: modelContext
                )
            }
        } else {
            workspace = try Self.loadWorkspace(
                tracks: requestTracks,
                appStoreID: appStoreID,
                cutoffDate: cutoffDate,
                in: fallbackModelContext
            )
        }

        cache(workspace, for: materializationID)
        return workspace
    }

    func updatedRows(
        for trackIdentityKeys: [String],
        appStoreID: Int64,
        dateRange: TrendDateRange,
        using backgroundModelStore: BackgroundModelStore?,
        fallbackModelContext: ModelContext
    ) async throws -> [String: Workspace.Row] {
        let identityKeys = Array(Set(trackIdentityKeys))
        guard !identityKeys.isEmpty else { return [:] }

        let cutoffDate = dateRange.cutoffDate
        let workspace: Workspace
        if let backgroundModelStore {
            workspace = try await backgroundModelStore.read { modelContext in
                let tracks = try Self.fetchTrackRequests(
                    identityKeys: identityKeys,
                    appStoreID: appStoreID,
                    in: modelContext
                )
                return try Self.loadWorkspace(
                    tracks: tracks,
                    appStoreID: appStoreID,
                    cutoffDate: cutoffDate,
                    in: modelContext
                )
            }
        } else {
            let tracks = try Self.fetchTrackRequests(
                identityKeys: identityKeys,
                appStoreID: appStoreID,
                in: fallbackModelContext
            )
            workspace = try Self.loadWorkspace(
                tracks: tracks,
                appStoreID: appStoreID,
                cutoffDate: cutoffDate,
                in: fallbackModelContext
            )
        }

        mergeUpdatedRowsIntoCache(
            workspace.rowsByIdentityKey,
            appStoreID: appStoreID,
            dateRangeID: dateRange.id
        )
        return workspace.rowsByIdentityKey
    }

    private func cache(
        _ workspace: Workspace,
        for materializationID: KeywordWorkspaceProjection.MaterializationID
    ) {
        cachedWorkspaces[materializationID] = workspace
        touch(materializationID)

        while cacheOrder.count > Self.cacheLimit {
            cachedWorkspaces[cacheOrder.removeFirst()] = nil
        }
    }

    private func touch(_ materializationID: KeywordWorkspaceProjection.MaterializationID) {
        cacheOrder.removeAll { $0 == materializationID }
        cacheOrder.append(materializationID)
    }

    private func mergeUpdatedRowsIntoCache(
        _ rowsByIdentityKey: [String: Workspace.Row],
        appStoreID: Int64,
        dateRangeID: String
    ) {
        guard !rowsByIdentityKey.isEmpty else { return }

        for materializationID in cacheOrder where materializationID.appStoreID == appStoreID
            && materializationID.dateRangeID == dateRangeID {
            guard let cachedWorkspace = cachedWorkspaces[materializationID] else { continue }
            var mergedRows = cachedWorkspace.rowsByIdentityKey
            for (identityKey, row) in rowsByIdentityKey where mergedRows[identityKey] != nil {
                mergedRows[identityKey] = row
            }
            cachedWorkspaces[materializationID] = Workspace(rowsByIdentityKey: mergedRows)
        }
    }

    private nonisolated static func loadWorkspace(
        tracks: [TrackRequest],
        appStoreID: Int64,
        cutoffDate: Date?,
        in modelContext: ModelContext
    ) throws -> Workspace {
        guard !tracks.isEmpty else {
            return Workspace(rowsByIdentityKey: [:])
        }

        let queryKeys = Array(Set(tracks.map(\.queryKey)))
        let metricsByQueryKey = try fetchMetrics(
            queryKeys: queryKeys,
            in: modelContext
        )
        let refreshStatusesByIdentityKey = try TrackedKeywordRefreshStatusStore.snapshots(
            for: tracks.map(\.identityKey),
            in: modelContext
        )
        let trendCrawls = try fetchCrawls(
            queryKeys: queryKeys,
            cutoffDate: cutoffDate,
            in: modelContext
        )
        var latestCrawlsByQueryKey = latestCrawlsByQueryKey(from: trendCrawls)
        let missingLatestQueryKeys = Set(queryKeys).subtracting(latestCrawlsByQueryKey.keys)
        for crawl in try fetchLatestCrawls(
            queryKeys: missingLatestQueryKeys,
            in: modelContext
        ) {
            latestCrawlsByQueryKey[crawl.queryKey] = crawl
        }
        let latestCrawlKeys = Set(latestCrawlsByQueryKey.values.map(\.observationKey))
        let trackedRankingsByCrawlKey = try fetchTrackedRankingsByCrawlKey(
            queryKeys: queryKeys,
            appStoreID: appStoreID,
            cutoffDate: cutoffDate,
            latestCrawlKeys: latestCrawlKeys,
            in: modelContext
        )
        let topResultsByCrawlKey = try fetchTopResultsByCrawlKey(
            crawlKeys: latestCrawlKeys,
            in: modelContext
        )
        let tracksByQueryKey = Dictionary(grouping: tracks, by: \.queryKey)
        var latestByIdentityKey: [String: KeywordRankingCrawlSummary] = [:]
        var trendByIdentityKey: [String: [KeywordRankingCrawlSummary]] = [:]

        for (queryKey, crawl) in latestCrawlsByQueryKey {
            let summary = crawl.summary(rank: trackedRankingsByCrawlKey[crawl.observationKey])
            for track in tracksByQueryKey[queryKey] ?? [] {
                latestByIdentityKey[track.identityKey] = summary
            }
        }

        for crawl in trendCrawls {
            let summary = crawl.summary(rank: trackedRankingsByCrawlKey[crawl.observationKey])
            for track in tracksByQueryKey[crawl.queryKey] ?? [] {
                trendByIdentityKey[track.identityKey, default: []].append(summary)
            }
        }

        let rowsByIdentityKey = Dictionary(
            uniqueKeysWithValues: tracks.map { track in
                let latestSnapshot = latestByIdentityKey[track.identityKey]
                return (
                    track.identityKey,
                    Workspace.Row(
                        metrics: metricsByQueryKey[track.queryKey],
                        refreshStatus: TrackedKeywordRefreshStatusStore.snapshot(
                            trackCreatedAt: track.createdAt,
                            legacyMessage: track.legacyStatusMessage,
                            legacyUpdatedAt: track.lastRefreshAt ?? track.createdAt,
                            persisted: refreshStatusesByIdentityKey[track.identityKey]
                        ),
                        latestSnapshot: latestSnapshot,
                        trendSnapshots: trendByIdentityKey[track.identityKey] ?? [],
                        rankingApps: latestSnapshot.flatMap {
                            topResultsByCrawlKey[$0.id]
                        } ?? []
                    )
                )
            }
        )
        return Workspace(rowsByIdentityKey: rowsByIdentityKey)
    }

    private nonisolated static func fetchTrackRequests(
        identityKeys: [String],
        appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> [TrackRequest] {
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                identityKeys.contains(track.identityKey) && track.appStoreID == appStoreID
            }
        )
        return try modelContext.fetch(descriptor).map(TrackRequest.init)
    }

    private nonisolated static func fetchMetrics(
        queryKeys: [String],
        in modelContext: ModelContext
    ) throws -> [String: KeywordMetricsSnapshot] {
        let descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metrics in
                queryKeys.contains(metrics.queryKey)
            }
        )
        return try modelContext.fetch(descriptor).reduce(into: [:]) { result, metrics in
            result[metrics.queryKey] = KeywordMetricsSnapshot(metrics)
        }
    }

    private nonisolated static func fetchCrawls(
        queryKeys: [String],
        cutoffDate: Date?,
        in modelContext: ModelContext
    ) throws -> [CrawlRecord] {
        let crawls: [KeywordRankingCrawl]
        if let cutoffDate {
            let descriptor = FetchDescriptor<KeywordRankingCrawl>(
                predicate: #Predicate { crawl in
                    queryKeys.contains(crawl.queryKey) && crawl.observedAt >= cutoffDate
                },
                sortBy: [
                    SortDescriptor(\KeywordRankingCrawl.queryKey, order: .forward),
                    SortDescriptor(\KeywordRankingCrawl.observedAt, order: .forward)
                ]
            )
            crawls = try modelContext.fetch(descriptor)
        } else {
            let descriptor = FetchDescriptor<KeywordRankingCrawl>(
                predicate: #Predicate { crawl in
                    queryKeys.contains(crawl.queryKey)
                },
                sortBy: [
                    SortDescriptor(\KeywordRankingCrawl.queryKey, order: .forward),
                    SortDescriptor(\KeywordRankingCrawl.observedAt, order: .forward)
                ]
            )
            crawls = try modelContext.fetch(descriptor)
        }
        return crawls.map {
            CrawlRecord(
                queryKey: $0.queryKey,
                observationKey: $0.observationKey,
                observedAt: $0.observedAt,
                source: $0.source,
                resultCount: $0.resultCount
            )
        }
    }

    private nonisolated static func fetchLatestCrawls(
        queryKeys: Set<String>,
        in modelContext: ModelContext
    ) throws -> [CrawlRecord] {
        var records: [CrawlRecord] = []
        records.reserveCapacity(queryKeys.count)

        for queryKey in queryKeys {
            let targetQueryKey = queryKey
            var descriptor = FetchDescriptor<KeywordRankingCrawl>(
                predicate: #Predicate { crawl in
                    crawl.queryKey == targetQueryKey
                },
                sortBy: [SortDescriptor(\KeywordRankingCrawl.observedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            guard let crawl = try modelContext.fetch(descriptor).first else { continue }
            records.append(
                CrawlRecord(
                    queryKey: crawl.queryKey,
                    observationKey: crawl.observationKey,
                    observedAt: crawl.observedAt,
                    source: crawl.source,
                    resultCount: crawl.resultCount
                )
            )
        }
        return records
    }

    private nonisolated static func latestCrawlsByQueryKey(
        from crawls: [CrawlRecord]
    ) -> [String: CrawlRecord] {
        crawls.reduce(into: [:]) { result, crawl in
            result[crawl.queryKey] = crawl
        }
    }

    private nonisolated static func fetchTrackedRankingsByCrawlKey(
        queryKeys: [String],
        appStoreID: Int64,
        cutoffDate: Date?,
        latestCrawlKeys: Set<String>,
        in modelContext: ModelContext
    ) throws -> [String: Int] {
        let rankings = try fetchTrackedRankings(
            queryKeys: queryKeys,
            appStoreID: appStoreID,
            cutoffDate: cutoffDate,
            in: modelContext
        )
        var rankingsByCrawlKey = Dictionary(
            uniqueKeysWithValues: rankings.map { ($0.crawlKey, $0.position) }
        )
        let missingLatestCrawlKeys = latestCrawlKeys.subtracting(rankingsByCrawlKey.keys)

        for ranking in try fetchTrackedRankings(
            crawlKeys: missingLatestCrawlKeys,
            appStoreID: appStoreID,
            in: modelContext
        ) {
            rankingsByCrawlKey[ranking.crawlKey] = ranking.position
        }
        return rankingsByCrawlKey
    }

    private nonisolated static func fetchTrackedRankings(
        queryKeys: [String],
        appStoreID: Int64,
        cutoffDate: Date?,
        in modelContext: ModelContext
    ) throws -> [RankingRecord] {
        let rankings: [KeywordAppRanking]
        if let cutoffDate {
            let descriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { ranking in
                    queryKeys.contains(ranking.queryKey)
                        && ranking.appStoreID == appStoreID
                        && ranking.observedAt >= cutoffDate
                }
            )
            rankings = try modelContext.fetch(descriptor)
        } else {
            let descriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { ranking in
                    queryKeys.contains(ranking.queryKey)
                        && ranking.appStoreID == appStoreID
                }
            )
            rankings = try modelContext.fetch(descriptor)
        }
        return rankings.map {
            RankingRecord(crawlKey: $0.crawlKey, position: $0.position)
        }
    }

    private nonisolated static func fetchTrackedRankings(
        crawlKeys: Set<String>,
        appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> [RankingRecord] {
        guard !crawlKeys.isEmpty else { return [] }

        var records: [RankingRecord] = []
        for crawlKeyChunk in chunks(
            Array(crawlKeys),
            size: 500
        ) {
            let descriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { ranking in
                    crawlKeyChunk.contains(ranking.crawlKey)
                        && ranking.appStoreID == appStoreID
                }
            )
            records.append(contentsOf: try modelContext.fetch(descriptor).map {
                RankingRecord(crawlKey: $0.crawlKey, position: $0.position)
            })
        }
        return records
    }

    private nonisolated static func fetchTopResultsByCrawlKey(
        crawlKeys: Set<String>,
        in modelContext: ModelContext
    ) throws -> [String: [KeywordRankingAppSummary]] {
        guard !crawlKeys.isEmpty else { return [:] }

        var resultsByCrawlKey: [String: [KeywordRankingAppSummary]] = [:]
        for crawlKeyChunk in chunks(
            Array(crawlKeys),
            size: 500
        ) {
            let descriptor = FetchDescriptor<KeywordAppRanking>(
                predicate: #Predicate { ranking in
                    crawlKeyChunk.contains(ranking.crawlKey)
                        && ranking.position <= 5
                },
                sortBy: [
                    SortDescriptor(\KeywordAppRanking.observedAt, order: .forward),
                    SortDescriptor(\KeywordAppRanking.position, order: .forward)
                ]
            )
            for ranking in try modelContext.fetch(descriptor) {
                resultsByCrawlKey[ranking.crawlKey, default: []].append(
                    KeywordRankingAppSummary(ranking)
                )
            }
        }
        return resultsByCrawlKey
    }

    private nonisolated static func chunks<Element>(
        _ values: [Element],
        size: Int
    ) -> [[Element]] {
        stride(from: 0, to: values.count, by: size).map { startIndex in
            Array(values[startIndex..<min(startIndex + size, values.count)])
        }
    }
}
