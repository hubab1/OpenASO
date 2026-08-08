import SwiftData
import SwiftUI

struct ScreenshotDownloadStatusView: View {
    enum Placement {
        case sidebar
        case sheet
    }

    let progressStore: ScreenshotDownloadProgressStore
    let placement: Placement

    var body: some View {
        if let download = progressStore.activeDownload {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if download.phase == .running {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: download.phase == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(download.phase == .failed ? .orange : .green)
                    }

                    Text(download.phase.title)
                        .font(.caption.weight(.semibold))

                    Spacer(minLength: 8)

                    Text(download.summaryText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: download.progressValue, total: download.progressTotal)
                    .controlSize(.small)

                if let message = download.message?.nilIfEmptyForStatus {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, placement == .sidebar ? 12 : 10)
            .padding(.vertical, placement == .sidebar ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.quaternary)
            }
        }
    }
}

private extension String {
    var nilIfEmptyForStatus: String? {
        let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

extension String {
    func highlightingMatches(of keyword: String) -> AttributedString {
        var attributed = AttributedString(self)
        for match in keywordHighlightRanges(of: keyword) {
            if let lowerBound = AttributedString.Index(match.lowerBound, within: attributed),
               let upperBound = AttributedString.Index(match.upperBound, within: attributed) {
                attributed[lowerBound..<upperBound].backgroundColor = .yellow.opacity(0.35)
            }
        }

        return attributed
    }

    func keywordHighlightRanges(of keyword: String) -> [Range<String.Index>] {
        let phrase = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        ranges.append(contentsOf: wholePhraseRanges(matching: phrase))

        let words = phrase.keywordHighlightWords()
        for word in words {
            for variant in word.keywordHighlightWordVariants() {
                ranges.append(contentsOf: wholeWordRanges(matching: variant))
            }
        }

        return mergedHighlightRanges(ranges)
    }

    private func wholePhraseRanges(matching phrase: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let match = range(
                of: phrase,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<endIndex
              ) {
            ranges.append(match)
            searchStart = match.upperBound
        }
        return ranges
    }

    private func wholeWordRanges(matching word: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let match = range(
                of: word,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<endIndex
              ) {
            if isKeywordWordBoundary(match.lowerBound, direction: .before),
               isKeywordWordBoundary(match.upperBound, direction: .after) {
                ranges.append(match)
            }
            searchStart = match.upperBound
        }
        return ranges
    }

    private enum KeywordBoundaryDirection {
        case before
        case after
    }

    private func isKeywordWordBoundary(_ index: String.Index, direction: KeywordBoundaryDirection) -> Bool {
        switch direction {
        case .before:
            guard index > startIndex else { return true }
            return !self[self.index(before: index)].isLetterOrNumber
        case .after:
            guard index < endIndex else { return true }
            return !self[index].isLetterOrNumber
        }
    }

    private func mergedHighlightRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let sortedRanges = ranges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
        guard var current = sortedRanges.first else { return [] }

        var merged: [Range<String.Index>] = []
        for range in sortedRanges.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound..<Swift.max(current.upperBound, range.upperBound)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }
}

private extension String {
    func keywordHighlightWords() -> [String] {
        components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func keywordHighlightWordVariants() -> [String] {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var variants = [normalized]
        let lowercase = normalized.lowercased()

        if lowercase.count > 3 {
            if lowercase.hasSuffix("ies") {
                variants.append(String(normalized.dropLast(3)) + "y")
            } else if lowercase.hasSuffix("es"), lowercase.hasAnySuffix(["ches", "shes", "xes", "zes", "ses"]) {
                variants.append(String(normalized.dropLast(2)))
            } else if lowercase.hasSuffix("s"), !lowercase.hasSuffix("ss"), !lowercase.hasSuffix("us") {
                variants.append(String(normalized.dropLast()))
            }
        }

        if lowercase.count > 2, !lowercase.hasSuffix("s") {
            if lowercase.hasSuffix("y"), let previous = lowercase.dropLast().last, !previous.isVowel {
                variants.append(String(normalized.dropLast()) + "ies")
            } else if lowercase.hasAnySuffix(["ch", "sh", "x", "z", "s"]) {
                variants.append(normalized + "es")
            } else {
                variants.append(normalized + "s")
            }
        }

        return Array(Set(variants)).sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }
    }
}

private extension String {
    func hasAnySuffix(_ suffixes: [String]) -> Bool {
        suffixes.contains { hasSuffix($0) }
    }
}

private extension Character {
    var isVowel: Bool {
        guard let scalar = lowercased().unicodeScalars.first else { return false }
        return CharacterSet(charactersIn: "aeiou").contains(scalar)
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}

struct KeywordMetricsSnapshot: Equatable, Sendable {
    let popularityScore: Int?
    let difficultyScore: Int?
    let updatedAt: Date
    let notes: String?

