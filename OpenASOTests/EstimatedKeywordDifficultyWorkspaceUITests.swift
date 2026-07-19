import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct EstimatedKeywordDifficultyWorkspaceUITests {
    @Test
    func defaultFilterPreservesEveryStateAndNarrowedFilterUsesOnlyEstimatedScore() {
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let missing = makeRow(
            term: "missing",
            appStoreID: 1,
            legacyDifficulty: 60,
            estimatedDifficulty: nil
        )
        let unavailable = makeRow(
            term: "unavailable",
            appStoreID: 2,
            legacyDifficulty: 60,
            estimatedDifficulty: summary(
                keyword: "unavailable",
                state: .unavailable,
                score: nil,
                confidenceScore: nil,
                confidence: nil,
                unavailableReason: .insufficientResults,
                rankingFetchedAt: fetchedAt
            )
        )
        let estimated = makeRow(
            term: "estimated",
            appStoreID: 3,
            legacyDifficulty: 5,
            estimatedDifficulty: summary(
                keyword: "estimated",
                state: .estimated,
                score: 60,
                confidenceScore: 80,
                confidence: .high,
                unavailableReason: nil,
                rankingFetchedAt: fetchedAt
            )
        )

        let defaultRows = KeywordWorkspaceProjection.filteredRows(
            [missing, unavailable, estimated],
            filters: filters(difficultyRange: MetricFilterRange.difficulty.defaultRange)
        )
        #expect(defaultRows.map { $0.track.term } == ["missing", "unavailable", "estimated"])

        let narrowedRows = KeywordWorkspaceProjection.filteredRows(
            [missing, unavailable, estimated],
            filters: filters(difficultyRange: 50 ... 70)
        )
        #expect(narrowedRows.map { $0.track.term } == ["estimated"])
        #expect(estimated.estimatedDifficultySortValue == 60)
        #expect(missing.estimatedDifficultySortValue == Int.max)
    }

    @Test
    func rowPresentationDistinguishesMissingFreshStaleAndUnavailable() {
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let estimated = summary(
            keyword: "focus",
            state: .estimated,
            score: 74,
            confidenceScore: 88,
            confidence: .high,
            unavailableReason: nil,
            rankingFetchedAt: fetchedAt
        )
        let unavailable = summary(
            keyword: "rare",
            state: .unavailable,
            score: nil,
            confidenceScore: nil,
            confidence: nil,
            unavailableReason: .insufficientRatingEvidence,
            rankingFetchedAt: fetchedAt
        )

        #expect(EstimatedKeywordDifficultyRowPresentation(
            summary: nil,
            asOf: fetchedAt
        ).state == .missing)
        #expect(EstimatedKeywordDifficultyRowPresentation(
            summary: estimated,
            asOf: fetchedAt.addingTimeInterval(
                EstimatedKeywordDifficultyFreshness.maximumAge - 1
            )
        ).state == .estimated(
            score: 74,
            confidenceScore: 88,
            confidence: .high,
            isStale: false
        ))
        #expect(EstimatedKeywordDifficultyRowPresentation(
            summary: estimated,
            asOf: fetchedAt.addingTimeInterval(
                EstimatedKeywordDifficultyFreshness.maximumAge
            )
        ).state == .estimated(
            score: 74,
            confidenceScore: 88,
            confidence: .high,
            isStale: true
        ))
        #expect(EstimatedKeywordDifficultyRowPresentation(
            summary: unavailable,
            asOf: fetchedAt
        ).state == .unavailable(
            reason: .insufficientRatingEvidence,
            isStale: false
        ))
    }

    @Test
    func legacyMetricsSnapshotMapLoadsMultipleQueryKeys() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let firstKey = KeywordQuery.makeQueryKey(
            term: "first",
            storefront: "us",
            platform: .iphone
        )
        let secondKey = KeywordQuery.makeQueryKey(
            term: "second",
            storefront: "gb",
            platform: .iphone
        )
        context.insert(KeywordDailyMetric(
            queryKey: firstKey,
            keyword: "first",
            storefront: "us",
            platform: .iphone,
            popularityScore: 11,
            difficultyScore: 91,
            source: .appleAdsPopularity
        ))
        context.insert(KeywordDailyMetric(
            queryKey: secondKey,
            keyword: "second",
            storefront: "gb",
            platform: .iphone,
            popularityScore: 22,
            difficultyScore: 82,
            source: .appleAdsPopularity
        ))
        try context.save()

        let snapshots = try KeywordMetricsSnapshot.map(
            for: [firstKey, secondKey, firstKey, "missing"],
            in: context
        )

        #expect(snapshots.count == 2)
        #expect(snapshots[firstKey]?.popularityScore == 11)
        #expect(snapshots[secondKey]?.popularityScore == 22)
    }

    private func filters(
        difficultyRange: ClosedRange<Double>
    ) -> KeywordWorkspaceProjection.Filters {
        KeywordWorkspaceProjection.Filters(
            searchText: "",
            popularityRange: MetricFilterRange.popularity.defaultRange,
            difficultyRange: difficultyRange,
            positionRange: MetricFilterRange.position.defaultRange,
            changeRange: MetricFilterRange.change.defaultRange,
            showsOnlyChangedKeywords: false
        )
    }

    private func makeRow(
        term: String,
        appStoreID: Int64,
        legacyDifficulty: Int?,
        estimatedDifficulty: EstimatedKeywordDifficultySummary?
    ) -> KeywordWorkspaceRow {
        let trackedApp = TrackedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.\(appStoreID)",
            name: "App \(appStoreID)",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = KeywordQuery(term: term, storefront: "us", platform: .iphone)
        let track = TrackedAppKeyword(
            term: term,
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query
        )
        return KeywordWorkspaceRow(
            track: track,
            storefront: nil,
            metrics: KeywordMetricsSnapshot(
                popularityScore: nil,
                difficultyScore: legacyDifficulty,
                updatedAt: .now,
                notes: nil
            ),
            estimatedDifficulty: estimatedDifficulty,
            latestSnapshot: nil,
            trendSnapshots: [],
            rankingApps: []
        )
    }

    private func summary(
        keyword: String,
        state: EstimatedKeywordDifficultyState,
        score: Int?,
        confidenceScore: Int?,
        confidence: EstimatedKeywordDifficultyConfidence?,
        unavailableReason: EstimatedKeywordDifficultyUnavailableReason?,
        rankingFetchedAt: Date
    ) -> EstimatedKeywordDifficultySummary {
        let queryKey = KeywordQuery.makeQueryKey(
            term: keyword,
            storefront: "us",
            platform: .iphone
        )
        return EstimatedKeywordDifficultySummary(
            queryKey: queryKey,
            calculationID: UUID(),
            keyword: keyword,
            storefront: "us",
            platformRaw: AppPlatform.iphone.rawValue,
            stateRaw: state.rawValue,
            score: score,
            confidenceScore: confidenceScore,
            confidenceRaw: confidence?.rawValue,
            unavailableReasonRaw: unavailableReason?.rawValue,
            estimationSourceRaw: EstimatedKeywordDifficultySource.topResultsHeuristic.rawValue,
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: 10,
            providerResultCount: 10,
            consideredResultCount: 10,
            ratedResultCount: 8,
            weightedRatingCoveragePercentage: 80,
            maximumRatingCount: 10_000,
            medianRatingCount: 500,
            ratingAuthorityScore: 70,
            metadataSaturationScore: 60,
            exactTitlePhraseMatchCount: 2,
            exactSubtitlePhraseMatchCount: 1,
            rankingSourceRaw: RankingSource.appStoreWeb.rawValue,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: rankingFetchedAt,
            fallbackProviderRaw: nil,
            fallbackCategoryRaw: nil,
            fallbackTransportCode: nil,
            fallbackHTTPStatus: nil,
            fallbackResponseFailureRaw: nil,
            notes: []
        )
    }
}
