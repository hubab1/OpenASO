import Foundation
import Testing
@testable import OpenASO

struct KeywordMarketInsightsPresentationTests {
    @Test
    func preservesSevenStatesAndOrthogonalEvidenceDetails() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let states = KeywordMarketInsightState.allCases
        let markets = states.enumerated().map { index, state in
            makeMarket(
                storefront: "s\(index)",
                state: state,
                date: date,
                isStale: state == .failedWithCachedEvidence
            )
        }
        let insight = makeInsight(markets: markets)
        let row = KeywordMarketInsightsPresentation(items: [insight]).rows[0]

        #expect(row.markets.map(\.market.state) == states)
        #expect(row.markets.map(\.status.title) == [
            "Not tracked",
            "Never refreshed",
            "Ranked",
            "Not ranked",
            "Refresh failed · cached",
            "Refresh failed",
            "Unavailable"
        ])
        let cached = row.markets[4]
        #expect(cached.hasCachedEvidenceAfterFailure)
        #expect(cached.rank == 12)
        #expect(cached.rankingSource == .appStoreWeb)
        #expect(cached.rankingSearchedAt == date)
        #expect(cached.resultCount == 300)
        #expect(cached.failure?.message == "Provider timed out")
        #expect(cached.isStale)
        #expect(cached.difficulty?.summary == "64 out of 100 · High confidence")
        #expect(cached.difficulty?.algorithmIdentifier == "top10-authority")
        #expect(cached.difficulty?.algorithmVersion == 2)
        #expect(cached.difficulty?.estimationSourceDisplayName == "Top-results heuristic")
        #expect(cached.difficulty?.rankingSourceDisplayName == "App Store Web")
        #expect(row.status.kind == .failed)
    }

    @Test
    func partialReasonsHaveSpecificActionableLabels() {
        let labels = KeywordMarketInsightsPartialReason.allCases.map(
            KeywordMarketInsightsPresentation.partialReasonTitle
        )

        #expect(labels.count == KeywordMarketInsightsPartialReason.allCases.count)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(labels[3].contains("24 hours"))
    }

    @Test
    func summaryDistinguishesUnavailablePartialAndCurrent() {
        let unavailable = KeywordMarketInsight(
            keyword: "unavailable",
            normalizedKeyword: "unavailable",
            platform: .iphone,
            markets: [],
            summary: summary(unavailableCount: 1),
            isPartial: true,
            partialReasons: [.statusScanCapped]
        )
        let partial = KeywordMarketInsight(
            keyword: "partial",
            normalizedKeyword: "partial",
            platform: .iphone,
            markets: [],
            summary: summary(),
            isPartial: true,
            partialReasons: [.notTracked]
        )
        let current = KeywordMarketInsight(
            keyword: "current",
            normalizedKeyword: "current",
            platform: .iphone,
            markets: [],
            summary: summary(),
            isPartial: false,
            partialReasons: []
        )

        let rows = KeywordMarketInsightsPresentation(
            items: [unavailable, partial, current]
        ).rows
        #expect(rows.map(\.status.kind) == [.unavailable, .incomplete, .current])
    }

    @Test
    func unavailableStateRetainsSavedRankingEvidence() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let market = KeywordMarketInsightMarket(
            storefront: "us",
            trackIdentityKey: "track-us",
            state: .unavailable,
            rankingEvidence: KeywordMarketInsightRankingEvidence(
                rank: 21,
                searchedAt: date,
                source: .iTunesFallback,
                resultCount: 200,
                snapshotKey: "snapshot-us"
            ),
            rankingFailure: nil,
            estimatedDifficulty: nil,
            isStale: false,
            isPartial: true
        )

        let row = KeywordMarketInsightsPresentation.MarketRow(market: market)
        #expect(row.status.kind == .unavailable)
        #expect(row.rank == 21)
        #expect(row.rankingSource == .iTunesFallback)
        #expect(row.rankingSearchedAt == date)
        #expect(row.resultCount == 200)
        #expect(row.requiresUnconfirmedEvidenceNotice)
    }

    @Test
    func countDescriptionsUseCorrectVisibleAndAccessibilityGrammar() {
        #expect(KeywordMarketInsightsPresentation.keywordCountDescription(1) == "1 keyword")
        #expect(KeywordMarketInsightsPresentation.keywordCountDescription(2) == "2 keywords")
        #expect(
            KeywordMarketInsightsPresentation.countryRowCountDescription(1)
                == "1 country row"
        )
        #expect(
            KeywordMarketInsightsPresentation.countryRowCountDescription(2)
                == "2 country rows"
        )
        #expect(
            KeywordMarketInsightsPresentation.coverageDescription(
                available: 1,
                requested: 1
            ) == "1 of 1 country"
        )
        #expect(
            KeywordMarketInsightsPresentation.coverageAccessibilityDescription(
                available: 1,
                requested: 1
            ) == "1 of 1 country has ranking evidence"
        )
        #expect(
            KeywordMarketInsightsPresentation.coverageAccessibilityDescription(
                available: 1,
                requested: 2
            ) == "1 of 2 countries have ranking evidence"
        )
        #expect(
            KeywordMarketInsightsPresentation.staleResultDescription(1)
                == "1 stale country result is labeled in the details."
        )
        #expect(
            KeywordMarketInsightsPresentation.staleResultDescription(2)
                == "2 stale country results are labeled in the details."
        )
    }

    private func makeInsight(
        markets: [KeywordMarketInsightMarket]
    ) -> KeywordMarketInsight {
        KeywordMarketInsight(
            keyword: "focus timer",
            normalizedKeyword: "focus timer",
            platform: .iphone,
            markets: markets,
            summary: KeywordMarketInsightSummary(
                requestedMarketCount: markets.count,
                trackedMarketCount: markets.count - 1,
                availableRankingEvidenceCount: 3,
                rankedEvidenceMarketCount: 2,
                freshRankedMarketCount: 1,
                notRankedMarketCount: 1,
                neverRefreshedMarketCount: 1,
                failedWithCachedEvidenceMarketCount: 1,
                failedWithoutEvidenceMarketCount: 1,
                notTrackedMarketCount: 1,
                unavailableMarketCount: 1,
                staleMarketCount: 1,
                bestMarket: nil,
                worstMarket: nil,
                averageRank: 12,
                rankSpread: 0
            ),
            isPartial: true,
            partialReasons: [.rankingRefreshFailed, .staleRankingEvidence]
        )
    }

    private func summary(
        unavailableCount: Int = 0
    ) -> KeywordMarketInsightSummary {
        KeywordMarketInsightSummary(
            requestedMarketCount: 0,
            trackedMarketCount: 0,
            availableRankingEvidenceCount: 0,
            rankedEvidenceMarketCount: 0,
            freshRankedMarketCount: 0,
            notRankedMarketCount: 0,
            neverRefreshedMarketCount: 0,
            failedWithCachedEvidenceMarketCount: 0,
            failedWithoutEvidenceMarketCount: 0,
            notTrackedMarketCount: 0,
            unavailableMarketCount: unavailableCount,
            staleMarketCount: 0,
            bestMarket: nil,
            worstMarket: nil,
            averageRank: nil,
            rankSpread: nil
        )
    }

    private func makeMarket(
        storefront: String,
        state: KeywordMarketInsightState,
        date: Date,
        isStale: Bool
    ) -> KeywordMarketInsightMarket {
        let hasEvidence = state == .ranked
            || state == .notRanked
            || state == .failedWithCachedEvidence
        let hasFailure = state == .failedWithCachedEvidence
            || state == .failedWithoutEvidence
        return KeywordMarketInsightMarket(
            storefront: storefront,
            trackIdentityKey: state == .notTracked ? nil : "track-\(storefront)",
            state: state,
            rankingEvidence: hasEvidence
                ? KeywordMarketInsightRankingEvidence(
                    rank: state == .notRanked ? nil : 12,
                    searchedAt: date,
                    source: .appStoreWeb,
                    resultCount: 300,
                    snapshotKey: "snapshot-\(storefront)"
                )
                : nil,
            rankingFailure: hasFailure
                ? KeywordMarketInsightRankingFailure(
                    message: "Provider timed out",
                    updatedAt: date.addingTimeInterval(60)
                )
                : nil,
            estimatedDifficulty: state == .failedWithCachedEvidence
                ? KeywordMarketInsightDifficulty(
                    state: EstimatedKeywordDifficultyState.estimated.rawValue,
                    score: 64,
                    confidenceScore: 82,
                    confidence: EstimatedKeywordDifficultyConfidence.high.rawValue,
                    unavailableReason: nil,
                    estimationSource: EstimatedKeywordDifficultySource.topResultsHeuristic.rawValue,
                    algorithmIdentifier: "top10-authority",
                    algorithmVersion: 2,
                    rankingSource: RankingSource.appStoreWeb.rawValue,
                    rankingFetchedAt: date,
                    computedAt: date.addingTimeInterval(2),
                    isStale: isStale
                )
                : nil,
            isStale: isStale,
            isPartial: state != .ranked && state != .notRanked || isStale
        )
    }
}