    init(
        popularityScore: Int?,
        difficultyScore: Int?,
        updatedAt: Date,
        notes: String?
    ) {
        self.popularityScore = popularityScore
        self.difficultyScore = difficultyScore
        self.updatedAt = updatedAt
        self.notes = notes
    }

    init(_ metrics: KeywordDailyMetric) {
        self.init(
            popularityScore: metrics.popularityScore,
            difficultyScore: metrics.difficultyScore,
            updatedAt: metrics.updatedAt,
            notes: metrics.notes
        )
    }

    static func map(
        for queryKeys: [String],
        in modelContext: ModelContext
    ) throws -> [String: KeywordMetricsSnapshot] {
        guard !queryKeys.isEmpty else {
            return [:]
        }

        var snapshotsByQueryKey: [String: KeywordMetricsSnapshot] = [:]
        snapshotsByQueryKey.reserveCapacity(queryKeys.count)

        for queryKey in Set(queryKeys) {
            let targetQueryKey = queryKey
            var descriptor = FetchDescriptor<KeywordDailyMetric>(
                predicate: #Predicate { metrics in
                    metrics.queryKey == targetQueryKey
                }
            )
            descriptor.fetchLimit = 1

            if let metrics = try modelContext.fetch(descriptor).first {
                snapshotsByQueryKey[metrics.queryKey] = KeywordMetricsSnapshot(metrics)
            }
        }

        return snapshotsByQueryKey
    }
}

struct KeywordTrackSnapshot: Identifiable, Equatable, Hashable, Sendable {
    let identityKey: String
    let appStoreID: Int64
    let queryKey: String
    let term: String
    let storefront: String
    let platform: AppPlatform
    let rankingAppCount: Int?
    let lastRefreshAt: Date?
    let notes: String
    let statusMessage: String?
    let createdAt: Date

    init(
        identityKey: String,
        appStoreID: Int64,
        queryKey: String,
        term: String,
        storefront: String,
        platform: AppPlatform,
        rankingAppCount: Int?,
        lastRefreshAt: Date?,
        notes: String,
        statusMessage: String?,
        createdAt: Date
    ) {
        self.identityKey = identityKey
        self.appStoreID = appStoreID
        self.queryKey = queryKey
        self.term = term
        self.storefront = storefront
        self.platform = platform
        self.rankingAppCount = rankingAppCount
        self.lastRefreshAt = lastRefreshAt
        self.notes = notes
        self.statusMessage = statusMessage
        self.createdAt = createdAt
    }

    init(_ track: TrackedAppKeyword) {
        self.init(
            identityKey: track.identityKey,
            appStoreID: track.appStoreID,
            queryKey: track.queryKey,
            term: track.term,
            storefront: track.storefront,
            platform: track.platform,
            rankingAppCount: track.rankingAppCount,
            lastRefreshAt: track.lastRefreshAt,
            notes: track.notes,
            statusMessage: track.statusMessage,
            createdAt: track.createdAt
        )
    }

    var id: String { identityKey }
}

struct KeywordWorkspaceRow: Identifiable, Equatable, Sendable {
    static let popularityStaleInterval: TimeInterval = 60 * 60 * 24 * 7

    let track: KeywordTrackSnapshot
    let storefront: StorefrontDefinition?
    let metrics: KeywordMetricsSnapshot?
    let refreshStatus: KeywordRefreshStatusSnapshot
    let latestSnapshot: KeywordRankingCrawlSummary?
    let trendSnapshots: [KeywordRankingCrawlSummary]
    let trendPoints: [Int]
    let trendDelta: Int?
    let currentRank: Int?
    let rankingApps: [KeywordRankingAppSummary]
    let allRankingApps: [KeywordRankingAppSummary]

