import Foundation
import Observation

struct KeywordResearchCopyTargetGeneration: Equatable, Hashable, Sendable {
    let persistentIdentifierToken: Data
    let appStoreID: Int64
    let createdAt: Date

    init(_ target: KeywordResearchCopyTargetSnapshot) {
        self.persistentIdentifierToken = target.persistentIdentifierToken
        self.appStoreID = target.appStoreID
        self.createdAt = target.createdAt
    }
}

struct KeywordResearchPostCopyRefreshPlan: Equatable, Sendable {
    let target: KeywordResearchCopyTargetSnapshot
    let trackIdentityKeys: [String]
    let storefronts: [String]

    init?(
        preview: KeywordResearchProjectCopyPreview,
        result: KeywordResearchProjectCopyResult
    ) {
        guard result.target.generation == preview.target.generation else { return nil }
        let requestedIdentityKeys = Set(result.trackIdentityKeys)
        let previewIdentityKeys = Set(preview.trackIdentityKeys)
        guard !requestedIdentityKeys.isEmpty,
              requestedIdentityKeys.isSubset(of: previewIdentityKeys)
        else { return nil }

        target = result.target
        trackIdentityKeys = result.trackIdentityKeys
        storefronts = Array(Set(preview.items.compactMap { item in
            requestedIdentityKeys.contains(item.trackIdentityKey)
                ? item.keyword.storefront
                : nil
        })).sorted()
    }
}

struct KeywordResearchPostCopyRefreshSummary: Equatable, Sendable {
    let requestedTrackCount: Int
    let completedTrackCount: Int
    let failedTrackCount: Int
    let issue: KeywordResearchErrorPresentation?

    var succeededTrackCount: Int {
        max(0, completedTrackCount - failedTrackCount)
    }

    var isFullySuccessful: Bool {
        completedTrackCount == requestedTrackCount
            && failedTrackCount == 0
            && issue == nil
    }
}

struct KeywordResearchProjectCopyDependencies: Sendable {
    let loadTargetsPage: @Sendable (
        _ offset: Int,
        _ limit: Int
    ) async throws -> KeywordResearchPage<KeywordResearchCopyTargetSnapshot>
    let loadAuthoritativeProject: @Sendable (
        _ generation: KeywordResearchProjectGeneration
    ) async throws -> KeywordResearchProjectSnapshot
    let preview: @Sendable (
        _ projectRevision: KeywordResearchProjectRevision,
        _ targetAppStoreID: Int64
    ) async throws -> KeywordResearchProjectCopyPreview
    let copy: @Sendable (
        _ preview: KeywordResearchProjectCopyPreview
    ) async throws -> KeywordResearchProjectCopyResult
    let refreshCopiedKeywords: @MainActor @Sendable (
        _ plan: KeywordResearchPostCopyRefreshPlan
    ) async throws -> KeywordResearchPostCopyRefreshSummary
}

enum KeywordResearchCopyTargetLoadOperation: Equatable, Sendable {
    case reload
    case nextPage
}

enum KeywordResearchProjectCopyWorkflowState: Equatable, Sendable {
    case idle
    case previewing(KeywordResearchCopyTargetGeneration)
    case ready(KeywordResearchProjectCopyPreview)
    case copying(KeywordResearchProjectCopyPreview)
    case stale(
        KeywordResearchProjectCopyPreview,
        KeywordResearchErrorPresentation
    )
    case copied(
        KeywordResearchProjectCopyPreview,
        KeywordResearchProjectCopyResult
    )
    case failed(
        KeywordResearchProjectCopyPreview?,
        KeywordResearchErrorPresentation
    )

    var displayedPreview: KeywordResearchProjectCopyPreview? {
        switch self {
        case .ready(let preview), .copying(let preview), .stale(let preview, _),
             .copied(let preview, _), .failed(let preview?, _):
            return preview
        case .idle, .previewing, .failed(nil, _):
            return nil
        }
    }

