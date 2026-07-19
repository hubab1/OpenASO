import Foundation

struct KeywordMarketInsightsPresentation: Equatable, Sendable {
    struct KeywordRow: Equatable, Identifiable, Sendable {
        let insight: KeywordMarketInsight
        let markets: [MarketRow]
        let status: Status

        var id: String { insight.id }
        var keyword: String { insight.keyword }
        var platform: AppPlatform { insight.platform }
        var requestedMarketCount: Int { insight.summary.requestedMarketCount }
        var availableEvidenceCount: Int {
            insight.summary.availableRankingEvidenceCount
        }
        var freshRankedMarketCount: Int { insight.summary.freshRankedMarketCount }
        var bestMarket: KeywordMarketInsightRankSummary? {
            insight.summary.bestMarket
        }
        var worstMarket: KeywordMarketInsightRankSummary? {
            insight.summary.worstMarket
        }
        var averageRank: Double? { insight.summary.averageRank }
        var rankSpread: Int? { insight.summary.rankSpread }

        init(insight: KeywordMarketInsight) {
            self.insight = insight
            self.markets = insight.markets.map(MarketRow.init)
            self.status = Status.summary(for: insight)
        }
    }

    struct MarketRow: Equatable, Identifiable, Sendable {
        let market: KeywordMarketInsightMarket
        let status: Status
        let difficulty: Difficulty?

        var id: String { market.id }
        var storefront: String { market.storefront.uppercased() }
        var rank: Int? { market.rankingEvidence?.rank }
        var rankingSource: RankingSource? { market.rankingEvidence?.source }
        var rankingSearchedAt: Date? { market.rankingEvidence?.searchedAt }
        var resultCount: Int? { market.rankingEvidence?.resultCount }
        var failure: KeywordMarketInsightRankingFailure? { market.rankingFailure }
        var hasCachedEvidenceAfterFailure: Bool {
            market.state == .failedWithCachedEvidence
        }
        var requiresUnconfirmedEvidenceNotice: Bool {
            market.state == .unavailable
        }
        var isStale: Bool { market.isStale }

        init(market: KeywordMarketInsightMarket) {
            self.market = market
            self.status = Status(marketState: market.state)
            self.difficulty = market.estimatedDifficulty.map(Difficulty.init)
        }
    }

    struct Difficulty: Equatable, Sendable {
        let state: String
        let score: Int?
        let confidenceScore: Int?
        let confidence: String?
        let unavailableReason: String?
        let estimationSource: String
        let algorithmIdentifier: String
        let algorithmVersion: Int
        let rankingSource: String
        let rankingFetchedAt: Date
        let computedAt: Date
        let isStale: Bool

        init(difficulty: KeywordMarketInsightDifficulty) {
            self.state = difficulty.state
            self.score = difficulty.score
            self.confidenceScore = difficulty.confidenceScore
            self.confidence = difficulty.confidence
            self.unavailableReason = difficulty.unavailableReason
            self.estimationSource = difficulty.estimationSource
            self.algorithmIdentifier = difficulty.algorithmIdentifier
            self.algorithmVersion = difficulty.algorithmVersion
            self.rankingSource = difficulty.rankingSource
            self.rankingFetchedAt = difficulty.rankingFetchedAt
            self.computedAt = difficulty.computedAt
            self.isStale = difficulty.isStale
        }

        var summary: String {
            if state == EstimatedKeywordDifficultyState.estimated.rawValue,
               let score,
               let confidence {
                return "\(score) out of 100 · \(confidence.capitalized) confidence"
            }
            if state == EstimatedKeywordDifficultyState.unavailable.rawValue {
                return "Unavailable · \(unavailableReasonDisplayName)"
            }
            return "Unsupported saved estimate"
        }

        var unavailableReasonDisplayName: String {
            switch unavailableReason.flatMap(
                EstimatedKeywordDifficultyUnavailableReason.init(rawValue:)
            ) {
            case .emptyKeyword:
                "Empty keyword"
            case .insufficientResults:
                "Not enough ranking results"
            case .insufficientRatingEvidence:
                "Not enough rating evidence"
            case nil:
                "Unknown reason"
            }
        }

