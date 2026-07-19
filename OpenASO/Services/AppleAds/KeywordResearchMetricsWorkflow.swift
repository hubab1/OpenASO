import Foundation
import SwiftData

enum KeywordResearchMetricsRefreshPolicy: Equatable, Sendable {
    case useFreshCache
    case requireNetwork
}

enum KeywordResearchMetricsIssueCode: String, Equatable, Sendable {
    case missingContextApp
    case missingSession
    case reconnectRequired
    case sessionExpired
    case configurationChanged
    case unsupportedStorefront
    case rateLimited
    case providerFailure
}

struct KeywordResearchMetricsIssue: Equatable, Sendable {
    let code: KeywordResearchMetricsIssueCode
    let message: String
}

enum KeywordResearchMetricsProvenance: Equatable, Sendable {
    /// `KeywordDailyMetric` has no Apple Ads account/app dimension. Cached
    /// values therefore cannot honestly claim which context produced them.
    case sharedCacheContextUnknown
    /// Ephemeral provenance for evidence fetched during this invocation only.
    case requestedContext(appStoreID: Int64)
}

enum KeywordResearchMetricsDisposition: String, Equatable, Sendable {
    case freshCache
    case refreshed
    case staleCacheFallback
    case notFound
    case unavailable
    case supersededByNewerCache
}

struct KeywordResearchMetricsOutcome: Equatable, Sendable {
    let projectGeneration: KeywordResearchProjectGeneration
    let keywordGeneration: KeywordResearchKeywordGeneration
    let queryKey: String
    let term: String
    let storefront: String
    let platform: AppPlatform
    let popularityScore: Int?
    let observedAt: Date?
    let provenance: KeywordResearchMetricsProvenance?
    let disposition: KeywordResearchMetricsDisposition
    let issue: KeywordResearchMetricsIssue?
}

struct KeywordResearchMetricsBatchResult: Equatable, Sendable {
    let outcomes: [KeywordResearchMetricsOutcome]

    static let empty = KeywordResearchMetricsBatchResult(outcomes: [])
}

enum KeywordResearchMetricsWorkflowError: LocalizedError, Equatable, Sendable {
    case tooManyKeywords(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyKeywords(let maximum):
            return "Select no more than \(maximum) research keywords at once."
        }
    }
}

/// Exact settings/session snapshot authorizing one popularity invocation.
///
/// This value is deliberately internal, non-Codable, and never included in an
/// outcome or log because its session contains authentication secrets.
struct KeywordResearchMetricsConfiguration: Equatable, Sendable {
    let contextAppStoreID: Int64?
    let webSession: AppleAdsWebSession?
    let requiresReconnect: Bool
}

