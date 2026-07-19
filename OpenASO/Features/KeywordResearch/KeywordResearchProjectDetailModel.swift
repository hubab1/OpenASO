import Foundation
import Observation

struct KeywordResearchProjectDetailDependencies: Sendable {
    let loadKeywordsPage: @Sendable (
        _ projectGeneration: KeywordResearchProjectGeneration,
        _ offset: Int,
        _ limit: Int
    ) async throws -> KeywordResearchKeywordPresentationPage
    let updateProject: @Sendable (
        _ revision: KeywordResearchProjectRevision,
        _ draft: KeywordResearchProjectDraft
    ) async throws -> KeywordResearchProjectSnapshot
    let addKeyword: @Sendable (
        _ projectRevision: KeywordResearchProjectRevision,
        _ draft: KeywordResearchKeywordDraft
    ) async throws -> KeywordResearchKeywordAddition
    let removeKeyword: @Sendable (
        _ keywordRevision: KeywordResearchKeywordRevision,
        _ projectRevision: KeywordResearchProjectRevision
    ) async throws -> KeywordResearchProjectSnapshot
    let refreshRanking: @Sendable (
        _ projectGeneration: KeywordResearchProjectGeneration,
        _ keywordGeneration: KeywordResearchKeywordGeneration
    ) async throws -> KeywordResearchRankingObservationSnapshot
    let refreshPopularity: @Sendable (
        _ projectGeneration: KeywordResearchProjectGeneration,
        _ keywordGeneration: KeywordResearchKeywordGeneration,
        _ policy: KeywordResearchMetricsRefreshPolicy
    ) async throws -> KeywordResearchMetricsOutcome
}

@Observable
@MainActor
final class KeywordResearchProjectDetailModel {
    private(set) var project: KeywordResearchProjectSnapshot
    private(set) var keywords: [KeywordResearchKeywordSnapshot] = []
    private(set) var nextOffset: Int?
    private(set) var loadState: KeywordResearchPageLoadState = .idle
    private(set) var mutationState: KeywordResearchMutationState = .idle
    private(set) var requiresReload = false
    private(set) var rankingStates: [KeywordResearchKeywordGeneration: KeywordResearchRefreshState<
        KeywordResearchRankingObservationSnapshot
    >] = [:]
    private(set) var popularityStates: [KeywordResearchKeywordGeneration: KeywordResearchRefreshState<
        KeywordResearchMetricsOutcome
    >] = [:]

    @ObservationIgnored private let dependencies: KeywordResearchProjectDetailDependencies
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var activeLoadGeneration: Int?
    @ObservationIgnored private var hasLoadedInitialPage = false
    @ObservationIgnored private var mutationGeneration = 0
    @ObservationIgnored private var rankingGenerations: [KeywordResearchKeywordGeneration: Int] = [:]
    @ObservationIgnored private var popularityGenerations: [KeywordResearchKeywordGeneration: Int] = [:]

    init(
        project: KeywordResearchProjectSnapshot,
        pageSize: Int = 50,
        dependencies: KeywordResearchProjectDetailDependencies
    ) {
        precondition(pageSize > 0)
        self.project = project
        self.pageSize = pageSize
        self.dependencies = dependencies
    }

    var hasMoreKeywords: Bool { nextOffset != nil }

    func rankingState(
        for keywordID: UUID
    ) -> KeywordResearchRefreshState<KeywordResearchRankingObservationSnapshot> {
        guard let keyword = keywords.first(where: { $0.id == keywordID }) else {
            return .idle
        }
        return rankingState(for: keyword)
    }

    func popularityState(
        for keywordID: UUID
    ) -> KeywordResearchRefreshState<KeywordResearchMetricsOutcome> {
        guard let keyword = keywords.first(where: { $0.id == keywordID }) else {
            return .idle
        }
        return popularityState(for: keyword)
    }

    func rankingState(
        for keyword: KeywordResearchKeywordSnapshot
    ) -> KeywordResearchRefreshState<KeywordResearchRankingObservationSnapshot> {
        rankingStates[keyword.generation] ?? .idle
    }

    func popularityState(
        for keyword: KeywordResearchKeywordSnapshot
    ) -> KeywordResearchRefreshState<KeywordResearchMetricsOutcome> {
        popularityStates[keyword.generation] ?? .idle
    }