        var estimationSourceDisplayName: String {
            switch EstimatedKeywordDifficultySource(rawValue: estimationSource) {
            case .topResultsHeuristic:
                "Top-results heuristic"
            case nil:
                "Unsupported source"
            }
        }

        var rankingSourceDisplayName: String {
            RankingSource(rawValue: rankingSource)?.displayName
                ?? "Unsupported source"
        }
    }

    struct Status: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case current
            case incomplete
            case failed
            case unavailable
        }

        let title: String
        let systemImage: String
        let kind: Kind

        init(marketState: KeywordMarketInsightState) {
            switch marketState {
            case .ranked:
                self.init(title: "Ranked", systemImage: "checkmark.circle", kind: .current)
            case .notRanked:
                self.init(title: "Not ranked", systemImage: "minus.circle", kind: .current)
            case .notTracked:
                self.init(title: "Not tracked", systemImage: "circle.dashed", kind: .incomplete)
            case .neverRefreshed:
                self.init(title: "Never refreshed", systemImage: "clock", kind: .incomplete)
            case .failedWithCachedEvidence:
                self.init(title: "Refresh failed · cached", systemImage: "exclamationmark.arrow.circlepath", kind: .failed)
            case .failedWithoutEvidence:
                self.init(title: "Refresh failed", systemImage: "exclamationmark.triangle", kind: .failed)
            case .unavailable:
                self.init(title: "Unavailable", systemImage: "questionmark.circle", kind: .unavailable)
            }
        }

        static func summary(for insight: KeywordMarketInsight) -> Status {
            if insight.summary.failedWithCachedEvidenceMarketCount > 0
                || insight.summary.failedWithoutEvidenceMarketCount > 0 {
                return Status(
                    title: "Refresh issues",
                    systemImage: "exclamationmark.triangle",
                    kind: .failed
                )
            }
            if insight.summary.unavailableMarketCount > 0 {
                return Status(
                    title: "Evidence unavailable",
                    systemImage: "questionmark.circle",
                    kind: .unavailable
                )
            }
            if insight.isPartial {
                return Status(
                    title: "Partial",
                    systemImage: "circle.lefthalf.filled",
                    kind: .incomplete
                )
            }
            return Status(
                title: "Current",
                systemImage: "checkmark.circle",
                kind: .current
            )
        }

        private init(title: String, systemImage: String, kind: Kind) {
            self.title = title
            self.systemImage = systemImage
            self.kind = kind
        }
    }

    let rows: [KeywordRow]

    init(items: [KeywordMarketInsight]) {
        self.rows = items.map(KeywordRow.init)
    }

    static func partialReasonTitle(
        _ reason: KeywordMarketInsightsPartialReason
    ) -> String {
        switch reason {
        case .notTracked:
            "Some requested countries are not tracked."
        case .neverRefreshed:
            "Some tracked keywords have never been refreshed."
        case .rankingRefreshFailed:
            "Some ranking refreshes failed; cached evidence is identified where available."
        case .staleRankingEvidence:
            "Some ranking evidence is at least 24 hours old."
        case .snapshotScanCapped:
            "The bounded ranking-history scan could not prove complete coverage."
        case .statusScanCapped:
            "The bounded refresh-status scan could not prove complete coverage."
        }
    }

    static func keywordCountDescription(_ count: Int) -> String {
        "\(count) \(count == 1 ? "keyword" : "keywords")"
    }

    static func countryRowCountDescription(_ count: Int) -> String {
        "\(count) \(count == 1 ? "country row" : "country rows")"
    }

    static func coverageDescription(available: Int, requested: Int) -> String {
        "\(available) of \(requested) \(requested == 1 ? "country" : "countries")"
    }

    static func coverageAccessibilityDescription(
        available: Int,
        requested: Int
    ) -> String {
        let verb = requested == 1 ? "has" : "have"
        return "\(coverageDescription(available: available, requested: requested)) \(verb) ranking evidence"
    }

    static func staleResultDescription(_ count: Int) -> String {
        let subject = count == 1 ? "stale country result is" : "stale country results are"
        return "\(count) \(subject) labeled in the details."
    }
}
