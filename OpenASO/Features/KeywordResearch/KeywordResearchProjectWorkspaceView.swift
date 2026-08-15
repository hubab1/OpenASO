import SwiftUI

struct KeywordResearchProjectWorkspaceView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings

    let project: KeywordResearchProjectSnapshot
    let storefronts: [BundledStorefront]
    let reconcileProject: @MainActor (KeywordResearchProjectSnapshot) -> Bool
    let resolveAuthoritativeProject: @MainActor (
        KeywordResearchProjectGeneration
    ) async throws -> KeywordResearchProjectSnapshot
    let makeHistoryModel: @MainActor (
        KeywordResearchProjectGeneration,
        KeywordResearchKeywordSnapshot
    ) -> KeywordResearchHistoryModel
    let makeCopyModel: @MainActor (
        KeywordResearchProjectSnapshot
    ) -> KeywordResearchProjectCopyModel

    @Binding private var blocksWorkspaceDismissal: Bool
    @State private var model: KeywordResearchProjectDetailModel
    @State private var selectedKeywordGeneration: KeywordResearchKeywordGeneration?
    @State private var editorContext: KeywordEditorContext?
    @State private var historyContext: KeywordResearchHistoryContext?
    @State private var copyContext: KeywordResearchCopyContext?
    @State private var keywordPendingRemoval: KeywordResearchKeywordSnapshot?
    @State private var removingKeywordGeneration: KeywordResearchKeywordGeneration?
    @State private var operationError: KeywordResearchErrorPresentation?

    init(
        project: KeywordResearchProjectSnapshot,
        model: KeywordResearchProjectDetailModel,
        storefronts: [BundledStorefront],
        blocksWorkspaceDismissal: Binding<Bool>,
        reconcileProject: @escaping @MainActor (KeywordResearchProjectSnapshot) -> Bool,
        resolveAuthoritativeProject: @escaping @MainActor (
            KeywordResearchProjectGeneration
        ) async throws -> KeywordResearchProjectSnapshot,
        makeHistoryModel: @escaping @MainActor (
            KeywordResearchProjectGeneration,
            KeywordResearchKeywordSnapshot
        ) -> KeywordResearchHistoryModel,
        makeCopyModel: @escaping @MainActor (
            KeywordResearchProjectSnapshot
        ) -> KeywordResearchProjectCopyModel
    ) {
        self.project = project
        self.storefronts = storefronts
        self.reconcileProject = reconcileProject
        self.resolveAuthoritativeProject = resolveAuthoritativeProject
        self.makeHistoryModel = makeHistoryModel
        self.makeCopyModel = makeCopyModel
        _blocksWorkspaceDismissal = blocksWorkspaceDismissal
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            keywordContent
        }
        .task {
            await reloadKeywords()
        }
        .onDisappear {
            model.cancelLoading()
        }
        .onChange(of: project) { _, replacement in
            model.replaceProject(replacement)
            if model.requiresReload {
                Task { await reloadKeywords() }
            }
        }
        .onChange(of: model.keywords) {
            reconcileKeywordSelection()
        }
        .sheet(item: $editorContext) { context in
            KeywordResearchKeywordEditorSheet(
                context: context,
                storefronts: storefronts,
                save: saveKeyword
            )
        }
        .sheet(item: $historyContext) { context in
            KeywordResearchHistorySheet(
                model: makeHistoryModel(
                    context.projectGeneration,
                    context.keyword
                )
            )
            .id(context.id)
        }
        .sheet(item: $copyContext) { context in
            KeywordResearchProjectCopySheet(
                model: makeCopyModel(context.project),
                blocksWorkspaceDismissal: $blocksWorkspaceDismissal,
                reconcileProject: reconcileProject
            )
            .id(context.id)
        }
        .confirmationDialog(
            "Remove research keyword?",
            isPresented: Binding(
                get: { keywordPendingRemoval != nil },
                set: { if !$0 { keywordPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let keywordPendingRemoval {
                Button("Remove \(keywordPendingRemoval.term)", role: .destructive) {
                    removeKeyword(keywordPendingRemoval)
                }
            }
        } message: {
            Text(
                "This removes the keyword from this project. Shared search and popularity "
                    + "evidence used by other memberships is retained."
            )
        }
        .alert(item: $operationError) { error in
            Alert(
                title: Text(error.title),
                message: Text([
                    error.message,
                    error.recoverySuggestion,
                ].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK")) {
                    model.clearMutationResult()
                }
            )
        }
    }

    private var selectedKeyword: KeywordResearchKeywordSnapshot? {
        guard let selectedKeywordGeneration else { return nil }
        return model.keywords.first { $0.generation == selectedKeywordGeneration }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(
                        "\(project.defaultStorefront.uppercased()) · "
                            + project.defaultPlatform.displayName
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if removingKeywordGeneration != nil {
                    ProgressView("Removing Keyword…")
                        .controlSize(.small)
                }

                Button("Copy to Tracked App…", systemImage: "doc.on.doc") {
                    editorContext = nil
                    historyContext = nil
                    copyContext = KeywordResearchCopyContext(project: model.project)
                }
                .help("Copy this project's exact keyword scope to a tracked app")
                .disabled(model.mutationState.isRunning)

                Button("Reload Keywords", systemImage: "arrow.clockwise") {
                    Task { await reloadKeywords() }
                }
                .labelStyle(.iconOnly)
                .help("Reload Keywords")
                .disabled(model.loadState.isLoading || model.mutationState.isRunning)

                Button("Add Research Keyword", systemImage: "plus") {
                    editorContext = .create(for: model.project)
                }
                .labelStyle(.iconOnly)
                .help("Add Research Keyword")
                .disabled(model.mutationState.isRunning)
            }

            if !project.notes.isEmpty {
                Text(project.notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(project.notes)
            }

            Text(
                "Search evidence is shared by exact keyword, storefront, and platform. "
                    + "It does not claim that this pre-live project has an App Store position."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.keywordResearchAccessibilityLabel)
    }

    @ViewBuilder
    private var keywordContent: some View {
        if model.keywords.isEmpty {
            emptyKeywordState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                List(selection: $selectedKeywordGeneration) {
                    ForEach(model.keywords) { keyword in
                        KeywordResearchKeywordRow(
                            keyword: keyword,
                            rankingState: model.rankingState(for: keyword),
                            popularityState: model.popularityState(for: keyword),
                            mutationIsRunning: model.mutationState.isRunning,
                            refreshSearchEvidence: {
                                Task { @MainActor [model] in
                                    await model.refreshRanking(for: keyword)
                                }
                            },
                            refreshPopularity: { policy in
                                Task { @MainActor [model] in
                                    await model.refreshPopularity(
                                        for: keyword,
                                        policy: policy
                                    )
                                }
                            },
                            openSettings: {
                                services.settingsStore.requestSettingsFocus(.platformAPI)
                                openSettings()
                            },
                            showHistory: {
                                historyContext = KeywordResearchHistoryContext(
                                    projectGeneration: model.project.generation,
                                    keyword: keyword
                                )
                            },
                            remove: {
                                keywordPendingRemoval = keyword
                            }
                        )
                        .tag(keyword.generation)
                    }
                }

                keywordListFooter
            }
        }
    }

    @ViewBuilder
    private var emptyKeywordState: some View {
        switch model.loadState {
        case .loading:
            ProgressView("Loading research keywords…")
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") {
                    Task { await reloadKeywords() }
                }
            }
            .accessibilityLabel(error.accessibilityLabel)
        case .idle, .loaded, .loadingNextPage:
            ContentUnavailableView {
                Label("No Research Keywords", systemImage: "text.magnifyingglass")
            } description: {
                Text("Add a keyword to collect shared search and popularity evidence.")
            } actions: {
                Button("Add Keyword") {
                    editorContext = .create(for: model.project)
                }
            }
        }
    }

    @ViewBuilder
    private var keywordListFooter: some View {
        if model.requiresReload {
            KeywordResearchStatusRow(
                title: "Keywords changed",
                message: "Reload before continuing to the next page.",
                systemImage: "arrow.clockwise",
                actionTitle: "Reload"
            ) {
                Task { await reloadKeywords() }
            }
        } else if case .failed(let error) = model.loadState {
            KeywordResearchStatusRow(
                title: error.title,
                message: error.message,
                systemImage: "exclamationmark.triangle",
                actionTitle: "Try Again"
            ) {
                Task { await reloadKeywords() }
            }
            .accessibilityLabel(error.accessibilityLabel)
        } else if model.loadState == .loadingNextPage {
            ProgressView("Loading more…")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(10)
        } else if model.hasMoreKeywords {
            Button("Load More") {
                Task { await model.loadNextPage() }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
        }
    }

    private func saveKeyword(
        context: KeywordEditorContext,
        draft: KeywordResearchKeywordDraft
    ) async -> KeywordEditorOutcome {
        guard context.projectGeneration == model.project.generation else {
            return KeywordEditorOutcome(
                keyword: nil,
                error: .presenting(
                    KeywordResearchProjectStoreError.staleProjectRevision(model.project.id)
                )
            )
        }

        let projectGeneration = model.project.generation
        guard let keyword = await model.addKeyword(draft) else {
            return KeywordEditorOutcome(
                keyword: nil,
                error: mutationError
            )
        }

        selectedKeywordGeneration = keyword.generation
        let published = KeywordResearchKeywordMutationPublication.additionWasPublished(
            state: model.mutationState,
            draftID: draft.id,
            keyword: keyword,
            keywords: model.keywords
        )
        if published, reconcileProject(model.project) {
            if model.requiresReload {
                await reloadKeywords()
            }
        } else {
            await recoverAfterCommittedMutation(projectGeneration: projectGeneration)
        }
        return KeywordEditorOutcome(keyword: keyword, error: nil)
    }

    private func removeKeyword(_ keyword: KeywordResearchKeywordSnapshot) {
        keywordPendingRemoval = nil
        removingKeywordGeneration = keyword.generation
        blocksWorkspaceDismissal = true
        operationError = nil
        Task {
            defer {
                removingKeywordGeneration = nil
                blocksWorkspaceDismissal = false
            }
            let projectGeneration = model.project.generation
            guard await model.removeKeyword(keyword) else {
                operationError = mutationError
                    ?? .presenting(OpenASOError.unexpectedResponse)
                return
            }
            if selectedKeywordGeneration == keyword.generation {
                selectedKeywordGeneration = nil
            }

            let published = KeywordResearchKeywordMutationPublication.removalWasPublished(
                state: model.mutationState,
                keyword: keyword,
                keywords: model.keywords
            )
            if published, reconcileProject(model.project) {
                if model.requiresReload {
                    await reloadKeywords()
                }
            } else {
                await recoverAfterCommittedMutation(projectGeneration: projectGeneration)
            }
            reconcileKeywordSelection()
        }
    }

    private var mutationError: KeywordResearchErrorPresentation? {
        guard case .failed(_, let error) = model.mutationState else { return nil }
        return error
    }

    private func reloadKeywords() async {
        await model.reload()
        reconcileKeywordSelection()
    }

    private func recoverAfterCommittedMutation(
        projectGeneration: KeywordResearchProjectGeneration
    ) async {
        do {
            let authoritativeProject = try await resolveAuthoritativeProject(
                projectGeneration
            )
            model.cancelLoading()
            model.replaceProject(authoritativeProject)
            await reloadKeywords()
        } catch {
            operationError = KeywordResearchErrorPresentation(
                kind: .conflict,
                title: "Keyword saved; reload needed",
                message: "The keyword change was saved, but the workspace could not reload "
                    + "the committed project state.",
                recoverySuggestion: "Reload the research workspace before making another change."
            )
        }
    }

    private func reconcileKeywordSelection() {
        selectedKeywordGeneration = KeywordResearchKeywordSelection.reconciled(
            selectedKeywordGeneration,
            keywords: model.keywords
        )
    }
}

