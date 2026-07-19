import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct EstimatedKeywordDifficultyPersistenceAdapterTests {
    @Test
    func primaryPageMapsEstimatorOutputAndRetainsExactMetadata() throws {
        let request = makeRequest()
        let page = SearchRankingPage(items: estimatedItems(), source: .appStoreWeb)
        let calculationID = UUID(uuidString: "00000000-0000-0000-0000-000000002001")!
        let rankingFetchedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let computedAt = rankingFetchedAt.addingTimeInterval(2)

        let payload = try #require(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: request,
            page: page,
            requestedResultLimit: 10,
            rankingFetchedAt: rankingFetchedAt,
            calculationID: calculationID,
            now: { computedAt }
        ))
        let estimate = try requireEstimate(
            KeywordDifficultyEstimator.estimate(
                keyword: request.term,
                searchResults: page.items
            )
        )

        #expect(payload.queryKey == request.queryKey)
        #expect(payload.calculationID == calculationID)
        #expect(payload.keyword == "focus timer")
        #expect(payload.storefront == "us")
        #expect(payload.platform == .iphone)
        #expect(payload.result == .estimated(
            score: estimate.score,
            confidenceScore: estimate.confidenceScore,
            confidence: persistenceConfidence(estimate.confidence)
        ))
        #expect(payload.estimationSource == .topResultsHeuristic)
        #expect(payload.algorithmIdentifier == estimate.algorithmIdentifier)
        #expect(payload.algorithmVersion == estimate.algorithmVersion)
        #expect(payload.requestedResultLimit == 10)
        #expect(payload.providerResultCount == page.resultCount)
        #expect(payload.evidence == persistenceEvidence(estimate.evidence))
        #expect(payload.rankingSource == .appStoreWeb)
        #expect(payload.rankingFetchedAt == rankingFetchedAt)
        #expect(payload.computedAt == computedAt)
        #expect(payload.fallback == nil)
        #expect(payload.notes == estimate.notes)

        let firstEvidence = try #require(payload.evidence.resultEvidence.first)
        #expect(firstEvidence.title == "  Focus Timer++: Deep Work!  ")
        #expect(firstEvidence.subtitle == "  Stay focused — privately!  ")
    }

    @Test
    func fallbackPageMapsStructuredProvenance() throws {
        let provenanceCases: [(
            input: SearchRankingFailureCategory,
            expected: EstimatedKeywordDifficultyFallbackProvenance
        )] = [
            (
                .transport(code: -1009),
                EstimatedKeywordDifficultyFallbackProvenance(
                    provider: .appStoreWeb,
                    category: .transport,
                    transportCode: -1009
                )
            ),
            (
                .httpStatus(503),
                EstimatedKeywordDifficultyFallbackProvenance(
                    provider: .appStoreWeb,
                    category: .httpStatus,
                    httpStatus: 503
                )
            ),
            (
                .provider,
                EstimatedKeywordDifficultyFallbackProvenance(
                    provider: .appStoreWeb,
                    category: .provider
                )
            ),
            (
                .other,
                EstimatedKeywordDifficultyFallbackProvenance(
                    provider: .appStoreWeb,
                    category: .other
                )
            )
        ]

        for provenanceCase in provenanceCases {
            let page = SearchRankingPage(
                items: estimatedItems(),
                source: .iTunesFallback,
                fallbackContext: SearchRankingFailureContext(
                    provider: .appStoreWeb,
                    category: provenanceCase.input
                )
            )
            let payload = try #require(makePayload(page: page))
            #expect(payload.rankingSource == .iTunesFallback)
            #expect(payload.fallback == provenanceCase.expected)
        }

        let responseCases: [(
            input: SearchRankingResponseFailure,
            expected: EstimatedKeywordDifficultyFallbackResponseFailure
        )] = [
            (.serializedServerDataMissing, .serializedServerDataMissing),
            (.decodingFailed, .decodingFailed),
            (.nonHTTPResponse, .nonHTTPResponse),
            (.requestIntentMissing, .requestIntentMissing),
            (.requestIntentAmbiguous, .requestIntentAmbiguous),
            (.pageShapeChanged, .pageShapeChanged),
            (.authoritativeShelfMissing, .authoritativeShelfMissing),
            (.authoritativeShelfAmbiguous, .authoritativeShelfAmbiguous),
            (.malformedSearchResult, .malformedSearchResult),
            (.truncatedResults, .truncatedResults)
        ]

        for responseCase in responseCases {
            let page = SearchRankingPage(
                items: estimatedItems(),
                source: .iTunesFallback,
                fallbackContext: SearchRankingFailureContext(
                    provider: .appStoreWeb,
                    category: .response(responseCase.input)
                )
            )
            let payload = try #require(makePayload(page: page))
            #expect(payload.fallback == EstimatedKeywordDifficultyFallbackProvenance(
                provider: .appStoreWeb,
                category: .response,
                responseFailure: responseCase.expected
            ))
        }
    }

    @Test
    func directITunesPageKeepsFallbackProvenanceNil() throws {
        let page = SearchRankingPage(
            items: estimatedItems(),
            source: .iTunesFallback,
            fallbackContext: nil
        )

        let payload = try #require(makePayload(page: page))

        #expect(payload.rankingSource == .iTunesFallback)
        #expect(payload.fallback == nil)
    }

    @Test
    func unavailableEstimatorStatesMapWithoutInventingAnEstimate() throws {
        let cases: [(
            term: String,
            items: [SearchRankingItem],
            reason: EstimatedKeywordDifficultyUnavailableReason
        )] = [
            ("", estimatedItems(), .emptyKeyword),
            ("focus timer", Array(estimatedItems().prefix(2)), .insufficientResults),
            (
                "focus timer",
                estimatedItems().map { item in
                    rankingItem(
                        position: item.position,
                        appStoreID: item.appStoreID,
                        title: item.name,
                        subtitle: item.subtitle,
                        ratingCount: nil
                    )
                },
                .insufficientRatingEvidence
            )
        ]

        for unavailableCase in cases {
            let request = makeRequest(term: unavailableCase.term)
            let page = SearchRankingPage(
                items: unavailableCase.items,
                source: .appStoreWeb
            )
            let payload = try #require(makePayload(request: request, page: page))
            let unavailable = try requireUnavailable(
                KeywordDifficultyEstimator.estimate(
                    keyword: request.term,
                    searchResults: page.items
                )
            )

            #expect(payload.result == .unavailable(reason: unavailableCase.reason))
            #expect(payload.algorithmIdentifier == unavailable.algorithmIdentifier)
            #expect(payload.algorithmVersion == unavailable.algorithmVersion)
            #expect(payload.evidence == persistenceEvidence(unavailable.evidence))
            #expect(payload.notes == unavailable.notes)
        }
    }

    @Test
    func explicitCalculationIdentifierProducesOneStablePayload() throws {
        let request = makeRequest()
        let page = SearchRankingPage(items: estimatedItems(), source: .appStoreWeb)
        let calculationID = UUID(uuidString: "00000000-0000-0000-0000-000000002002")!
        let rankingFetchedAt = Date(timeIntervalSince1970: 1_720_000_100)
        let computedAt = rankingFetchedAt.addingTimeInterval(1)

        let first = try #require(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: request,
            page: page,
            requestedResultLimit: 10,
            rankingFetchedAt: rankingFetchedAt,
            calculationID: calculationID,
            now: { computedAt }
        ))
        let second = try #require(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: request,
            page: page,
            requestedResultLimit: 10,
            rankingFetchedAt: rankingFetchedAt,
            calculationID: calculationID,
            now: { computedAt }
        ))

        #expect(first.calculationID == calculationID)
        #expect(second.calculationID == calculationID)
        #expect(first == second)
    }

    @Test
    func invalidProvenanceQueryKeysAndLimitsAreRejectedAndClockIsClamped() throws {
        let request = makeRequest()
        let fetchedAt = Date(timeIntervalSince1970: 1_720_000_200)
        let validPage = SearchRankingPage(
            items: estimatedItems(),
            source: .appStoreWeb
        )
        let primaryWithFallback = SearchRankingPage(
            items: estimatedItems(),
            source: .appStoreWeb,
            fallbackContext: SearchRankingFailureContext(
                provider: .appStoreWeb,
                category: .provider
            )
        )
        let fallbackAttributingItself = SearchRankingPage(
            items: estimatedItems(),
            source: .iTunesFallback,
            fallbackContext: SearchRankingFailureContext(
                provider: .iTunesFallback,
                category: .httpStatus(500)
            )
        )

        #expect(makePayload(request: request, page: primaryWithFallback) == nil)
        #expect(makePayload(request: request, page: fallbackAttributingItself) == nil)
        var clockCallCount = 0
        let clampedPayload = try #require(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: request,
            page: validPage,
            requestedResultLimit: 10,
            rankingFetchedAt: fetchedAt,
            now: {
                clockCallCount += 1
                return fetchedAt.addingTimeInterval(-1)
            }
        ))
        #expect(clockCallCount == 1)
        #expect(clampedPayload.computedAt == fetchedAt)
        #expect(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: RankingRefreshRequest(
                identityKey: request.identityKey,
                queryKey: "different::us::iphone",
                term: request.term,
                storefront: request.storefront,
                platform: request.platform
            ),
            page: validPage,
            requestedResultLimit: 10,
            rankingFetchedAt: fetchedAt
        ) == nil)
        #expect(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: request,
            page: validPage,
            requestedResultLimit: 0,
            rankingFetchedAt: fetchedAt
        ) == nil)
        #expect(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: request,
            page: validPage,
            requestedResultLimit: EstimatedKeywordDifficultyStore.maximumRequestedResultCount + 1,
            rankingFetchedAt: fetchedAt
        ) == nil)
        #expect(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: request,
            page: validPage,
            requestedResultLimit: validPage.resultCount - 1,
            rankingFetchedAt: fetchedAt
        ) == nil)
    }

    @Test
    func optionalUpsertRejectsReplacedTrackGeneration() throws {
        let container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let modelContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 123,
            bundleID: "example.generation",
            name: "Generation App",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        let query = try KeywordQuery.fetchOrInsert(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            in: modelContext
        )
        let original = TrackedAppKeyword(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        trackedApp.keywordTracks.append(original)
        modelContext.insert(trackedApp)
        modelContext.insert(original)
        try modelContext.save()

        let page = SearchRankingPage(items: estimatedItems(), source: .appStoreWeb)
        let fetchedAt = Date(timeIntervalSince1970: 200)
        let originalRequest = RankingRefreshRequest(track: original)
        let payload = try #require(EstimatedKeywordDifficultyPersistenceAdapter.payload(
            request: originalRequest,
            page: page,
            requestedResultLimit: 10,
            rankingFetchedAt: fetchedAt,
            now: { fetchedAt }
        ))
        let originalPageResult = RankingRefreshPageResult(
            request: originalRequest,
            page: page,
            searchedAt: fetchedAt,
            observedHour: nil,
            submissionCount: 1,
            winningCount: 1,
            confidence: "single_source",
            requestedResultLimit: 10,
            estimatedDifficultyPayload: payload
        )

        _ = try TrackedKeywordDeletionService.deleteTracks(
            [TrackedKeywordDeletionRequest(track: original)],
            in: modelContext
        )
        let replacement = TrackedAppKeyword(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        trackedApp.keywordTracks.append(replacement)
        modelContext.insert(replacement)
        try modelContext.save()

        #expect(try EstimatedKeywordDifficultyPersistenceAdapter.upsertIfCurrent(
            for: originalPageResult,
            in: modelContext
        ) == nil)
        #expect(try EstimatedKeywordDifficultyStore.snapshot(
            queryKey: replacement.queryKey,
            in: modelContext
        ) == nil)
    }
}

