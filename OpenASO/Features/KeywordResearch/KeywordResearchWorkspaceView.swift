import SwiftUI

struct KeywordResearchWorkspaceLauncher: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        if let factory = KeywordResearchModelFactory(services: services) {
            KeywordResearchWorkspaceView(
                factory: factory,
                storefronts: (try? services.storefrontCatalog.bundledStorefronts()) ?? []
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

    private let storefronts: [BundledStorefront]

    @State private var projectsModel: KeywordResearchProjectsModel
    @State private var selectedProjectGeneration: KeywordResearchProjectGeneration?
    @State private var editorContext: ProjectEditorContext?
    @State private var projectPendingDeletion: KeywordResearchProjectSnapshot?
    @State private var deletingProjectGeneration: KeywordResearchProjectGeneration?
    @State private var deletionError: KeywordResearchErrorPresentation?

    init(
        factory: KeywordResearchModelFactory,
        storefronts: [BundledStorefront]
    ) {
        self.storefronts = storefronts
        _projectsModel = State(initialValue: factory.makeProjectsModel())
    }

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            projectDetail
        }
        .navigationTitle("Keyword Research")
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if deletingProjectGeneration != nil {
                    ProgressView("Deleting Project…")
                        .controlSize(.small)
                } else if let selectedProject {
                    Button {
                        editorContext = .edit(selectedProject)
                    } label: {
                        Label("Edit Project", systemImage: "pencil")
                    }
                    .disabled(projectsModel.mutationState.isRunning)

                    Button(role: .destructive) {
                        projectPendingDeletion = selectedProject
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                    .disabled(projectsModel.mutationState.isRunning)
                }

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(deletingProjectGeneration != nil)
            }
        }
        .interactiveDismissDisabled(deletingProjectGeneration != nil)
        .task {
            guard projectsModel.loadState == .idle else { return }
            await projectsModel.reload()
            reconcileSelection()
        }
        .onChange(of: projectsModel.projects) {
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
            StatusRow(
                title: "Projects changed",
                message: "Reload before continuing to the next page.",
                systemImage: "arrow.clockwise",
                actionTitle: "Reload"
            ) {
                Task { await reloadProjects() }
            }
        } else if case .failed(let error) = projectsModel.loadState {
            StatusRow(
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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(project.name)
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text("Pre-live research project")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Default storefront", value: project.defaultStorefront.uppercased())
                    LabeledContent("Default platform", value: project.defaultPlatform.displayName)
                    LabeledContent("Bundle identifier", value: project.bundleID ?? "Not set")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes")
                            .font(.headline)
                        Text(project.notes.isEmpty ? "No notes" : project.notes)
                            .foregroundStyle(project.notes.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Independent research")
                            .font(.headline)
                        Text(
                            "This workspace does not claim that the project has an App Store rank. "
                                + "Ranking evidence belongs to shared keyword search results."
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(project.keywordResearchAccessibilityLabel)
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

    private func reconcileSelection() {
        selectedProjectGeneration = KeywordResearchWorkspaceSelection.reconciled(
            selectedProjectGeneration,
            projects: projectsModel.projects
        )
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

private struct StatusRow: View {
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
