import SwiftData
import SwiftUI

// Shows, for every tracked keyword, where the app currently ranks best and
// worst across all tracked markets.
struct KeywordMarketInsightsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services

    let trackedApp: TrackedApp

    @Query private var tracks: [TrackedAppKeyword]

    @State private var rows: [KeywordMarketInsightRow] = []
    @State private var searchText = ""
    @State private var sortOrder = [
        KeyPathComparator(\KeywordMarketInsightRow.bestRankSortValue)
    ]

    init(trackedApp: TrackedApp) {
        self.trackedApp = trackedApp

        let appStoreID = trackedApp.appStoreID
        _tracks = Query(
            filter: #Predicate<TrackedAppKeyword> { track in
                track.appStoreID == appStoreID
            },
            sort: [
                SortDescriptor(\TrackedAppKeyword.term, order: .forward),
                SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
            ]
        )
    }

    private var filteredRows: [KeywordMarketInsightRow] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = normalizedSearch.isEmpty
            ? rows
            : rows.filter { $0.keyword.localizedCaseInsensitiveContains(normalizedSearch) }
        return matching.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Market Insights")
                        .font(.title2)
                        .bold()
                    Text("Where \(trackedApp.name) ranks highest and lowest per keyword across all tracked markets.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            if rows.isEmpty {
                ContentUnavailableView(
                    "No Ranked Keywords Yet",
                    systemImage: "globe",
                    description: Text("Refresh keywords to collect rankings across markets first.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredRows, sortOrder: $sortOrder) {
                    TableColumn("Keyword", value: \.keywordSortValue) { row in
                        Text(row.keyword)
                            .font(.body.weight(.medium))
                    }
                    .width(min: 160, ideal: 200)

                    TableColumn("Device", value: \.platformSortValue) { row in
                        Text(row.platformDisplayName)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 70, max: 90)

                    TableColumn("Best Market", value: \.bestRankSortValue) { row in
                        KeywordMarketRankCell(market: row.bestMarket, style: .best)
                    }
                    .width(min: 170, ideal: 210)

                    TableColumn("Worst Market", value: \.worstRankSortValue) { row in
                        KeywordMarketRankCell(market: row.worstMarket, style: .worst)
                    }
                    .width(min: 170, ideal: 210)

                    TableColumn("Best–Worst Spread", value: \.spreadSortValue) { row in
                        Text(row.spreadText)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 110, ideal: 130, max: 150)

                    TableColumn("Avg. Rank", value: \.averageRankSortValue) { row in
                        Text(row.averageRankText)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 80, ideal: 90, max: 110)

                    TableColumn("Ranked Markets", value: \.rankedCountSortValue) { row in
                        Text("\(row.rankedMarketCount.formatted()) / \(row.trackedMarketCount.formatted())")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 110, ideal: 120, max: 140)
                }
            }

            Divider()

            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter keywords", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 220)
                }
                Spacer()
                Text("\(filteredRows.count.formatted()) keywords across \(trackedMarketCount.formatted()) markets")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 1_060, idealWidth: 1_180, minHeight: 640, idealHeight: 820)
        .task(id: trackReloadSignature) {
            rebuildRows()
        }
    }

    private var trackedMarketCount: Int {
        Set(tracks.map(\.storefront)).count
    }

    private var trackReloadSignature: Int {
        var hasher = Hasher()
        hasher.combine(services.backgroundModelStoreRevision)
        hasher.combine(tracks.count)
        for track in tracks {
            hasher.combine(track.identityKey)
            hasher.combine(track.lastRefreshAt)
        }
        return hasher.finalize()
    }

    private func rebuildRows() {
        let storefrontTitles = storefrontTitleLookup
        let grouped = Dictionary(grouping: tracks) { track in
            [track.term.normalizedKeywordKey, track.platformRaw].joined(separator: "::")
        }

        rows = grouped.values.compactMap { group -> KeywordMarketInsightRow? in
            guard let sample = group.first else { return nil }

            let markets: [KeywordMarketInsightRow.Market] = group.map { track in
                let latest = track.latestSnapshot
                return KeywordMarketInsightRow.Market(
                    storefront: track.storefront,
                    title: storefrontTitles[track.storefront] ?? track.storefront.uppercased(),
                    rank: latest?.rank,
                    searchedAt: latest?.searchedAt ?? track.lastRefreshAt
                )
            }
            let ranked = markets
                .filter { $0.rank != nil }
                .sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }

            let rankValues = ranked.compactMap(\.rank)
            return KeywordMarketInsightRow(
                keyword: sample.term,
                platformDisplayName: sample.platform.displayName,
                platformRaw: sample.platformRaw,
                bestMarket: ranked.first,
                worstMarket: ranked.last,
                averageRank: rankValues.isEmpty
                    ? nil
                    : Double(rankValues.reduce(0, +)) / Double(rankValues.count),
                rankedMarketCount: ranked.count,
                trackedMarketCount: markets.count
            )
        }
    }

    private var storefrontTitleLookup: [String: String] {
        let storefronts = (try? services.storefrontCatalog.bundledStorefronts()) ?? []
        return Dictionary(uniqueKeysWithValues: storefronts.map {
            ($0.code.lowercased(), "\($0.flagEmoji) \($0.name)")
        })
    }
}

struct KeywordMarketInsightRow: Identifiable {
    struct Market {
        let storefront: String
        let title: String
        let rank: Int?
        let searchedAt: Date?
    }

    let keyword: String
    let platformDisplayName: String
    let platformRaw: String
    let bestMarket: Market?
    let worstMarket: Market?
    let averageRank: Double?
    let rankedMarketCount: Int
    let trackedMarketCount: Int

    var id: String { [keyword.lowercased(), platformRaw].joined(separator: "::") }

    var keywordSortValue: String { keyword.localizedLowercase }
    var platformSortValue: String { platformDisplayName }
    var bestRankSortValue: Int { bestMarket?.rank ?? .max }
    var worstRankSortValue: Int { worstMarket?.rank ?? .max }
    var averageRankSortValue: Double { averageRank ?? .greatestFiniteMagnitude }
    var rankedCountSortValue: Int { rankedMarketCount }
    var spreadSortValue: Int {
        guard let best = bestMarket?.rank, let worst = worstMarket?.rank else { return .max }
        return worst - best
    }

    var spreadText: String {
        guard let best = bestMarket?.rank, let worst = worstMarket?.rank else { return "-" }
        guard worst > best else { return "0" }
        return (worst - best).formatted()
    }

    var averageRankText: String {
        guard let averageRank else { return "-" }
        return averageRank.formatted(.number.precision(.fractionLength(0...1)))
    }
}

private struct KeywordMarketRankCell: View {
    enum Style {
        case best
        case worst
    }

    let market: KeywordMarketInsightRow.Market?
    let style: Style

    var body: some View {
        if let market, let rank = market.rank {
            HStack(spacing: 6) {
                Text("#\(rank)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(rankColor(rank))
                    .frame(width: 46, alignment: .trailing)
                Text(market.title)
                    .lineLimit(1)
            }
        } else {
            Text("Not ranked")
                .foregroundStyle(.secondary)
        }
    }

    private func rankColor(_ rank: Int) -> Color {
        switch style {
        case .best:
            if rank <= 10 { return .green }
            if rank <= 50 { return .primary }
            return .secondary
        case .worst:
            if rank > 100 { return .orange }
            return .secondary
        }
    }
}