    var reviewablePreview: KeywordResearchProjectCopyPreview? {
        guard case .ready(let preview) = self else { return nil }
        return preview
    }

    var result: KeywordResearchProjectCopyResult? {
        guard case .copied(_, let result) = self else { return nil }
        return result
    }

    var presentedError: KeywordResearchErrorPresentation? {
        switch self {
        case .stale(_, let error), .failed(_, let error):
            return error
        case .idle, .previewing, .ready, .copying, .copied:
            return nil
        }
    }

    var isCopying: Bool {
        if case .copying = self { return true }
        return false
    }

    var isComplete: Bool {
        if case .copied = self { return true }
        return false
    }
}

@Observable
@MainActor
final class KeywordResearchProjectCopyModel {
    private(set) var project: KeywordResearchProjectSnapshot
    private(set) var targets: [KeywordResearchCopyTargetSnapshot] = []
    private(set) var selectedTargetGeneration: KeywordResearchCopyTargetGeneration?
    private(set) var nextTargetOffset: Int?
    private(set) var targetLoadState: KeywordResearchPageLoadState = .idle
    private(set) var failedTargetLoadOperation: KeywordResearchCopyTargetLoadOperation?
    private(set) var workflowState: KeywordResearchProjectCopyWorkflowState = .idle
    private(set) var refreshState: KeywordResearchRefreshState<
        KeywordResearchPostCopyRefreshSummary
    > = .idle

    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let dependencies: KeywordResearchProjectCopyDependencies
    @ObservationIgnored private var targetLoadGeneration = 0
    @ObservationIgnored private var activeTargetLoadGeneration: Int?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0

    init(
        project: KeywordResearchProjectSnapshot,
        pageSize: Int = 50,
        dependencies: KeywordResearchProjectCopyDependencies
    ) {
        precondition(pageSize > 0)
        self.project = project
        self.pageSize = pageSize
        self.dependencies = dependencies
    }

    var selectedTarget: KeywordResearchCopyTargetSnapshot? {
        guard let selectedTargetGeneration else { return nil }
        return targets.first { $0.generation == selectedTargetGeneration }
    }

    var hasMoreTargets: Bool {
        nextTargetOffset != nil
    }

    var blocksDismissal: Bool {
        workflowState.isCopying
    }

    var canConfirmCopy: Bool {
        guard let preview = workflowState.reviewablePreview,
              preview.totalKeywordCount > 0,
              !targetLoadState.isLoading,
              selectedTargetGeneration == preview.target.generation
        else { return false }
        return true
    }

    var refreshPlan: KeywordResearchPostCopyRefreshPlan? {
        guard case .copied(let preview, let result) = workflowState else { return nil }
        return KeywordResearchPostCopyRefreshPlan(preview: preview, result: result)
    }

