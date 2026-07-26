import SwiftUI

struct KeywordResearchCopyContext: Identifiable {
    let project: KeywordResearchProjectSnapshot

    var id: KeywordResearchProjectRevision { project.revision }
}

struct KeywordResearchProjectCopySheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding private var blocksWorkspaceDismissal: Bool
    @State private var model: KeywordResearchProjectCopyModel
    @State private var confirmationPreview: KeywordResearchProjectCopyPreview?

    private let reconcileProject: @MainActor (KeywordResearchProjectSnapshot) -> Bool

    init(
        model: KeywordResearchProjectCopyModel,
        blocksWorkspaceDismissal: Binding<Bool>,
        reconcileProject: @escaping @MainActor (
            KeywordResearchProjectSnapshot
        ) -> Bool
    ) {
        _model = State(initialValue: model)
        _blocksWorkspaceDismissal = blocksWorkspaceDismissal
        self.reconcileProject = reconcileProject
    }

    var body: some View {
        HStack(spacing: 0) {
            targetSidebar
                .frame(width: 320)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 580)
        .task {
            guard model.targetLoadState == .idle else { return }
            await model.reloadTargets()
        }
        .onDisappear {
            model.cancelTransientOperations()
            blocksWorkspaceDismissal = false
        }
        .onChange(of: model.project) { _, project in
            _ = reconcileProject(project)
        }
        .onChange(of: model.blocksDismissal, initial: true) { _, blocks in
            blocksWorkspaceDismissal = blocks
        }
        .interactiveDismissDisabled(model.blocksDismissal)
        .confirmationDialog(
            confirmation?.title ?? "Copy research keywords?",
            isPresented: Binding(
                get: { confirmationPreview != nil },
                set: { if !$0 { confirmationPreview = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.actionTitle) {
                    confirmationPreview = nil
                    Task { await model.confirmCopy() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let confirmation {
                Text(confirmation.message)
            }
        }
    }

    private var confirmation: KeywordResearchCopyConfirmationPresentation? {
        confirmationPreview.map {
            KeywordResearchCopyConfirmationPresentation(preview: $0)
        }
    }

    private var targetSelection: Binding<KeywordResearchCopyTargetGeneration?> {
        Binding(
            get: { model.selectedTargetGeneration },
            set: { selection in
                model.selectTarget(selection)
                guard selection != nil else { return }
                Task { await model.reviewSelectedTarget() }
            }
        )
    }

    private var targetSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tracked Apps")
                    .font(.headline)
                Spacer()
                Button("Reload Tracked Apps", systemImage: "arrow.clockwise") {
                    Task { await model.reloadTargets() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reload Tracked Apps")
                .disabled(
                    model.targetLoadState.isLoading
                        || model.blocksDismissal
                        || model.workflowState.isComplete
                )

                Button(
                    model.workflowState.isComplete ? "Done" : "Cancel",
                    systemImage: model.workflowState.isComplete ? "checkmark" : "xmark"
                ) {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(model.workflowState.isComplete ? "Done" : "Cancel")
                .disabled(model.blocksDismissal)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if model.targets.isEmpty {
                emptyTargetState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: targetSelection) {
                    ForEach(model.targets) { target in
                        KeywordResearchCopyTargetRow(target: target)
                            .tag(target.generation)
                    }
                }
                .disabled(model.blocksDismissal || model.workflowState.isComplete)

                targetListFooter
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var emptyTargetState: some View {
        switch model.targetLoadState {
        case .loading:
            ProgressView("Loading tracked apps…")
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") {
                    Task { await model.retryFailedTargetLoad() }
                }
            }
            .accessibilityLabel(error.accessibilityLabel)
        case .idle, .loaded, .loadingNextPage:
            ContentUnavailableView {
                Label("No Tracked Apps", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("Add a live App Store app before copying research keywords.")
            }
        }
    }

    @ViewBuilder
    private var targetListFooter: some View {
        if case .failed(let error) = model.targetLoadState {
            KeywordResearchStatusRow(
                title: error.title,
                message: error.message,
                systemImage: "exclamationmark.triangle",
                actionTitle: "Try Again"
            ) {
                Task { await model.retryFailedTargetLoad() }
            }
            .accessibilityLabel(error.accessibilityLabel)
        } else if model.targetLoadState == .loadingNextPage {
            ProgressView("Loading more tracked apps…")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(10)
        } else if model.hasMoreTargets {
            Button("Load More Tracked Apps") {
                Task { await model.loadNextTargetsPage() }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .disabled(model.blocksDismissal || model.workflowState.isComplete)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.workflowState {
        case .copied(let preview, let result):
            KeywordResearchCopyCompletionView(
                preview: preview,
                result: result,
                refreshState: model.refreshState,
                refresh: {
                    Task { await model.refreshCopiedKeywords() }
                },
                close: { dismiss() }
            )
        case .previewing:
            ProgressView("Building exact copy preview…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle:
            if model.selectedTarget != nil {
                ContentUnavailableView {
                    Label("Preview Not Loaded", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Review the selected tracked app before copying.")
                } actions: {
                    Button("Review Copy") {
                        Task { await model.reviewSelectedTarget() }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select a Tracked App",
                    systemImage: "square.stack.3d.up",
                    description: Text(
                        "Choose the exact live app that should receive this project's keywords."
                    )
                )
            }
        case .ready(let preview):
            previewDetail(preview, mode: .ready)
        case .copying(let preview):
            previewDetail(preview, mode: .copying)
        case .stale(let preview, let error):
            previewDetail(preview, mode: .requiresReview(error))
        case .failed(let preview?, let error):
            previewDetail(preview, mode: .failed(error))
        case .failed(nil, let error):
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text([error.message, error.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: "\n\n"))
            } actions: {
                if model.selectedTargetGeneration == nil {
                    Button("Reload Tracked Apps") {
                        Task { await model.reloadTargets() }
                    }
                } else {
                    Button("Review Again") {
                        Task { await model.reviewSelectedTarget() }
                    }
                }
            }
            .accessibilityLabel(error.accessibilityLabel)
        }
    }

    private func previewDetail(
        _ preview: KeywordResearchProjectCopyPreview,
        mode: KeywordResearchCopyPreviewMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    KeywordResearchCopyDestinationHeader(preview: preview)

                    if let error = mode.error {
                        KeywordResearchCopyNotice(
                            title: error.title,
                            message: error.message,
                            systemImage: "exclamationmark.triangle",
                            color: .orange
                        )
                        .accessibilityLabel(error.accessibilityLabel)
                    }

                    KeywordResearchCopyBundleNotice(
                        advisory: KeywordResearchCopyBundleAdvisory(
                            preview.bundleCompatibility
                        )
                    )
                    KeywordResearchCopyCounts(preview: preview)

                    Text(
                        "The project remains separate. Existing tracked keywords and their "
                            + "history stay unchanged; new tracks reuse shared query evidence "
                            + "without inventing refresh history."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }

            Divider()

            Text("Exact project scope")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            List(preview.items) { item in
                KeywordResearchCopyItemRow(item: item)
            }
            .frame(minHeight: 220)

            Divider()

            HStack(spacing: 12) {
                if mode.isCopying {
                    ProgressView("Copying keywords atomically…")
                        .controlSize(.small)
                } else if mode.requiresReview {
                    Button("Refresh Preview") {
                        Task { await model.reviewSelectedTarget() }
                    }
                } else if preview.totalKeywordCount == 0 {
                    Label("This project has no keywords to copy.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else if preview.additionCount == 0 {
                    Label(
                        "All project keywords are already tracked by this app.",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if mode.isReady, preview.totalKeywordCount > 0 {
                    if preview.additionCount > 0 {
                        Button("Copy \(preview.additionCount) New Keywords") {
                            confirmationPreview = preview
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canConfirmCopy)
                    } else {
                        Button("Continue to Optional Refresh") {
                            Task { await model.confirmCopy() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canConfirmCopy)
                    }
                }
            }
            .padding(16)
        }
        .disabled(mode.isCopying)
    }
}

private enum KeywordResearchCopyPreviewMode {
    case ready
    case copying
    case requiresReview(KeywordResearchErrorPresentation)
    case failed(KeywordResearchErrorPresentation)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isCopying: Bool {
        if case .copying = self { return true }
        return false
    }

    var requiresReview: Bool {
        switch self {
        case .requiresReview, .failed:
            return true
        case .ready, .copying:
            return false
        }
    }

    var error: KeywordResearchErrorPresentation? {
        switch self {
        case .requiresReview(let error), .failed(let error):
            return error
        case .ready, .copying:
            return nil
        }
    }
}

private struct KeywordResearchCopyTargetRow: View {
    let target: KeywordResearchCopyTargetSnapshot

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(
                appStoreID: target.appStoreID,
                preferredIconURLString: target.iconURLString,
                size: 40,
                cornerRadius: 9
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(target.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(target.bundleID ?? "Bundle identifier unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: "App ID \(target.appStoreID)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.keywordResearchCopyAccessibilityLabel)
    }
}

private struct KeywordResearchCopyDestinationHeader: View {
    let preview: KeywordResearchProjectCopyPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Copy destination")
                .font(.headline)
            HStack(alignment: .center, spacing: 12) {
                AppIconView(
                    appStoreID: preview.target.appStoreID,
                    preferredIconURLString: preview.target.iconURLString,
                    size: 52,
                    cornerRadius: 12
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.target.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(preview.target.bundleID ?? "Bundle identifier unavailable")
                        .foregroundStyle(.secondary)
                    Text("From research project \(preview.project.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct KeywordResearchCopyBundleNotice: View {
    let advisory: KeywordResearchCopyBundleAdvisory

    var body: some View {
        KeywordResearchCopyNotice(
            title: advisory.title,
            message: advisory.message,
            systemImage: advisory.systemImage,
            color: color
        )
    }

    private var color: Color {
        switch advisory.kind {
        case .match:
            return .green
        case .warning:
            return .orange
        case .unavailable:
            return .secondary
        }
    }
}

private struct KeywordResearchCopyNotice: View {
    let title: String
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct KeywordResearchCopyCounts: View {
    let preview: KeywordResearchProjectCopyPreview

    var body: some View {
        HStack(spacing: 12) {
            count(
                title: "Will Add",
                value: preview.additionCount,
                systemImage: "plus.circle"
            )
            count(
                title: "Already Tracked",
                value: preview.duplicateCount,
                systemImage: "checkmark.circle"
            )
            count(
                title: "Project Total",
                value: preview.totalKeywordCount,
                systemImage: "number.circle"
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(preview.additionCount) will be added, "
                + "\(preview.duplicateCount) already tracked, "
                + "\(preview.totalKeywordCount) project keywords total"
        )
    }

    private func count(title: String, value: Int, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct KeywordResearchCopyItemRow: View {
    let item: KeywordResearchProjectCopyItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.keyword.term)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(item.keyword.storefront.uppercased())
                    Text(item.keyword.platform.displayName)
                    if !item.keyword.notes.isEmpty {
                        Text(item.keyword.notes)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Label(dispositionTitle, systemImage: dispositionImage)
                .font(.caption)
                .foregroundStyle(
                    item.disposition == .add ? Color.primary : Color.secondary
                )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dispositionTitle: String {
        item.disposition == .add ? "Will add" : "Already tracked"
    }

    private var dispositionImage: String {
        item.disposition == .add ? "plus.circle" : "checkmark.circle"
    }

    private var accessibilityLabel: String {
        var label = "\(item.keyword.keywordResearchAccessibilityLabel), \(dispositionTitle)"
        let notes = item.keyword.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            label += ", notes \(notes)"
        }
        return label
    }
}

private struct KeywordResearchCopyCompletionView: View {
    let preview: KeywordResearchProjectCopyPreview
    let result: KeywordResearchProjectCopyResult
    let refreshState: KeywordResearchRefreshState<KeywordResearchPostCopyRefreshSummary>
    let refresh: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(completionTitle, systemImage: "checkmark.circle.fill")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)

                Text(resultMessage)
                    .font(.title3)

                Text(
                    "The research project is still available and remains separate from the "
                        + "tracked app. Future project changes will not synchronize automatically."
                )
                .foregroundStyle(.secondary)

                if result.convergedCompletedCopy {
                    KeywordResearchCopyNotice(
                        title: "Destination already satisfied the copy",
                        message: "Another completed change produced the same safe target state "
                            + "before this attempt returned.",
                        systemImage: "arrow.triangle.2.circlepath.circle",
                        color: .secondary
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Optional network refresh")
                        .font(.headline)
                    Text(
                        "Fetch current rankings and popularity for all "
                            + "\(result.totalKeywordCount) project keywords at "
                            + "\(result.target.name), including already-tracked keywords. "
                            + "Ratings and reviews are not refreshed."
                    )
                    .foregroundStyle(.secondary)

                    refreshContent
                }

                HStack {
                    Spacer()
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var refreshContent: some View {
        switch refreshState {
        case .idle:
            Button("Refresh \(result.totalKeywordCount) Tracked Keywords", action: refresh)
                .disabled(result.totalKeywordCount == 0)
        case .refreshing(let previous):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(previous.map(refreshSummary) ?? "Refreshing tracked keywords…")
            }
        case .current(let summary):
            Label(
                refreshSummary(summary),
                systemImage: summary.isFullySuccessful
                    ? "checkmark.circle"
                    : "exclamationmark.triangle"
            )
            if let issue = summary.issue {
                Text(issue.accessibilityLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Refresh Again", action: refresh)
            }
        case .failed(let previous, let error):
            Label(error.title, systemImage: "exclamationmark.triangle")
            Text(error.message)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let previous {
                Text(refreshSummary(previous))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Try Refresh Again", action: refresh)
        }
    }

    private var resultMessage: String {
        if result.insertedCount == 0,
           result.alreadyPresentCount == result.totalKeywordCount {
            return "All \(result.totalKeywordCount) project keyword"
                + (result.totalKeywordCount == 1 ? " was" : "s were")
                + " already tracked by \(result.target.name). No keyword rows were changed."
        }
        return "Added \(result.insertedCount) new keyword"
            + (result.insertedCount == 1 ? "" : "s")
            + " to \(result.target.name). "
            + "\(result.alreadyPresentCount) already-tracked keyword"
            + (result.alreadyPresentCount == 1 ? " was" : "s were")
            + " left unchanged."
    }

    private var completionTitle: String {
        result.insertedCount == 0 ? "Tracked Keywords Ready" : "Copy Complete"
    }

    private func refreshSummary(
        _ summary: KeywordResearchPostCopyRefreshSummary
    ) -> String {
        let rankingSummary = "Refreshed rankings for \(summary.succeededTrackCount) of "
            + "\(summary.requestedTrackCount) tracked keywords"
        if summary.failedTrackCount > 0 {
            return rankingSummary + "; \(summary.failedTrackCount) ranking refresh"
                + (summary.failedTrackCount == 1 ? " failed." : "es failed.")
        }
        if summary.issue != nil {
            return rankingSummary + "; the popularity refresh reported an issue."
        }
        return rankingSummary + "."
    }
}
