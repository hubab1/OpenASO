import Foundation
import Testing
@testable import OpenASO

@MainActor
struct KeywordMarketInsightsModelTests {
    @Test
    func supersededCompletionCannotReplaceNewScope() async throws {
        let model = KeywordMarketInsightsModel()
        let loader = ControlledKeywordMarketInsightsLoader()
        let dataSource = KeywordMarketInsightsDataSource { request in
            try await loader.load(request)
        }
        let staleScope = try scope(appStoreID: 1)
        let freshScope = try scope(appStoreID: 2)

        let staleTask = Task { @MainActor in
            await model.load(scope: staleScope, using: dataSource)
        }
        await loader.waitForRequestCount(1)

        let freshTask = Task { @MainActor in
            await model.load(scope: freshScope, using: dataSource)
        }
        await loader.waitForRequestCount(2)

        await loader.succeedRequest(
            at: 1,
            with: page(scope: freshScope, keyword: "fresh")
        )
        await freshTask.value
        #expect(model.items.map(\.keyword) == ["fresh"])

        await loader.succeedRequest(
            at: 0,
            with: page(scope: staleScope, keyword: "stale")
        )
        await staleTask.value
        #expect(model.snapshot?.scope == freshScope)
        #expect(model.items.map(\.keyword) == ["fresh"])
    }

