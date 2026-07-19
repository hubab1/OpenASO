import Foundation
import SwiftData

struct KeywordResearchRankingItemSnapshot: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let position: Int
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
}

struct KeywordResearchRankingObservationSnapshot: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let projectGeneration: KeywordResearchProjectGeneration
    let keywordGeneration: KeywordResearchKeywordGeneration
    let queryKey: String
    let term: String
    let storefront: String
    let platform: AppPlatform
    let observedAt: Date
    let observedHour: Int
    let source: RankingSource
    let resultCount: Int
    let submissionCount: Int
    let winningCount: Int
    let confidence: String?
    let items: [KeywordResearchRankingItemSnapshot]
}

/// App-only ranking workflow for pre-live research memberships.
///
/// SwiftData models remain inside `BackgroundModelStore` operations. The
/// provider request runs between a read preflight and a single revalidated
/// write, so a deleted, replaced, or retargeted generation cannot receive a
/// late observation.
actor KeywordResearchRankingWorkflow {
    /// Persisted crawls always request the full supported result window.
    /// The shared crawl schema has no completeness dimension, so allowing a
    /// caller-selected prefix could replace and prune a fuller same-day crawl.
    static let persistedResultLimit = SearchRankingCrawl.fullKeywordRankingLimit

    private let modelStore: BackgroundModelStore
    private let rankingCoordinator: RankingRefreshCoordinator

    init(
        backgroundModelStore: BackgroundModelStore,
        rankingCoordinator: RankingRefreshCoordinator
    ) {
        self.modelStore = backgroundModelStore
        self.rankingCoordinator = rankingCoordinator
    }

    func refresh(
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGeneration: KeywordResearchKeywordGeneration
    ) async throws -> KeywordResearchRankingObservationSnapshot {
        let target = try await modelStore.read { modelContext in
            try Self.requireTarget(
                projectGeneration: projectGeneration,
                keywordGeneration: keywordGeneration,
                in: modelContext
            )
        }
        try Task.checkCancellation()

        let request = RankingRefreshRequest(
            identityKey: keywordGeneration.id.uuidString.lowercased(),
            queryKey: target.queryKey,
            term: target.term,
            storefront: target.storefront,
            platform: target.platform
        )
        let pageResult: RankingRefreshPageResult
        do {
            pageResult = try await rankingCoordinator.fetchRankingPage(
                for: request,
                limit: Self.persistedResultLimit
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OpenASOError.map(error)
        }
        try Task.checkCancellation()

        let commit = try await modelStore.write { modelContext in
            try Task.checkCancellation()
            let currentTarget = try Self.requireTarget(
                projectGeneration: projectGeneration,
                keywordGeneration: keywordGeneration,
                in: modelContext
            )
            guard currentTarget == target,
                  pageResult.request.queryKey == currentTarget.queryKey
            else {
                throw KeywordResearchProjectStoreError.staleKeywordRevision(
                    keywordGeneration.id
                )
            }

            let query = try Self.requireQuery(for: currentTarget, in: modelContext)
            let persisted = try rankingCoordinator.persistSharedRankingObservation(
                pageResult,
                query: query,
                in: modelContext
            )
            try rankingCoordinator.rebuildDerivedStats(
                forQueryKey: currentTarget.queryKey,
                in: modelContext
            )
            let snapshot = Self.snapshot(
                persisted.observation,
                projectGeneration: projectGeneration,
                keywordGeneration: keywordGeneration
            )
            try Task.checkCancellation()
            return CommitResult(
                snapshot: snapshot,
                shouldScheduleMetadataEnrichment: persisted.appliedIncomingPage
            )
        }

        // A successful write return is the commit point. Do not report
        // cancellation after data is durable: doing so would suppress the
        // post-commit enrichment and make an equal retry a permanent no-op.
        if commit.shouldScheduleMetadataEnrichment {
            rankingCoordinator.scheduleTopRankingMetadataEnrichment(for: pageResult)
        }
        return commit.snapshot
    }
}

private extension KeywordResearchRankingWorkflow {
    struct Target: Equatable, Sendable {
        let queryKey: String
        let term: String
        let storefront: String
        let platform: AppPlatform
    }

    struct CommitResult: Sendable {
        let snapshot: KeywordResearchRankingObservationSnapshot
        let shouldScheduleMetadataEnrichment: Bool
    }

    static func requireTarget(
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGeneration: KeywordResearchKeywordGeneration,
        in modelContext: ModelContext
    ) throws -> Target {
        let projectID = projectGeneration.id
        var projectDescriptor = FetchDescriptor<KeywordResearchProject>(
            predicate: #Predicate { project in
                project.id == projectID
            }
        )
        projectDescriptor.fetchLimit = 1
        guard let project = try modelContext.fetch(projectDescriptor).first else {
            throw KeywordResearchProjectStoreError.projectNotFound(projectID)
        }
        guard project.incarnationID == projectGeneration.incarnationID else {
            throw KeywordResearchProjectStoreError.staleProjectRevision(projectID)
        }

        let keywordID = keywordGeneration.id
        var keywordDescriptor = FetchDescriptor<KeywordResearchKeyword>(
            predicate: #Predicate { keyword in
                keyword.id == keywordID
            }
        )
        keywordDescriptor.fetchLimit = 1
        guard let keyword = try modelContext.fetch(keywordDescriptor).first else {
            throw KeywordResearchProjectStoreError.keywordNotFound(keywordID)
        }
        guard keyword.incarnationID == keywordGeneration.incarnationID else {
            throw KeywordResearchProjectStoreError.staleKeywordRevision(keywordID)
        }
        guard keyword.projectID == project.id else {
            throw KeywordResearchProjectStoreError.keywordNotFound(keywordID)
        }

        return Target(
            queryKey: keyword.queryKey,
            term: keyword.term,
            storefront: keyword.storefront,
            platform: keyword.platform
        )
    }

    static func requireQuery(
        for target: Target,
        in modelContext: ModelContext
    ) throws -> KeywordQuery {
        let queryKey = target.queryKey
        var descriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == queryKey
            }
        )
        descriptor.fetchLimit = 1
        guard let query = try modelContext.fetch(descriptor).first,
              query.term == target.term,
              query.storefront == target.storefront,
              query.platform == target.platform
        else {
            throw OpenASOError.unexpectedResponse
        }
        return query
    }

    static func snapshot(
        _ observation: KeywordRankingCrawl,
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGeneration: KeywordResearchKeywordGeneration
    ) -> KeywordResearchRankingObservationSnapshot {
        let items = observation.items
            .map {
                KeywordResearchRankingItemSnapshot(
                    id: $0.itemKey,
                    position: $0.position,
                    appStoreID: $0.appStoreID,
                    bundleID: $0.bundleID,
                    name: $0.name,
                    subtitle: $0.subtitle,
                    sellerName: $0.sellerName
                )
            }
            .sorted {
                if $0.position != $1.position {
                    return $0.position < $1.position
                }
                if $0.appStoreID != $1.appStoreID {
                    return $0.appStoreID < $1.appStoreID
                }
                return $0.id < $1.id
            }
        return KeywordResearchRankingObservationSnapshot(
            id: observation.observationKey,
            projectGeneration: projectGeneration,
            keywordGeneration: keywordGeneration,
            queryKey: observation.queryKey,
            term: observation.keyword,
            storefront: observation.storefront,
            platform: observation.platform,
            observedAt: observation.observedAt,
            observedHour: observation.observedHour,
            source: observation.source,
            resultCount: observation.resultCount,
            submissionCount: observation.submissionCount,
            winningCount: observation.winningCount,
            confidence: observation.confidenceRaw,
            items: items
        )
    }
}
