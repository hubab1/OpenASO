import Foundation
import SwiftData

final class KeywordMetricsService: Sendable {
    private let httpClient: HTTPClient
    private let apiClient: AppleAdsAPIClient
    @MainActor private let popularityClient: AppleAdsPopularityClient
    @MainActor private let settingsStore: AppSettingsStore
    @MainActor private let webSessionStore: AppleAdsWebSessionStore
    private let freshnessFetchObserver: @Sendable (_ queryKeyCount: Int) -> Void
    private let bulkFreshnessFetchHook: @Sendable () throws -> Void
    private let metricsTTL: TimeInterval = 60 * 60 * 24 * 7

    @MainActor
    init(
        httpClient: HTTPClient,
        credentialStore: AppleAdsCredentialStore,
        settingsStore: AppSettingsStore,
        webSessionStore: AppleAdsWebSessionStore,
        freshnessFetchObserver: @escaping @Sendable (_ queryKeyCount: Int) -> Void = { _ in },
        bulkFreshnessFetchHook: @escaping @Sendable () throws -> Void = {}
    ) {
        self.httpClient = httpClient
        self.apiClient = AppleAdsAPIClient(httpClient: httpClient)
        self.settingsStore = settingsStore
        self.webSessionStore = webSessionStore
        self.freshnessFetchObserver = freshnessFetchObserver
        self.bulkFreshnessFetchHook = bulkFreshnessFetchHook
        self.popularityClient = AppleAdsPopularityClient(
            httpClient: httpClient,
            webSessionStore: webSessionStore
        )
    }

    func verifyAppleAdsCredentials(_ credentials: AppleAdsCredentials) async throws -> AppleAdsCredentials {
        try await apiClient.verify(credentials: credentials)
    }

    func searchAppleAdsApps(named query: String, using credentials: AppleAdsCredentials) async throws -> [AppleAdsPromotedApp] {
        try await apiClient.searchOwnedApps(named: query, using: credentials)
    }

    func resolveDefaultAppleAdsApp(using credentials: AppleAdsCredentials) async throws -> AppleAdsPromotedApp {
        try await apiClient.resolveDefaultOwnedApp(using: credentials)
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

        let uniqueTracks = Dictionary(grouping: tracks, by: \.queryKey)
            .compactMapValues(\.first)
            .values
            .sorted(by: Self.trackOrdering)
        let metricsByQueryKey = freshnessMetricsMap(for: uniqueTracks.map(\.queryKey), in: modelContext)
        var outcomes: [KeywordMetricsRefreshOutcome] = []
        var tracksNeedingPopularity: [TrackedAppKeyword] = []
        var clearedFreshStatuses: [(track: TrackedAppKeyword, statusMessage: String)] = []

        for track in uniqueTracks {
            guard !Task.isCancelled else { return outcomes }

            guard Self.shouldRefreshMetrics(metricsTTL: metricsTTL, metric: metricsByQueryKey[track.queryKey]) else {
                if let statusMessage = track.statusMessage,
                   Self.isPopularityStatusMessage(statusMessage) {
                    track.statusMessage = nil
                    clearedFreshStatuses.append((track, statusMessage))
                }
                outcomes.append(
                    KeywordMetricsRefreshOutcome(
                        trackID: track.persistentModelID,
                        errorMessage: nil,
                        disposition: .upToDate
                    )
                )
                continue
            }

            guard settingsStore.popularityContextAppStoreID != nil else {
                let payload = Self.makeAppleAdsMetrics(popularityResult: .missingContextApp)
                Self.applyMetricsPayload(payload, for: track, in: modelContext, outcomes: &outcomes)
                continue
            }

            tracksNeedingPopularity.append(track)
        }

        if !clearedFreshStatuses.isEmpty {
            do {
                try modelContext.save()
            } catch {
                for clearedStatus in clearedFreshStatuses where clearedStatus.track.statusMessage == nil {
                    clearedStatus.track.statusMessage = clearedStatus.statusMessage
                }
            }
        }

        if let contextAppStoreID = settingsStore.popularityContextAppStoreID {
            let storefrontGroups = Self.orderedTrackGroups(tracksNeedingPopularity)
            if webSessionStore.requiresReconnect {
                outcomes.append(contentsOf: storefrontGroups.flatMap(\.tracks).map {
                    KeywordMetricsRefreshOutcome(
                        trackID: $0.persistentModelID,
                        errorMessage: nil,
                        disposition: .skipped
                    )
                })
                return outcomes
            }

            for (groupIndex, group) in storefrontGroups.enumerated() {
                guard !Task.isCancelled else { return outcomes }

                let storefrontTracks = group.tracks
                let storefrontCode = storefrontTracks.first?.storefront ?? "US"
                let popularityResult = await popularityClient.searchPopularities(
                    for: storefrontTracks.map(\.term),
                    storefrontCode: storefrontCode,
                    adamId: contextAppStoreID
                )

                switch popularityResult {
                case .success(let popularities):
                    for track in storefrontTracks {
                        let result: AppleAdsPopularityResult
                        if let popularity = popularities[AppleAdsCMPopularityClient.normalizedKeywordKey(track.term)] {
                            result = .success(popularity)
                        } else {
                            result = .notFound
                        }
                        let payload = Self.makeAppleAdsMetrics(popularityResult: result)
                        Self.applyMetricsPayload(payload, for: track, in: modelContext, outcomes: &outcomes)
                    }
                case .missingCredentials:
                    Self.applyPopularityResult(.missingCredentials, to: storefrontTracks, in: modelContext, outcomes: &outcomes)
                case .expiredSession(let attemptedSession):
                    webSessionStore.markReconnectRequired(for: attemptedSession)
                    let skippedTracks = storefrontGroups[groupIndex...].flatMap(\.tracks)
                    outcomes.append(contentsOf: skippedTracks.map {
                        KeywordMetricsRefreshOutcome(
                            trackID: $0.persistentModelID,
                            errorMessage: nil,
                            disposition: .skipped
                        )
                    })
                    try? modelContext.save()
                    return outcomes
                case .cancelled:
                    return outcomes
                case .failure(let message):
                    Self.applyPopularityResult(.failure(message), to: storefrontTracks, in: modelContext, outcomes: &outcomes)
                }
            }
        }

        try? modelContext.save()
        return outcomes
    }