    func reloadTargets() async {
        guard activeTargetLoadGeneration == nil,
              !workflowState.isCopying,
              !workflowState.isComplete
        else { return }

        targetLoadGeneration &+= 1
        let generation = targetLoadGeneration
        activeTargetLoadGeneration = generation
        targetLoadState = .loading
        failedTargetLoadOperation = nil
        defer {
            if activeTargetLoadGeneration == generation {
                activeTargetLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadTargetsPage(0, pageSize)
            try Task.checkCancellation()
            guard generation == targetLoadGeneration else { return }

            let reloadedTargets = Self.deduplicated(page.items)
            targets = reloadedTargets
            nextTargetOffset = page.nextOffset
            targetLoadState = .loaded
            reconcileSelection()
        } catch is CancellationError {
            guard generation == targetLoadGeneration else { return }
            targetLoadState = targets.isEmpty ? .idle : .loaded
        } catch {
            guard generation == targetLoadGeneration else { return }
            guard !Task.isCancelled else {
                targetLoadState = targets.isEmpty ? .idle : .loaded
                return
            }
            failedTargetLoadOperation = .reload
            targetLoadState = .failed(.presentingCopyWorkflow(error))
        }
    }

    func loadNextTargetsPage() async {
        guard activeTargetLoadGeneration == nil,
              !workflowState.isCopying,
              !workflowState.isComplete,
              let offset = nextTargetOffset
        else { return }

        targetLoadGeneration &+= 1
        let generation = targetLoadGeneration
        activeTargetLoadGeneration = generation
        targetLoadState = .loadingNextPage
        failedTargetLoadOperation = nil
        defer {
            if activeTargetLoadGeneration == generation {
                activeTargetLoadGeneration = nil
            }
        }

        do {
            let page = try await dependencies.loadTargetsPage(offset, pageSize)
            try Task.checkCancellation()
            guard generation == targetLoadGeneration else { return }

            targets = Self.merging(targets, with: page.items)
            nextTargetOffset = page.nextOffset
            targetLoadState = .loaded
            reconcileSelection()
        } catch is CancellationError {
            guard generation == targetLoadGeneration else { return }
            targetLoadState = targets.isEmpty ? .idle : .loaded
        } catch {
            guard generation == targetLoadGeneration else { return }
            guard !Task.isCancelled else {
                targetLoadState = targets.isEmpty ? .idle : .loaded
                return
            }
            failedTargetLoadOperation = .nextPage
            targetLoadState = .failed(.presentingCopyWorkflow(error))
        }
    }

    func retryFailedTargetLoad() async {
        switch failedTargetLoadOperation {
        case .reload:
            await reloadTargets()
        case .nextPage:
            await loadNextTargetsPage()
        case nil:
            break
        }
    }

    func selectTarget(_ generation: KeywordResearchCopyTargetGeneration?) {
        guard !workflowState.isCopying, !workflowState.isComplete else { return }
        guard generation == nil || targets.contains(where: { $0.generation == generation }) else {
            return
        }
        guard selectedTargetGeneration != generation else { return }

        previewGeneration &+= 1
        selectedTargetGeneration = generation
        workflowState = .idle
        refreshState = .idle
    }

    func reviewSelectedTarget() async {
        guard !workflowState.isCopying,
              !workflowState.isComplete,
              let selectedTargetGeneration
        else { return }

        previewGeneration &+= 1
        let generation = previewGeneration
        let projectGeneration = project.generation
        workflowState = .previewing(selectedTargetGeneration)

        do {
            let authoritativeProject = try await dependencies.loadAuthoritativeProject(
                projectGeneration
            )
            try Task.checkCancellation()
            guard generation == previewGeneration,
                  self.selectedTargetGeneration == selectedTargetGeneration
            else { return }
            guard authoritativeProject.generation == projectGeneration else {
                throw KeywordResearchProjectStoreError.staleProjectRevision(project.id)
            }

            let preview = try await dependencies.preview(
                authoritativeProject.revision,
                selectedTargetGeneration.appStoreID
            )
            try Task.checkCancellation()
            guard generation == previewGeneration,
                  self.selectedTargetGeneration == selectedTargetGeneration
            else { return }
            guard preview.project == authoritativeProject else {
                throw KeywordResearchProjectCopyError.stalePreview
            }
            guard preview.target.generation == selectedTargetGeneration else {
                recordTarget(preview.target)
                self.selectedTargetGeneration = nil
                workflowState = .failed(
                    nil,
                    .presentingCopyWorkflow(
                        KeywordResearchProjectCopyError.staleTarget(
                            selectedTargetGeneration.appStoreID
                        )
                    )
                )
                return
            }

            project = authoritativeProject
            recordTarget(preview.target)
            workflowState = .ready(preview)
        } catch is CancellationError {
            guard generation == previewGeneration else { return }
            workflowState = .idle
        } catch {
            guard generation == previewGeneration else { return }
            if Self.targetWasRemoved(error) {
                self.selectedTargetGeneration = nil
            }
            workflowState = .failed(nil, .presentingCopyWorkflow(error))
        }
    }

    func confirmCopy() async {
        guard case .ready(let preview) = workflowState,
              preview.totalKeywordCount > 0,
              activeTargetLoadGeneration == nil,
              selectedTargetGeneration == preview.target.generation
        else { return }

        workflowState = .copying(preview)
        do {
            try Task.checkCancellation()
            let result = try await dependencies.copy(preview)

            // A successful dependency return is the persistence commit point.
            // Publish it even if cancellation arrived while the actor returned.
            workflowState = .copied(preview, result)
            refreshState = .idle
        } catch is CancellationError {
            workflowState = .ready(preview)
        } catch {
            let presentation = KeywordResearchErrorPresentation.presentingCopyWorkflow(error)
            if Self.previewBecameStale(error) {
                workflowState = .stale(preview, presentation)
            } else if Self.targetWasRemoved(error) {
                targets.removeAll { $0.appStoreID == preview.target.appStoreID }
                selectedTargetGeneration = nil
                workflowState = .failed(nil, presentation)
            } else {
                workflowState = .failed(preview, presentation)
            }
        }
    }

    func refreshCopiedKeywords() async {
        guard let plan = refreshPlan, !refreshState.isRefreshing else { return }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previous = refreshState.value
        refreshState = .refreshing(previous: previous)

        do {
            try Task.checkCancellation()
            let summary = try await dependencies.refreshCopiedKeywords(plan)

            // Refresh may have persisted partial evidence. Do not erase the
            // returned result merely because cancellation arrived afterward.
            guard generation == refreshGeneration else { return }
            refreshState = .current(summary)
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            refreshState = previous.map(KeywordResearchRefreshState.current) ?? .idle
        } catch {
            guard generation == refreshGeneration else { return }
            refreshState = .failed(previous: previous, .presentingCopyWorkflow(error))
        }
    }

    func cancelTransientOperations() {
        targetLoadGeneration &+= 1
        previewGeneration &+= 1
        activeTargetLoadGeneration = nil
        if targetLoadState.isLoading {
            targetLoadState = targets.isEmpty ? .idle : .loaded
        }
        if case .previewing = workflowState {
            workflowState = .idle
        }
    }

    private func reconcileSelection() {
        guard !workflowState.isCopying, !workflowState.isComplete else { return }
        guard let selectedTargetGeneration else { return }
        guard targets.contains(where: { $0.generation == selectedTargetGeneration }) else {
            previewGeneration &+= 1
            self.selectedTargetGeneration = nil
            workflowState = .idle
            return
        }
    }

    private func recordTarget(_ target: KeywordResearchCopyTargetSnapshot) {
        if let index = targets.firstIndex(where: { $0.appStoreID == target.appStoreID }) {
            targets[index] = target
        }
    }

    private static func deduplicated(
        _ targets: [KeywordResearchCopyTargetSnapshot]
    ) -> [KeywordResearchCopyTargetSnapshot] {
        merging([], with: targets)
    }

    private static func merging(
        _ existing: [KeywordResearchCopyTargetSnapshot],
        with additions: [KeywordResearchCopyTargetSnapshot]
    ) -> [KeywordResearchCopyTargetSnapshot] {
        var merged = existing
        for target in additions {
            if let index = merged.firstIndex(where: { $0.appStoreID == target.appStoreID }) {
                merged[index] = target
            } else {
                merged.append(target)
            }
        }
        return merged
    }

    private static func previewBecameStale(_ error: Error) -> Bool {
        if let error = error as? KeywordResearchProjectCopyError {
            switch error {
            case .staleTarget, .stalePreview:
                return true
            case .invalidOffset, .invalidLimit, .targetNotFound,
                 .projectKeywordLimitExceeded, .sharedQueryNotFound,
                 .sharedQueryMismatch, .targetTrackMismatch:
                return false
            }
        }
        if let error = error as? KeywordResearchProjectStoreError,
           case .staleProjectRevision = error {
            return true
        }
        return false
    }

    private static func targetWasRemoved(_ error: Error) -> Bool {
        guard let error = error as? KeywordResearchProjectCopyError else { return false }
        if case .targetNotFound = error { return true }
        return false
    }
}

extension KeywordResearchCopyTargetSnapshot {
    var generation: KeywordResearchCopyTargetGeneration {
        KeywordResearchCopyTargetGeneration(self)
    }

