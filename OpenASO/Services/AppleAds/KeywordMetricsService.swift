import Foundation
import SwiftData

final class KeywordMetricsService: Sendable {
    private let httpClient: HTTPClient
    private let apiClient: AppleAdsAPIClient
    @MainActor private let popularityClient: AppleAdsPopularityClient
    @MainActor private let settingsStore: AppSettingsStore
    private let metricsTTL: TimeInterval = 60 * 60 * 24 * 7
    private static let popularityStorefrontConcurrency = 2

    @MainActor
    init(
        httpClient: HTTPClient,
        credentialStore: AppleAdsCredentialStore,
        settingsStore: AppSettingsStore,
        webSessionStore: AppleAdsWebSessionStore
    ) {
        self.httpClient = httpClient
        self.apiClient = AppleAdsAPIClient(httpClient: httpClient)
        self.settingsStore = settingsStore
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
        guard !queryKeys.isEmpty else {
            return [:]
        }

        let targetQueryKeys = queryKeys
        let descriptor = FetchDescriptor<KeywordDailyMetric>(
            predicate: #Predicate { metrics in
                targetQueryKeys.contains(metrics.queryKey)
            }
        )
        let metrics = try modelContext.fetch(descriptor)
        return Dictionary(uniqueKeysWithValues: metrics.map { ($0.queryKey, $0) })
    }

    @MainActor
    func refreshMetrics(
        for trackedApp: TrackedApp,
        tracks: [TrackedAppKeyword],
        in modelContext: ModelContext
    ) async -> [KeywordMetricsRefreshOutcome] {
        let uniqueTracks = Dictionary(grouping: tracks, by: \.queryKey).compactMapValues(\.first)
        var outcomes: [KeywordMetricsRefreshOutcome] = []
        var tracksNeedingPopularity: [TrackedAppKeyword] = []

        for track in uniqueTracks.values {
            guard Self.shouldRefreshMetrics(metricsTTL: metricsTTL, for: track.queryKey, in: modelContext) else {
                outcomes.append(KeywordMetricsRefreshOutcome(trackID: track.persistentModelID, errorMessage: nil))
                continue
            }

            guard settingsStore.popularityContextAppStoreID != nil else {
                let payload = Self.makeAppleAdsMetrics(popularityResult: .missingContextApp)
                Self.applyMetricsPayload(payload, for: track, in: modelContext, outcomes: &outcomes)
                continue
            }

            tracksNeedingPopularity.append(track)
        }

        if let contextAppStoreID = settingsStore.popularityContextAppStoreID {
            for (_, storefrontTracks) in Dictionary(grouping: tracksNeedingPopularity, by: \.storefront) {
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
        guard !trackIdentityKeys.isEmpty else { return [] }

        let metricsTTL = metricsTTL
        let candidates = try await modelStore.read { modelContext in
            let targetIdentityKeys = trackIdentityKeys
            let descriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    targetIdentityKeys.contains(track.identityKey)
                }
            )
            let tracks = try modelContext.fetch(descriptor)
            let uniqueTracks = Dictionary(grouping: tracks, by: \.queryKey).compactMapValues(\.first)
            return uniqueTracks.values.map { track in
                KeywordMetricsRefreshCandidate(
                    trackID: track.persistentModelID,
                    trackIdentityKey: track.identityKey,
                    term: track.term,
                    storefront: track.storefront,
                    shouldRefresh: Self.shouldRefreshMetrics(
                        metricsTTL: metricsTTL,
                        for: track.queryKey,
                        in: modelContext
                    )
                )
            }
        }

        var outcomes: [KeywordMetricsRefreshOutcome] = []
        var tracksNeedingPopularity: [KeywordMetricsRefreshCandidate] = []
        let totalCount = candidates.count
        var completedCount = 0
        var failureCount = 0
        await progress?(0, totalCount, 0)

        for candidate in candidates {
            guard candidate.shouldRefresh else {
                outcomes.append(KeywordMetricsRefreshOutcome(trackID: candidate.trackID, errorMessage: nil))
                completedCount += 1
                await progress?(completedCount, totalCount, failureCount)
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
                continue
            }

            tracksNeedingPopularity.append(candidate)
        }

        guard let popularityContextAppStoreID else {
            return outcomes
        }

        guard let webSession, webSession.isComplete else {
            for candidate in tracksNeedingPopularity {
                let outcome = try await persistMetricsPayload(
                    Self.makeAppleAdsMetrics(popularityResult: .missingCredentials),
                    for: candidate,
                    using: modelStore
                )
                outcomes.append(outcome)
                if outcome.errorMessage != nil { failureCount += 1 }
                completedCount += 1
                await progress?(completedCount, totalCount, failureCount)
            }
            return outcomes
        }

        let cmPopularityClient = AppleAdsCMPopularityClient(httpClient: httpClient)
        let storefrontGroups = Dictionary(grouping: tracksNeedingPopularity, by: \.storefront)
            .map { storefront, candidates in
                KeywordMetricsStorefrontBatch(
                    storefront: storefront,
                    candidates: candidates
                )
            }
            .sorted { $0.storefront < $1.storefront }

        for await batchResult in Self.popularityBatchResults(
            storefrontGroups,
            cmPopularityClient: cmPopularityClient,
            popularityContextAppStoreID: popularityContextAppStoreID,
            webSession: webSession
        ) {
            for candidate in batchResult.candidates {
                let result: AppleAdsPopularityResult
                if let errorMessage = batchResult.errorMessage {
                    result = .failure(errorMessage)
                } else if let popularity = batchResult.popularities[AppleAdsCMPopularityClient.normalizedKeywordKey(candidate.term)] {
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
            }
        }

        return outcomes
    }

    private static func popularityBatchResults(
        _ batches: [KeywordMetricsStorefrontBatch],
        cmPopularityClient: AppleAdsCMPopularityClient,
        popularityContextAppStoreID: Int64,
        webSession: AppleAdsWebSession
    ) -> AsyncStream<KeywordMetricsStorefrontBatchResult> {
        AsyncStream { continuation in
            Task {
                await withTaskGroup(of: KeywordMetricsStorefrontBatchResult.self) { group in
                    var nextBatchIndex = 0
                    var activeFetchCount = 0

                    func enqueueNextFetchIfPossible() {
                        guard activeFetchCount < popularityStorefrontConcurrency,
                              nextBatchIndex < batches.count
                        else {
                            return
                        }

                        let batch = batches[nextBatchIndex]
                        nextBatchIndex += 1
                        activeFetchCount += 1
                        group.addTask {
                            do {
                                let popularities = try await cmPopularityClient.keywordPopularities(
                                    for: batch.candidates.map(\.term),
                                    storefrontCode: batch.storefront,
                                    adamId: popularityContextAppStoreID,
                                    session: webSession
                                )
                                return KeywordMetricsStorefrontBatchResult(
                                    candidates: batch.candidates,
                                    popularities: popularities,
                                    errorMessage: nil
                                )
                            } catch {
                                return KeywordMetricsStorefrontBatchResult(
                                    candidates: batch.candidates,
                                    popularities: [:],
                                    errorMessage: OpenASOError.map(error).localizedDescription
                                )
                            }
                        }
                    }

                    for _ in 0..<min(popularityStorefrontConcurrency, batches.count) {
                        enqueueNextFetchIfPossible()
                    }

                    while let result = await group.next() {
                        activeFetchCount -= 1
                        continuation.yield(result)
                        enqueueNextFetchIfPossible()
                    }
                }
                continuation.finish()
            }
        }
    }

    func refreshStalePopularityMetrics(
        popularityContextAppStoreID: Int64,
        webSession: AppleAdsWebSession,
        using modelStore: BackgroundModelStore,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [KeywordMetricsRefreshOutcome] {
        guard webSession.isComplete else { return [] }

        let trackIdentityKeys = try await stalePopularityTrackIdentityKeys(using: modelStore)

        guard !trackIdentityKeys.isEmpty else { return [] }

        return try await refreshMetrics(
            for: trackIdentityKeys,
            popularityContextAppStoreID: popularityContextAppStoreID,
            webSession: webSession,
            using: modelStore,
            progress: progress
        )
    }

    func stalePopularityTrackIdentityKeys(using modelStore: BackgroundModelStore) async throws -> [String] {
        let metricsTTL = metricsTTL
        return try await modelStore.read { modelContext in
            let descriptor = FetchDescriptor<TrackedAppKeyword>()
            let tracks = try modelContext.fetch(descriptor)
            let uniqueTracks = Dictionary(grouping: tracks, by: \.queryKey).compactMapValues(\.first)
            return uniqueTracks.values
                .filter { track in
                    Self.shouldRefreshMetrics(
                        metricsTTL: metricsTTL,
                        for: track.queryKey,
                        in: modelContext
                    )
                }
                .map(\.identityKey)
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
                forTrackIdentityKey: candidate.trackIdentityKey,
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
        forTrackIdentityKey trackIdentityKey: String,
        fallbackTrackID: PersistentIdentifier,
        in modelContext: ModelContext
    ) throws -> KeywordMetricsRefreshOutcome {
        let targetIdentityKey = trackIdentityKey
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.identityKey == targetIdentityKey
            }
        )
        guard let track = try modelContext.fetch(descriptor).first else {
            return KeywordMetricsRefreshOutcome(
                trackID: fallbackTrackID,
                errorMessage: OpenASOError.appNotFound.localizedDescription
            )
        }

        var outcomes: [KeywordMetricsRefreshOutcome] = []
        applyMetricsPayload(payload, for: track, in: modelContext, outcomes: &outcomes)
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

    private static func shouldRefreshMetrics(metricsTTL: TimeInterval, for queryKey: String, in modelContext: ModelContext) -> Bool {
        guard let metrics = try? fetchMetrics(queryKey: queryKey, in: modelContext) else {
            return true
        }

        return metrics.popularityScore == nil || Date.now.timeIntervalSince(metrics.updatedAt) >= metricsTTL
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
        if let difficultyScore = payload.difficultyScore {
            metrics.difficultyScore = difficultyScore
        }
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
                statusMessage: "Popularity failed to fetch. Connect an Apple Ads web session in Settings."
            )
        case .missingContextApp:
            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "Popularity failed to fetch. Reconnect Apple Ads in Settings so OpenASO can detect a linked app."
            )
        case .notFound:
            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "Popularity failed to fetch. Apple Ads returned no popularity for this keyword using the configured popularity app."
            )
        case .failure(let message):
            if isUnsupportedAppleAdsStorefrontMessage(message) {
                return KeywordMetricsPayload(
                    popularityScore: nil,
                    difficultyScore: nil,
                    source: .appleAdsPopularity,
                    statusMessage: "Popularity unavailable. \(message)"
                )
            }

            return KeywordMetricsPayload(
                popularityScore: nil,
                difficultyScore: nil,
                source: .appleAdsPopularity,
                statusMessage: "Popularity failed to fetch. \(message)"
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

    private static func clearPopularityStatusIfNeeded(for track: TrackedAppKeyword) {
        guard track.statusMessage?.hasPrefix("Popularity failed to fetch.") == true
            || track.statusMessage?.hasPrefix("Popularity unavailable.") == true
        else {
            return
        }

        track.statusMessage = nil
    }
}

struct KeywordMetricsRefreshOutcome: Sendable {
    let trackID: PersistentIdentifier
    let errorMessage: String?
}

private struct KeywordMetricsRefreshCandidate: Sendable {
    let trackID: PersistentIdentifier
    let trackIdentityKey: String
    let term: String
    let storefront: String
    let shouldRefresh: Bool
}

private struct KeywordMetricsStorefrontBatch: Sendable {
    let storefront: String
    let candidates: [KeywordMetricsRefreshCandidate]
}

private struct KeywordMetricsStorefrontBatchResult: Sendable {
    let candidates: [KeywordMetricsRefreshCandidate]
    let popularities: [String: Int]
    let errorMessage: String?
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
            let popularities = try await cmPopularityClient.keywordPopularities(
                for: keywords,
                storefrontCode: storefrontCode,
                adamId: adamId,
                session: session
            )
            return .success(popularities)
        } catch {
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