    func refreshMetrics(
        for trackIdentityKeys: [String],
        popularityContextAppStoreID: Int64?,
        webSession: AppleAdsWebSession?,
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [KeywordMetricsRefreshOutcome] {
        (try await refreshMetricsBatch(
            for: trackIdentityKeys,
            popularityContextAppStoreID: popularityContextAppStoreID,
            webSession: webSession,
            using: modelStore,
            progress: progress
        )).outcomes
    }

    func refreshMetricsBatch(
        for trackIdentityKeys: [String],
        popularityContextAppStoreID: Int64?,
        webSession: AppleAdsWebSession?,
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
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
            for track in tracks where !Self.shouldRefreshMetrics(
                metricsTTL: metricsTTL,
                metric: metricsByQueryKey[track.queryKey]
            ) {
                Self.clearPopularityStatusIfNeeded(for: track)
            }
            return tracksByQueryKey.values.compactMap { queryTracks -> KeywordMetricsRefreshCandidate? in
                let sortedQueryTracks = queryTracks.sorted { $0.identityKey < $1.identityKey }
                guard let track = sortedQueryTracks.first else { return nil }
                return KeywordMetricsRefreshCandidate(
                    trackID: track.persistentModelID,
                    trackIdentityKey: track.identityKey,
                    trackIdentityKeys: sortedQueryTracks.map(\.identityKey),
                    term: track.term,
                    storefront: track.storefront,
                    shouldRefresh: Self.shouldRefreshMetrics(metricsTTL: metricsTTL, metric: metricsByQueryKey[track.queryKey])
                )
            }
            .sorted(by: Self.candidateOrdering)
        }
        try Task.checkCancellation()

        var outcomes: [KeywordMetricsRefreshOutcome] = []
        var batchErrors: [KeywordMetricsBatchError] = []
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
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
                continue
            }