    var keywordResearchCopyAccessibilityLabel: String {
        var parts = [
            name,
            "App Store ID \(appStoreID)",
            defaultPlatform.displayName,
        ]
        if let bundleID {
            parts.append("bundle identifier \(bundleID)")
        }
        return parts.joined(separator: ", ")
    }
}

struct KeywordResearchCopyBundleAdvisory: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case match
        case warning
        case unavailable
    }

    let kind: Kind
    let title: String
    let message: String
    let systemImage: String

    init(_ compatibility: KeywordResearchBundleCompatibility) {
        switch compatibility {
        case .matches:
            kind = .match
            title = "Bundle identifiers match"
            message = "The research project and tracked app identify the same bundle."
            systemImage = "checkmark.circle"
        case .mismatch:
            kind = .warning
            title = "Bundle identifiers differ"
            message = "Copying is allowed, but verify this tracked app is the intended destination."
            systemImage = "exclamationmark.triangle"
        case .unavailable:
            kind = .unavailable
            title = "Bundle match unavailable"
            message = "One side has no bundle identifier. Verify the destination before copying."
            systemImage = "questionmark.circle"
        }
    }
}

struct KeywordResearchCopyConfirmationPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let actionTitle: String

    init(preview: KeywordResearchProjectCopyPreview) {
        let additions = Self.count(preview.additionCount, singular: "new keyword")
        let duplicates = Self.count(preview.duplicateCount, singular: "existing keyword")
        title = "Copy \(additions) to \(preview.target.name)?"
        message = "\(duplicates) will remain unchanged. The research project stays separate "
            + "and future edits will not synchronize automatically."
        actionTitle = preview.bundleCompatibility == .mismatch ? "Copy Anyway" : "Copy Keywords"
    }

    private static func count(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}

