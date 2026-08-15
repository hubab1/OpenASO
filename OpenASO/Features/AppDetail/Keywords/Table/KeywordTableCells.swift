import SwiftData
import SwiftUI

struct KeywordCell: View {
    let row: KeywordWorkspaceRow

    var body: some View {
        Text(row.track.term)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
    }
}

struct KeywordLastUpdatedCell: View {
    let row: KeywordWorkspaceRow

    var body: some View {
        Group {
            if let date = row.latestSnapshot?.searchedAt {
                Text(Self.lastUpdatedText(for: date))
                    .monospacedDigit()
            } else {
                Text("Not updated")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, alignment: .leading)
    }

    static func lastUpdatedText(for date: Date, now: Date = .now) -> String {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(date)))

        if elapsedSeconds < 60 {
            return elapsedSeconds <= 5 ? "Just now" : "\(elapsedSeconds)s ago"
        }

        let elapsedMinutes = elapsedSeconds / 60
        if elapsedMinutes < 60 {
            return "\(elapsedMinutes)m ago"
        }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            return "\(elapsedHours)h ago"
        }

        let elapsedDays = elapsedHours / 24
        if elapsedDays < 7 {
            return "\(elapsedDays)d ago"
        }

        let elapsedWeeks = elapsedDays / 7
        if elapsedWeeks < 5 {
            return "\(elapsedWeeks)w ago"
        }

        let elapsedMonths = elapsedDays / 30
        if elapsedMonths < 12 {
            return "\(elapsedMonths)mo ago"
        }

        let elapsedYears = elapsedDays / 365
        return "\(elapsedYears)y ago"
    }
}

struct KeywordStoreCell: View {
    let row: KeywordWorkspaceRow

