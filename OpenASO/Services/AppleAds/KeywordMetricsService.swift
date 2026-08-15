import Foundation
import OSLog
import SwiftData

final class KeywordMetricsService: Sendable {
    private let apiClient: any AppleAdsPlatformAPI
    @MainActor private let credentialStore: AppleAdsCredentialStore
    private let freshnessFetchObserver: @Sendable (_ queryKeyCount: Int) -> Void
    private let bulkFreshnessFetchHook: @Sendable () throws -> Void
    private let metricsTTL: TimeInterval = 60 * 60 * 24 * 7

    @MainActor
    init(
        httpClient: HTTPClient,
        credentialStore: AppleAdsCredentialStore,
        settingsStore: AppSettingsStore,
        webSessionStore: AppleAdsWebSessionStore,
        apiClient: any AppleAdsPlatformAPI = OfficialAppleAdsPlatformAPI(),
        freshnessFetchObserver: @escaping @Sendable (_ queryKeyCount: Int) -> Void = { _ in },
        bulkFreshnessFetchHook: @escaping @Sendable () throws -> Void = {}
    ) {
        self.apiClient = apiClient
        self.credentialStore = credentialStore
        self.freshnessFetchObserver = freshnessFetchObserver
        self.bulkFreshnessFetchHook = bulkFreshnessFetchHook
        _ = httpClient
        _ = settingsStore
        _ = webSessionStore
    }

    func verifyAppleAdsCredentials(_ credentials: AppleAdsCredentials) async throws -> AppleAdsCredentials {
        try await apiClient.verify(credentials: credentials).applying(to: credentials)
    }

    func searchAppleAdsApps(named query: String, using credentials: AppleAdsCredentials) async throws -> [AppleAdsPromotedApp] {
        try await apiClient.searchOwnedApps(named: query, using: credentials, limit: 50)
    }

    func resolveDefaultAppleAdsApp(using credentials: AppleAdsCredentials) async throws -> AppleAdsPromotedApp {
        guard let app = try await apiClient.searchOwnedApps(
            named: nil,
            using: credentials,
            limit: 1
        ).first else {
            throw OpenASOError.providerUnavailable(
                "Apple Ads needs access to at least one of your App Store apps."
            )
        }
        return app
    }