extension KeywordResearchErrorPresentation {
    static func presentingCopyWorkflow(_ error: Error) -> Self {
        if let error = error as? KeywordResearchProjectCopyError {
            switch error {
            case .invalidOffset, .invalidLimit:
                return Self(
                    kind: .unexpected,
                    title: "Tracked apps unavailable",
                    message: "This page of tracked apps could not be loaded.",
                    recoverySuggestion: "Reload the destination list."
                )
            case .targetNotFound:
                return Self(
                    kind: .notFound,
                    title: "Tracked app unavailable",
                    message: "The selected destination no longer exists.",
                    recoverySuggestion: "Reload the destination list and choose again."
                )
            case .staleTarget, .stalePreview:
                return Self(
                    kind: .conflict,
                    title: "Copy preview changed",
                    message: "The project or tracked app changed after this preview was created.",
                    recoverySuggestion: "Refresh the preview and review the new counts before copying."
                )
            case .projectKeywordLimitExceeded(let maximum):
                return Self(
                    kind: .limitReached,
                    title: "Project is too large",
                    message: "Copy supports at most \(maximum) project keywords.",
                    recoverySuggestion: "Remove project keywords before trying again."
                )
            case .sharedQueryNotFound, .sharedQueryMismatch, .targetTrackMismatch:
                return Self(
                    kind: .conflict,
                    title: "Keyword data changed",
                    message: "The shared keyword data no longer matches this copy preview.",
                    recoverySuggestion: "Reload the research workspace before trying again."
                )
            }
        }
        return presenting(error)
    }
}
