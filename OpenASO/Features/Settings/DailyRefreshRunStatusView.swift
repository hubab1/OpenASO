import Foundation
import SwiftUI

struct DailyRefreshRunStatusPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case preparing
        case refreshing
        case finishing
        case noWork
        case success
        case partialFailure
        case failure
        case cancelled
    }

    enum Progress: Equatable, Sendable {
        case indeterminate
        case determinate(completed: Int, total: Int)
    }

    let kind: Kind
    let title: String
    let detail: String
    let systemImage: String?
    let progress: Progress?
    let finishedAt: Date?
    let facts: String?
    let issueMessage: String?
    let accessibilityLabel: String
    let accessibilityValue: String

    var isActive: Bool {
        switch kind {
        case .preparing, .refreshing, .finishing:
            true
        case .noWork, .success, .partialFailure, .failure, .cancelled:
            false
        }
    }

    init?(
        activeRun: HeadlessRefreshActiveSnapshot?,
        latestRun: HeadlessRefreshRunSummary?
    ) {
        if let activeRun {
            self = Self(activeRun: activeRun)
        } else if let latestRun,
                  let presentation = Self(latestRun: latestRun) {
            self = presentation
        } else {
            return nil
        }
    }

    private init(activeRun: HeadlessRefreshActiveSnapshot) {
        let completed = max(0, activeRun.completedAppCount)
        let total = activeRun.plannedAppCount.map { max(0, $0) }
        let progress: Progress
        let kind: Kind
        let title: String
        let detail: String

        switch activeRun.phase {
        case .planning:
            kind = .preparing
            title = "Preparing automatic refresh"
            detail = "Building the refresh plan."
            progress = .indeterminate
        case .refreshing:
            kind = .refreshing
            title = "Refreshing apps"
            if let total, total > 0 {
                let completed = min(completed, total)
                detail = "\(completed) of \(total) apps complete."
                progress = .determinate(completed: completed, total: total)
            } else if total == 0 {
                detail = "No apps are queued for this refresh."
                progress = .indeterminate
            } else {
                detail = "Waiting for the refresh plan."
                progress = .indeterminate
            }
        case .finishing:
            kind = .finishing
            title = "Finishing automatic refresh"
            if let total, total > 0 {
                let completed = min(completed, total)
                detail = "\(completed) of \(total) apps complete."
                progress = .determinate(completed: completed, total: total)
            } else if total == 0 {
                detail = "No apps were queued. Finalizing the result."
                progress = .indeterminate
            } else {
                detail = "Finalizing the refresh result."
                progress = .indeterminate
            }
        }

        self.kind = kind
        self.title = title
        self.detail = detail
        self.systemImage = nil
        self.progress = progress
        self.finishedAt = nil
        self.facts = nil
        self.issueMessage = nil
        self.accessibilityLabel = "Automatic refresh progress"
        self.accessibilityValue = detail
    }

    private init?(latestRun: HeadlessRefreshRunSummary) {
        let result: (kind: Kind, title: String, detail: String, systemImage: String)
        switch latestRun.disposition {
        case .noWork:
            result = (
                .noWork,
                "No refresh work needed",
                "No apps needed refreshing.",
                "checkmark.circle"
            )
        case .success:
            result = (
                .success,
                "Automatic refresh completed",
                "All completed app refreshes succeeded.",
                "checkmark.circle.fill"
            )
        case .partialFailure:
            result = (
                .partialFailure,
                "Automatic refresh completed with issues",
                "Some apps did not fully refresh.",
                "exclamationmark.triangle.fill"
            )
        case .failure:
            result = (
                .failure,
                "Automatic refresh failed",
                "The automatic refresh could not complete.",
                "xmark.octagon.fill"
            )
        case .cancelled:
            result = (
                .cancelled,
                "Automatic refresh cancelled",
                "The automatic refresh stopped before completing.",
                "stop.circle.fill"
            )
        case .skippedAlreadyRunning, .rejectedRequestConflict:
            return nil
        }

        let appNoun = latestRun.plannedAppCount == 1 ? "app" : "apps"
        let facts = "Completed \(latestRun.completedAppCount) "
            + "of \(latestRun.plannedAppCount) \(appNoun): "
            + "\(latestRun.successfulAppCount) succeeded, "
            + "\(latestRun.partialFailureAppCount) partial, "
            + "\(latestRun.failedAppCount) failed."
        let issueMessage = latestRun.issue?.message
        let finishedText = latestRun.finishedAt.formatted(
            date: .abbreviated,
            time: .shortened
        )
        let accessibilityParts: [String?] = [
            result.title + ".",
            result.detail,
            "Finished \(finishedText).",
            facts,
            issueMessage,
        ]
        let accessibilityValue = accessibilityParts
            .compactMap { $0 }
            .joined(separator: " ")

        self.kind = result.kind
        self.title = result.title
        self.detail = result.detail
        self.systemImage = result.systemImage
        self.progress = nil
        self.finishedAt = latestRun.finishedAt
        self.facts = facts
        self.issueMessage = issueMessage
        self.accessibilityLabel = "Latest automatic refresh result this session"
        self.accessibilityValue = accessibilityValue
    }
}

struct DailyRefreshRunStatusView: View {
    let activeRun: HeadlessRefreshActiveSnapshot?
    let latestRun: HeadlessRefreshRunSummary?

    var body: some View {
        if let presentation = DailyRefreshRunStatusPresentation(
            activeRun: activeRun,
            latestRun: latestRun
        ) {
            if presentation.isActive {
                ActiveStatus(presentation: presentation)
            } else {
                LatestResult(presentation: presentation)
            }
        }
    }
}

private extension DailyRefreshRunStatusView {
    struct ActiveStatus: View {
        let presentation: DailyRefreshRunStatusPresentation

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressIndicator(presentation: presentation)

                    Text(presentation.title)
                        .font(.callout)
                        .bold()
                }

                Text(presentation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct ProgressIndicator: View {
        let presentation: DailyRefreshRunStatusPresentation

        var body: some View {
            switch presentation.progress {
            case .some(.indeterminate):
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(presentation.accessibilityLabel)
                    .accessibilityValue(presentation.accessibilityValue)
            case .some(.determinate(let completed, let total)):
                ProgressView(value: Double(completed), total: Double(total))
                    .controlSize(.small)
                    .accessibilityLabel(presentation.accessibilityLabel)
                    .accessibilityValue(presentation.accessibilityValue)
            case .none:
                EmptyView()
            }
        }
    }

    struct LatestResult: View {
        let presentation: DailyRefreshRunStatusPresentation

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest result this session")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let systemImage = presentation.systemImage {
                    Label(presentation.title, systemImage: systemImage)
                        .font(.callout)
                        .bold()
                }

                Text(presentation.detail)
                    .font(.callout)

                if let finishedAt = presentation.finishedAt {
                    Text("Finished \(finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let facts = presentation.facts {
                    Text(facts)
                        .font(.callout)
                        .monospacedDigit()
                }

                if let issueMessage = presentation.issueMessage {
                    Label(issueMessage, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
        }
    }
}