    init(
        track: KeywordTrackSnapshot,
        storefront: StorefrontDefinition?,
        metrics: KeywordMetricsSnapshot?,
        refreshStatus: KeywordRefreshStatusSnapshot = .empty,
        latestSnapshot: KeywordRankingCrawlSummary?,
        trendSnapshots: [KeywordRankingCrawlSummary],
        rankingApps: [KeywordRankingAppSummary],
        allRankingApps: [KeywordRankingAppSummary]? = nil
    ) {
        self.track = track
        self.storefront = storefront
        self.metrics = metrics
        self.refreshStatus = refreshStatus
        self.latestSnapshot = latestSnapshot
        self.currentRank = latestSnapshot?.rank
        let orderedTrendSnapshots = trendSnapshots.sorted { lhs, rhs in
            if lhs.searchedAt == rhs.searchedAt {
                return lhs.id < rhs.id
            }
            return lhs.searchedAt < rhs.searchedAt
        }
        self.trendSnapshots = orderedTrendSnapshots
        let trendPoints = orderedTrendSnapshots.compactMap(\.rank)
        self.trendPoints = trendPoints
        if let earliest = trendPoints.first, let latest = trendPoints.last, trendPoints.count > 1 {
            self.trendDelta = earliest - latest
        } else {
            self.trendDelta = nil
        }
        self.rankingApps = rankingApps
        self.allRankingApps = allRankingApps ?? rankingApps
    }

    init(
        track: TrackedAppKeyword,
        storefront: StorefrontDefinition?,
        metrics: KeywordMetricsSnapshot?,
        refreshStatus: KeywordRefreshStatusSnapshot = .empty,
        latestSnapshot: KeywordRankingCrawlSummary?,
        trendSnapshots: [KeywordRankingCrawlSummary],
        rankingApps: [KeywordRankingAppSummary],
        allRankingApps: [KeywordRankingAppSummary]? = nil
    ) {
        self.init(
            track: KeywordTrackSnapshot(track),
            storefront: storefront,
            metrics: metrics,
            refreshStatus: refreshStatus,
            latestSnapshot: latestSnapshot,
            trendSnapshots: trendSnapshots,
            rankingApps: rankingApps,
            allRankingApps: allRankingApps
        )
    }

    init(
        track: TrackedAppKeyword,
        storefront: StorefrontDefinition?,
        metrics: KeywordDailyMetric?,
        refreshStatus: KeywordRefreshStatusSnapshot = .empty,
        latestSnapshot: KeywordRankingCrawlSummary?,
        trendSnapshots: [KeywordRankingCrawlSummary],
        rankingApps: [KeywordRankingAppSummary],
        allRankingApps: [KeywordRankingAppSummary]? = nil
    ) {
        self.init(
            track: track,
            storefront: storefront,
            metrics: metrics.map(KeywordMetricsSnapshot.init),
            refreshStatus: refreshStatus,
            latestSnapshot: latestSnapshot,
            trendSnapshots: trendSnapshots,
            rankingApps: rankingApps,
            allRankingApps: allRankingApps
        )
    }

    init(
        track: TrackedAppKeyword,
        storefront: StorefrontDefinition?,
        metrics: KeywordDailyMetric?,
        refreshStatus: KeywordRefreshStatusSnapshot = .empty,
        latestSnapshot: TrackedKeywordDailyRanking?,
        trendSnapshots: [TrackedKeywordDailyRanking],
        rankingApps: [TrackedKeywordRankedResult]
    ) {
        self.init(
            track: track,
            storefront: storefront,
            metrics: metrics.map(KeywordMetricsSnapshot.init),
            refreshStatus: refreshStatus,
            latestSnapshot: latestSnapshot.map(KeywordRankingCrawlSummary.init),
            trendSnapshots: trendSnapshots.map(KeywordRankingCrawlSummary.init),
            rankingApps: rankingApps.map(KeywordRankingAppSummary.init),
            allRankingApps: rankingApps.map(KeywordRankingAppSummary.init)
        )
    }

    var id: String { track.identityKey }

    func updating(
        metrics: KeywordMetricsSnapshot?,
        refreshStatus: KeywordRefreshStatusSnapshot,
        latestSnapshot: KeywordRankingCrawlSummary?,
        trendSnapshots: [KeywordRankingCrawlSummary],
        rankingApps: [KeywordRankingAppSummary]
    ) -> Self {
        Self(
            track: track,
            storefront: storefront,
            metrics: metrics,
            refreshStatus: refreshStatus,
            latestSnapshot: latestSnapshot,
            trendSnapshots: trendSnapshots,
            rankingApps: rankingApps
        )
    }

    var keywordSortValue: String { track.term }

    var lastUpdatedSortValue: Date { latestSnapshot?.searchedAt ?? .distantPast }

    var storefrontSortValue: String {
        storefront?.name ?? track.storefront
    }

    var popularitySortValue: Int { metrics?.popularityScore ?? -1 }

    var positionSortValue: Int { currentRank ?? Int.max }