enum KeywordResearchKeywordSelection {
    static func reconciled(
        _ selection: KeywordResearchKeywordGeneration?,
        keywords: [KeywordResearchKeywordSnapshot]
    ) -> KeywordResearchKeywordGeneration? {
        guard let selection else { return keywords.first?.generation }
        return keywords.contains { $0.generation == selection } ? selection : nil
    }
}

enum KeywordResearchKeywordMutationPublication {
    static func additionWasPublished(
        state: KeywordResearchMutationState,
        draftID: UUID,
        keyword: KeywordResearchKeywordSnapshot,
        keywords: [KeywordResearchKeywordSnapshot]
    ) -> Bool {
        guard state == .succeeded(.addKeyword(draftID)) else { return false }
        return keywords.contains { $0.generation == keyword.generation }
    }

    static func removalWasPublished(
        state: KeywordResearchMutationState,
        keyword: KeywordResearchKeywordSnapshot,
        keywords: [KeywordResearchKeywordSnapshot]
    ) -> Bool {
        guard state == .succeeded(.removeKeyword(keyword.id)) else { return false }
        return !keywords.contains { $0.generation == keyword.generation }
    }
}

private struct KeywordResearchKeywordRow: View {
    let keyword: KeywordResearchKeywordSnapshot
    let rankingState: KeywordResearchRefreshState<KeywordResearchRankingObservationSnapshot>
    let popularityState: KeywordResearchRefreshState<KeywordResearchMetricsOutcome>
    let mutationIsRunning: Bool
    let refreshSearchEvidence: () -> Void
    let refreshPopularity: (KeywordResearchMetricsRefreshPolicy) -> Void
    let openSettings: () -> Void
    let showHistory: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(keyword.term)
                        .fontWeight(.medium)
                    if !keyword.notes.isEmpty {
                        Text(keyword.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(keyword.storefront.uppercased())
                    .font(.caption)
                    .fontWeight(.medium)
                Text(keyword.platform.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionsMenu
            }

            HStack(alignment: .top, spacing: 12) {
                KeywordResearchRankingStateView(state: rankingState)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                KeywordResearchPopularityStateView(state: popularityState)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var actionsMenu: some View {
        Menu {
            Button("View Shared Search History", action: showHistory)

            Divider()
            Button("Refresh Search Evidence", action: refreshSearchEvidence)
                .disabled(rankingState.isRefreshing)
            Button("Refresh Popularity") {
                refreshPopularity(.useFreshCache)
            }
            .disabled(popularityState.isRefreshing)
            Button("Refresh Popularity from Network") {
                refreshPopularity(.requireNetwork)
            }
            .disabled(popularityState.isRefreshing)

            if popularityError?.kind == .authenticationRequired {
                Divider()
                Button("Open Settings", action: openSettings)
            }

            Divider()
            Button("Remove Keyword", role: .destructive, action: remove)
                .disabled(mutationIsRunning)
        } label: {
            Label("Actions for \(keyword.term)", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .help("Keyword Actions")
    }

    private var popularityError: KeywordResearchErrorPresentation? {
        switch popularityState {
        case .failed(_, let error):
            return error
        case .current(let outcome), .refreshing(previous: let outcome?):
            return outcome.issue.map(KeywordResearchErrorPresentation.presenting)
        case .idle, .refreshing(previous: nil):
            return nil
        }
    }
}

private struct KeywordResearchRankingStateView: View {
    let state: KeywordResearchRefreshState<KeywordResearchRankingObservationSnapshot>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Search evidence", systemImage: "list.number")
                .font(.caption)
                .fontWeight(.medium)
            switch state {
            case .idle:
                secondary("Not refreshed in this session")
            case .refreshing(let previous):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(previous.map(summary) ?? "Refreshing…")
                }
            case .current(let observation):
                secondary(summary(observation))
            case .failed(let previous, let error):
                Label(error.title, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .help(error.accessibilityLabel)
                if let previous {
                    secondary(summary(previous))
                }
            }
        }
    }

    private func summary(_ observation: KeywordResearchRankingObservationSnapshot) -> String {
        "\(observation.resultCount) results · \(observation.source.displayName) · "
            + observation.observedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private struct KeywordResearchPopularityStateView: View {
    let state: KeywordResearchRefreshState<KeywordResearchMetricsOutcome>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Popularity", systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption)
                .fontWeight(.medium)
            switch state {
            case .idle:
                secondary("Not refreshed in this session")
            case .refreshing(let previous):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(previous.map(summary) ?? "Refreshing…")
                }
            case .current(let outcome):
                outcomeView(outcome)
            case .failed(let previous, let error):
                Label(error.title, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .help(error.accessibilityLabel)
                if let previous {
                    outcomeView(previous)
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeView(_ outcome: KeywordResearchMetricsOutcome) -> some View {
        secondary(summary(outcome))
        if let issue = outcome.issue {
            let error = KeywordResearchErrorPresentation.presenting(issue)
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .help(error.accessibilityLabel)
                .accessibilityLabel(error.accessibilityLabel)
        }
    }

    private func summary(_ outcome: KeywordResearchMetricsOutcome) -> String {
        let score = outcome.popularityScore.map(String.init) ?? "Unavailable"
        return "Score \(score) · \(outcome.disposition.displayName) · "
            + (outcome.provenance?.displayName ?? "No provenance")
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private extension KeywordResearchMetricsDisposition {
    var displayName: String {
        switch self {
        case .freshCache: "Fresh shared cache"
        case .refreshed: "Refreshed"
        case .staleCacheFallback: "Stale shared cache"
        case .notFound: "Not found"
        case .unavailable: "Unavailable"
        case .supersededByNewerCache: "Newer shared cache"
        }
    }
}

private extension KeywordResearchMetricsProvenance {
    var displayName: String {
        switch self {
        case .sharedCacheContextUnknown:
            "Shared cache, context unknown"
        case .requestedContext:
            "Requested Apple Ads context"
        }
    }
}