    var body: some View {
        HStack(spacing: 6) {
            if let flagEmoji = row.storefront?.flagEmoji, !flagEmoji.isEmpty {
                Text(flagEmoji)
            }

            Text(storefrontName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
    }

    private var storefrontName: String {
        let code = row.track.storefront.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if let name = row.storefront?.name, !name.isEmpty {
            return name
        }

        return Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

struct KeywordPopularityCell: View {
    let row: KeywordWorkspaceRow
    let requiresAppleAdsReconnect: Bool
    let openAppleAdsSettings: () -> Void

    @State private var isShowingIndicatorPopover = false

    init(
        row: KeywordWorkspaceRow,
        requiresAppleAdsReconnect: Bool = false,
        openAppleAdsSettings: @escaping () -> Void
    ) {
        self.row = row
        self.requiresAppleAdsReconnect = requiresAppleAdsReconnect
        self.openAppleAdsSettings = openAppleAdsSettings
    }

    var body: some View {
        HStack(spacing: 4) {
            MetricBarView(
                value: row.displayedPopularityScore,
                maxValue: 100,
                colorScale: .lowRedHighGreen,
                placeholder: "-"
            )

            if indicatorState.isVisible {
                Button {
                    isShowingIndicatorPopover.toggle()
                } label: {
                    Image(systemName: indicatorSystemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(indicatorTint)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(indicatorHelp)
                .accessibilityLabel(indicatorHelp)
                .popover(isPresented: $isShowingIndicatorPopover, arrowEdge: .bottom) {
                    KeywordPopularityIndicatorPopover(
                        state: indicatorState,
                        openAppleAdsSettings: {
                            isShowingIndicatorPopover = false
                            openAppleAdsSettings()
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var indicatorState: KeywordPopularityIndicatorState {
        row.popularityIndicatorState(requiresAppleAdsReconnect: requiresAppleAdsReconnect)
    }

    private var indicatorSystemImage: String {
        switch indicatorState {
        case .none:
            return "circle"
        case .stale:
            return "clock.badge.exclamationmark"
        case .reconnectRequired:
            return "arrow.clockwise.circle.fill"
        case .needsSetup:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "exclamationmark.circle"
        }
    }

    private var indicatorTint: Color {
        switch indicatorState {
        case .none:
            return .secondary
        case .stale:
            return .orange
        case .reconnectRequired, .needsSetup:
            return .red
        case .unavailable:
            return .secondary
        }
    }

    private var indicatorHelp: String {
        switch indicatorState {
        case .none:
            return "Popularity is up to date"
        case .stale:
            return "Popularity is stale"
        case .reconnectRequired:
            return "Apple Ads reconnect required"
        case .needsSetup:
            return "Apple Ads setup required"
        case .unavailable:
            return "Apple Ads popularity unavailable"
        }
    }
}

struct KeywordPositionCell: View {
    let row: KeywordWorkspaceRow

    var body: some View {
        HStack(spacing: 2) {
            RankingPositionBadge(rank: row.currentRank, hasSnapshot: row.latestSnapshot != nil)

            Text(row.positionLabelText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(row.positionLabelStyle)
                .frame(width: 30, alignment: .leading)
        }
        .frame(width: 58, alignment: .leading)
    }
}

struct KeywordTrendCell: View {
    let row: KeywordWorkspaceRow

    var body: some View {
        HStack(spacing: 6) {
            Text(row.trendDeltaText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(row.trendColor)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 46, alignment: .trailing)

            KeywordTrendSparklineView(points: row.trendPoints, color: row.trendColor)
                .frame(width: 58, height: 22)
        }
        .padding(.vertical, 3)
    }
}

struct AppsInRankingButton: View {
    let row: KeywordWorkspaceRow
    let trackedAppStoreID: Int64
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore
    let presentRanking: (KeywordWorkspaceRow) -> Void

    var body: some View {
        Button(action: showRanking) {
            AppsInRankingCell(
                row: row,
                trackedAppStoreID: trackedAppStoreID,
                modelContext: modelContext,
                appCatalogService: appCatalogService,
                appIconStore: appIconStore
            )
        }
        .buttonStyle(.plain)
        .help("Show ranking apps")
        .disabled(row.latestSnapshot == nil)
    }

    func showRanking() {
        presentRanking(row)
    }
}

struct AppsInRankingCell: View {
    let row: KeywordWorkspaceRow
    let trackedAppStoreID: Int64
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore

    var body: some View {
        HStack(spacing: 5) {
            if row.rankingApps.isEmpty {
                Text("-")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(row.rankingApps) { result in
                    let isTrackedApp = result.appStoreID == trackedAppStoreID

                    AppIconImageView(
                        appStoreID: result.appStoreID,
                        storefrontCode: row.track.storefront,
                        size: 24,
                        cornerRadius: 6,
                        modelContext: modelContext,
                        appCatalogService: appCatalogService,
                        appIconStore: appIconStore
                    )
                    .background {
                        if isTrackedApp {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.18))
                                .padding(-3)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isTrackedApp ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    )
                    .shadow(color: isTrackedApp ? Color.accentColor.opacity(0.35) : .clear, radius: 4)
                }

                if let remainingRankingAppCount = row.remainingRankingAppCount, remainingRankingAppCount > 0 {
                    Text("+\(remainingRankingAppCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KeywordNotesCell: View {
    let row: KeywordWorkspaceRow
    let editNotes: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: editNotes) {
            HStack(spacing: 6) {
                if row.track.notes.isEmpty {
                    if isHovered {
                        Text("Add Notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "note.text")
                        .foregroundStyle(.secondary)

                    Text(row.track.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .help("Edit notes")
        .onHover { isHovered = $0 }
    }
}

struct KeywordStatusCell: View {
    let row: KeywordWorkspaceRow
    let showAppleAdsSettings: () -> Void

    @State private var isHovered = false

    var body: some View {
        if let statusMessage = row.statusMessage, !statusMessage.isEmpty {
            if statusMessage.hasPrefix("Popularity unavailable.") {
                statusContent(statusMessage, isInteractive: false)
            } else if statusMessage.hasPrefix("Popularity failed to fetch.") {
                Button(action: showAppleAdsSettings) {
                    statusContent(statusMessage, isInteractive: true)
                }
                .buttonStyle(.plain)
                .help("Open Apple Ads settings")
                .onHover { isHovered = $0 }
            } else {
                statusContent(statusMessage, isInteractive: false)
            }
        } else {
            Text("-")
                .foregroundStyle(.secondary)
        }
    }

    func statusContent(_ statusMessage: String, isInteractive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isInteractive && isHovered ? Color.red.opacity(0.12) : Color.clear)
        }
    }
}

private struct KeywordPopularityIndicatorPopover: View {
    let state: KeywordPopularityIndicatorState
    let openAppleAdsSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let detailMessage {
                Text(detailMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsSettingsButton {
                Button(action: openAppleAdsSettings) {
                    Label("Open Apple Ads Settings", systemImage: "gearshape")
                }
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var detailMessage: String? {
        switch state {
        case .reconnectRequired(let message), .needsSetup(let message), .unavailable(let message):
            return message
        case .none, .stale:
            return nil
        }
    }

    private var showsSettingsButton: Bool {
        switch state {
        case .stale, .reconnectRequired, .needsSetup:
            return true
        case .none, .unavailable:
            return false
        }
    }

    private var title: String {
        switch state {
        case .none:
            return "Popularity"
        case .stale:
            return "Popularity Needs Refresh"
        case .reconnectRequired:
            return "Apple Ads Reconnect Required"
        case .needsSetup:
            return "Apple Ads Setup Required"
        case .unavailable:
            return "Popularity Unavailable"
        }
    }

    private var message: String {
        switch state {
        case .none:
            return "Popularity is up to date."
        case .stale(let lastUpdatedAt):
            return "Popularity was last updated on \(lastUpdatedAt.formatted(date: .abbreviated, time: .shortened)). Refresh your Apple Ads web session so OpenASO can update this value."
        case .reconnectRequired:
            return "Refresh your Apple Ads session before requesting new popularity data. Existing cached values remain available."
        case .needsSetup:
            return "Popularity could not be fetched for this keyword. Connect or refresh Apple Ads so OpenASO can detect a linked app automatically."
        case .unavailable:
            return "Apple Ads keyword popularity is not available for this keyword's storefront."
        }
    }

    private var systemImage: String {
        switch state {
        case .none:
            return "checkmark.circle.fill"
        case .stale:
            return "clock.badge.exclamationmark"
        case .reconnectRequired:
            return "arrow.clockwise.circle.fill"
        case .needsSetup:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .none:
            return .green
        case .stale:
            return .orange
        case .reconnectRequired, .needsSetup:
            return .red
        case .unavailable:
            return .secondary
        }
    }
}

#Preview("Keyword Cells") {
    KeywordTableCellsPreview()
}