    func metricsMap(for queryKeys: [String], in modelContext: ModelContext) throws -> [String: KeywordDailyMetric] {
        let uniqueQueryKeys = Array(Set(queryKeys))
        guard !uniqueQueryKeys.isEmpty else {
            return [:]
        }

        let targetQueryKeys = uniqueQueryKeys
        let descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metrics in
                targetQueryKeys.contains(metrics.queryKey)
            }
        )
        let metrics = try modelContext.fetch(descriptor)
        return Dictionary(uniqueKeysWithValues: metrics.map { ($0.queryKey, $0) })
    }

    /// Fetches Apple Ads popularity evidence for app-independent query scopes.
    /// Query keys are opaque identities supplied by the owning workflow; that
    /// workflow revalidates their persisted scalars after this suspension and
    /// calls `persistPopularityMetrics(_:in:)` inside its own transaction.
    func fetchPopularityMetrics(
        for targets: [KeywordResearchTarget],
        now: @Sendable () -> Date = { Date() }
    ) async throws -> [KeywordPopularityMetricEvidence] {
        try await fetchOfficialPopularityMetrics(for: targets, now: now)
    }

    /// Compatibility entry point for callers that still carry the retired
    /// browser-session context in their refresh request.
    func fetchPopularityMetrics(
        for targets: [KeywordResearchTarget],
        contextAppStoreID: Int64,
        webSession: AppleAdsWebSession,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> [KeywordPopularityMetricEvidence] {
        _ = contextAppStoreID
        _ = webSession
        return try await fetchOfficialPopularityMetrics(for: targets, now: now)
    }

    private func fetchOfficialPopularityMetrics(
        for targets: [KeywordResearchTarget],
        now: @Sendable () -> Date
    ) async throws -> [KeywordPopularityMetricEvidence] {
        try Task.checkCancellation()

        let orderedTargets = Self.orderedUniquePopularityTargets(targets)
        guard !orderedTargets.isEmpty else { return [] }
        let credentials = try await requireAppleAdsCredentials()

        var popularityByQueryKey: [String: Int] = [:]
        let targetsByStorefront = Dictionary(grouping: orderedTargets, by: \.storefront)

        do {
            for storefront in targetsByStorefront.keys.sorted() {
                guard let storefrontTargets = targetsByStorefront[storefront] else { continue }
                try Task.checkCancellation()
                let popularities = try await fetchOfficialPopularityScores(
                    for: storefrontTargets.map(\.term),
                    countryOrRegion: storefront,
                    credentials: credentials,
                    asOf: now()
                )
                try Task.checkCancellation()

                for target in storefrontTargets {
                    let normalizedTerm = AppleAdsSearchTermPopularity.normalized(target.term)
                    guard let popularity = popularities[normalizedTerm] else { continue }
                    popularityByQueryKey[target.queryKey] = min(100, max(1, popularity))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }

        try Task.checkCancellation()
        let observedAt = now()
        return orderedTargets.map { target in
            KeywordPopularityMetricEvidence(
                target: target,
                popularityScore: popularityByQueryKey[target.queryKey],
                observedAt: observedAt
            )
        }
    }

    private func requireAppleAdsCredentials() async throws -> AppleAdsCredentials {
        let credentials = await credentialStore.apiCredentials
        guard credentials.isComplete else {
            throw OpenASOError.providerUnavailable(
                "Configure and verify Apple Ads Platform API credentials in Settings."
            )
        }
        return credentials
    }

    private func fetchOfficialPopularityScores(
        for searchTerms: [String],
        countryOrRegion: String,
        credentials: AppleAdsCredentials,
        asOf date: Date
    ) async throws -> [String: Int] {
        let rows = try await apiClient.searchTermPopularity(
            for: searchTerms,
            countryOrRegion: countryOrRegion,
            window: .recentCompletedWeeks(asOf: date),
            using: credentials
        )

        var latestRows: [String: AppleAdsSearchTermPopularity] = [:]
        for row in rows where row.popularity1to100 != nil {
            let key = row.normalizedSearchTerm
            guard let existing = latestRows[key] else {
                latestRows[key] = row
                continue
            }
            let rowWeek = row.week ?? row.month ?? ""
            let existingWeek = existing.week ?? existing.month ?? ""
            if rowWeek > existingWeek
                || (rowWeek == existingWeek
                    && (row.popularity1to100 ?? 0) > (existing.popularity1to100 ?? 0)) {
                latestRows[key] = row
            }
        }

        return latestRows.compactMapValues(\.popularity1to100)
    }

    /// Applies fetched evidence to shared query metrics without touching
    /// tracked apps, tracks, refresh statuses, or `AppKeywordStats`. The caller
    /// owns the surrounding transaction and must first revalidate any project
    /// or keyword generation that authorized the fetch. Evidence is the
    /// deterministic, query-unique output of `fetchPopularityMetrics`.
    func persistPopularityMetrics(
        _ evidence: [KeywordPopularityMetricEvidence],
        in modelContext: ModelContext
    ) throws -> [KeywordPopularityMetricOutcome] {
        try Task.checkCancellation()
        guard !evidence.isEmpty else { return [] }
        let outcomes = try Self.upsertPopularityMetrics(
            evidence: evidence,
            in: modelContext
        )
        try Task.checkCancellation()
        return outcomes
    }

    private func freshnessMetricsMap(
        for queryKeys: [String],
        in modelContext: ModelContext
    ) -> [String: KeywordDailyMetric] {
        let uniqueQueryKeys = Array(Set(queryKeys))
        guard !uniqueQueryKeys.isEmpty else { return [:] }

        freshnessFetchObserver(uniqueQueryKeys.count)
        do {
            try bulkFreshnessFetchHook()
            return try metricsMap(for: uniqueQueryKeys, in: modelContext)
        } catch {
            var metricsByQueryKey: [String: KeywordDailyMetric] = [:]
            for queryKey in uniqueQueryKeys {
                if let metric = try? Self.fetchMetrics(queryKey: queryKey, in: modelContext) {
                    metricsByQueryKey[queryKey] = metric
                }
            }
            return metricsByQueryKey
        }
    }

    @MainActor
    func refreshMetrics(
        for trackedApp: TrackedApp,
        tracks: [TrackedAppKeyword],
        in modelContext: ModelContext
    ) async -> [KeywordMetricsRefreshOutcome] {
        guard !Task.isCancelled else { return [] }

        let tracksByQueryKey = Dictionary(grouping: tracks, by: \.queryKey)
        let uniqueTracks = tracksByQueryKey.values
            .compactMap { $0.min(by: { left, right in left.identityKey < right.identityKey }) }
            .sorted(by: Self.trackOrdering)
        let uniqueTrackIDs = uniqueTracks.map(\.persistentModelID)
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            let message = OpenASOError.map(error).localizedDescription
            modelContext.rollback()
            return uniqueTrackIDs.map {
                KeywordMetricsRefreshOutcome(
                    trackID: $0,
                    errorMessage: message,
                    disposition: .failed
                )
            }
        }
        let metricsByQueryKey = freshnessMetricsMap(for: uniqueTracks.map(\.queryKey), in: modelContext)
        let persistedStatuses = (try? TrackedKeywordRefreshStatusStore.snapshots(
            for: uniqueTracks.map(\.identityKey),
            in: modelContext
        )) ?? [:]
        var outcomes: [KeywordMetricsRefreshOutcome] = []
        var tracksNeedingPopularity: [TrackedAppKeyword] = []

        for track in uniqueTracks {
            guard !Task.isCancelled else { return outcomes }
            let queryTracks = tracksByQueryKey[track.queryKey] ?? [track]
            let popularityStatus = TrackedKeywordRefreshStatusStore.snapshot(
                for: track,
                persisted: persistedStatuses[track.identityKey]
            )
            guard Self.shouldRefreshMetrics(
                metricsTTL: metricsTTL,
                metric: metricsByQueryKey[track.queryKey],
                popularityStatus: popularityStatus
            ) else {
                do {
                    if let metric = metricsByQueryKey[track.queryKey],
                       metric.popularityScore != nil {
                        for siblingTrack in queryTracks {
                            try TrackedKeywordRefreshStatusStore.set(
                                nil,
                                domain: .popularity,
                                for: siblingTrack,
                                updatedAt: metric.updatedAt,
                                in: modelContext
                            )
                        }
                    }
                    try modelContext.save()
                    outcomes.append(
                        KeywordMetricsRefreshOutcome(
                            trackID: track.persistentModelID,
                            errorMessage: nil,
                            disposition: .upToDate
                        )
                    )
                } catch {
                    let message = OpenASOError.map(error).localizedDescription
                    modelContext.rollback()
                    OpenASOLog.refresh.error(
                        "Failed to persist resolved popularity status: \(String(reflecting: error), privacy: .private(mask: .hash))"
                    )
                    outcomes.append(
                        KeywordMetricsRefreshOutcome(
                            trackID: track.persistentModelID,
                            errorMessage: message,
                            disposition: .failed
                        )
                    )
                }
                continue
            }

            tracksNeedingPopularity.append(track)
        }

        let credentials = credentialStore.apiCredentials
        guard credentials.isComplete else {
            _ = Self.applyPopularityResult(
                .missingCredentials,
                to: tracksNeedingPopularity,
                tracksByQueryKey: tracksByQueryKey,
                in: modelContext,
                outcomes: &outcomes
            )
            return outcomes
        }

        let storefrontGroups = Self.orderedTrackGroups(tracksNeedingPopularity)
        for group in storefrontGroups {
            guard !Task.isCancelled else { return outcomes }
            let storefrontTracks = group.tracks
            let storefrontCode = storefrontTracks.first?.storefront ?? "US"

            do {
                let popularities = try await fetchOfficialPopularityScores(
                    for: storefrontTracks.map(\.term),
                    countryOrRegion: storefrontCode,
                    credentials: credentials,
                    asOf: Date()
                )
                guard !Task.isCancelled else { return outcomes }
                for track in storefrontTracks {
                    guard !Task.isCancelled else { return outcomes }
                    let key = AppleAdsSearchTermPopularity.normalized(track.term)
                    let result = popularities[key].map(AppleAdsPopularityResult.success)
                        ?? .notFound
                    Self.applyMetricsPayloadSafely(
                        Self.makeAppleAdsMetrics(popularityResult: result),
                        for: track,
                        statusTracks: tracksByQueryKey[track.queryKey] ?? [track],
                        in: modelContext,
                        outcomes: &outcomes
                    )
                }
            } catch {
                if Self.isCancellation(error) { return outcomes }
                guard Self.applyPopularityResult(
                    .failure(OpenASOError.map(error).localizedDescription),
                    to: storefrontTracks,
                    tracksByQueryKey: tracksByQueryKey,
                    in: modelContext,
                    outcomes: &outcomes
                ) else { return outcomes }
            }
        }

        return outcomes
    }

    func refreshMetrics(
        for trackIdentityKeys: [String],
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [KeywordMetricsRefreshOutcome] {
        (try await refreshMetricsBatch(
            for: trackIdentityKeys,
            using: modelStore,
            progress: progress
        )).outcomes
    }

    @available(*, deprecated, message: "Apple Ads Platform credentials are read from the credential store.")
    func refreshMetrics(
        for trackIdentityKeys: [String],
        popularityContextAppStoreID: Int64?,
        webSession: AppleAdsWebSession?,
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [KeywordMetricsRefreshOutcome] {
        (try await refreshMetricsBatch(
            for: trackIdentityKeys,
            using: modelStore,
            progress: progress
        )).outcomes
    }

    func refreshMetricsBatch(
        for trackIdentityKeys: [String],
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil,
        didPersist: (@Sendable (KeywordMetricsPersistenceUpdate) async -> Void)? = nil
    ) async throws -> KeywordMetricsRefreshBatchResult {
        try Task.checkCancellation()
        guard !trackIdentityKeys.isEmpty else { return .empty }

        let metricsTTL = metricsTTL
        let candidates = try await modelStore.write { modelContext in
            let targetIdentityKeys = trackIdentityKeys
            let descriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    targetIdentityKeys.contains(track.identityKey)
                }
            )
            let tracks = try modelContext.fetch(descriptor)
            let tracksByQueryKey = Dictionary(grouping: tracks, by: \.queryKey)
            let metricsByQueryKey = self.freshnessMetricsMap(
                for: Array(tracksByQueryKey.keys),
                in: modelContext
            )
            let persistedStatuses = try TrackedKeywordRefreshStatusStore.snapshots(
                for: tracks.map(\.identityKey),
                in: modelContext
            )
            return try tracksByQueryKey.values.compactMap { queryTracks -> KeywordMetricsRefreshCandidate? in
                let sortedTracks = queryTracks.sorted { $0.identityKey < $1.identityKey }
                guard let track = sortedTracks.first else { return nil }
                let metric = metricsByQueryKey[track.queryKey]
                let popularityStatus = TrackedKeywordRefreshStatusStore.snapshot(
                    for: track,
                    persisted: persistedStatuses[track.identityKey]
                )
                let shouldRefresh = Self.shouldRefreshMetrics(
                    metricsTTL: metricsTTL,
                    metric: metric,
                    popularityStatus: popularityStatus
                )
                if !shouldRefresh, let metric, metric.popularityScore != nil {
                    for siblingTrack in sortedTracks {
                        try TrackedKeywordRefreshStatusStore.set(
                            nil,
                            domain: .popularity,
                            for: siblingTrack,
                            updatedAt: metric.updatedAt,
                            in: modelContext
                        )
                    }
                }
                return KeywordMetricsRefreshCandidate(
                    trackID: track.persistentModelID,
                    trackIdentityKey: track.identityKey,
                    trackIdentityKeys: sortedTracks.map(\.identityKey),
                    term: track.term,
                    storefront: track.storefront,
                    shouldRefresh: shouldRefresh
                )
            }
                .sorted(by: Self.candidateOrdering)
        }
        try Task.checkCancellation()

        var outcomes: [KeywordMetricsRefreshOutcome] = []
        let batchErrors: [KeywordMetricsBatchError] = []
        var tracksNeedingPopularity: [KeywordMetricsRefreshCandidate] = []
        let totalCount = candidates.count
        var completedCount = 0
        var failureCount = 0
        await progress?(0, totalCount, 0)
        try Task.checkCancellation()

        for candidate in candidates {
            try Task.checkCancellation()

            guard candidate.shouldRefresh else {
                outcomes.append(
                    KeywordMetricsRefreshOutcome(
                        trackID: candidate.trackID,
                        errorMessage: nil,
                        disposition: .upToDate
                    )
                )
                completedCount += 1
                await didPersist?(candidate.persistenceUpdate)
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
                continue
            }

            tracksNeedingPopularity.append(candidate)
        }

        let credentials = await credentialStore.apiCredentials
        guard credentials.isComplete else {
            for candidate in tracksNeedingPopularity {
                try Task.checkCancellation()
                let outcome = try await persistMetricsPayload(
                    Self.makeAppleAdsMetrics(popularityResult: .missingCredentials),
                    for: candidate,
                    using: modelStore
                )
                outcomes.append(outcome)
                if outcome.disposition == .failed { failureCount += 1 }
                completedCount += 1
                await didPersist?(candidate.persistenceUpdate)
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
            }
            return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
        }

        let storefrontGroups = Self.orderedCandidateGroups(tracksNeedingPopularity)
        try Task.checkCancellation()
        guard !storefrontGroups.isEmpty else {
            return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
        }

        for group in storefrontGroups {
            try Task.checkCancellation()
            let storefrontTracks = group.tracks
            let storefrontCode = storefrontTracks.first?.storefront ?? "US"
            let popularities: [String: Int]
            do {
                popularities = try await fetchOfficialPopularityScores(
                    for: storefrontTracks.map(\.term),
                    countryOrRegion: storefrontCode,
                    credentials: credentials,
                    asOf: Date()
                )
            } catch {
                try Task.checkCancellation()
                if Self.isCancellation(error) {
                    throw error
                }
                for candidate in storefrontTracks {
                    try Task.checkCancellation()
                    let outcome = try await persistMetricsPayload(
                        Self.makeAppleAdsMetrics(popularityResult: .failure(OpenASOError.map(error).localizedDescription)),
                        for: candidate,
                        using: modelStore
                    )
                    outcomes.append(outcome)
                    if outcome.disposition == .failed { failureCount += 1 }
                    completedCount += 1
                    await didPersist?(candidate.persistenceUpdate)
                    await progress?(completedCount, totalCount, failureCount)
                    try Task.checkCancellation()
                }
                continue
            }

            for candidate in storefrontTracks {
                try Task.checkCancellation()
                let result: AppleAdsPopularityResult
                if let popularity = popularities[
                    AppleAdsSearchTermPopularity.normalized(candidate.term)
                ] {
                    result = .success(popularity)
                } else {
                    result = .notFound
                }
                let outcome = try await persistMetricsPayload(
                    Self.makeAppleAdsMetrics(popularityResult: result),
                    for: candidate,
                    using: modelStore
                )
                outcomes.append(outcome)
                if outcome.disposition == .failed { failureCount += 1 }
                completedCount += 1
                await didPersist?(candidate.persistenceUpdate)
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
            }
        }

        return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
    }

    @available(*, deprecated, message: "Apple Ads Platform credentials are read from the credential store.")
    func refreshMetricsBatch(
        for trackIdentityKeys: [String],
        popularityContextAppStoreID: Int64?,
        webSession: AppleAdsWebSession?,
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil,
        didPersist: (@Sendable (KeywordMetricsPersistenceUpdate) async -> Void)? = nil
    ) async throws -> KeywordMetricsRefreshBatchResult {
        _ = popularityContextAppStoreID
        _ = webSession
        return try await refreshMetricsBatch(
            for: trackIdentityKeys,
            using: modelStore,
            progress: progress,
            didPersist: didPersist
        )
    }

    func refreshStalePopularityMetrics(
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [KeywordMetricsRefreshOutcome] {
        let trackIdentityKeys = try await prepareStalePopularityRefresh(using: modelStore).trackIdentityKeys

        guard !trackIdentityKeys.isEmpty else { return [] }

        return try await refreshMetrics(
            for: trackIdentityKeys,
            using: modelStore,
            progress: progress
        )
    }

    @available(*, deprecated, message: "Apple Ads Platform credentials are read from the credential store.")
    func refreshStalePopularityMetrics(
        popularityContextAppStoreID: Int64,
        webSession: AppleAdsWebSession,
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [KeywordMetricsRefreshOutcome] {
        _ = popularityContextAppStoreID
        _ = webSession

        return try await refreshStalePopularityMetrics(
            using: modelStore,
            progress: progress
        )
    }

    func stalePopularityTrackIdentityKeys(using modelStore: BackgroundModelStore) async throws -> [String] {
        try await prepareStalePopularityRefresh(using: modelStore).trackIdentityKeys
    }

    func prepareStalePopularityRefresh(
        using modelStore: BackgroundModelStore
    ) async throws -> StalePopularityRefreshPreparation {
        let metricsTTL = metricsTTL
        return try await modelStore.write { modelContext in
            let descriptor = FetchDescriptor<TrackedAppKeyword>()
            let tracks = try modelContext.fetch(descriptor)
            let tracksByQueryKey = Dictionary(grouping: tracks, by: \.queryKey)
            let metricsByQueryKey = self.freshnessMetricsMap(
                for: Array(tracksByQueryKey.keys),
                in: modelContext
            )
            let persistedStatuses = try TrackedKeywordRefreshStatusStore.snapshots(
                for: tracks.map(\.identityKey),
                in: modelContext
            )
            var refreshIdentityKeys: [String] = []
            var refreshQueryCount = 0
            var clearedStatusCount = 0
            for queryTracks in tracksByQueryKey.values {
                let sortedTracks = queryTracks.sorted { $0.identityKey < $1.identityKey }
                guard let track = sortedTracks.first else { continue }
                let metric = metricsByQueryKey[track.queryKey]
                let popularityStatus = TrackedKeywordRefreshStatusStore.snapshot(
                    for: track,
                    persisted: persistedStatuses[track.identityKey]
                )
                if Self.shouldRefreshMetrics(
                    metricsTTL: metricsTTL,
                    metric: metric,
                    popularityStatus: popularityStatus
                ) {
                    refreshIdentityKeys.append(contentsOf: sortedTracks.map(\.identityKey))
                    refreshQueryCount += 1
                } else if let metric, metric.popularityScore != nil {
                    for siblingTrack in sortedTracks {
                        let previousStatus = try TrackedKeywordRefreshStatusStore.snapshot(
                            for: siblingTrack,
                            in: modelContext
                        ).popularityMessage
                        try TrackedKeywordRefreshStatusStore.set(
                            nil,
                            domain: .popularity,
                            for: siblingTrack,
                            updatedAt: metric.updatedAt,
                            in: modelContext
                        )
                        let updatedStatus = try TrackedKeywordRefreshStatusStore.snapshot(
                            for: siblingTrack,
                            in: modelContext
                        ).popularityMessage
                        if previousStatus != nil, updatedStatus == nil {
                            clearedStatusCount += 1
                        }
                    }
                }
            }
            return StalePopularityRefreshPreparation(
                trackIdentityKeys: refreshIdentityKeys.sorted(),
                refreshQueryCount: refreshQueryCount,
                clearedStatusCount: clearedStatusCount
            )
        }
    }

    private func persistMetricsPayload(
        _ payload: KeywordMetricsPayload,
        for candidate: KeywordMetricsRefreshCandidate,
        using modelStore: BackgroundModelStore
    ) async throws -> KeywordMetricsRefreshOutcome {
        try await modelStore.write { modelContext in
            try Self.applyMetricsPayload(
                payload,
                forTrackIdentityKeys: candidate.trackIdentityKeys,
                preferredTrackIdentityKey: candidate.trackIdentityKey,
                fallbackTrackID: candidate.trackID,
                in: modelContext
            )
        }
    }

    @discardableResult
    private static func applyPopularityResult(
        _ result: AppleAdsPopularityResult,
        to tracks: [TrackedAppKeyword],
        tracksByQueryKey: [String: [TrackedAppKeyword]],
        in modelContext: ModelContext,
        outcomes: inout [KeywordMetricsRefreshOutcome]
    ) -> Bool {
        for track in tracks {
            guard !Task.isCancelled else { return false }
            let payload = makeAppleAdsMetrics(popularityResult: result)
            applyMetricsPayloadSafely(
                payload,
                for: track,
                statusTracks: tracksByQueryKey[track.queryKey] ?? [track],
                in: modelContext,
                outcomes: &outcomes
            )
        }
        return true
    }

    private static func applyMetricsPayload(
        _ payload: KeywordMetricsPayload,
        forTrackIdentityKeys trackIdentityKeys: [String],
        preferredTrackIdentityKey: String,
        fallbackTrackID: PersistentIdentifier,
        in modelContext: ModelContext
    ) throws -> KeywordMetricsRefreshOutcome {
        let targetIdentityKeys = trackIdentityKeys
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                targetIdentityKeys.contains(track.identityKey)
            }
        )
        let tracks = try modelContext.fetch(descriptor)
        guard let track = tracks.first(where: { $0.identityKey == preferredTrackIdentityKey })
            ?? tracks.first
        else {
            return KeywordMetricsRefreshOutcome(
                trackID: fallbackTrackID,
                errorMessage: OpenASOError.appNotFound.localizedDescription
            )
        }

        var outcomes: [KeywordMetricsRefreshOutcome] = []
        try applyMetricsPayload(
            payload,
            for: track,
            statusTracks: tracks,
            in: modelContext,
            outcomes: &outcomes
        )
        return outcomes.last ?? KeywordMetricsRefreshOutcome(trackID: fallbackTrackID, errorMessage: nil)
    }

    private static func applyMetricsPayload(
        _ payload: KeywordMetricsPayload,
        for track: TrackedAppKeyword,
        statusTracks: [TrackedAppKeyword],
        in modelContext: ModelContext,
        outcomes: inout [KeywordMetricsRefreshOutcome]
    ) throws {
        let uniqueStatusTracks = Dictionary(
            uniqueKeysWithValues: statusTracks.map { ($0.identityKey, $0) }
        ).values
        for statusTrack in uniqueStatusTracks {
            try TrackedKeywordRefreshStatusStore.set(
                payload.statusMessage,
                domain: .popularity,
                for: statusTrack,
                updatedAt: payload.updatedAt,
                in: modelContext
            )
        }
        upsertMetrics(payload, for: track, in: modelContext)
        if let statusMessage = payload.statusMessage {
            outcomes.append(KeywordMetricsRefreshOutcome(
                trackID: track.persistentModelID,
                errorMessage: statusMessage,
                disposition: payload.outcomeDisposition
            ))
        } else {
            outcomes.append(KeywordMetricsRefreshOutcome(
                trackID: track.persistentModelID,
                errorMessage: nil,
                disposition: payload.outcomeDisposition
            ))
        }
    }

    private static func applyMetricsPayloadSafely(
        _ payload: KeywordMetricsPayload,
        for track: TrackedAppKeyword,
        statusTracks: [TrackedAppKeyword],
        in modelContext: ModelContext,
        outcomes: inout [KeywordMetricsRefreshOutcome]
    ) {
        var stagedOutcomes: [KeywordMetricsRefreshOutcome] = []
        do {
            try applyMetricsPayload(
                payload,
                for: track,
                statusTracks: statusTracks,
                in: modelContext,
                outcomes: &stagedOutcomes
            )
            try modelContext.save()
            outcomes.append(contentsOf: stagedOutcomes)
        } catch {
            let mappedError = OpenASOError.map(error)
            modelContext.rollback()
            OpenASOLog.refresh.error(
                "Failed to persist popularity refresh status: \(String(reflecting: error), privacy: .private(mask: .hash))"
            )
            outcomes.append(KeywordMetricsRefreshOutcome(
                trackID: track.persistentModelID,
                errorMessage: mappedError.localizedDescription
            ))
        }
    }

    private static func shouldRefreshMetrics(
        metricsTTL: TimeInterval,
        metric: KeywordDailyMetric?,
        popularityStatus: KeywordRefreshStatusSnapshot
    ) -> Bool {
        guard let metric else {
            return true
        }

        if metric.popularityScore != nil {
            return Date.now.timeIntervalSince(metric.updatedAt) >= metricsTTL
        }

        guard popularityStatus.popularityMessage?.hasPrefix("Popularity unavailable.") == true,
              let unavailableAt = popularityStatus.popularityUpdatedAt
        else {
            return true
        }
        return Date.now.timeIntervalSince(unavailableAt) >= metricsTTL
    }

    private static func orderedUniquePopularityTargets(
        _ targets: [KeywordResearchTarget]
    ) -> [KeywordResearchTarget] {
        let ordered = targets.sorted {
            if $0.storefront != $1.storefront {
                return $0.storefront < $1.storefront
            }
            if $0.queryKey != $1.queryKey {
                return $0.queryKey < $1.queryKey
            }
            return $0.term < $1.term
        }
        var seenQueryKeys: Set<String> = []
        return ordered.filter { seenQueryKeys.insert($0.queryKey).inserted }
    }

    private static func upsertPopularityMetrics(
        evidence: [KeywordPopularityMetricEvidence],
        in modelContext: ModelContext
    ) throws -> [KeywordPopularityMetricOutcome] {
        let queryKeys = evidence.map(\.target.queryKey)
        let descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metric in
                queryKeys.contains(metric.queryKey)
            }
        )
        let existingMetrics = try modelContext.fetch(descriptor)
        var metricsByQueryKey = Dictionary(
            uniqueKeysWithValues: existingMetrics.map { ($0.queryKey, $0) }
        )
        var outcomes: [KeywordPopularityMetricOutcome] = []
        outcomes.reserveCapacity(evidence.count)

        for item in evidence {
            let target = item.target
            guard let popularityScore = item.popularityScore else {
                outcomes.append(KeywordPopularityMetricOutcome(
                    target: target,
                    popularityScore: nil,
                    observedAt: item.observedAt,
                    disposition: .notFound
                ))
                continue
            }

            let disposition: KeywordPopularityMetricPersistenceDisposition
            if let metric = metricsByQueryKey[target.queryKey] {
                // A difficulty-only or failed-popularity row does not contain
                // popularity evidence, so its generic row timestamp must not
                // suppress the first successful popularity observation.
                guard metric.popularityScore == nil || item.observedAt > metric.updatedAt else {
                    outcomes.append(KeywordPopularityMetricOutcome(
                        target: target,
                        popularityScore: popularityScore,
                        observedAt: item.observedAt,
                        disposition: .ignoredNotNewer
                    ))
                    continue
                }

                metric.keyword = target.term
                metric.storefront = target.storefront
                metric.platform = target.platform
                metric.popularityScore = popularityScore
                metric.source = .appleAdsPopularity
                metric.popularityDate = nil
                metric.submissionCount = 1
                metric.winningCount = 1
                metric.confidenceRaw = "single_source"
                // `updatedAt` is shared by every field on the legacy row.
                // Applying first popularity evidence must not move a newer
                // difficulty-only row timestamp backwards.
                metric.updatedAt = max(metric.updatedAt, item.observedAt)
                disposition = .updated
            } else {
                let metric = KeywordDailyMetric(
                    queryKey: target.queryKey,
                    keyword: target.term,
                    storefront: target.storefront,
                    platform: target.platform,
                    popularityScore: popularityScore,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    submissionCount: 1,
                    winningCount: 1,
                    confidence: "single_source",
                    updatedAt: item.observedAt
                )
                modelContext.insert(metric)
                metricsByQueryKey[target.queryKey] = metric
                disposition = .inserted
            }

            outcomes.append(KeywordPopularityMetricOutcome(
                target: target,
                popularityScore: popularityScore,
                observedAt: item.observedAt,
                disposition: disposition
            ))
        }

        return outcomes
    }

    private static func fetchMetrics(queryKey: String, in modelContext: ModelContext) throws -> KeywordDailyMetric? {
        let targetQueryKey = queryKey
        let descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metrics in
                metrics.queryKey == targetQueryKey
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private static func upsertMetrics(_ payload: KeywordMetricsPayload, for track: TrackedAppKeyword, in modelContext: ModelContext) {
        let metrics: KeywordDailyMetric
        if let existing = try? fetchMetrics(queryKey: track.queryKey, in: modelContext) {
            metrics = existing
        } else {
            metrics = KeywordDailyMetric(
                queryKey: track.queryKey,
                keyword: track.term,
                storefront: track.storefront,
                platform: track.platform,
                popularityScore: payload.popularityScore,
                difficultyScore: payload.difficultyScore,
                source: payload.source,
                popularityDate: payload.popularityDate,
                submissionCount: payload.submissionCount,
                winningCount: payload.winningCount,
                confidence: payload.confidence,
                notes: payload.notes
            )
            modelContext.insert(metrics)
        }

        metrics.keyword = track.term
        metrics.storefront = track.storefront
        metrics.platform = track.platform

        let shouldPreserveExistingPopularity = payload.preservesExistingPopularity
            && metrics.popularityScore != nil
        guard !shouldPreserveExistingPopularity else {
            return
        }

        metrics.popularityScore = payload.popularityScore
        metrics.difficultyScore = payload.difficultyScore
        metrics.source = payload.source
        metrics.popularityDate = payload.popularityDate
        metrics.submissionCount = payload.submissionCount
        metrics.winningCount = payload.winningCount
        metrics.confidenceRaw = payload.confidence
        metrics.updatedAt = payload.updatedAt
        metrics.notes = payload.notes
    }

    private static func makeAppleAdsMetrics(
        popularityResult: AppleAdsPopularityResult
    ) -> KeywordMetricsPayload {
        let popularityScore: Int
        switch popularityResult {
        case .success(let score):
            popularityScore = min(100, max(1, score))
        case .missingCredentials:
            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "Popularity failed to fetch. Configure and verify Apple Ads Platform API credentials in Settings.",
                outcomeDisposition: .failed,
                preservesExistingPopularity: true
            )
        case .missingContextApp:
            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "Popularity failed to fetch. Configure Apple Ads Platform API access in Settings.",
                outcomeDisposition: .failed,
                preservesExistingPopularity: true
            )
        case .notFound:
            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "Popularity unavailable. Apple Ads returned no eligible row for this keyword and country or region; terms need at least 500 searches and 10 impressions in the reporting period.",
                outcomeDisposition: .skipped
            )
        case .failure(let message):
            if isUnsupportedAppleAdsStorefrontMessage(message) {
                return KeywordMetricsPayload(
                    popularityScore: nil,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    statusMessage: "Popularity unavailable. \(message)",
                    outcomeDisposition: .skipped
                )
            }

            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "Popularity failed to fetch. \(message)",
                outcomeDisposition: .failed,
                preservesExistingPopularity: true
            )
        }

        return KeywordMetricsPayload(
            popularityScore: popularityScore,
            difficultyScore: nil,
            source: .appleAdsPopularity
        )
    }

    private static func isUnsupportedAppleAdsStorefrontMessage(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("apple ads")
            && lowercasedMessage.contains("keyword popularity")
            && (lowercasedMessage.contains("not available") || lowercasedMessage.contains("does not support"))
    }

    private static func trackOrdering(_ lhs: TrackedAppKeyword, _ rhs: TrackedAppKeyword) -> Bool {
        let lhsStorefront = lhs.storefront.lowercased()
        let rhsStorefront = rhs.storefront.lowercased()
        if lhsStorefront != rhsStorefront {
            return lhsStorefront < rhsStorefront
        }
        return lhs.identityKey < rhs.identityKey
    }

    private static func candidateOrdering(
        _ lhs: KeywordMetricsRefreshCandidate,
        _ rhs: KeywordMetricsRefreshCandidate
    ) -> Bool {
        let lhsStorefront = lhs.storefront.lowercased()
        let rhsStorefront = rhs.storefront.lowercased()
        if lhsStorefront != rhsStorefront {
            return lhsStorefront < rhsStorefront
        }
        return lhs.trackIdentityKey < rhs.trackIdentityKey
    }

    private static func orderedTrackGroups(_ tracks: [TrackedAppKeyword]) -> [KeywordMetricsTrackGroup] {
        let grouped = Dictionary(grouping: tracks) { $0.storefront.lowercased() }
        return grouped.keys.sorted().map { storefront in
            KeywordMetricsTrackGroup(
                tracks: (grouped[storefront] ?? []).sorted(by: Self.trackOrdering)
            )
        }
    }

    private static func orderedCandidateGroups(
        _ candidates: [KeywordMetricsRefreshCandidate]
    ) -> [KeywordMetricsCandidateGroup] {
        let grouped = Dictionary(grouping: candidates) { $0.storefront.lowercased() }
        return grouped.keys.sorted().map { storefront in
            KeywordMetricsCandidateGroup(
                tracks: (grouped[storefront] ?? []).sorted(by: Self.candidateOrdering)
            )
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

enum KeywordMetricsRefreshDisposition: String, Sendable {
    case refreshed
    case upToDate
    case failed
    case skipped
}

struct KeywordPopularityMetricEvidence: Equatable, Sendable {
    let target: KeywordResearchTarget
    let popularityScore: Int?
    let observedAt: Date
}

enum KeywordPopularityMetricPersistenceDisposition: String, Equatable, Sendable {
    case inserted
    case updated
    case ignoredNotNewer
    case notFound
}

struct KeywordPopularityMetricOutcome: Equatable, Sendable {
    let target: KeywordResearchTarget
    let popularityScore: Int?
    let observedAt: Date
    let disposition: KeywordPopularityMetricPersistenceDisposition
}

struct KeywordMetricsRefreshOutcome: Sendable {
    let trackID: PersistentIdentifier
    let errorMessage: String?
    let disposition: KeywordMetricsRefreshDisposition

    init(
        trackID: PersistentIdentifier,
        errorMessage: String?,
        disposition: KeywordMetricsRefreshDisposition? = nil
    ) {
        self.trackID = trackID
        self.errorMessage = errorMessage
        self.disposition = disposition ?? (errorMessage == nil ? .refreshed : .failed)
    }

    var isSkipped: Bool {
        disposition == .skipped
    }
}

struct KeywordMetricsPersistenceUpdate: Equatable, Sendable {
    let trackIdentityKeys: [String]
}

enum KeywordMetricsBatchErrorCode: String, Equatable, Sendable {
    case appleAdsSessionExpired = "apple_ads_session_expired"
}

struct KeywordMetricsBatchError: Equatable, Sendable {
    let code: KeywordMetricsBatchErrorCode
    let message: String

    static let appleAdsSessionExpired = KeywordMetricsBatchError(
        code: .appleAdsSessionExpired,
        message: AppleAdsWebSessionExpiredError.message
    )
}

struct KeywordMetricsRefreshBatchResult: Sendable {
    let outcomes: [KeywordMetricsRefreshOutcome]
    let batchErrors: [KeywordMetricsBatchError]

    static let empty = KeywordMetricsRefreshBatchResult(outcomes: [], batchErrors: [])

    var skippedCount: Int {
        outcomes.lazy.filter(\.isSkipped).count
    }

    var failureCount: Int {
        outcomes.lazy.filter { $0.disposition == .failed }.count + batchErrors.count
    }

    var firstErrorMessage: String? {
        batchErrors.first?.message
            ?? outcomes.lazy.first(where: { $0.disposition == .failed })?.errorMessage
    }
}

struct StalePopularityRefreshPreparation: Sendable {
    let trackIdentityKeys: [String]
    let refreshQueryCount: Int
    let clearedStatusCount: Int
}

private struct KeywordMetricsRefreshCandidate: Sendable {
    let trackID: PersistentIdentifier
    let trackIdentityKey: String
    let trackIdentityKeys: [String]
    let term: String
    let storefront: String
    let shouldRefresh: Bool

    var persistenceUpdate: KeywordMetricsPersistenceUpdate {
        KeywordMetricsPersistenceUpdate(trackIdentityKeys: trackIdentityKeys)
    }
}

private struct KeywordMetricsTrackGroup {
    let tracks: [TrackedAppKeyword]
}

private struct KeywordMetricsCandidateGroup: Sendable {
    let tracks: [KeywordMetricsRefreshCandidate]
}

private struct KeywordMetricsPayload: Sendable {
    let popularityScore: Int?
    let difficultyScore: Int?
    let source: KeywordMetricsSource
    var notes: String? = nil
    var statusMessage: String? = nil
    var outcomeDisposition: KeywordMetricsRefreshDisposition = .refreshed
    var preservesExistingPopularity = false
    var popularityDate: String? = nil
    var submissionCount: Int = 1
    var winningCount: Int = 1
    var confidence: String? = "single_source"
    var updatedAt: Date = .now
}

struct AppleAdsPromotedApp: Codable, Equatable, Identifiable, Sendable {
    let adamId: Int64
    let appName: String
    let developerName: String
    let countryOrRegionCodes: [String]

    var id: Int64 { adamId }
}

private enum AppleAdsPopularityResult {
    case success(Int)
    case missingCredentials
    case missingContextApp
    case notFound
    case failure(String)
}
