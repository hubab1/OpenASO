import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct KeywordMarketInsightsServiceTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test
    func requestNormalizesScopeAppliesDefaultsAndCapsEffectiveKeywordsByEvidence() throws {
        let request = try KeywordMarketInsightsRequest(
            appStoreID: 123,
            storefronts: [" US ", "ca", "us"],
            platform: .iphone,
            keyword: "  Focus TIMER  ",
            limit: 50,
            marketEvidenceLimit: 3
        )

        #expect(request.appStoreID == 123)
        #expect(request.storefronts == ["ca", "us"])
        #expect(request.keyword == "focus timer")
        #expect(request.limit == 50)
        #expect(request.marketEvidenceLimit == 3)
        #expect(request.effectiveKeywordLimit == 1)

        let defaults = try KeywordMarketInsightsRequest(
            appStoreID: 123,
            storefronts: ["us"],
            platform: .iphone
        )
        #expect(defaults.limit == KeywordMarketInsightsRequest.defaultKeywordLimit)
        #expect(
            defaults.marketEvidenceLimit
                == KeywordMarketInsightsRequest.defaultMarketEvidenceLimit
        )
    }

    @Test
    func requestRejectsInvalidAndUnboundedInputs() throws {
        #expect(throws: OpenASOError.invalidAppStoreID) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 0,
                storefronts: ["us"],
                platform: .iphone
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: [],
                platform: .iphone
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: ["   "],
                platform: .iphone
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: Array(
                    repeating: "us",
                    count: KeywordMarketInsightsRequest.maximumStorefrontCount + 1
                ),
                platform: .iphone
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: [
                    String(
                        repeating: "x",
                        count: KeywordMarketInsightsRequest.maximumStorefrontLength + 1
                    )
                ],
                platform: .iphone
            )
        }
        #expect(throws: OpenASOError.emptyQuery) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: ["us"],
                platform: .iphone,
                keyword: "  \n "
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: ["us"],
                platform: .iphone,
                keyword: String(
                    repeating: "k",
                    count: KeywordMarketInsightsRequest.maximumKeywordLength + 1
                )
            )
        }
        for invalidLimit in [0, KeywordMarketInsightsRequest.maximumKeywordLimit + 1] {
            #expect(throws: OpenASOError.self) {
                _ = try KeywordMarketInsightsRequest(
                    appStoreID: 1,
                    storefronts: ["us"],
                    platform: .iphone,
                    limit: invalidLimit
                )
            }
        }
        for invalidEvidenceLimit in [
            0,
            KeywordMarketInsightsRequest.maximumMarketEvidenceLimit + 1,
        ] {
            #expect(throws: OpenASOError.self) {
                _ = try KeywordMarketInsightsRequest(
                    appStoreID: 1,
                    storefronts: ["us"],
                    platform: .iphone,
                    marketEvidenceLimit: invalidEvidenceLimit
                )
            }
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: ["ca", "us"],
                platform: .iphone,
                marketEvidenceLimit: 1
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: ["us"],
                platform: .iphone,
                cursor: ""
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: ["us"],
                platform: .iphone,
                cursor: String(
                    repeating: "x",
                    count: KeywordMarketInsightsRequest.maximumCursorLength + 1
                )
            )
        }
        #expect(throws: OpenASOError.self) {
            _ = try KeywordMarketInsightsRequest(
                appStoreID: 1,
                storefronts: ["us"],
                platform: .iphone,
                keyword: "focus",
                cursor: "cursor"
            )
        }
    }

    @Test
    func exactKeywordDistinguishesRankedNotRankedNeverRefreshedAndNotTracked() async throws {
        let fixture = try Fixture()
        let ranked = try fixture.addTrack(keyword: "Focus Timer", storefront: "us")
        fixture.addSnapshot(to: ranked, rank: 4, searchedAt: now.addingTimeInterval(-60))
        let notRanked = try fixture.addTrack(keyword: "focus timer", storefront: "ca")
        fixture.addSnapshot(to: notRanked, rank: nil, searchedAt: now.addingTimeInterval(-120))
        _ = try fixture.addTrack(keyword: "FOCUS TIMER", storefront: "gb")
        try fixture.save()

        let page = try await fixture.service(now: now).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us", "gb", "au", "ca"],
            platform: .iphone,
            keyword: " focus TIMER "
        ))
        let item = try #require(page.items.first)

        #expect(page.items.count == 1)
        #expect(page.scope.keyword == "focus timer")
        #expect(item.normalizedKeyword == "focus timer")
        #expect(item.markets.map(\.storefront) == ["au", "ca", "gb", "us"])
        #expect(item.markets.map(\.state) == [
            .notTracked,
            .notRanked,
            .neverRefreshed,
            .ranked,
        ])
        #expect(item.summary.requestedMarketCount == 4)
        #expect(item.summary.trackedMarketCount == 3)
        #expect(item.summary.availableRankingEvidenceCount == 2)
        #expect(item.summary.rankedEvidenceMarketCount == 1)
        #expect(item.summary.notRankedMarketCount == 1)
        #expect(item.summary.neverRefreshedMarketCount == 1)
        #expect(item.summary.notTrackedMarketCount == 1)
        #expect(item.partialReasons == [.neverRefreshed, .notTracked])
        #expect(page.returnedMarketEvidenceCount == 4)
        #expect(page.isPartial)
    }

    @Test
    func newerFailuresDistinguishCachedEvidenceFromNoEvidence() async throws {
        let fixture = try Fixture()
        let cached = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addSnapshot(to: cached, rank: 7, searchedAt: now.addingTimeInterval(-600))
        fixture.addRankingStatus(
            to: cached,
            message: "Ranking failed after the cached observation.",
            updatedAt: now.addingTimeInterval(-300)
        )
        let missing = try fixture.addTrack(keyword: "focus", storefront: "ca")
        fixture.addRankingStatus(
            to: missing,
            message: "Ranking failed without evidence.",
            updatedAt: now.addingTimeInterval(-300)
        )
        try fixture.save()

        let loadedItem = try await fixture.exactInsight(
            keyword: "focus",
            storefronts: ["ca", "us"],
            now: now
        )
        let item = try #require(loadedItem)
        let ca = try #require(item.markets.first { $0.storefront == "ca" })
        let us = try #require(item.markets.first { $0.storefront == "us" })

        #expect(ca.state == .failedWithoutEvidence)
        #expect(ca.rankingEvidence == nil)
        #expect(ca.rankingFailure?.message == "Ranking failed without evidence.")
        #expect(us.state == .failedWithCachedEvidence)
        #expect(us.rankingEvidence?.rank == 7)
        #expect(us.rankingFailure?.message == "Ranking failed after the cached observation.")
        #expect(item.summary.failedWithCachedEvidenceMarketCount == 1)
        #expect(item.summary.failedWithoutEvidenceMarketCount == 1)
        #expect(item.summary.rankedEvidenceMarketCount == 1)
        #expect(item.partialReasons == [.rankingRefreshFailed])
    }

    @Test
    func newerRankingEvidenceSupersedesAnOlderFailure() async throws {
        let fixture = try Fixture()
        let track = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addRankingStatus(
            to: track,
            message: "Older failure.",
            updatedAt: now.addingTimeInterval(-600)
        )
        fixture.addSnapshot(to: track, rank: 3, searchedAt: now.addingTimeInterval(-300))
        try fixture.save()

        let loadedItem = try await fixture.exactInsight(
            keyword: "focus",
            storefronts: ["us"],
            now: now
        )
        let item = try #require(loadedItem)
        let market = try #require(item.markets.first)
        #expect(market.state == .ranked)
        #expect(market.rankingEvidence?.rank == 3)
        #expect(market.rankingFailure == nil)
        #expect(!item.isPartial)
    }

    @Test
    func staleBoundaryIsExactlyTwentyFourHours() async throws {
        let fixture = try Fixture()
        let stale = try fixture.addTrack(keyword: "focus", storefront: "ca")
        fixture.addSnapshot(
            to: stale,
            rank: 8,
            searchedAt: now.addingTimeInterval(-(24 * 60 * 60))
        )
        let fresh = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addSnapshot(
            to: fresh,
            rank: 2,
            searchedAt: now.addingTimeInterval(-(24 * 60 * 60) + 0.001)
        )
        try fixture.save()

        let loadedItem = try await fixture.exactInsight(
            keyword: "focus",
            storefronts: ["us", "ca"],
            now: now
        )
        let item = try #require(loadedItem)
        let ca = try #require(item.markets.first { $0.storefront == "ca" })
        let us = try #require(item.markets.first { $0.storefront == "us" })

        #expect(ca.isStale)
        #expect(!us.isStale)
        #expect(item.summary.staleMarketCount == 1)
        #expect(item.summary.freshRankedMarketCount == 1)
        #expect(item.partialReasons == [.staleRankingEvidence])
    }

    @Test
    func statusFromDeletedTrackGenerationIsIgnored() async throws {
        let fixture = try Fixture()
        let track = try fixture.addTrack(
            keyword: "focus",
            storefront: "us",
            createdAt: now.addingTimeInterval(-1_000)
        )
        fixture.addRankingStatus(
            identityKey: track.identityKey,
            trackCreatedAt: track.createdAt.addingTimeInterval(-1),
            message: "Failure from a deleted track generation.",
            updatedAt: now
        )
        try fixture.save()

        let loadedItem = try await fixture.exactInsight(
            keyword: "focus",
            storefronts: ["us"],
            now: now
        )
        let item = try #require(loadedItem)
        let market = try #require(item.markets.first)
        #expect(market.state == .neverRefreshed)
        #expect(market.rankingFailure == nil)
        #expect(item.partialReasons == [.neverRefreshed])
    }

    @Test
    func cappedStatusScanDoesNotTreatPopularityOnlyCoverageAsRankingCoverage() async throws {
        let fixture = try Fixture()
        let track = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addStatus(
            to: track,
            domain: .popularity,
            message: "Popularity failed.",
            updatedAt: now
        )
        fixture.addRankingStatus(
            to: track,
            message: "Ranking failed.",
            updatedAt: now.addingTimeInterval(-1)
        )
        try fixture.save()

        let page = try await fixture.service(
            now: now,
            maximumStatusScanCount: 1
        ).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            keyword: "focus"
        ))
        let market = try #require(page.items.first?.markets.first)

        #expect(market.state == .unavailable)
        #expect(market.rankingFailure == nil)
        #expect(page.partialReasons.contains(.statusScanCapped))
    }

    @Test
    func cappedStatusScanTreatsEqualTimeContendersAsUnknown() async throws {
        let fixture = try Fixture()
        let track = try fixture.addTrack(keyword: "focus", storefront: "us")
        let first = TrackedKeywordRefreshStatus(
            trackIdentityKey: track.identityKey,
            trackCreatedAt: track.createdAt,
            appStoreID: fixture.appStoreID,
            domain: .ranking,
            message: nil,
            updatedAt: now
        )
        let second = TrackedKeywordRefreshStatus(
            trackIdentityKey: track.identityKey,
            trackCreatedAt: track.createdAt,
            appStoreID: fixture.appStoreID,
            domain: .ranking,
            message: nil,
            updatedAt: now
        )
        let ordered = [first, second].sorted { $0.statusKey < $1.statusKey }
        ordered[0].message = "Failure tied with a resolved watermark."
        ordered[1].message = nil
        fixture.modelContext.insert(first)
        fixture.modelContext.insert(second)
        try fixture.save()

        let page = try await fixture.service(
            now: now,
            maximumStatusScanCount: 1
        ).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            keyword: "focus"
        ))
        let market = try #require(page.items.first?.markets.first)

        #expect(market.state == .unavailable)
        #expect(market.rankingFailure == nil)
        #expect(page.partialReasons.contains(.statusScanCapped))
    }

    @Test
    func newerSnapshotResolvesStatusCoverageBeyondTheScanCutoff() async throws {
        let fixture = try Fixture()
        let us = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addSnapshot(to: us, rank: 3, searchedAt: now)
        let ca = try fixture.addTrack(keyword: "focus", storefront: "ca")
        fixture.addRankingStatus(
            to: ca,
            message: "Ranking failed.",
            updatedAt: now.addingTimeInterval(-60)
        )
        fixture.addStatus(
            to: ca,
            domain: .popularity,
            message: "Popularity failed.",
            updatedAt: now.addingTimeInterval(-120)
        )
        try fixture.save()

        let page = try await fixture.service(
            now: now,
            maximumStatusScanCount: 1
        ).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["ca", "us"],
            platform: .iphone,
            keyword: "focus"
        ))
        let markets = try #require(page.items.first?.markets)

        #expect(markets.first { $0.storefront == "us" }?.state == .ranked)
        #expect(markets.first { $0.storefront == "ca" }?.state == .failedWithoutEvidence)
        #expect(!page.partialReasons.contains(.statusScanCapped))
        #expect(page.partialReasons == [.rankingRefreshFailed])
    }

    @Test
    func cappedSnapshotScanMarksOnlyMissingLatestEvidenceUnavailable() async throws {
        let fixture = try Fixture()
        let us = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addSnapshot(to: us, rank: 2, searchedAt: now)
        let ca = try fixture.addTrack(keyword: "focus", storefront: "ca")
        fixture.addSnapshot(
            to: ca,
            rank: 8,
            searchedAt: now.addingTimeInterval(-1)
        )
        try fixture.save()

        let page = try await fixture.service(
            now: now,
            maximumSnapshotScanCount: 1
        ).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us", "ca"],
            platform: .iphone,
            keyword: "focus"
        ))
        let markets = try #require(page.items.first?.markets)

        #expect(markets.first { $0.storefront == "us" }?.state == .ranked)
        #expect(markets.first { $0.storefront == "ca" }?.state == .unavailable)
        #expect(page.items.first?.summary.unavailableMarketCount == 1)
        #expect(page.partialReasons.contains(.snapshotScanCapped))
    }

    @Test
    func cappedSnapshotScanIsCompleteWhenEveryTrackHasLatestEvidence() async throws {
        let fixture = try Fixture()
        let track = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addSnapshot(to: track, rank: 2, searchedAt: now)
        fixture.addSnapshot(
            to: track,
            rank: 4,
            searchedAt: now.addingTimeInterval(-(24 * 60 * 60) - 60)
        )
        try fixture.save()

        let page = try await fixture.service(
            now: now,
            maximumSnapshotScanCount: 1
        ).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            keyword: "focus"
        ))

        #expect(page.items.first?.markets.first?.rankingEvidence?.rank == 2)
        #expect(page.items.first?.markets.first?.state == .ranked)
        #expect(!page.partialReasons.contains(.snapshotScanCapped))
        #expect(!page.isPartial)
    }

    @Test
    func rankSummaryIsDeterministicForTiesAndUsesOnlyRankedEvidence() async throws {
        let fixture = try Fixture()
        for (storefront, rank) in [("us", 2), ("ca", 2), ("gb", 8), ("au", 8)] {
            let track = try fixture.addTrack(keyword: "focus", storefront: storefront)
            fixture.addSnapshot(to: track, rank: rank, searchedAt: now.addingTimeInterval(-60))
        }
        let unranked = try fixture.addTrack(keyword: "focus", storefront: "de")
        fixture.addSnapshot(to: unranked, rank: nil, searchedAt: now.addingTimeInterval(-60))
        try fixture.save()

        let loadedItem = try await fixture.exactInsight(
            keyword: "focus",
            storefronts: ["us", "de", "gb", "ca", "au"],
            now: now
        )
        let item = try #require(loadedItem)

        #expect(item.summary.rankedEvidenceMarketCount == 4)
        #expect(item.summary.bestMarket?.storefront == "ca")
        #expect(item.summary.bestMarket?.rank == 2)
        #expect(item.summary.worstMarket?.storefront == "au")
        #expect(item.summary.worstMarket?.rank == 8)
        #expect(item.summary.averageRank == 5)
        #expect(item.summary.rankSpread == 6)
        #expect(item.summary.notRankedMarketCount == 1)
    }

    @Test
    func cursorPaginatesWithoutOverlapAndIsBoundToFullScope() async throws {
        let fixture = try Fixture()
        for keyword in ["app", "app a", "app::m", "zulu"] {
            _ = try fixture.addTrack(keyword: keyword, storefront: "us")
        }
        try fixture.save()
        let service = fixture.service(now: now)
        let firstRequest = try KeywordMarketInsightsRequest(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            limit: 1,
            marketEvidenceLimit: 10
        )
        let first = try await service.insights(for: firstRequest)
        let firstCursor = try #require(first.nextCursor)

        #expect(first.items.map(\.normalizedKeyword) == ["app"])
        #expect(first.effectiveKeywordLimit == 1)

        let second = try await service.insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            limit: 1,
            marketEvidenceLimit: 10,
            cursor: firstCursor
        ))
        let secondCursor = try #require(second.nextCursor)
        #expect(second.items.map(\.normalizedKeyword) == ["app a"])

        let third = try await service.insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            limit: 1,
            marketEvidenceLimit: 10,
            cursor: secondCursor
        ))
        let thirdCursor = try #require(third.nextCursor)
        #expect(third.items.map(\.normalizedKeyword) == ["app::m"])

        let fourth = try await service.insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            limit: 1,
            marketEvidenceLimit: 10,
            cursor: thirdCursor
        ))
        #expect(fourth.items.map(\.normalizedKeyword) == ["zulu"])
        #expect(fourth.nextCursor == nil)
        #expect(Set(
            (first.items + second.items + third.items + fourth.items)
                .map(\.normalizedKeyword)
        ) == Set(["app", "app a", "app::m", "zulu"]))

        await #expect(throws: OpenASOError.self) {
            _ = try await service.insights(for: .init(
                appStoreID: fixture.appStoreID,
                storefronts: ["us"],
                platform: .iphone,
                limit: 2,
                marketEvidenceLimit: 10,
                cursor: firstCursor
            ))
        }
        await #expect(throws: OpenASOError.self) {
            _ = try await service.insights(for: .init(
                appStoreID: fixture.appStoreID,
                storefronts: ["us"],
                platform: .ipad,
                limit: 1,
                marketEvidenceLimit: 10,
                cursor: firstCursor
            ))
        }
        let tampered = try tamperScopeDigest(in: firstCursor)
        await #expect(throws: OpenASOError.self) {
            _ = try await service.insights(for: .init(
                appStoreID: fixture.appStoreID,
                storefronts: ["us"],
                platform: .iphone,
                limit: 1,
                marketEvidenceLimit: 10,
                cursor: tampered
            ))
        }
    }

    @Test
    func cursorRemainsBoundedForLongStoredKeywords() async throws {
        let fixture = try Fixture()
        let firstKeyword = String(repeating: "a", count: 2_000)
        let secondKeyword = String(repeating: "z", count: 2_000)
        _ = try fixture.addTrack(keyword: firstKeyword, storefront: "us")
        _ = try fixture.addTrack(keyword: secondKeyword, storefront: "us")
        try fixture.save()
        let service = fixture.service(now: now)

        let first = try await service.insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)
        let second = try await service.insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            limit: 1,
            cursor: cursor
        ))

        #expect(cursor.utf8.count < 512)
        #expect(first.items.map(\.normalizedKeyword) == [firstKeyword])
        #expect(second.items.map(\.normalizedKeyword) == [secondKeyword])
        #expect(second.nextCursor == nil)
    }

    @Test
    func unfilteredTrackScanIsBoundedButExactKeywordBypassesTheScan() async throws {
        let fixture = try Fixture()
        _ = try fixture.addTrack(keyword: "alpha", storefront: "us")
        _ = try fixture.addTrack(keyword: "bravo", storefront: "us")
        try fixture.save()
        let service = fixture.service(now: now, maximumTrackScanCount: 1)

        await #expect(throws: OpenASOError.self) {
            _ = try await service.insights(for: .init(
                appStoreID: fixture.appStoreID,
                storefronts: ["us"],
                platform: .iphone
            ))
        }

        let exact = try await service.insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone,
            keyword: "alpha"
        ))
        #expect(exact.items.map(\.normalizedKeyword) == ["alpha"])
    }

    @Test
    func evidenceBudgetReducesPageSizeAndResponseNeverExceedsIt() async throws {
        let fixture = try Fixture()
        for keyword in ["alpha", "bravo"] {
            for storefront in ["au", "ca", "us"] {
                _ = try fixture.addTrack(keyword: keyword, storefront: storefront)
            }
        }
        try fixture.save()

        let page = try await fixture.service(now: now).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us", "au", "ca"],
            platform: .iphone,
            limit: 50,
            marketEvidenceLimit: 5
        ))

        #expect(page.requestedKeywordLimit == 50)
        #expect(page.effectiveKeywordLimit == 1)
        #expect(page.items.count == 1)
        #expect(page.items.first?.normalizedKeyword == "alpha")
        #expect(page.returnedMarketEvidenceCount == 3)
        #expect(page.returnedMarketEvidenceCount <= page.marketEvidenceLimit)
        #expect(page.nextCursor != nil)
    }

    @Test
    func exactUntrackedKeywordReturnsExplicitEvidenceForEveryRequestedMarket() async throws {
        let fixture = try Fixture()
        _ = try fixture.addTrack(keyword: "unrelated keyword", storefront: "us")
        try fixture.save()

        let page = try await fixture.service(now: now).insights(for: .init(
            appStoreID: fixture.appStoreID,
            storefronts: ["us", "ca"],
            platform: .iphone,
            keyword: "  Missing Keyword "
        ))
        let item = try #require(page.items.first)

        #expect(item.keyword == "missing keyword")
        #expect(item.normalizedKeyword == "missing keyword")
        #expect(item.markets.map(\.storefront) == ["ca", "us"])
        #expect(item.markets.allSatisfy { $0.state == .notTracked })
        #expect(item.markets.allSatisfy { $0.trackIdentityKey == nil })
        #expect(item.summary.notTrackedMarketCount == 2)
        #expect(item.partialReasons == [.notTracked])
        #expect(page.nextCursor == nil)
    }

    @Test
    func projectedDifficultyPreservesProvenanceAndFreshnessWithoutEvidenceRows() async throws {
        let fixture = try Fixture()
        let track = try fixture.addTrack(keyword: "focus", storefront: "us")
        fixture.addDifficulty(
            queryKey: track.queryKey,
            keyword: track.term,
            storefront: track.storefront,
            score: 73,
            confidenceScore: 81,
            rankingFetchedAt: now.addingTimeInterval(-(24 * 60 * 60)),
            computedAt: now.addingTimeInterval(-60)
        )
        try fixture.save()

        let loadedItem = try await fixture.exactInsight(
            keyword: "focus",
            storefronts: ["ca", "us"],
            now: now
        )
        let item = try #require(loadedItem)
        let trackedMarket = try #require(item.markets.first { $0.storefront == "us" })
        let untrackedMarket = try #require(item.markets.first { $0.storefront == "ca" })
        let difficulty = try #require(trackedMarket.estimatedDifficulty)

        #expect(difficulty.state == EstimatedKeywordDifficultyState.estimated.rawValue)
        #expect(difficulty.score == 73)
        #expect(difficulty.confidenceScore == 81)
        #expect(difficulty.confidence == EstimatedKeywordDifficultyConfidence.high.rawValue)
        #expect(difficulty.estimationSource == EstimatedKeywordDifficultySource.topResultsHeuristic.rawValue)
        #expect(difficulty.algorithmIdentifier == "top10-authority-saturation")
        #expect(difficulty.algorithmVersion == 1)
        #expect(difficulty.rankingSource == RankingSource.appStoreWeb.rawValue)
        #expect(difficulty.rankingFetchedAt == now.addingTimeInterval(-(24 * 60 * 60)))
        #expect(difficulty.computedAt == now.addingTimeInterval(-60))
        #expect(difficulty.isStale)
        #expect(untrackedMarket.estimatedDifficulty == nil)
    }

    @Test
    func cancelledTaskFailsBeforeReadingInsights() async throws {
        let fixture = try Fixture()
        _ = try fixture.addTrack(keyword: "focus", storefront: "us")
        try fixture.save()
        let service = fixture.service(now: now)
        let request = try KeywordMarketInsightsRequest(
            appStoreID: fixture.appStoreID,
            storefronts: ["us"],
            platform: .iphone
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.insights(for: request)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    private func tamperScopeDigest(in cursor: String) throws -> String {
        var base64 = cursor.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        let data = try #require(Data(base64Encoded: base64))
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["scopeDigest"] = String(repeating: "0", count: 64)
        let tamperedData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return tamperedData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private struct Fixture {
    let appStoreID: Int64 = 123
    let container: ModelContainer
    let modelContext: ModelContext
    let trackedApp: TrackedApp

    init() throws {
        container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        modelContext = ModelContext(container)
        trackedApp = TrackedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.market-insights",
            name: "Market Insights",
            sellerName: "Example Seller",
            defaultPlatform: .iphone,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        modelContext.insert(trackedApp)
    }

    func service(
        now: Date,
        maximumTrackScanCount: Int = 10_000,
        maximumSnapshotScanCount: Int = 10_000,
        maximumStatusScanCount: Int = 10_000
    ) -> KeywordMarketInsightsService {
        KeywordMarketInsightsService(
            backgroundModelStore: BackgroundModelStore(modelContainer: container),
            now: { now },
            maximumTrackScanCount: maximumTrackScanCount,
            maximumSnapshotScanCount: maximumSnapshotScanCount,
            maximumStatusScanCount: maximumStatusScanCount
        )
    }

    func exactInsight(
        keyword: String,
        storefronts: [String],
        now: Date
    ) async throws -> KeywordMarketInsight? {
        let page = try await service(now: now).insights(for: .init(
            appStoreID: appStoreID,
            storefronts: storefronts,
            platform: .iphone,
            keyword: keyword
        ))
        return page.items.first
    }

    @discardableResult
    func addTrack(
        keyword: String,
        storefront: String,
        platform: AppPlatform = .iphone,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 700_000_100)
    ) throws -> TrackedAppKeyword {
        let query = try KeywordQuery.fetchOrInsert(
            term: keyword,
            storefront: storefront,
            platform: platform,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: keyword,
            storefront: storefront,
            platform: platform,
            trackedApp: trackedApp,
            query: query,
            createdAt: createdAt
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)
        return track
    }

    func addSnapshot(
        to track: TrackedAppKeyword,
        rank: Int?,
        searchedAt: Date,
        source: RankingSource = .appStoreWeb,
        resultCount: Int = 20
    ) {
        let snapshot = TrackedKeywordDailyRanking(
            rank: rank,
            searchedAt: searchedAt,
            source: source,
            resultCount: resultCount,
            keywordTrack: track
        )
        track.snapshots.append(snapshot)
        modelContext.insert(snapshot)
    }

    func addRankingStatus(
        to track: TrackedAppKeyword,
        message: String?,
        updatedAt: Date
    ) {
        addRankingStatus(
            identityKey: track.identityKey,
            trackCreatedAt: track.createdAt,
            message: message,
            updatedAt: updatedAt
        )
    }

    func addRankingStatus(
        identityKey: String,
        trackCreatedAt: Date,
        message: String?,
        updatedAt: Date
    ) {
        addStatus(
            identityKey: identityKey,
            trackCreatedAt: trackCreatedAt,
            domain: .ranking,
            message: message,
            updatedAt: updatedAt
        )
    }

    func addStatus(
        to track: TrackedAppKeyword,
        domain: KeywordRefreshStatusDomain,
        message: String?,
        updatedAt: Date
    ) {
        addStatus(
            identityKey: track.identityKey,
            trackCreatedAt: track.createdAt,
            domain: domain,
            message: message,
            updatedAt: updatedAt
        )
    }

    func addStatus(
        identityKey: String,
        trackCreatedAt: Date,
        domain: KeywordRefreshStatusDomain,
        message: String?,
        updatedAt: Date
    ) {
        modelContext.insert(TrackedKeywordRefreshStatus(
            trackIdentityKey: identityKey,
            trackCreatedAt: trackCreatedAt,
            appStoreID: appStoreID,
            domain: domain,
            message: message,
            updatedAt: updatedAt
        ))
    }

    func addDifficulty(
        queryKey: String,
        keyword: String,
        storefront: String,
        score: Int,
        confidenceScore: Int,
        rankingFetchedAt: Date,
        computedAt: Date
    ) {
        modelContext.insert(EstimatedKeywordDifficultyMetric(
            queryKey: queryKey,
            calculationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            keyword: keyword,
            storefront: storefront,
            platformRaw: AppPlatform.iphone.rawValue,
            stateRaw: EstimatedKeywordDifficultyState.estimated.rawValue,
            score: score,
            confidenceScore: confidenceScore,
            confidenceRaw: EstimatedKeywordDifficultyConfidence.high.rawValue,
            unavailableReasonRaw: nil,
            estimationSourceRaw: EstimatedKeywordDifficultySource.topResultsHeuristic.rawValue,
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: 10,
            providerResultCount: 10,
            consideredResultCount: 10,
            ratedResultCount: 9,
            weightedRatingCoveragePercentage: 90,
            maximumRatingCount: 100_000,
            medianRatingCount: 5_000,
            ratingAuthorityScore: 75,
            metadataSaturationScore: 71,
            exactTitlePhraseMatchCount: 2,
            exactSubtitlePhraseMatchCount: 1,
            rankingSourceRaw: RankingSource.appStoreWeb.rawValue,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: computedAt,
            fallbackProviderRaw: nil,
            fallbackCategoryRaw: nil,
            fallbackTransportCode: nil,
            fallbackHTTPStatus: nil,
            fallbackResponseFailureRaw: nil,
            notes: ["Local heuristic test fixture."]
        ))
    }

    func save() throws {
        try modelContext.save()
    }
}