    @Test
    func paginationUsesCursorAppendsOnceAndPreservesRowsOnFailure() async throws {
        let model = KeywordMarketInsightsModel()
        let scope = try scope(appStoreID: 7)
        let requests = KeywordMarketInsightsRequestRecorder()
        let firstPage = page(
            scope: scope,
            keyword: "alpha",
            nextCursor: "next"
        )
        let secondPage = page(scope: scope, keyword: "beta")
        let dataSource = KeywordMarketInsightsDataSource { request in
            await requests.record(request)
            if request.cursor == nil { return firstPage }
            if request.cursor == "next" { return secondPage }
            throw TestLoaderError.failed
        }

        await model.load(scope: scope, using: dataSource)
        #expect(model.canLoadNextPage)
        await model.loadNextPage(using: dataSource)

        #expect(model.items.map(\.keyword) == ["alpha", "beta"])
        #expect(!model.canLoadNextPage)
        let recorded = await requests.values
        #expect(recorded.map(\.cursor) == [nil, "next"])
        #expect(recorded.allSatisfy {
            $0.limit == KeywordMarketInsightsRequest.defaultKeywordLimit
                && $0.marketEvidenceLimit
                    == KeywordMarketInsightsRequest.defaultMarketEvidenceLimit
        })

        let failingModel = KeywordMarketInsightsModel()
        let failingDataSource = KeywordMarketInsightsDataSource { request in
            if request.cursor == nil { return firstPage }
            throw TestLoaderError.failed
        }
        await failingModel.load(scope: scope, using: failingDataSource)
        await failingModel.loadNextPage(using: failingDataSource)

        #expect(failingModel.items.map(\.keyword) == ["alpha"])
        #expect(failingModel.canLoadNextPage)
        #expect(failingModel.paginationErrorMessage != nil)
    }

    @Test
    func initialFailureIsRecoverableAndReloadResetsCursor() async throws {
        let model = KeywordMarketInsightsModel()
        let scope = try scope(appStoreID: 8)
        let attempts = KeywordMarketInsightsAttemptCounter()
        let expected = page(scope: scope, keyword: "recovered")
        let dataSource = KeywordMarketInsightsDataSource { request in
            let attempt = await attempts.next()
            #expect(request.cursor == nil)
            if attempt == 1 { throw TestLoaderError.failed }
            return expected
        }

        await model.load(scope: scope, using: dataSource)
        #expect(model.errorMessage != nil)
        #expect(model.items.isEmpty)

        await model.load(scope: scope, using: dataSource)
        #expect(model.errorMessage == nil)
        #expect(model.items.map(\.keyword) == ["recovered"])
    }

    @Test
    func paginationCannotSupersedeSameScopeReload() async throws {
        let model = KeywordMarketInsightsModel()
        let scope = try scope(appStoreID: 9)
        let firstPage = page(
            scope: scope,
            keyword: "old",
            nextCursor: "stale-cursor"
        )
        await model.load(
            scope: scope,
            using: KeywordMarketInsightsDataSource { _ in firstPage }
        )

        let loader = ControlledKeywordMarketInsightsLoader()
        let dataSource = KeywordMarketInsightsDataSource { request in
            try await loader.load(request)
        }
        let reloadTask = Task { @MainActor in
            await model.load(scope: scope, using: dataSource)
        }
        await loader.waitForRequestCount(1)

        #expect(!model.canLoadNextPage)
        await model.loadNextPage(using: dataSource)
        #expect(await loader.requestCount == 1)

        await loader.succeedRequest(
            at: 0,
            with: page(scope: scope, keyword: "fresh")
        )
        await reloadTask.value
        #expect(model.items.map(\.keyword) == ["fresh"])
    }

    @Test
    func nonCooperativeCanceledReloadRestoresSameScopeSnapshot() async throws {
        let model = KeywordMarketInsightsModel()
        let scope = try scope(appStoreID: 10)
        let previous = page(scope: scope, keyword: "previous")
        await model.load(
            scope: scope,
            using: KeywordMarketInsightsDataSource { _ in previous }
        )

        let loader = ControlledKeywordMarketInsightsLoader()
        let dataSource = KeywordMarketInsightsDataSource { request in
            try await loader.load(request)
        }
        let reloadTask = Task { @MainActor in
            await model.load(scope: scope, using: dataSource)
        }
        await loader.waitForRequestCount(1)
        reloadTask.cancel()
        await loader.succeedRequest(
            at: 0,
            with: page(scope: scope, keyword: "canceled")
        )
        await reloadTask.value

        #expect(model.items.map(\.keyword) == ["previous"])
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test
    func nonCooperativeCanceledPaginationPreservesRowsCursorAndErrorState() async throws {
        let model = KeywordMarketInsightsModel()
        let scope = try scope(appStoreID: 11)
        let first = page(
            scope: scope,
            keyword: "alpha",
            nextCursor: "next"
        )
        await model.load(
            scope: scope,
            using: KeywordMarketInsightsDataSource { _ in first }
        )

        let loader = ControlledKeywordMarketInsightsLoader()
        let dataSource = KeywordMarketInsightsDataSource { request in
            try await loader.load(request)
        }
        let paginationTask = Task { @MainActor in
            await model.loadNextPage(using: dataSource)
        }
        await loader.waitForRequestCount(1)
        paginationTask.cancel()
        await loader.succeedRequest(
            at: 0,
            with: page(scope: scope, keyword: "beta")
        )
        await paginationTask.value

        #expect(model.items.map(\.keyword) == ["alpha"])
        #expect(model.snapshot?.nextCursor == "next")
        #expect(model.paginationErrorMessage == nil)
        #expect(model.canLoadNextPage)
    }

    @Test
    func paginationAggregatesDistinctPartialReasonsAndPageTotals() async throws {
        let model = KeywordMarketInsightsModel()
        let scope = try scope(appStoreID: 12)
        let first = page(
            scope: scope,
            keyword: "alpha",
            nextCursor: "next",
            partialReasons: [.notTracked],
            staleMarketCount: 1,
            returnedMarketEvidenceCount: 2
        )
        let second = page(
            scope: scope,
            keyword: "beta",
            partialReasons: [.rankingRefreshFailed],
            staleMarketCount: 3,
            returnedMarketEvidenceCount: 4
        )
        let dataSource = KeywordMarketInsightsDataSource { request in
            request.cursor == nil ? first : second
        }

        await model.load(scope: scope, using: dataSource)
        await model.loadNextPage(using: dataSource)

        #expect(model.snapshot?.partialReasons == [
            .notTracked,
            .rankingRefreshFailed
        ])
        #expect(model.snapshot?.staleMarketCount == 4)
        #expect(model.snapshot?.returnedMarketEvidenceCount == 6)
    }

    private func scope(appStoreID: Int64) throws -> KeywordMarketInsightsViewScope {
        try KeywordMarketInsightsViewScope(
            appStoreID: appStoreID,
            storefronts: ["us"],
            platform: .iphone
        )
    }

    private func page(
        scope: KeywordMarketInsightsViewScope,
        keyword: String,
        nextCursor: String? = nil,
        partialReasons: [KeywordMarketInsightsPartialReason] = [],
        staleMarketCount: Int = 0,
        returnedMarketEvidenceCount: Int = 0
    ) -> KeywordMarketInsightsPage {
        let insight = KeywordMarketInsight(
            keyword: keyword,
            normalizedKeyword: keyword,
            platform: scope.platform,
            markets: [],
            summary: KeywordMarketInsightSummary(
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
                unavailableMarketCount: 0,
                staleMarketCount: 0,
                bestMarket: nil,
                worstMarket: nil,
                averageRank: nil,
                rankSpread: nil
            ),
            isPartial: !partialReasons.isEmpty,
            partialReasons: partialReasons
        )
        return KeywordMarketInsightsPage(
            scope: KeywordMarketInsightsScope(
                appStoreID: scope.appStoreID,
                storefronts: scope.storefronts,
                platform: scope.platform,
                keyword: nil
            ),
            items: [insight],
            nextCursor: nextCursor,
            requestedKeywordLimit: KeywordMarketInsightsRequest.defaultKeywordLimit,
            effectiveKeywordLimit: KeywordMarketInsightsRequest.defaultKeywordLimit,
            marketEvidenceLimit: KeywordMarketInsightsRequest.defaultMarketEvidenceLimit,
            returnedMarketEvidenceCount: returnedMarketEvidenceCount,
            isPartial: !partialReasons.isEmpty,
            partialReasons: partialReasons,
            staleMarketCount: staleMarketCount
        )
    }
}

private enum TestLoaderError: Error {
    case failed
}

private actor ControlledKeywordMarketInsightsLoader {
    private struct Request {
        let request: KeywordMarketInsightsRequest
        let continuation: CheckedContinuation<
            Result<KeywordMarketInsightsPage, Error>,
            Never
        >
    }

    private var requests: [Request] = []

    var requestCount: Int { requests.count }

    func load(
        _ request: KeywordMarketInsightsRequest
    ) async throws -> KeywordMarketInsightsPage {
        let result = await withCheckedContinuation { continuation in
            requests.append(Request(request: request, continuation: continuation))
        }
        return try result.get()
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        while requests.count < expectedCount {
            await Task.yield()
        }
    }

    func succeedRequest(at index: Int, with page: KeywordMarketInsightsPage) {
        requests[index].continuation.resume(returning: .success(page))
    }
}

private actor KeywordMarketInsightsRequestRecorder {
    private(set) var values: [KeywordMarketInsightsRequest] = []

    func record(_ request: KeywordMarketInsightsRequest) {
        values.append(request)
    }
}

private actor KeywordMarketInsightsAttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