    var trendSortValue: Int { trendDelta ?? Int.min }

    var positionLabelText: String {
        if let currentRank {
            return "\(currentRank)"
        }

        return "-"
    }

    var positionLabelStyle: HierarchicalShapeStyle {
        currentRank == nil ? .secondary : .primary
    }

    var rankingAppCount: Int? {
        if let rankingAppCount = track.rankingAppCount {
            return rankingAppCount
        }

        if let resultCount = latestSnapshot?.resultCount {
            return resultCount
        }

        return nil
    }

    var remainingRankingAppCount: Int? {
        guard let rankingAppCount else { return nil }
        return max(0, rankingAppCount - rankingApps.count)
    }

    var trendDeltaText: String {
        guard let trendDelta else {
            return "-"
        }

        if trendDelta > 0 {
            return "+\(trendDelta)"
        }

        if trendDelta < 0 {
            return "\(trendDelta)"
        }

        return "±0"
    }

    var trendAccessibilityText: String {
        guard let trendDelta else {
            return "Not enough history to determine a ranking trend."
        }

        if trendDelta > 0 {
            let positionLabel = trendDelta == 1 ? "position" : "positions"
            return "Up \(trendDelta) \(positionLabel)."
        }

        if trendDelta < 0 {
            let amount = abs(trendDelta)
            let positionLabel = amount == 1 ? "position" : "positions"
            return "Down \(amount) \(positionLabel)."
        }

        return "Ranking unchanged."
    }

    var trendCellAccessibilityValue: String {
        let storefrontName = storefront?.name ?? track.storefront.uppercased()
        return "\(trendAccessibilityText) \(storefrontName), \(track.platform.displayName)."
    }

    var trendColor: Color {
        guard let trendDelta else {
            return .secondary
        }

        if trendDelta > 0 {
            return .green
        }

        if trendDelta < 0 {
            return .red
        }

        return .secondary
    }

    var statusMessage: String? {
        if let statusMessage = refreshStatus.displayMessage, !statusMessage.isEmpty {
            return statusMessage
        }

        if let statusMessage = track.statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }

        guard
            let notes = metrics?.notes,
            !notes.isEmpty,
            metrics?.popularityScore == nil,
            metrics?.difficultyScore == nil
        else {
            return nil
        }

        return "Popularity failed to fetch. \(notes)"
    }

    var popularityIndicatorState: KeywordPopularityIndicatorState {
        popularityIndicatorState(now: .now)
    }

    func popularityIndicatorState(
        now: Date = .now,
        requiresAppleAdsReconnect: Bool
    ) -> KeywordPopularityIndicatorState {
        popularityIndicatorState(now: now)
            .overridingForAppleAdsReconnectRequirement(requiresAppleAdsReconnect)
    }

    func popularityIndicatorState(now: Date) -> KeywordPopularityIndicatorState {
        if metrics?.popularityScore != nil {
            guard let updatedAt = metrics?.updatedAt,
                  now.timeIntervalSince(updatedAt) >= Self.popularityStaleInterval
            else {
                return .none
            }

            return .stale(lastUpdatedAt: updatedAt)
        }

        let popularityStatusMessage = refreshStatus.popularityMessage
            ?? track.statusMessage.flatMap { legacyStatusMessage in
                TrackedKeywordRefreshStatusStore.domain(forLegacyMessage: legacyStatusMessage) == .popularity
                    ? legacyStatusMessage
                    : nil
            }
            ?? statusMessage

        guard let popularityStatusMessage else {
            return .none
        }

        if popularityStatusMessage.hasPrefix("Popularity unavailable.") {
            return .unavailable(message: popularityStatusMessage)
        }

        if popularityStatusMessage.hasPrefix("Popularity failed to fetch.") {
            return .needsSetup(message: popularityStatusMessage)
        }

        return .none
    }
}

struct KeywordRankingCrawlSummary: Identifiable, Equatable, Sendable {
    let id: String
    let rank: Int?
    let searchedAt: Date
    let source: RankingSource
    let resultCount: Int
    let errorMessage: String?

    init(
        id: String,
        rank: Int?,
        searchedAt: Date,
        source: RankingSource,
        resultCount: Int,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.rank = rank
        self.searchedAt = searchedAt
        self.source = source
        self.resultCount = resultCount
        self.errorMessage = errorMessage
    }

    init(_ snapshot: TrackedKeywordDailyRanking) {
        self.init(
            id: snapshot.snapshotKey,
            rank: snapshot.rank,
            searchedAt: snapshot.searchedAt,
            source: snapshot.source,
            resultCount: snapshot.resultCount,
            errorMessage: snapshot.errorMessage
        )
    }

