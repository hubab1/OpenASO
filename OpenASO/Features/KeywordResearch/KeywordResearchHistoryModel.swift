import Foundation
import Observation

struct KeywordResearchHistoryDependencies: Sendable {
    let loadPage: @Sendable (
        _ projectGeneration: KeywordResearchProjectGeneration,
        _ keywordGeneration: KeywordResearchKeywordGeneration,
        _ cursor: KeywordResearchRankingHistoryCursor?,
        _ limit: Int
    ) async throws -> KeywordResearchRankingHistoryPage
}

enum KeywordResearchHistoryLoadOperation: Equatable, Sendable {
    case reload
    case nextPage
}

/// Presents shared query observations for a research membership. Positions in
/// each observation belong to returned App Store results; the model does not
/// infer a rank for a pre-live project.
@Observable
@MainActor
final class KeywordResearchHistoryModel {
    private(set) var projectGeneration: KeywordResearchProjectGeneration
    private(set) var keyword: KeywordResearchKeywordSnapshot
    private(set) var observations: [KeywordResearchRankingObservationSnapshot] = []
    private(set) var nextCursor: KeywordResearchRankingHistoryCursor?
    private(set) var loadState: KeywordResearchPageLoadState = .idle
    private(set) var failedOperation: KeywordResearchHistoryLoadOperation?
    private(set) var requiresReload = false

    @ObservationIgnored private let dependencies: KeywordResearchHistoryDependencies
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var activeLoadGeneration: Int?
    @ObservationIgnored private var hasLoadedInitialPage = false

    init(
        projectGeneration: KeywordResearchProjectGeneration,
        keyword: KeywordResearchKeywordSnapshot,
        pageSize: Int = 50,
        dependencies: KeywordResearchHistoryDependencies
    ) {
        precondition(pageSize > 0)
        precondition(keyword.projectID == projectGeneration.id)
        self.projectGeneration = projectGeneration
        self.keyword = keyword
        self.pageSize = pageSize
        self.dependencies = dependencies
    }

    var hasMoreObservations: Bool { !requiresReload && nextCursor != nil }

    var accessibilitySummary: String {
        let countDescription = observations.count == 1
            ? "1 shared search observation"
            : "\(observations.count) shared search observations"
        return "\(keyword.term), \(countDescription), storefront "
            + "\(keyword.storefront.uppercased()), \(keyword.platform.displayName)"
    }

