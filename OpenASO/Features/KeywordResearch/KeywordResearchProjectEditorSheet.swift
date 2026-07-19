import SwiftUI

struct ProjectEditorContext: Identifiable {
    let id: UUID
    let project: KeywordResearchProjectSnapshot?
    let initialDraft: KeywordResearchProjectDraft

    static func create() -> Self {
        let draft = KeywordResearchProjectDraft()
        return Self(id: draft.id, project: nil, initialDraft: draft)
    }

    static func edit(_ project: KeywordResearchProjectSnapshot) -> Self {
        Self(
            id: project.id,
            project: project,
            initialDraft: KeywordResearchProjectDraft(project: project)
        )
    }
}

struct ProjectEditorOutcome: Sendable {
    let project: KeywordResearchProjectSnapshot?
    let error: KeywordResearchErrorPresentation?
}

struct KeywordResearchProjectEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: ProjectEditorContext
    let storefronts: [BundledStorefront]
    let save: @MainActor (
        _ context: ProjectEditorContext,
        _ draft: KeywordResearchProjectDraft
    ) async -> ProjectEditorOutcome

    @State private var draft: KeywordResearchProjectDraft
    @State private var isSaving = false
    @State private var error: KeywordResearchErrorPresentation?

    init(
        context: ProjectEditorContext,
        storefronts: [BundledStorefront],
        save: @escaping @MainActor (
            _ context: ProjectEditorContext,
            _ draft: KeywordResearchProjectDraft
        ) async -> ProjectEditorOutcome
    ) {
        self.context = context
        self.storefronts = storefronts
        self.save = save
        _draft = State(initialValue: context.initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(context.project == nil ? "New Research Project" : "Edit Research Project")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Name", text: $draft.name)
                TextField("Bundle identifier (optional)", text: $draft.bundleID)

                if storefronts.isEmpty {
                    TextField("Default storefront", text: $draft.defaultStorefront)
                } else {
                    Picker("Default storefront", selection: $draft.defaultStorefront) {
                        ForEach(storefronts, id: \.code) { storefront in
                            Text("\(storefront.flagEmoji) \(storefront.name)")
                                .tag(storefront.code.lowercased())
                        }
                    }
                }

                Picker("Default platform", selection: $draft.defaultPlatform) {
                    ForEach(AppPlatform.allCases) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }

                TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            .formStyle(.grouped)

            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error.title, systemImage: "exclamationmark.triangle")
                        .fontWeight(.medium)
                    Text(error.message)
                    if let recoverySuggestion = error.recoverySuggestion {
                        Text(recoverySuggestion)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(error.accessibilityLabel)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button {
                    submit()
                } label: {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            Text("Saving…")
                        }
                    } else {
                        Text(context.project == nil ? "Create" : "Save")
                    }
                }
                .accessibilityLabel(
                    isSaving
                        ? "Saving Research Project"
                        : (context.project == nil ? "Create Research Project" : "Save Research Project")
                )
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || draft.name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 460)
        .interactiveDismissDisabled(isSaving)
    }

    private func submit() {
        guard !isSaving else { return }
        isSaving = true
        error = nil

        Task {
            let outcome = await save(context, draft)
            isSaving = false
            if outcome.project != nil {
                dismiss()
            } else {
                error = outcome.error ?? .presenting(OpenASOError.unexpectedResponse)
            }
        }
    }
}