@MainActor
private func makePayload(
    request: RankingRefreshRequest = makeRequest(),
    page: SearchRankingPage
) -> EstimatedKeywordDifficultyPersistencePayload? {
    let rankingFetchedAt = Date(timeIntervalSince1970: 1_720_000_000)
    return EstimatedKeywordDifficultyPersistenceAdapter.payload(
        request: request,
        page: page,
        requestedResultLimit: 10,
        rankingFetchedAt: rankingFetchedAt,
        calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000002000")!,
        now: { rankingFetchedAt.addingTimeInterval(1) }
    )
}

@MainActor
private func makeRequest(
    term: String = "focus timer",
    storefront: String = "us",
    platform: AppPlatform = .iphone
) -> RankingRefreshRequest {
    let queryKey = KeywordQuery.makeQueryKey(
        term: term,
        storefront: storefront,
        platform: platform
    )
    return RankingRefreshRequest(
        identityKey: "123::\(queryKey)",
        queryKey: queryKey,
        term: term,
        storefront: storefront,
        platform: platform
    )
}

@MainActor
private func estimatedItems() -> [SearchRankingItem] {
    [
        rankingItem(
            position: 1,
            appStoreID: 101,
            title: "  Focus Timer++: Deep Work!  ",
            subtitle: "  Stay focused — privately!  ",
            ratingCount: 12_000
        ),
        rankingItem(
            position: 2,
            appStoreID: 102,
            title: "Deep Focus Clock",
            subtitle: "Timer and study sessions",
            ratingCount: 8_000
        ),
        rankingItem(
            position: 3,
            appStoreID: 103,
            title: "Study Sessions",
            subtitle: "Focus timer for work",
            ratingCount: 4_000
        ),
        rankingItem(
            position: 4,
            appStoreID: 104,
            title: "Quiet Productivity",
            subtitle: nil,
            ratingCount: 1_000
        )
    ]
}