    func reload() async {
        guard activeLoadGeneration == nil else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        activeLoadGeneration = generation
        let targetProject = project.generation
        loadState = .loading
        defer {
            if activeLoadGeneration == generation {
                activeLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadKeywordsPage(targetProject, 0, pageSize)
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  project.generation == targetProject
            else { return }

            keywords = Self.deduplicated(page.keywords)
            nextOffset = page.nextOffset
            hasLoadedInitialPage = true
            requiresReload = false
            pruneRefreshStates()
            loadState = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            loadState = keywords.isEmpty ? .idle : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            guard !Task.isCancelled else {
                loadState = keywords.isEmpty ? .idle : .loaded
                return
            }
            loadState = .failed(.presenting(error))
        }
    }

    func loadNextPage() async {
        guard !requiresReload,
              activeLoadGeneration == nil,
              let offset = nextOffset
        else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        activeLoadGeneration = generation
        let targetProject = project.generation
        loadState = .loadingNextPage
        defer {
            if activeLoadGeneration == generation {
                activeLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadKeywordsPage(
                targetProject,
                offset,
                pageSize
            )
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  project.generation == targetProject
            else { return }

            keywords = Self.merging(keywords, with: page.keywords)
            nextOffset = page.nextOffset
            loadState = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            loadState = keywords.isEmpty ? .idle : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            guard !Task.isCancelled else {
                loadState = keywords.isEmpty ? .idle : .loaded
                return
            }
            loadState = .failed(.presenting(error))
        }
    }

    @discardableResult
    func updateProject(
        with draft: KeywordResearchProjectDraft
    ) async -> KeywordResearchProjectSnapshot? {
        let targetRevision = project.revision
        let action = KeywordResearchMutationAction.updateProject(project.id)
        guard let mutationGeneration = begin(action) else { return nil }

        do {
            try Task.checkCancellation()
            let updated = try await dependencies.updateProject(targetRevision, draft)

            // The returned snapshot is authoritative, including its advanced
            // revision. Do not check cancellation after this commit point.
            guard mutationGeneration == self.mutationGeneration,
                  project.generation == targetRevision.generation
            else { return updated }
            guard updated.generation == targetRevision.generation else {
                mutationState = .failed(
                    action,
                    .presenting(KeywordResearchProjectStoreError.staleProjectRevision(project.id))
                )
                return nil
            }
            project = updated
            mutationState = .succeeded(action)
            return updated
        } catch is CancellationError {
            if mutationGeneration == self.mutationGeneration {
                mutationState = .idle
            }
            return nil
        } catch {
            if mutationGeneration == self.mutationGeneration {
                mutationState = Task.isCancelled
                    ? .idle
                    : .failed(action, .presenting(error))
            }
            return nil
        }
    }

    /// The draft UUID is passed through unchanged and can be reused after an
    /// indeterminate transport failure without creating a second membership.
    @discardableResult
    func addKeyword(
        _ draft: KeywordResearchKeywordDraft
    ) async -> KeywordResearchKeywordSnapshot? {
        let targetRevision = project.revision
        let action = KeywordResearchMutationAction.addKeyword(draft.id)
        guard let mutationGeneration = begin(action) else { return nil }

        do {
            try Task.checkCancellation()
            let addition = try await dependencies.addKeyword(targetRevision, draft)

            // A successful dependency return is committed. Publish it even if
            // cancellation arrived while the persistence actor returned.
            guard mutationGeneration == self.mutationGeneration,
                  project.generation == targetRevision.generation
            else { return addition.keyword }
            guard addition.project.generation == targetRevision.generation,
                  addition.keyword.projectID == targetRevision.generation.id
            else {
                mutationState = .failed(
                    action,
                    .presenting(KeywordResearchProjectStoreError.staleProjectRevision(project.id))
                )
                return nil
            }
            invalidatePendingLoad(
                markReloadRequired: activeLoadGeneration != nil || !hasLoadedInitialPage
            )
            project = addition.project
            keywords = Self.upserting(addition.keyword, in: keywords)
            loadState = .loaded
            mutationState = .succeeded(action)
            return addition.keyword
        } catch is CancellationError {
            if mutationGeneration == self.mutationGeneration {
                mutationState = .idle
            }
            return nil
        } catch {
            if mutationGeneration == self.mutationGeneration {
                mutationState = Task.isCancelled
                    ? .idle
                    : .failed(action, .presenting(error))
            }
            return nil
        }
    }

    @discardableResult
    func removeKeyword(_ keyword: KeywordResearchKeywordSnapshot) async -> Bool {
        guard keyword.projectID == project.id else { return false }
        let targetRevision = project.revision
        let action = KeywordResearchMutationAction.removeKeyword(keyword.id)
        guard let mutationGeneration = begin(action) else { return false }

        do {
            try Task.checkCancellation()
            let updatedProject = try await dependencies.removeKeyword(
                keyword.revision,
                targetRevision
            )

            // Deletion has committed on successful return. It is never
            // automatically retried, including after a revision conflict.
            guard mutationGeneration == self.mutationGeneration,
                  project.generation == targetRevision.generation
            else { return true }
            guard updatedProject.generation == targetRevision.generation else {
                mutationState = .failed(
                    action,
                    .presenting(KeywordResearchProjectStoreError.staleProjectRevision(project.id))
                )
                return false
            }
            invalidatePendingLoad(
                markReloadRequired: activeLoadGeneration != nil || !hasLoadedInitialPage
            )
            let removedLoadedKeyword = keywords.contains {
                $0.generation == keyword.generation
            }
            project = updatedProject
            keywords.removeAll { $0.generation == keyword.generation }
            if removedLoadedKeyword, let offset = nextOffset {
                nextOffset = max(0, offset - 1)
            }
            invalidateRefreshes(for: keyword.generation)
            mutationState = .succeeded(action)
            return true
        } catch is CancellationError {
            if mutationGeneration == self.mutationGeneration {
                mutationState = .idle
            }
            return false
        } catch {
            if mutationGeneration == self.mutationGeneration {
                mutationState = Task.isCancelled
                    ? .idle
                    : .failed(action, .presenting(error))
            }
            return false
        }
    }

    func refreshRanking(for keyword: KeywordResearchKeywordSnapshot) async {
        guard contains(keyword), !rankingState(for: keyword).isRefreshing else { return }

        let targetProject = project.generation
        let targetKeyword = keyword.generation
        let generation = nextRankingGeneration(for: targetKeyword)
        let previous = rankingState(for: keyword).value
        rankingStates[targetKeyword] = .refreshing(previous: previous)

        do {
            try Task.checkCancellation()
            let observation = try await dependencies.refreshRanking(
                targetProject,
                targetKeyword
            )
            guard rankingGenerations[targetKeyword] == generation,
                  project.generation == targetProject,
                  contains(targetKeyword)
            else { return }
            rankingStates[targetKeyword] = .current(observation)
        } catch is CancellationError {
            guard rankingGenerations[targetKeyword] == generation else { return }
            rankingStates[targetKeyword] = previous.map { .current($0) } ?? .idle
        } catch {
            guard rankingGenerations[targetKeyword] == generation else { return }
            rankingStates[targetKeyword] = Task.isCancelled
                ? (previous.map { .current($0) } ?? .idle)
                : .failed(previous: previous, .presenting(error))
        }
    }

    func refreshPopularity(
        for keyword: KeywordResearchKeywordSnapshot,
        policy: KeywordResearchMetricsRefreshPolicy = .useFreshCache
    ) async {
        guard contains(keyword), !popularityState(for: keyword).isRefreshing else { return }

        let targetProject = project.generation
        let targetKeyword = keyword.generation
        let generation = nextPopularityGeneration(for: targetKeyword)
        let previous = popularityState(for: keyword).value
        popularityStates[targetKeyword] = .refreshing(previous: previous)

        do {
            try Task.checkCancellation()
            let outcome = try await dependencies.refreshPopularity(
                targetProject,
                targetKeyword,
                policy
            )
            guard popularityGenerations[targetKeyword] == generation,
                  project.generation == targetProject,
                  contains(targetKeyword)
            else { return }

            popularityStates[targetKeyword] = .current(outcome)
        } catch is CancellationError {
            guard popularityGenerations[targetKeyword] == generation else { return }
            popularityStates[targetKeyword] = previous.map { .current($0) } ?? .idle
        } catch {
            guard popularityGenerations[targetKeyword] == generation else { return }
            popularityStates[targetKeyword] = Task.isCancelled
                ? (previous.map { .current($0) } ?? .idle)
                : .failed(previous: previous, .presenting(error))
        }
    }

    func replaceProject(_ replacement: KeywordResearchProjectSnapshot) {
        if replacement.generation == project.generation {
            if replacement != project {
                loadGeneration &+= 1
                activeLoadGeneration = nil
                requiresReload = true
                loadState = keywords.isEmpty ? .idle : .loaded
                mutationGeneration &+= 1
                mutationState = .idle
            }
            project = replacement
            return
        }

        project = replacement
        loadGeneration &+= 1
        activeLoadGeneration = nil
        loadState = .idle
        keywords = []
        nextOffset = nil
        hasLoadedInitialPage = false
        requiresReload = false
        rankingStates = [:]
        popularityStates = [:]
        rankingGenerations = [:]
        popularityGenerations = [:]
        mutationGeneration &+= 1
        mutationState = .idle
    }

    func clearMutationResult() {
        guard !mutationState.isRunning else { return }
        mutationState = .idle
    }

    func cancelLoading() {
        guard activeLoadGeneration != nil else { return }
        invalidatePendingLoad(markReloadRequired: true)
    }

    private func begin(_ action: KeywordResearchMutationAction) -> Int? {
        guard !mutationState.isRunning else { return nil }
        mutationGeneration &+= 1
        mutationState = .running(action)
        return mutationGeneration
    }

    private func invalidatePendingLoad(markReloadRequired: Bool) {
        loadGeneration &+= 1
        activeLoadGeneration = nil
        requiresReload = requiresReload || markReloadRequired
        loadState = keywords.isEmpty ? .idle : .loaded
    }

    private func contains(_ keyword: KeywordResearchKeywordSnapshot) -> Bool {
        contains(keyword.generation)
    }

    private func contains(_ generation: KeywordResearchKeywordGeneration) -> Bool {
        keywords.contains { $0.generation == generation }
    }

    private func nextRankingGeneration(
        for keywordGeneration: KeywordResearchKeywordGeneration
    ) -> Int {
        let next = (rankingGenerations[keywordGeneration] ?? 0) &+ 1
        rankingGenerations[keywordGeneration] = next
        return next
    }

    private func nextPopularityGeneration(
        for keywordGeneration: KeywordResearchKeywordGeneration
    ) -> Int {
        let next = (popularityGenerations[keywordGeneration] ?? 0) &+ 1
        popularityGenerations[keywordGeneration] = next
        return next
    }

    private func invalidateRefreshes(
        for keywordGeneration: KeywordResearchKeywordGeneration
    ) {
        rankingGenerations[keywordGeneration] =
            (rankingGenerations[keywordGeneration] ?? 0) &+ 1
        popularityGenerations[keywordGeneration] =
            (popularityGenerations[keywordGeneration] ?? 0) &+ 1
        rankingStates[keywordGeneration] = nil
        popularityStates[keywordGeneration] = nil
    }

    private func pruneRefreshStates() {
        let generations = Set(keywords.map(\.generation))
        rankingStates = rankingStates.filter { generations.contains($0.key) }
        popularityStates = popularityStates.filter { generations.contains($0.key) }
        rankingGenerations = rankingGenerations.filter { generations.contains($0.key) }
        popularityGenerations = popularityGenerations.filter { generations.contains($0.key) }
    }
}

private extension KeywordResearchProjectDetailModel {
    static func deduplicated(
        _ keywords: [KeywordResearchKeywordSnapshot]
    ) -> [KeywordResearchKeywordSnapshot] {
        merging([], with: keywords)
    }

    static func merging(
        _ existing: [KeywordResearchKeywordSnapshot],
        with incoming: [KeywordResearchKeywordSnapshot]
    ) -> [KeywordResearchKeywordSnapshot] {
        incoming.reduce(existing) { result, keyword in
            upserting(keyword, in: result)
        }
    }

    static func upserting(
        _ keyword: KeywordResearchKeywordSnapshot,
        in keywords: [KeywordResearchKeywordSnapshot]
    ) -> [KeywordResearchKeywordSnapshot] {
        var result = keywords
        if let index = result.firstIndex(where: { $0.id == keyword.id }) {
            result[index] = keyword
        } else {
            result.append(keyword)
        }
        return result.sorted(by: orderedBefore)
    }

    static func orderedBefore(
        _ lhs: KeywordResearchKeywordSnapshot,
        _ rhs: KeywordResearchKeywordSnapshot
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