    func reload() async {
        guard activeLoadGeneration == nil else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        activeLoadGeneration = generation
        failedOperation = nil
        let targetProject = projectGeneration
        let targetKeyword = keyword.generation
        loadState = .loading
        defer {
            if activeLoadGeneration == generation {
                activeLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadPage(
                targetProject,
                targetKeyword,
                nil,
                pageSize
            )
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  projectGeneration == targetProject,
                  keyword.generation == targetKeyword
            else { return }

            observations = Self.deduplicated(page.observations)
            nextCursor = page.nextCursor
            hasLoadedInitialPage = true
            requiresReload = false
            loadState = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            failedOperation = nil
            loadState = observations.isEmpty ? .idle : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            guard !Task.isCancelled else {
                failedOperation = nil
                loadState = observations.isEmpty ? .idle : .loaded
                return
            }
            failedOperation = .reload
            loadState = .failed(.presenting(error))
        }
    }

    func loadNextPage() async {
        guard !requiresReload,
              activeLoadGeneration == nil,
              let cursor = nextCursor
        else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        activeLoadGeneration = generation
        failedOperation = nil
        let targetProject = projectGeneration
        let targetKeyword = keyword.generation
        loadState = .loadingNextPage
        defer {
            if activeLoadGeneration == generation {
                activeLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadPage(
                targetProject,
                targetKeyword,
                cursor,
                pageSize
            )
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  projectGeneration == targetProject,
                  keyword.generation == targetKeyword
            else { return }

            observations = Self.merging(observations, with: page.observations)
            nextCursor = page.nextCursor
            loadState = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            failedOperation = nil
            loadState = observations.isEmpty ? .idle : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            guard !Task.isCancelled else {
                failedOperation = nil
                loadState = observations.isEmpty ? .idle : .loaded
                return
            }
            failedOperation = .nextPage
            loadState = .failed(.presenting(error))
        }
    }

    func retryFailedLoad() async {
        if failedOperation == .nextPage, nextCursor != nil, !requiresReload {
            await loadNextPage()
        } else {
            await reload()
        }
    }

    /// Makes a just-refreshed shared observation visible without claiming a
    /// project-specific rank. The next backend reload remains authoritative.
    func record(_ observation: KeywordResearchRankingObservationSnapshot) {
        guard observation.projectGeneration == projectGeneration,
              observation.keywordGeneration == keyword.generation,
              observation.queryKey == keyword.queryKey,
              observation.term == keyword.term,
              observation.storefront == keyword.storefront,
              observation.platform == keyword.platform
        else { return }

        // An in-flight read may have started before the commit, and a newly
        // visible observation can belong before an existing continuation.
        // Keep it visible, but require an authoritative first-page reload
        // before continuing pagination from an incomplete history.
        let invalidatesCursor = activeLoadGeneration != nil
            || !hasLoadedInitialPage
            || nextCursor != nil
        if activeLoadGeneration != nil {
            invalidatePendingLoad(markReloadRequired: true)
        } else {
            requiresReload = requiresReload || invalidatesCursor
        }
        observations = Self.upserting(observation, in: observations)
        failedOperation = nil
        loadState = .loaded
    }

    func replaceMembership(
        projectGeneration: KeywordResearchProjectGeneration,
        keyword replacement: KeywordResearchKeywordSnapshot
    ) {
        guard replacement.projectID == projectGeneration.id else { return }
        let sameGeneration = self.projectGeneration == projectGeneration
            && keyword.generation == replacement.generation
        let sameQuery = keyword.queryKey == replacement.queryKey
            && keyword.term == replacement.term
            && keyword.storefront == replacement.storefront
            && keyword.platform == replacement.platform
        guard !sameGeneration || !sameQuery else {
            keyword = replacement
            return
        }

        loadGeneration &+= 1
        activeLoadGeneration = nil
        self.projectGeneration = projectGeneration
        keyword = replacement
        observations = []
        nextCursor = nil
        hasLoadedInitialPage = false
        failedOperation = nil
        requiresReload = false
        loadState = .idle
    }

    func cancelLoading() {
        guard activeLoadGeneration != nil else { return }
        invalidatePendingLoad(markReloadRequired: true)
    }

    private func invalidatePendingLoad(markReloadRequired: Bool) {
        loadGeneration &+= 1
        activeLoadGeneration = nil
        failedOperation = nil
        requiresReload = requiresReload || markReloadRequired
        loadState = observations.isEmpty ? .idle : .loaded
    }
}

private extension KeywordResearchHistoryModel {
    static func deduplicated(
        _ observations: [KeywordResearchRankingObservationSnapshot]
    ) -> [KeywordResearchRankingObservationSnapshot] {
        merging([], with: observations)
    }

    static func merging(
        _ existing: [KeywordResearchRankingObservationSnapshot],
        with incoming: [KeywordResearchRankingObservationSnapshot]
    ) -> [KeywordResearchRankingObservationSnapshot] {
        incoming.reduce(existing) { result, observation in
            upserting(observation, in: result)
        }
    }

    static func upserting(
        _ observation: KeywordResearchRankingObservationSnapshot,
        in observations: [KeywordResearchRankingObservationSnapshot]
    ) -> [KeywordResearchRankingObservationSnapshot] {
        var result = observations
        if let index = result.firstIndex(where: { $0.id == observation.id }) {
            result[index] = observation
        } else {
            result.append(observation)
        }
        return result.sorted(by: orderedBefore)
    }

    static func orderedBefore(
        _ lhs: KeywordResearchRankingObservationSnapshot,
        _ rhs: KeywordResearchRankingObservationSnapshot
    ) -> Bool {
        if lhs.observedAt != rhs.observedAt {
            return lhs.observedAt > rhs.observedAt
        }
        return lhs.id < rhs.id
    }
}
