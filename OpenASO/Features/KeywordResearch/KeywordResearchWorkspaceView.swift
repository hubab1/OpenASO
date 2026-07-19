import SwiftUI

struct KeywordResearchWorkspaceLauncher: View {
    @Environment(AppServices.self) private var services
    let detailModelCache: KeywordResearchProjectDetailModelCache

    var body: some View {
        if let factory = KeywordResearchModelFactory(services: services) {
            KeywordResearchWorkspaceView(
                factory: factory,
                storefronts: (try? services.storefrontCatalog.bundledStorefronts()) ?? [],
                detailModelCache: detailModelCache
            )
        } else {
            ContentUnavailableView(
                "Research Workspace Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(
                    "OpenASO could not initialize the persistent research services. "
                        + "Close this sheet and retry after the workspace store is available."
                )
            )
            .frame(minWidth: 680, minHeight: 480)
        }
    }
}

struct KeywordResearchWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss

    private let factory: KeywordResearchModelFactory
    private let storefronts: [BundledStorefront]
    private let detailModelCache: KeywordResearchProjectDetailModelCache

    @State private var projectsModel: KeywordResearchProjectsModel
    @State private var selectedProjectGeneration: KeywordResearchProjectGeneration?
    @State private var editorContext: ProjectEditorContext?
    @State private var projectPendingDeletion: KeywordResearchProjectSnapshot?
    @State private var deletingProjectGeneration: KeywordResearchProjectGeneration?
    @State private var deletionError: KeywordResearchErrorPresentation?
    @State private var detailBlocksDismissal = false

    init(
        factory: KeywordResearchModelFactory,
        storefronts: [BundledStorefront],
        detailModelCache: KeywordResearchProjectDetailModelCache
    ) {
        self.factory = factory
        self.storefronts = storefronts
        self.detailModelCache = detailModelCache
        _projectsModel = State(initialValue: factory.makeProjectsModel())
    }

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .disabled(
                    detailBlocksDismissal || deletingProjectGeneration != nil
                )
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            projectDetail
                .disabled(deletingProjectGeneration != nil)
        }
        .navigationTitle("Keyword Research")
        .frame(minWidth: 900, minHeight: 620)
        .interactiveDismissDisabled(
            deletingProjectGeneration != nil || detailBlocksDismissal
        )
        .task {
            guard projectsModel.loadState == .idle else { return }
            await projectsModel.reload()
            reconcileSelection()
        }
        .onChange(of: projectsModel.projects) {
            detailModelCache.reconcile(with: projectsModel.projects)
            reconcileSelection()
        }
        .sheet(item: $editorContext) { context in
            KeywordResearchProjectEditorSheet(
                context: context,
                storefronts: storefronts,
                save: saveProject
            )
        }
        .confirmationDialog(
            "Delete research project?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let projectPendingDeletion {
                Button("Delete \(projectPendingDeletion.name)", role: .destructive) {
                    deleteProject(projectPendingDeletion)
                }
            }
        } message: {
            Text(
                "This removes the project and its keyword memberships. "
                    + "Shared query evidence used elsewhere is retained."
            )
        }
        .alert(item: $deletionError) { error in
            Alert(
                title: Text(error.title),
                message: Text([
                    error.message,
                    error.recoverySuggestion,
                ].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK")) {
                    projectsModel.clearMutationResult()
                }
            )
        }
    }

    private var selectedProject: KeywordResearchProjectSnapshot? {
        guard let selectedProjectGeneration else { return nil }
        return projectsModel.projects.first {
            $0.generation == selectedProjectGeneration
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Research Projects")
                    .font(.headline)
                Spacer()
                Button("Reload Projects", systemImage: "arrow.clockwise") {
                    Task { await reloadProjects() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reload Projects")
                .disabled(projectsModel.loadState.isLoading)

                Button("New Research Project", systemImage: "plus") {
                    editorContext = .create()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Research Project")
                .disabled(projectsModel.mutationState.isRunning)

                if deletingProjectGeneration != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Deleting Project")
                } else if let selectedProject {
                    Menu("Project Actions", systemImage: "ellipsis.circle") {
                        Button("Edit Project", systemImage: "pencil") {
                            editorContext = .edit(selectedProject)
                        }

                        Button("Delete Project", systemImage: "trash", role: .destructive) {
                            projectPendingDeletion = selectedProject
                        }
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .help("Project Actions")
                    .disabled(projectsModel.mutationState.isRunning)
                }

                Button("Close Keyword Research", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close Keyword Research")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if projectsModel.projects.isEmpty {
                emptyProjectState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedProjectGeneration) {
                    ForEach(projectsModel.projects) { project in
                        ProjectRow(project: project)
                            .tag(project.generation)
                    }
                }

                projectListFooter
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var emptyProjectState: some View {
        switch projectsModel.loadState {
        case .loading:
            ProgressView("Loading research projects…")
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") {
                    Task { await reloadProjects() }
                }
            }
            .accessibilityLabel(error.accessibilityLabel)
        case .idle, .loaded, .loadingNextPage:
            ContentUnavailableView {
                Label("No Research Projects", systemImage: "lightbulb")
            } description: {
                Text("Create a project before an app is live, without using a fake App Store ID.")
            } actions: {
                Button("New Project") {
                    editorContext = .create()
                }
            }
        }
    }

    @ViewBuilder
    private var projectListFooter: some View {
        if projectsModel.requiresReload {
            KeywordResearchStatusRow(
                title: "Projects changed",
                message: "Reload before continuing to the next page.",
                systemImage: "arrow.clockwise",
                actionTitle: "Reload"
            ) {
                Task { await reloadProjects() }
            }
        } else if case .failed(let error) = projectsModel.loadState {
            KeywordResearchStatusRow(
                title: error.title,
                message: error.message,
                systemImage: "exclamationmark.triangle",
                actionTitle: "Try Again"
            ) {
                Task { await reloadProjects() }
            }
            .accessibilityLabel(error.accessibilityLabel)
        } else if projectsModel.loadState == .loadingNextPage {
            ProgressView("Loading more…")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(10)
        } else if projectsModel.hasMoreProjects {
            Button("Load More") {
                Task { await projectsModel.loadNextPage() }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
        }
    }

    @ViewBuilder
    private var projectDetail: some View {
        if let project = selectedProject {
            KeywordResearchProjectWorkspaceView(
                project: project,
                model: detailModelCache.model(for: project) {
                    factory.makeProjectDetailModel(project: project)
                },
                storefronts: storefronts,
                blocksWorkspaceDismissal: $detailBlocksDismissal,
                reconcileProject: projectsModel.recordAuthoritativeProject,
                resolveAuthoritativeProject: resolveAuthoritativeProject,
                makeHistoryModel: { projectGeneration, keyword in
                    factory.makeHistoryModel(
                        projectGeneration: projectGeneration,
                        keyword: keyword
                    )
                },
                makeCopyModel: { project in
                    factory.makeProjectCopyModel(project: project)
                }
            )
            .id(project.generation)
        } else {
            ContentUnavailableView(
                "Select a Research Project",
                systemImage: "sidebar.left",
                description: Text("Choose a project from the sidebar or create a new one.")
            )
        }
    }

    private func saveProject(
        context: ProjectEditorContext,
        draft: KeywordResearchProjectDraft
    ) async -> ProjectEditorOutcome {
        let project: KeywordResearchProjectSnapshot?
        if let existing = context.project {
            project = await projectsModel.update(
                revision: existing.revision,
                with: draft
            )
        } else {
            project = await projectsModel.create(draft)
        }

        if let project {
            selectedProjectGeneration = project.generation
            return ProjectEditorOutcome(project: project, error: nil)
        }
        return ProjectEditorOutcome(
            project: nil,
            error: projectsModel.mutationState.presentedError
        )
    }

    private func deleteProject(_ project: KeywordResearchProjectSnapshot) {
        projectPendingDeletion = nil
        deletingProjectGeneration = project.generation
        deletionError = nil
        Task {
            guard await projectsModel.delete(project) else {
                deletingProjectGeneration = nil
                deletionError = projectsModel.mutationState.presentedError
                    ?? .presenting(OpenASOError.unexpectedResponse)
                return
            }
            detailModelCache.remove(project.generation)
            deletingProjectGeneration = nil
            if selectedProjectGeneration == project.generation {
                selectedProjectGeneration = nil
            }
            reconcileSelection()
        }
    }

    private func reloadProjects() async {
        await projectsModel.reload()
        reconcileSelection()
    }

    private func resolveAuthoritativeProject(
        _ generation: KeywordResearchProjectGeneration
    ) async throws -> KeywordResearchProjectSnapshot {
        let loaded = try await factory.loadProject(generation: generation)
        if projectsModel.recordAuthoritativeProject(loaded) {
            return loaded
        }
        if let current = projectsModel.projects.first(where: {
            $0.generation == generation && $0.updatedAt >= loaded.updatedAt
        }) {
            return current
        }
        throw KeywordResearchProjectStoreError.staleProjectRevision(generation.id)
    }

    private func reconcileSelection() {
        selectedProjectGeneration = KeywordResearchWorkspaceSelection.reconciled(
            selectedProjectGeneration,
            projects: projectsModel.projects
        )
    }
}

@MainActor
final class KeywordResearchProjectDetailModelCache {
    private var models: [
        KeywordResearchProjectGeneration: KeywordResearchProjectDetailModel
    ] = [:]

    func model(
        for project: KeywordResearchProjectSnapshot,
        create: () -> KeywordResearchProjectDetailModel
    ) -> KeywordResearchProjectDetailModel {
        if let existing = models[project.generation] {
            return existing
        }
        let model = create()
        models[project.generation] = model
        return model
    }

    func reconcile(with projects: [KeywordResearchProjectSnapshot]) {
        for project in projects {
            models[project.generation]?.replaceProject(project)
        }
    }

    func remove(_ generation: KeywordResearchProjectGeneration) {
        models[generation] = nil
    }
}

enum KeywordResearchWorkspaceSelection {
    static func reconciled(
        _ selection: KeywordResearchProjectGeneration?,
        projects: [KeywordResearchProjectSnapshot]
    ) -> KeywordResearchProjectGeneration? {
        guard let selection else { return projects.first?.generation }
        return projects.contains { $0.generation == selection } ? selection : nil
    }
}

private struct ProjectRow: View {
    let project: KeywordResearchProjectSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .fontWeight(.medium)
                .lineLimit(1)
            Text("\(project.defaultStorefront.uppercased()) · \(project.defaultPlatform.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.keywordResearchAccessibilityLabel)
    }
}

struct KeywordResearchStatusRow: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(10)
    }
}

private extension KeywordResearchMutationState {
    var presentedError: KeywordResearchErrorPresentation? {
        guard case .failed(_, let error) = self else { return nil }
        return error
    }
}