/// App-only popularity workflow for pre-live research memberships.
///
/// Provider work runs between generation-safe reads and one final revalidated
/// `BackgroundModelStore` write. The captured Apple Ads configuration is the
/// invocation authority. Re-reading it before the final write prevents normal
/// in-process settings changes from accepting late evidence, although settings
/// and SwiftData do not share a globally atomic revision/lease.
actor KeywordResearchMetricsWorkflow {
    static let freshnessInterval: TimeInterval = 60 * 60 * 24 * 7
    static let maximumKeywordCount = KeywordResearchProjectStore.maximumKeywordCountPerProject

    private let modelStore: BackgroundModelStore
    private let metricsService: KeywordMetricsService
    private let rankingCoordinator: RankingRefreshCoordinator
    private let targetResolver: KeywordResearchTargetResolver
    private let configurationProvider: @MainActor @Sendable () -> KeywordResearchMetricsConfiguration
    private let reconnectMarker: @MainActor @Sendable (AppleAdsWebSession) -> Void
    private let now: @Sendable () -> Date

    init(
        backgroundModelStore: BackgroundModelStore,
        metricsService: KeywordMetricsService,
        rankingCoordinator: RankingRefreshCoordinator,
        targetResolver: KeywordResearchTargetResolver = KeywordResearchTargetResolver(),
        configurationProvider: @escaping @MainActor @Sendable () -> KeywordResearchMetricsConfiguration,
        reconnectMarker: @escaping @MainActor @Sendable (AppleAdsWebSession) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.modelStore = backgroundModelStore
        self.metricsService = metricsService
        self.rankingCoordinator = rankingCoordinator
        self.targetResolver = targetResolver
        self.configurationProvider = configurationProvider
        self.reconnectMarker = reconnectMarker
        self.now = now
    }

    func refresh(
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGeneration: KeywordResearchKeywordGeneration,
        policy: KeywordResearchMetricsRefreshPolicy = .useFreshCache
    ) async throws -> KeywordResearchMetricsOutcome {
        let result = try await refresh(
            projectGeneration: projectGeneration,
            keywordGenerations: [keywordGeneration],
            policy: policy
        )
        guard let outcome = result.outcomes.first else {
            throw KeywordResearchProjectStoreError.keywordNotFound(keywordGeneration.id)
        }
        return outcome
    }

    func refresh(
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGenerations: [KeywordResearchKeywordGeneration],
        policy: KeywordResearchMetricsRefreshPolicy = .useFreshCache
    ) async throws -> KeywordResearchMetricsBatchResult {
        let keywordGenerations = try Self.uniqueKeywordGenerations(keywordGenerations)
        guard !keywordGenerations.isEmpty else { return .empty }

        let freshnessReference = now()
        let selections = try await modelStore.read { modelContext in
            var resolved: [ResolvedSelection] = []
            resolved.reserveCapacity(keywordGenerations.count)
            for keywordGeneration in keywordGenerations {
                let target = try targetResolver.requireTarget(
                    projectGeneration: projectGeneration,
                    keywordGeneration: keywordGeneration,
                    in: modelContext
                )
                _ = try targetResolver.requireQuery(for: target, in: modelContext)
                resolved.append(ResolvedSelection(
                    projectGeneration: projectGeneration,
                    keywordGeneration: keywordGeneration,
                    target: target,
                    cachedMetric: nil
                ))
            }

            let queryKeys = resolved.map(\.target.queryKey)
            let metrics = try metricsService.metricsMap(for: queryKeys, in: modelContext)
            return resolved.map { selection in
                ResolvedSelection(
                    projectGeneration: selection.projectGeneration,
                    keywordGeneration: selection.keywordGeneration,
                    target: selection.target,
                    cachedMetric: metrics[selection.target.queryKey].map(CachedMetric.init)
                )
            }
        }
        try Task.checkCancellation()

        var outcomesByKeywordID: [UUID: KeywordResearchMetricsOutcome] = [:]
        var pendingNetworkSelections: [ResolvedSelection] = []
        for selection in selections {
            if policy == .useFreshCache,
               let cachedMetric = selection.cachedMetric,
               cachedMetric.popularityScore != nil,
               freshnessReference.timeIntervalSince(cachedMetric.updatedAt) < Self.freshnessInterval {
                outcomesByKeywordID[selection.keywordGeneration.id] = selection.outcome(
                    metric: cachedMetric,
                    provenance: .sharedCacheContextUnknown,
                    disposition: .freshCache,
                    issue: nil
                )
            } else {
                pendingNetworkSelections.append(selection)
            }
        }

        guard !pendingNetworkSelections.isEmpty else {
            return Self.orderedResult(selections: selections, outcomesByKeywordID: outcomesByKeywordID)
        }
        // Freeze the post-preflight selection before it is captured by
        // `BackgroundModelStore`'s concurrently executing closures.
        let networkSelections = pendingNetworkSelections

        let configuration = await configurationProvider()
        try Task.checkCancellation()
        if let issue = Self.configurationIssue(configuration) {
            let currentMetrics = try await currentMetricsAfterRevalidating(
                networkSelections,
                honorCancellation: true
            )
            Self.applyFallback(
                issue: issue,
                to: networkSelections,
                currentMetrics: currentMetrics,
                outcomesByKeywordID: &outcomesByKeywordID
            )
            return Self.orderedResult(selections: selections, outcomesByKeywordID: outcomesByKeywordID)
        }
        guard let contextAppStoreID = configuration.contextAppStoreID,
              let webSession = configuration.webSession
        else {
            throw OpenASOError.unexpectedResponse
        }

        var fetchedEvidence: [KeywordPopularityMetricEvidence] = []
        var failedIssuesByQueryKey: [String: KeywordResearchMetricsIssue] = [:]
        let groupedSelections = Dictionary(grouping: networkSelections, by: \.target.storefront)
        do {
            for storefront in groupedSelections.keys.sorted() {
                try Task.checkCancellation()
                let storefrontSelections = (groupedSelections[storefront] ?? []).sorted {
                    if $0.target.queryKey != $1.target.queryKey {
                        return $0.target.queryKey < $1.target.queryKey
                    }
                    return $0.keywordGeneration.id.uuidString < $1.keywordGeneration.id.uuidString
                }
                do {
                    fetchedEvidence.append(contentsOf: try await metricsService.fetchPopularityMetrics(
                        for: storefrontSelections.map(\.target),
                        contextAppStoreID: contextAppStoreID,
                        webSession: webSession,
                        now: now
                    ))
                } catch is AppleAdsWebSessionExpiredError {
                    // Recording exact-session expiry is a security-state
                    // commit point. Once marked, return a truthful outcome
                    // instead of reporting cancellation after the durable UI
                    // state already changed.
                    await reconnectMarker(webSession)
                    let issue = Self.issue(.sessionExpired)
                    let currentMetrics = try await currentMetricsAfterRevalidating(
                        networkSelections,
                        honorCancellation: false
                    )
                    Self.applyFallback(
                        issue: issue,
                        to: networkSelections,
                        currentMetrics: currentMetrics,
                        outcomesByKeywordID: &outcomesByKeywordID
                    )
                    return Self.orderedResult(
                        selections: selections,
                        outcomesByKeywordID: outcomesByKeywordID
                    )
                } catch {
                    if Self.isCancellation(error) {
                        throw CancellationError()
                    }
                    let issue = Self.providerIssue(error)
                    for selection in storefrontSelections {
                        failedIssuesByQueryKey[selection.target.queryKey] = issue
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        try Task.checkCancellation()

        let currentConfiguration = await configurationProvider()
        try Task.checkCancellation()
        guard currentConfiguration == configuration,
              !currentConfiguration.requiresReconnect
        else {
            let currentMetrics = try await currentMetricsAfterRevalidating(
                networkSelections,
                honorCancellation: true
            )
            Self.applyFallback(
                issue: Self.issue(.configurationChanged),
                to: networkSelections,
                currentMetrics: currentMetrics,
                outcomesByKeywordID: &outcomesByKeywordID
            )
            return Self.orderedResult(selections: selections, outcomesByKeywordID: outcomesByKeywordID)
        }

        let successfulQueryKeys = Set(fetchedEvidence.map(\.target.queryKey))
            .subtracting(failedIssuesByQueryKey.keys)
        let evidenceToPersist = fetchedEvidence.filter {
            successfulQueryKeys.contains($0.target.queryKey)
        }
        let commit = try await modelStore.write { modelContext in
            try Task.checkCancellation()
            // Revalidate the complete requested batch, including provider
            // failures. Late responses must not outlive a deleted, replaced,
            // or retargeted research membership.
            for selection in networkSelections {
                let currentTarget = try targetResolver.requireTarget(
                    projectGeneration: selection.projectGeneration,
                    keywordGeneration: selection.keywordGeneration,
                    in: modelContext
                )
                guard currentTarget == selection.target else {
                    throw KeywordResearchProjectStoreError.staleKeywordRevision(
                        selection.keywordGeneration.id
                    )
                }
                _ = try targetResolver.requireQuery(for: currentTarget, in: modelContext)
            }

            let persistence = try metricsService.persistPopularityMetrics(
                evidenceToPersist,
                in: modelContext
            )
            let appliedQueryKeys = Set(persistence.compactMap { outcome -> String? in
                switch outcome.disposition {
                case .inserted, .updated:
                    return outcome.target.queryKey
                case .ignoredNotNewer, .notFound:
                    return nil
                }
            })
            for queryKey in appliedQueryKeys {
                try rankingCoordinator.rebuildDerivedStats(
                    forQueryKey: queryKey,
                    in: modelContext
                )
            }

            let currentMetrics = try metricsService.metricsMap(
                for: networkSelections.map(\.target.queryKey),
                in: modelContext
            )
            try Task.checkCancellation()
            return CommitBatchResult(
                persistence: persistence,
                currentMetrics: Dictionary(uniqueKeysWithValues: currentMetrics.map {
                    ($0.key, CachedMetric($0.value))
                })
            )
        }

        let persistenceByQueryKey = Dictionary(
            uniqueKeysWithValues: commit.persistence.map { ($0.target.queryKey, $0) }
        )
        for selection in networkSelections {
            let queryKey = selection.target.queryKey
            let currentMetric = commit.currentMetrics[queryKey]
            if let issue = failedIssuesByQueryKey[queryKey] {
                outcomesByKeywordID[selection.keywordGeneration.id] = selection.fallbackOutcome(
                    issue: issue,
                    currentMetric: currentMetric
                )
            } else if let persistence = persistenceByQueryKey[queryKey] {
                outcomesByKeywordID[selection.keywordGeneration.id] = selection.outcome(
                    commitOutcome: CommitOutcome(
                        persistence: persistence,
                        currentMetric: currentMetric
                    ),
                    contextAppStoreID: contextAppStoreID
                )
            } else {
                outcomesByKeywordID[selection.keywordGeneration.id] = selection.fallbackOutcome(
                    issue: Self.issue(.providerFailure),
                    currentMetric: currentMetric
                )
            }
        }
        return Self.orderedResult(selections: selections, outcomesByKeywordID: outcomesByKeywordID)
    }
}

private extension KeywordResearchMetricsWorkflow {
    struct CachedMetric: Equatable, Sendable {
        let popularityScore: Int?
        let updatedAt: Date

        var containsPopularityEvidence: Bool {
            popularityScore != nil
        }

        init(_ metric: KeywordDailyMetric) {
            popularityScore = metric.popularityScore
            updatedAt = metric.updatedAt
        }
    }

    struct ResolvedSelection: Equatable, Sendable {
        let projectGeneration: KeywordResearchProjectGeneration
        let keywordGeneration: KeywordResearchKeywordGeneration
        let target: KeywordResearchTarget
        let cachedMetric: CachedMetric?

        func outcome(
            metric: CachedMetric,
            provenance: KeywordResearchMetricsProvenance,
            disposition: KeywordResearchMetricsDisposition,
            issue: KeywordResearchMetricsIssue?
        ) -> KeywordResearchMetricsOutcome {
            KeywordResearchMetricsOutcome(
                projectGeneration: projectGeneration,
                keywordGeneration: keywordGeneration,
                queryKey: target.queryKey,
                term: target.term,
                storefront: target.storefront,
                platform: target.platform,
                popularityScore: metric.popularityScore,
                observedAt: metric.updatedAt,
                provenance: provenance,
                disposition: disposition,
                issue: issue
            )
        }

        func fallbackOutcome(
            issue: KeywordResearchMetricsIssue,
            currentMetric: CachedMetric? = nil
        ) -> KeywordResearchMetricsOutcome {
            if let popularityMetric = currentMetric ?? cachedMetric,
               popularityMetric.containsPopularityEvidence {
                return outcome(
                    metric: popularityMetric,
                    provenance: .sharedCacheContextUnknown,
                    disposition: .staleCacheFallback,
                    issue: issue
                )
            }
            return KeywordResearchMetricsOutcome(
                projectGeneration: projectGeneration,
                keywordGeneration: keywordGeneration,
                queryKey: target.queryKey,
                term: target.term,
                storefront: target.storefront,
                platform: target.platform,
                popularityScore: nil,
                observedAt: nil,
                provenance: nil,
                disposition: .unavailable,
                issue: issue
            )
        }

        func outcome(
            commitOutcome: CommitOutcome,
            contextAppStoreID: Int64
        ) -> KeywordResearchMetricsOutcome {
            switch commitOutcome.persistence.disposition {
            case .inserted, .updated:
                return KeywordResearchMetricsOutcome(
                    projectGeneration: projectGeneration,
                    keywordGeneration: keywordGeneration,
                    queryKey: target.queryKey,
                    term: target.term,
                    storefront: target.storefront,
                    platform: target.platform,
                    popularityScore: commitOutcome.persistence.popularityScore,
                    observedAt: commitOutcome.persistence.observedAt,
                    provenance: .requestedContext(appStoreID: contextAppStoreID),
                    disposition: .refreshed,
                    issue: nil
                )
            case .ignoredNotNewer:
                if let currentMetric = commitOutcome.currentMetric,
                   currentMetric.containsPopularityEvidence {
                    return outcome(
                        metric: currentMetric,
                        provenance: .sharedCacheContextUnknown,
                        disposition: .supersededByNewerCache,
                        issue: nil
                    )
                }
                return fallbackOutcome(
                    issue: KeywordResearchMetricsWorkflow.issue(.providerFailure)
                )
            case .notFound:
                // Another refresh may have inserted or advanced this shared
                // metric while the provider request was suspended. Report
                // the transaction's current cache, not a stale preflight
                // snapshot.
                if let popularityMetric = commitOutcome.currentMetric ?? cachedMetric,
                   popularityMetric.containsPopularityEvidence {
                    return KeywordResearchMetricsOutcome(
                        projectGeneration: projectGeneration,
                        keywordGeneration: keywordGeneration,
                        queryKey: target.queryKey,
                        term: target.term,
                        storefront: target.storefront,
                        platform: target.platform,
                        popularityScore: popularityMetric.popularityScore,
                        observedAt: popularityMetric.updatedAt,
                        provenance: .sharedCacheContextUnknown,
                        disposition: .notFound,
                        issue: nil
                    )
                }
                return KeywordResearchMetricsOutcome(
                    projectGeneration: projectGeneration,
                    keywordGeneration: keywordGeneration,
                    queryKey: target.queryKey,
                    term: target.term,
                    storefront: target.storefront,
                    platform: target.platform,
                    popularityScore: nil,
                    observedAt: nil,
                    provenance: nil,
                    disposition: .notFound,
                    issue: nil
                )
            }
        }
    }

    struct CommitOutcome: Sendable {
        let persistence: KeywordPopularityMetricOutcome
        let currentMetric: CachedMetric?
    }

    struct CommitBatchResult: Sendable {
        let persistence: [KeywordPopularityMetricOutcome]
        let currentMetrics: [String: CachedMetric]
    }

    func currentMetricsAfterRevalidating(
        _ selections: [ResolvedSelection],
        honorCancellation: Bool
    ) async throws -> [String: CachedMetric] {
        if honorCancellation {
            try Task.checkCancellation()
        }
        let snapshots = try await modelStore.read { modelContext in
            if honorCancellation {
                try Task.checkCancellation()
            }
            for selection in selections {
                let currentTarget = try targetResolver.requireTarget(
                    projectGeneration: selection.projectGeneration,
                    keywordGeneration: selection.keywordGeneration,
                    in: modelContext
                )
                guard currentTarget == selection.target else {
                    throw KeywordResearchProjectStoreError.staleKeywordRevision(
                        selection.keywordGeneration.id
                    )
                }
                _ = try targetResolver.requireQuery(for: currentTarget, in: modelContext)
            }
            let metrics = try metricsService.metricsMap(
                for: selections.map(\.target.queryKey),
                in: modelContext
            )
            if honorCancellation {
                try Task.checkCancellation()
            }
            return Dictionary(uniqueKeysWithValues: metrics.map {
                ($0.key, CachedMetric($0.value))
            })
        }
        if honorCancellation {
            try Task.checkCancellation()
        }
        return snapshots
    }

    static func uniqueKeywordGenerations(
        _ generations: [KeywordResearchKeywordGeneration]
    ) throws -> [KeywordResearchKeywordGeneration] {
        var seen: Set<KeywordResearchKeywordGeneration> = []
        let uniqueGenerations = generations.filter { seen.insert($0).inserted }
        guard uniqueGenerations.count <= maximumKeywordCount else {
            throw KeywordResearchMetricsWorkflowError.tooManyKeywords(
                maximum: maximumKeywordCount
            )
        }
        return uniqueGenerations
    }

    static func orderedResult(
        selections: [ResolvedSelection],
        outcomesByKeywordID: [UUID: KeywordResearchMetricsOutcome]
    ) -> KeywordResearchMetricsBatchResult {
        KeywordResearchMetricsBatchResult(
            outcomes: selections.compactMap { outcomesByKeywordID[$0.keywordGeneration.id] }
        )
    }

    static func applyFallback(
        issue: KeywordResearchMetricsIssue,
        to selections: [ResolvedSelection],
        currentMetrics: [String: CachedMetric] = [:],
        outcomesByKeywordID: inout [UUID: KeywordResearchMetricsOutcome]
    ) {
        for selection in selections {
            outcomesByKeywordID[selection.keywordGeneration.id] = selection.fallbackOutcome(
                issue: issue,
                currentMetric: currentMetrics[selection.target.queryKey]
            )
        }
    }

    static func configurationIssue(
        _ configuration: KeywordResearchMetricsConfiguration
    ) -> KeywordResearchMetricsIssue? {
        guard let contextAppStoreID = configuration.contextAppStoreID,
              contextAppStoreID > 0
        else {
            return issue(.missingContextApp)
        }
        guard configuration.webSession?.isComplete == true else {
            return issue(.missingSession)
        }
        guard !configuration.requiresReconnect else {
            return issue(.reconnectRequired)
        }
        return nil
    }

    static func providerIssue(_ error: Error) -> KeywordResearchMetricsIssue {
        if let openASOError = error as? OpenASOError {
            switch openASOError {
            case .rateLimited:
                return issue(.rateLimited)
            case .providerUnavailable(let message)
                where isUnsupportedStorefrontMessage(message):
                return issue(.unsupportedStorefront)
            default:
                break
            }
        }
        return issue(.providerFailure)
    }

    static func issue(_ code: KeywordResearchMetricsIssueCode) -> KeywordResearchMetricsIssue {
        let message: String
        switch code {
        case .missingContextApp:
            message = "Connect Apple Ads and choose a linked context app before refreshing popularity."
        case .missingSession:
            message = "Connect an Apple Ads web session before refreshing popularity."
        case .reconnectRequired:
            message = "Reconnect the Apple Ads web session before refreshing popularity."
        case .sessionExpired:
            message = AppleAdsWebSessionExpiredError.message
        case .configurationChanged:
            message = "Apple Ads settings changed during refresh. Run it again with the current configuration."
        case .unsupportedStorefront:
            message = "Apple Ads keyword popularity is unavailable for this storefront."
        case .rateLimited:
            message = "Apple is rate-limiting keyword popularity. Try again shortly."
        case .providerFailure:
            message = "Apple Ads keyword popularity could not be fetched."
        }
        return KeywordResearchMetricsIssue(code: code, message: message)
    }

    static func isUnsupportedStorefrontMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("apple ads")
            && normalized.contains("keyword popularity")
            && (normalized.contains("not available") || normalized.contains("does not support"))
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