    init(crawl: KeywordRankingCrawl, rank: Int?, errorMessage: String? = nil) {
        self.init(
            id: crawl.observationKey,
            rank: rank,
            searchedAt: crawl.observedAt,
            source: crawl.source,
            resultCount: crawl.resultCount,
            errorMessage: errorMessage
        )
    }
}

struct KeywordRankingAppSummary: Identifiable, Equatable, Sendable {
    let id: Int64
    let position: Int
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?

    init(
        position: Int,
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String?,
        sellerName: String?
    ) {
        self.id = appStoreID
        self.position = position
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
    }

    init(_ result: TrackedKeywordRankedResult) {
        self.init(
            position: result.position,
            appStoreID: result.appStoreID,
            bundleID: result.bundleID,
            name: result.name,
            subtitle: result.subtitle,
            sellerName: result.sellerName
        )
    }

    init(_ ranking: KeywordAppRanking) {
        self.init(
            position: ranking.position,
            appStoreID: ranking.appStoreID,
            bundleID: ranking.bundleID,
            name: ranking.name,
            subtitle: ranking.subtitle,
            sellerName: ranking.sellerName
        )
    }
}

enum KeywordPopularityIndicatorState: Equatable {
    case none
    case stale(lastUpdatedAt: Date)
    case reconnectRequired(message: String)
    case needsSetup(message: String)
    case unavailable(message: String)

    static let reconnectRequiredDetail = "Apple Ads asked for sign-in again. Any cached popularity remains visible, but refresh the session before requesting an update."

    var isVisible: Bool {
        self != .none
    }

    func overridingForAppleAdsReconnectRequirement(_ isRequired: Bool) -> Self {
        guard isRequired else { return self }
        if case .unavailable = self {
            return self
        }
        return .reconnectRequired(message: Self.reconnectRequiredDetail)
    }
}

struct MetricBarView: View {
    let value: Int?
    let maxValue: Int
    let colorScale: MetricColorScale
    let placeholder: String

    let trackWidth: CGFloat = 48

    var body: some View {
        HStack(spacing: 2) {
            Text(value.map(String.init) ?? placeholder)
                .font(.subheadline.monospacedDigit())
                .frame(width: 22, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))

                if let value {
                    let normalizedValue = normalizedValue(value)
                    Capsule()
                        .fill(colorScale.color(for: normalizedValue))
                        .frame(width: trackWidth * normalizedValue)
                }
            }
            .frame(width: trackWidth, height: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.map { "\($0) out of \(maxValue)" } ?? "No value")
        }
    }

    func normalizedValue(_ value: Int) -> CGFloat {
        guard maxValue > 0 else { return 0 }
        return max(0, min(1, CGFloat(value) / CGFloat(maxValue)))
    }
}

enum MetricColorScale {
    case lowRedHighGreen
    case lowGreenHighRed

    func color(for normalizedValue: CGFloat) -> Color {
        let clampedValue = max(0, min(1, normalizedValue))
        let greenHue: CGFloat = 1.0 / 3.0
        let hue = switch self {
        case .lowRedHighGreen:
            greenHue * clampedValue
        case .lowGreenHighRed:
            greenHue * (1 - clampedValue)
        }

        return Color(hue: hue, saturation: 0.78, brightness: 0.82)
    }
}

struct RankingPositionBadge: View {
    let rank: Int?
    let hasSnapshot: Bool

    @ViewBuilder
    var body: some View {
        switch rank {
        case 1:
            RankingBadgeIcon(color: .medalGold)
        case 2:
            RankingBadgeIcon(color: .medalSilver)
        case 3:
            RankingBadgeIcon(color: .medalBronze)
        default:
            if hasSnapshot {
                RankingBadgeIcon(color: .secondary.opacity(0.55), systemImage: "number")
            } else {
                Color.clear
                    .frame(width: 22, height: 22)
            }
        }
    }
}

struct RankingBadgeIcon: View {
    let color: Color
    var systemImage = "medal.fill"

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
    }
}

extension Color {
    static let medalGold = Color(red: 0.83, green: 0.64, blue: 0.16)
    static let medalSilver = Color(red: 0.72, green: 0.72, blue: 0.70)
    static let medalBronze = Color(red: 0.72, green: 0.42, blue: 0.18)
}

#Preview("Keyword Table Support") {
    KeywordTableSupportPreview()
}