@MainActor
private func rankingItem(
    position: Int,
    appStoreID: Int64,
    title: String,
    subtitle: String?,
    ratingCount: Int?
) -> SearchRankingItem {
    SearchRankingItem(
        position: position,
        appStoreID: appStoreID,
        bundleID: "com.example.\(appStoreID)",
        name: title,
        subtitle: subtitle,
        sellerName: "Example Seller",
        ratingCount: ratingCount,
        platform: .iphone
    )
}

private func persistenceConfidence(
    _ confidence: EstimatedKeywordDifficulty.Confidence
) -> EstimatedKeywordDifficultyConfidence {
    switch confidence {
    case .low: .low
    case .medium: .medium
    case .high: .high
    }
}

private func persistenceEvidence(
    _ evidence: KeywordDifficultyEvidence
) -> EstimatedKeywordDifficultyEvidence {
    EstimatedKeywordDifficultyEvidence(
        consideredResultCount: evidence.consideredResultCount,
        ratedResultCount: evidence.ratedResultCount,
        weightedRatingCoveragePercentage: evidence.weightedRatingCoveragePercentage,
        maximumRatingCount: evidence.maximumRatingCount,
        medianRatingCount: evidence.medianRatingCount,
        ratingAuthorityScore: evidence.ratingAuthorityScore,
        metadataSaturationScore: evidence.metadataSaturationScore,
        resultEvidence: evidence.resultEvidence.map { result in
            EstimatedKeywordDifficultyResultEvidence(
                position: result.position,
                appStoreID: result.appStoreID,
                title: result.title,
                subtitle: result.subtitle,
                ratingCount: result.ratingCount,
                ratingAuthorityScore: result.ratingAuthorityScore,
                titleTokenCoveragePercentage: result.titleTokenCoveragePercentage,
                combinedTokenCoveragePercentage: result.combinedTokenCoveragePercentage,
                metadataMatchScore: result.metadataMatchScore,
                exactTitlePhraseMatch: result.exactTitlePhraseMatch,
                exactSubtitlePhraseMatch: result.exactSubtitlePhraseMatch
            )
        }
    )
}

private func requireEstimate(
    _ estimation: KeywordDifficultyEstimation
) throws -> EstimatedKeywordDifficulty {
    guard case .estimated(let estimate) = estimation else {
        Issue.record("Expected an estimated keyword difficulty result")
        throw AdapterTestError.unexpectedEstimation
    }
    return estimate
}

private func requireUnavailable(
    _ estimation: KeywordDifficultyEstimation
) throws -> KeywordDifficultyUnavailable {
    guard case .unavailable(let unavailable) = estimation else {
        Issue.record("Expected an unavailable keyword difficulty result")
        throw AdapterTestError.unexpectedEstimation
    }
    return unavailable
}

private enum AdapterTestError: Error {
    case unexpectedEstimation
}
