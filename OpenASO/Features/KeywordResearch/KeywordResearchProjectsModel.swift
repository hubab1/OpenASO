import Foundation
import Observation

struct KeywordResearchProjectsDependencies: Sendable {
    let loadPage: @Sendable (
        _ offset: Int,
        _ limit: Int
    ) async throws -> KeywordResearchProjectPresentationPage
    let createProject: @Sendable (
        _ draft: KeywordResearchProjectDraft
    ) async throws -> KeywordResearchProjectSnapshot
    let updateProject: @Sendable (
        _ revision: KeywordResearchProjectRevision,
        _ draft: KeywordResearchProjectDraft
    ) async throws -> KeywordResearchProjectSnapshot
    let deleteProject: @Sendable (
        _ revision: KeywordResearchProjectRevision
    ) async throws -> Void
}

@Observable
@MainActor
final class KeywordResearchProjectsModel {
    private(set) var projects: [KeywordResearchProjectSnapshot] = []
    private(set) var nextOffset: Int?
    private(set) var loadState: KeywordResearchPageLoadState = .idle
    private(set) var mutationState: KeywordResearchMutationState = .idle
    private(set) var requiresReload = false

    @ObservationIgnored private let dependencies: KeywordResearchProjectsDependencies
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var activeLoadGeneration: Int?
    @ObservationIgnored private var hasLoadedInitialPage = false

    init(
        pageSize: Int = 50,
        dependencies: KeywordResearchProjectsDependencies
    ) {
        precondition(pageSize > 0)
        self.pageSize = pageSize
        self.dependencies = dependencies
    }

    var hasMoreProjects: Bool { !requiresReload && nextOffset != nil }

    func reload() async {
        guard activeLoadGeneration == nil else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        activeLoadGeneration = generation
        loadState = .loading
        defer {
            if activeLoadGeneration == generation {
                activeLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadPage(0, pageSize)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }

            projects = Self.deduplicated(page.projects)
            nextOffset = page.nextOffset
            hasLoadedInitialPage = true
            requiresReload = false
            loadState = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            loadState = projects.isEmpty ? .idle : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            guard !Task.isCancelled else {
                loadState = projects.isEmpty ? .idle : .loaded
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
        loadState = .loadingNextPage
        defer {
            if activeLoadGeneration == generation {
                activeLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadPage(offset, pageSize)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }

            projects = Self.merging(projects, with: page.projects)
            nextOffset = page.nextOffset
            loadState = .loaded
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            loadState = projects.isEmpty ? .idle : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            guard !Task.isCancelled else {
                loadState = projects.isEmpty ? .idle : .loaded
                return
            }
            loadState = .failed(.presenting(error))
        }
    }

    /// The draft owns the idempotency UUID. Retrying the same draft passes the
    /// same UUID to persistence; this model never synthesizes a replacement.
    @discardableResult
    func create(_ draft: KeywordResearchProjectDraft) async -> KeywordResearchProjectSnapshot? {
        let action = KeywordResearchMutationAction.createProject(draft.id)
        guard begin(action) else { return nil }

        do {
            try Task.checkCancellation()
            let project = try await dependencies.createProject(draft)

            // Returning from the dependency is the mutation commit point. A
            // cancellation check here could report failure after durable data.
            invalidatePendingLoad(
                markReloadRequired: activeLoadGeneration != nil || !hasLoadedInitialPage
            )
            projects = Self.upserting(project, in: projects)
            loadState = .loaded
            mutationState = .succeeded(action)
            return project
        } catch is CancellationError {
            mutationState = .idle
            return nil
        } catch {
            mutationState = Task.isCancelled
                ? .idle
                : .failed(action, .presenting(error))
            return nil
        }
    }

    @discardableResult
    func update(
        revision: KeywordResearchProjectRevision,
        with draft: KeywordResearchProjectDraft
    ) async -> KeywordResearchProjectSnapshot? {
        let action = KeywordResearchMutationAction.updateProject(revision.generation.id)
        guard begin(action) else { return nil }

        do {
            try Task.checkCancellation()
            let project = try await dependencies.updateProject(revision, draft)

            // Always thread the returned revision into the visible snapshot.
            invalidatePendingLoad(
                markReloadRequired: activeLoadGeneration != nil || !hasLoadedInitialPage
            )
            projects = Self.upserting(project, in: projects)
            mutationState = .succeeded(action)
            return project
        } catch is CancellationError {
            mutationState = .idle
            return nil
        } catch {
            mutationState = Task.isCancelled
                ? .idle
                : .failed(action, .presenting(error))
            return nil
        }
    }

    @discardableResult
    func delete(_ project: KeywordResearchProjectSnapshot) async -> Bool {
        let action = KeywordResearchMutationAction.deleteProject(project.id)
        guard begin(action) else { return false }

        do {
            try Task.checkCancellation()
            try await dependencies.deleteProject(project.revision)

            // A successful return means deletion committed. Do not turn a
            // post-commit cancellation into an error or retry the deletion.
            invalidatePendingLoad(
                markReloadRequired: activeLoadGeneration != nil || !hasLoadedInitialPage
            )
            let removedLoadedProject = projects.contains {
                $0.generation == project.generation
            }
            projects.removeAll { $0.generation == project.generation }
            if removedLoadedProject, let offset = nextOffset {
                nextOffset = max(0, offset - 1)
            }
            mutationState = .succeeded(action)
            return true
        } catch is CancellationError {
            mutationState = .idle
            return false
        } catch {
            mutationState = Task.isCancelled
                ? .idle
                : .failed(action, .presenting(error))
            return false
        }
    }

    func clearMutationResult() {
        guard !mutationState.isRunning else { return }
        mutationState = .idle
    }

    func cancelLoading() {
        guard activeLoadGeneration != nil else { return }
        invalidatePendingLoad(markReloadRequired: true)
    }

    private func begin(_ action: KeywordResearchMutationAction) -> Bool {
        guard !mutationState.isRunning else { return false }
        mutationState = .running(action)
        return true
    }

    private func invalidatePendingLoad(markReloadRequired: Bool) {
        loadGeneration &+= 1
        activeLoadGeneration = nil
        requiresReload = requiresReload || markReloadRequired
        loadState = projects.isEmpty ? .idle : .loaded
    }
}

private extension KeywordResearchProjectsModel {
    static func deduplicated(
        _ projects: [KeywordResearchProjectSnapshot]
    ) -> [KeywordResearchProjectSnapshot] {
        merging([], with: projects)
    }

    static func merging(
        _ existing: [KeywordResearchProjectSnapshot],
        with incoming: [KeywordResearchProjectSnapshot]
    ) -> [KeywordResearchProjectSnapshot] {
        incoming.reduce(existing) { result, project in
            upserting(project, in: result)
        }
    }

    static func upserting(
        _ project: KeywordResearchProjectSnapshot,
        in projects: [KeywordResearchProjectSnapshot]
    ) -> [KeywordResearchProjectSnapshot] {
        var result = projects
        if let index = result.firstIndex(where: { $0.id == project.id }) {
            result[index] = project
        } else {
            result.append(project)
        }
        return result.sorted(by: orderedBefore)
    }

    static func orderedBefore(
        _ lhs: KeywordResearchProjectSnapshot,
        _ rhs: KeywordResearchProjectSnapshot
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
