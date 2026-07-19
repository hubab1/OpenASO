import SwiftUI

struct KeywordEditorContext: Identifiable {
    let id: UUID
    let projectGeneration: KeywordResearchProjectGeneration
    let initialDraft: KeywordResearchKeywordDraft

    static func create(for project: KeywordResearchProjectSnapshot) -> Self {
        let draft = KeywordResearchKeywordDraft(
            storefront: project.defaultStorefront,
            platform: project.defaultPlatform
        )
        return Self(
            id: draft.id,
            projectGeneration: project.generation,
            initialDraft: draft
        )
    }
}

struct KeywordEditorOutcome: Sendable {
    let keyword: KeywordResearchKeywordSnapshot?
    let error: KeywordResearchErrorPresentation?
}

struct KeywordResearchKeywordEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: KeywordEditorContext
    let storefronts: [BundledStorefront]
    let save: @MainActor (
        _ context: KeywordEditorContext,
        _ draft: KeywordResearchKeywordDraft
    ) async -> KeywordEditorOutcome

    @State private var draft: KeywordResearchKeywordDraft
    @State private var isSaving = false
    @State private var error: KeywordResearchErrorPresentation?

    init(
        context: KeywordEditorContext,
        storefronts: [BundledStorefront],
        save: @escaping @MainActor (
            _ context: KeywordEditorContext,
            _ draft: KeywordResearchKeywordDraft
        ) async -> KeywordEditorOutcome
    ) {
        self.context = context
        self.storefronts = storefronts
        self.save = save
        _draft = State(initialValue: context.initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Research Keyword")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Keyword", text: $draft.term)

                if storefronts.isEmpty {
                    TextField("Storefront", text: $draft.storefront)
                } else {
                    Picker("Storefront", selection: $draft.storefront) {
                        ForEach(storefronts, id: \.code) { storefront in
                            Text("\(storefront.flagEmoji) \(storefront.name)")
                                .tag(storefront.code.lowercased())
                        }
                    }
                }

                Picker("Platform", selection: $draft.platform) {
                    ForEach(AppPlatform.allCases) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }

                TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            .formStyle(.grouped)

            Text(
                "This membership reuses shared evidence for the exact keyword, storefront, "
                    + "and platform. It does not create a fake tracked app."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

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
                            Text("Adding…")
                        }
                    } else {
                        Text("Add")
                    }
                }
                .accessibilityLabel(isSaving ? "Adding Research Keyword" : "Add Research Keyword")
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || draft.term.trimmingCharacters(
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
            if outcome.keyword != nil {
                dismiss()
            } else {
                error = outcome.error ?? .presenting(OpenASOError.unexpectedResponse)
            }
        }
    }
}
