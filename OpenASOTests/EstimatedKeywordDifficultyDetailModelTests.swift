import Foundation
import Testing
@testable import OpenASO

@MainActor
struct EstimatedKeywordDifficultyDetailModelTests {
    @Test
    func publishesLoadedMissingAndFailedStatesDistinctly() async {
        let loadedModel = EstimatedKeywordDifficultyDetailModel()
        let expected = snapshot(queryKey: "loaded", score: 64)
        await loadedModel.load(
            queryKey: "loaded",
            using: EstimatedKeywordDifficultyDetailDataSource { _ in expected }
        )
        #expect(loadedModel.state == .loaded(expected))

        let missingModel = EstimatedKeywordDifficultyDetailModel()
        await missingModel.load(
            queryKey: "missing",
            using: EstimatedKeywordDifficultyDetailDataSource { _ in nil }
        )
        #expect(missingModel.state == .missing)

        let failedModel = EstimatedKeywordDifficultyDetailModel()
        await failedModel.load(
            queryKey: "failed",
            using: EstimatedKeywordDifficultyDetailDataSource { _ in
                throw DetailLoaderError.failed
            }
        )
        guard case let .failed(message) = failedModel.state else {
            Issue.record("Expected a distinct failed state")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test
    func supersededCompletionCannotReplaceLatestSnapshot() async {
        let model = EstimatedKeywordDifficultyDetailModel()
        let loader = ControlledEstimatedKeywordDifficultyLoader()
        let dataSource = EstimatedKeywordDifficultyDetailDataSource(load: loader.load)

        let staleTask = Task { @MainActor in
            await model.load(queryKey: "stale", using: dataSource)
        }
        await loader.waitForRequestCount(1)

        let freshTask = Task { @MainActor in
            await model.load(queryKey: "fresh", using: dataSource)
        }
        await loader.waitForRequestCount(2)

        let freshSnapshot = snapshot(queryKey: "fresh", score: 88)
        loader.succeedRequest(at: 1, with: freshSnapshot)
        await freshTask.value
        #expect(model.snapshot == freshSnapshot)

        loader.succeedRequest(at: 0, with: snapshot(queryKey: "stale", score: 12))
        await staleTask.value
        #expect(model.snapshot == freshSnapshot)
    }

    @Test
    func cancellationRestoresIdleStateWithoutPublishingResult() async {
        let model = EstimatedKeywordDifficultyDetailModel()
        let loader = ControlledEstimatedKeywordDifficultyLoader()
        let dataSource = EstimatedKeywordDifficultyDetailDataSource(load: loader.load)

        let task = Task { @MainActor in
            await model.load(queryKey: "cancelled", using: dataSource)
        }
        await loader.waitForRequestCount(1)
        task.cancel()
        loader.succeedRequest(at: 0, with: snapshot(queryKey: "cancelled", score: 55))
        await task.value

        #expect(model.state == .idle)
    }

    private func snapshot(
        queryKey: String,
        score: Int
    ) -> EstimatedKeywordDifficultySnapshot {
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return EstimatedKeywordDifficultySnapshot(
            queryKey: queryKey,
            calculationID: UUID(),
            keyword: queryKey,
            storefront: "us",
            platformRaw: AppPlatform.iphone.rawValue,
            stateRaw: EstimatedKeywordDifficultyState.estimated.rawValue,
            score: score,
            confidenceScore: 80,
            confidenceRaw: EstimatedKeywordDifficultyConfidence.high.rawValue,
            unavailableReasonRaw: nil,
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
            rankingFetchedAt: fetchedAt,
            computedAt: fetchedAt.addingTimeInterval(1),
            fallbackProviderRaw: nil,
            fallbackCategoryRaw: nil,
            fallbackTransportCode: nil,
            fallbackHTTPStatus: nil,
            fallbackResponseFailureRaw: nil,
            notes: [],
            resultEvidence: []
        )
    }
}

private enum DetailLoaderError: Error {
    case failed
}

@MainActor
private final class ControlledEstimatedKeywordDifficultyLoader {
    private struct Request {
        let queryKey: String
        let continuation: CheckedContinuation<
            Result<EstimatedKeywordDifficultySnapshot?, Error>,
            Never
        >
    }

    private var requests: [Request] = []

    func load(queryKey: String) async throws -> EstimatedKeywordDifficultySnapshot? {
        let result = await withCheckedContinuation { continuation in
            requests.append(Request(queryKey: queryKey, continuation: continuation))
        }
        return try result.get()
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        while requests.count < expectedCount {
            await Task.yield()
        }
    }

    func succeedRequest(
        at index: Int,
        with snapshot: EstimatedKeywordDifficultySnapshot?
    ) {
        requests[index].continuation.resume(returning: .success(snapshot))
    }
}