            guard popularityContextAppStoreID != nil else {
                let outcome = try await persistMetricsPayload(
                    Self.makeAppleAdsMetrics(popularityResult: .missingContextApp),
                    for: candidate,
                    using: modelStore
                )
                outcomes.append(outcome)
                if outcome.errorMessage != nil { failureCount += 1 }
                completedCount += 1
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
                continue
            }

            tracksNeedingPopularity.append(candidate)
        }

        guard let popularityContextAppStoreID else {
            return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
        }

        guard let webSession, webSession.isComplete else {
            for candidate in tracksNeedingPopularity {
                try Task.checkCancellation()
                let outcome = try await persistMetricsPayload(
                    Self.makeAppleAdsMetrics(popularityResult: .missingCredentials),
                    for: candidate,
                    using: modelStore
                )
                outcomes.append(outcome)
                if outcome.errorMessage != nil { failureCount += 1 }
                completedCount += 1
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
            }
            return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
        }

        let cmPopularityClient = AppleAdsCMPopularityClient(httpClient: httpClient)
        let storefrontGroups = Self.orderedCandidateGroups(tracksNeedingPopularity)
        try Task.checkCancellation()
        if await webSessionStore.requiresReconnect(for: webSession) {
            try Task.checkCancellation()
            batchErrors.append(.appleAdsSessionExpired)
            failureCount += 1
            if storefrontGroups.isEmpty {
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
            }
            for candidate in storefrontGroups.flatMap(\.tracks) {
                try Task.checkCancellation()
                outcomes.append(
                    KeywordMetricsRefreshOutcome(
                        trackID: candidate.trackID,
                        errorMessage: nil,
                        disposition: .skipped
                    )
                )
                completedCount += 1
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
            }
            return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
        }

        guard !storefrontGroups.isEmpty else {
            return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
        }

        for (groupIndex, group) in storefrontGroups.enumerated() {
            try Task.checkCancellation()
            let storefrontTracks = group.tracks
            let storefrontCode = storefrontTracks.first?.storefront ?? "US"
            let popularities: [String: Int]
            do {
                popularities = try await cmPopularityClient.keywordPopularities(
                    for: storefrontTracks.map(\.term),
                    storefrontCode: storefrontCode,
                    adamId: popularityContextAppStoreID,
                    session: webSession
                )
            } catch is AppleAdsWebSessionExpiredError {
                try Task.checkCancellation()
                await webSessionStore.markReconnectRequired(for: webSession)
                batchErrors.append(.appleAdsSessionExpired)
                failureCount += 1
                let skippedCandidates = storefrontGroups[groupIndex...].flatMap(\.tracks)
                for candidate in skippedCandidates {
                    try Task.checkCancellation()
                    outcomes.append(
                        KeywordMetricsRefreshOutcome(
                            trackID: candidate.trackID,
                            errorMessage: nil,
                            disposition: .skipped
                        )
                    )
                    completedCount += 1
                    await progress?(completedCount, totalCount, failureCount)
                    try Task.checkCancellation()
                }
                break
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
                    if outcome.errorMessage != nil { failureCount += 1 }
                    completedCount += 1
                    await progress?(completedCount, totalCount, failureCount)
                    try Task.checkCancellation()
                }
                continue
            }

            for candidate in storefrontTracks {
                try Task.checkCancellation()
                let result: AppleAdsPopularityResult
                if let popularity = popularities[AppleAdsCMPopularityClient.normalizedKeywordKey(candidate.term)] {
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
                if outcome.errorMessage != nil { failureCount += 1 }
                completedCount += 1
                await progress?(completedCount, totalCount, failureCount)
                try Task.checkCancellation()
            }
        }

        return KeywordMetricsRefreshBatchResult(outcomes: outcomes, batchErrors: batchErrors)
    }

    func refreshStalePopularityMetrics(
        popularityContextAppStoreID: Int64,
        webSession: AppleAdsWebSession,
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [KeywordMetricsRefreshOutcome] {
        guard webSession.isComplete else { return [] }

        let preparation = try await prepareStalePopularityRefresh(using: modelStore)
        let trackIdentityKeys = preparation.trackIdentityKeys

        guard !trackIdentityKeys.isEmpty else { return [] }

        return try await refreshMetrics(
            for: trackIdentityKeys,
            popularityContextAppStoreID: popularityContextAppStoreID,
            webSession: webSession,
            using: modelStore,
            progress: progress
        )
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
            var clearedStatusCount = 0
            for track in tracks where !Self.shouldRefreshMetrics(
                metricsTTL: metricsTTL,
                metric: metricsByQueryKey[track.queryKey]
            ) {
                if Self.clearPopularityStatusIfNeeded(for: track) {
                    clearedStatusCount += 1
                }
            }
            let queryTracksNeedingRefresh = tracksByQueryKey.values.filter { queryTracks in
                guard let track = queryTracks.first else { return false }
                return Self.shouldRefreshMetrics(
                    metricsTTL: metricsTTL,
                    metric: metricsByQueryKey[track.queryKey]
                )
            }
            let refreshIdentityKeys = queryTracksNeedingRefresh.flatMap { $0.map(\.identityKey) }
            return StalePopularityRefreshPreparation(
                trackIdentityKeys: refreshIdentityKeys.sorted(),
                refreshQueryCount: queryTracksNeedingRefresh.count,
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

    private static func applyPopularityResult(
        _ result: AppleAdsPopularityResult,
        to tracks: [TrackedAppKeyword],
        in modelContext: ModelContext,
        outcomes: inout [KeywordMetricsRefreshOutcome]
    ) {
        for track in tracks {
            let payload = makeAppleAdsMetrics(popularityResult: result)
            applyMetricsPayload(payload, for: track, in: modelContext, outcomes: &outcomes)
        }
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
            ?? tracks.first else {
            return KeywordMetricsRefreshOutcome(
                trackID: fallbackTrackID,
                errorMessage: OpenASOError.appNotFound.localizedDescription
            )
        }

        var outcomes: [KeywordMetricsRefreshOutcome] = []
        applyMetricsPayload(payload, for: track, in: modelContext, outcomes: &outcomes)
        if payload.statusMessage == nil {
            for siblingTrack in tracks {
                clearPopularityStatusIfNeeded(for: siblingTrack)
            }
        }
        return outcomes.last ?? KeywordMetricsRefreshOutcome(trackID: fallbackTrackID, errorMessage: nil)
    }

    private static func applyMetricsPayload(
        _ payload: KeywordMetricsPayload,
        for track: TrackedAppKeyword,
        in modelContext: ModelContext,
        outcomes: inout [KeywordMetricsRefreshOutcome]
    ) {
        upsertMetrics(payload, for: track, in: modelContext)
        if let statusMessage = payload.statusMessage {
            track.statusMessage = statusMessage
            outcomes.append(KeywordMetricsRefreshOutcome(trackID: track.persistentModelID, errorMessage: statusMessage))
        } else {
            clearPopularityStatusIfNeeded(for: track)
            outcomes.append(KeywordMetricsRefreshOutcome(trackID: track.persistentModelID, errorMessage: nil))
        }
    }

    private static func shouldRefreshMetrics(metricsTTL: TimeInterval, metric: KeywordDailyMetric?) -> Bool {
        guard let metric else {
            return true
        }

        return metric.popularityScore == nil || Date.now.timeIntervalSince(metric.updatedAt) >= metricsTTL
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

        let shouldPreserveExistingPopularity = payload.statusMessage != nil && metrics.popularityScore != nil
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
                statusMessage: "\(popularityFailedToFetchPrefix) Connect an Apple Ads web session in Settings."
            )
        case .missingContextApp:
            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "\(popularityFailedToFetchPrefix) Reconnect Apple Ads in Settings so OpenASO can detect a linked app."
            )
        case .notFound:
            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "\(popularityFailedToFetchPrefix) Apple Ads returned no popularity for this keyword using the configured popularity app."
            )
        case .failure(let message):
            if isUnsupportedAppleAdsStorefrontMessage(message) {
                return KeywordMetricsPayload(
                    popularityScore: nil,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    statusMessage: "\(popularityUnavailablePrefix) \(message)"
                )
            }

            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "\(popularityFailedToFetchPrefix) \(message)"
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

    @discardableResult
    private static func clearPopularityStatusIfNeeded(for track: TrackedAppKeyword) -> Bool {
        guard isPopularityStatusMessage(track.statusMessage) else { return false }
        track.statusMessage = nil
        return true
    }

    static let popularityFailedToFetchPrefix = "Popularity failed to fetch."
    static let popularityUnavailablePrefix = "Popularity unavailable."

    static func isPopularityStatusMessage(_ statusMessage: String?) -> Bool {
        guard let statusMessage else { return false }
        return statusMessage.hasPrefix(popularityFailedToFetchPrefix)
            || statusMessage.hasPrefix(popularityUnavailablePrefix)
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
        outcomes.lazy.filter { $0.errorMessage != nil }.count + batchErrors.count
    }

    var firstErrorMessage: String? {
        batchErrors.first?.message ?? outcomes.lazy.compactMap(\.errorMessage).first
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
    var popularityDate: String? = nil
    var submissionCount: Int = 1
    var winningCount: Int = 1
    var confidence: String? = "single_source"
    var updatedAt: Date = .now
}

private struct AppleAdsAPIClient: Sendable {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func verify(credentials: AppleAdsCredentials) async throws -> AppleAdsCredentials {
        let credentials = credentials.trimmed
        guard credentials.canVerify else {
            throw OpenASOError.providerUnavailable("Enter the Apple Ads client ID, team ID, key ID, and private key.")
        }

        let accessToken = try await requestAccessToken(using: credentials)
        let orgID = try await requestOrgID(accessToken: accessToken)
        return AppleAdsCredentials(
            clientID: credentials.clientID,
            teamID: credentials.teamID,
            keyID: credentials.keyID,
            privateKey: credentials.privateKey,
            orgID: orgID
        )
    }

    func searchOwnedApps(named query: String, using credentials: AppleAdsCredentials) async throws -> [AppleAdsPromotedApp] {
        let credentials = credentials.trimmed
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 3 else {
            throw OpenASOError.providerUnavailable("Enter at least three characters to search Apple Ads apps.")
        }
        guard credentials.canVerify else {
            throw OpenASOError.providerUnavailable("Enter the Apple Ads client ID, team ID, key ID, and private key.")
        }

        let accessToken = try await requestAccessToken(using: credentials)
        let orgID = credentials.orgID.isEmpty ? try await requestOrgID(accessToken: accessToken) : credentials.orgID
        return try await searchOwnedApps(
            named: normalizedQuery,
            accessToken: accessToken,
            orgID: orgID
        )
    }

    func resolveDefaultOwnedApp(using credentials: AppleAdsCredentials) async throws -> AppleAdsPromotedApp {
        let credentials = credentials.trimmed
        guard credentials.canVerify else {
            throw OpenASOError.providerUnavailable("Enter and verify Apple Ads API credentials to find a linked app.")
        }

        let accessToken = try await requestAccessToken(using: credentials)
        let orgID = credentials.orgID.isEmpty ? try await requestOrgID(accessToken: accessToken) : credentials.orgID
        let campaignApps = try await fetchCampaignApps(accessToken: accessToken, orgID: orgID)
        if let app = campaignApps.first {
            return app
        }

        throw OpenASOError.providerUnavailable("Apple Ads needs at least one app with an Apple Ads campaign linked to this account to fetch popularity and difficulty data.")
    }

    private func searchOwnedApps(named query: String, accessToken: String, orgID: String) async throws -> [AppleAdsPromotedApp] {
        var components = URLComponents(string: "https://api.searchads.apple.com/api/v5/search/apps")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "returnOwnedApps", value: "true")
        ]

        guard let url = components.url else {
            throw OpenASOError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("orgId=\(orgID)", forHTTPHeaderField: "X-AP-Context")

        let data = try await validatedData(for: request, using: httpClient)
        let response = try JSONDecoder().decode(AppleAdsAppSearchEnvelope.self, from: data)
        return response.data
    }

    private func fetchCampaignApps(accessToken: String, orgID: String) async throws -> [AppleAdsPromotedApp] {
        var request = URLRequest(url: URL(string: "https://api.searchads.apple.com/api/v5/campaigns")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("orgId=\(orgID)", forHTTPHeaderField: "X-AP-Context")

        let data = try await validatedData(for: request, using: httpClient)
        let response = try JSONDecoder().decode(AppleAdsCampaignEnvelope.self, from: data)
        var seenAppIDs: Set<Int64> = []
        return response.data.compactMap { campaign in
            guard !campaign.deleted, seenAppIDs.insert(campaign.adamId).inserted else {
                return nil
            }

            return AppleAdsPromotedApp(
                adamId: campaign.adamId,
                appName: campaign.appName ?? "App ID \(campaign.adamId)",
                developerName: "",
                countryOrRegionCodes: campaign.countriesOrRegions
            )
        }
    }

    private func requestAccessToken(using credentials: AppleAdsCredentials) async throws -> String {
        let clientSecret = try AppleSearchAdsJWT(
            clientID: credentials.clientID,
            teamID: credentials.teamID,
            keyID: credentials.keyID,
            privateKey: credentials.privateKey
        ).signed()

        var request = URLRequest(url: URL(string: "https://appleid.apple.com/auth/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "scope", value: "searchadsorg"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data = try await validatedData(for: request, using: httpClient)
        let response = try JSONDecoder().decode(AccessTokenResponse.self, from: data)
        return response.accessToken
    }

    private func requestOrgID(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.searchads.apple.com/api/v5/acls")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await validatedData(for: request, using: httpClient)
        let response = try JSONDecoder().decode(UserACLEnvelope.self, from: data)
        guard let orgID = response.data.first?.orgID else {
            throw OpenASOError.providerUnavailable("Apple Ads credentials verified, but no org ID was returned.")
        }
        return String(orgID)
    }
}

@MainActor
private final class AppleAdsPopularityClient {
    private let webSessionStore: AppleAdsWebSessionStore
    private let cmPopularityClient: AppleAdsCMPopularityClient

    init(
        httpClient: HTTPClient,
        webSessionStore: AppleAdsWebSessionStore
    ) {
        self.webSessionStore = webSessionStore
        self.cmPopularityClient = AppleAdsCMPopularityClient(httpClient: httpClient)
    }

    func searchPopularity(for keyword: String, storefrontCode: String, adamId: Int64) async -> AppleAdsPopularityResult {
        guard let session = webSessionStore.session, session.isComplete else {
            return .missingCredentials
        }

        do {
            if let popularity = try await cmPopularityClient.keywordPopularity(
                for: keyword,
                storefrontCode: storefrontCode,
                adamId: adamId,
                session: session
            ) {
                return .success(popularity)
            }

            return .notFound
        } catch {
            return .failure(OpenASOError.map(error).localizedDescription)
        }
    }

    func searchPopularities(for keywords: [String], storefrontCode: String, adamId: Int64) async -> AppleAdsPopularityBatchResult {
        guard let session = webSessionStore.session, session.isComplete else {
            return .missingCredentials
        }

        do {
            try Task.checkCancellation()
            let popularities = try await cmPopularityClient.keywordPopularities(
                for: keywords,
                storefrontCode: storefrontCode,
                adamId: adamId,
                session: session
            )
            try Task.checkCancellation()
            return .success(popularities)
        } catch is AppleAdsWebSessionExpiredError {
            return .expiredSession(session)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            if Task.isCancelled {
                return .cancelled
            }
            return .failure(OpenASOError.map(error).localizedDescription)
        }
    }
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

private enum AppleAdsPopularityBatchResult {
    case success([String: Int])
    case missingCredentials
    case expiredSession(AppleAdsWebSession)
    case cancelled
    case failure(String)
}

private struct AccessTokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct UserACLEnvelope: Decodable {
    let data: [UserACL]
}

private struct UserACL: Decodable {
    let orgID: Int

    private enum CodingKeys: String, CodingKey {
        case orgID = "orgId"
    }
}

private struct AppleAdsAppSearchEnvelope: Decodable {
    let data: [AppleAdsPromotedApp]
}

private struct AppleAdsCampaignEnvelope: Decodable {
    let data: [AppleAdsCampaign]
}

private struct AppleAdsCampaign: Decodable {
    let adamId: Int64
    let appName: String?
    let countriesOrRegions: [String]
    let deleted: Bool
}
