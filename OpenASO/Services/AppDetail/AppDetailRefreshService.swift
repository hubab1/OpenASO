import Foundation
import SwiftData

struct AppDetailRefreshAppSnapshot: Sendable {
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let defaultPlatform: AppPlatform
}

enum AppDetailRefreshWorkspace: Sendable {
    case keywords
    case ratings
}

enum AppDetailRefreshStorefrontSelection: Sendable {
    case all(codes: [String])
    case storefront(code: String)

    var codes: [String] {
        switch self {
        case .all(let codes):
            return codes
        case .storefront(let code):
            return [code]
        }
    }
}

struct AppDetailRefreshRequest: Sendable {
    let app: AppDetailRefreshAppSnapshot
    let workspace: AppDetailRefreshWorkspace
    let storefrontSelection: AppDetailRefreshStorefrontSelection
    let trackIdentityKeys: [String]
    let trigger: String
    let refreshKeywords: Bool
    let refreshMetrics: Bool
    let refreshRatings: Bool
    let refreshReviews: Bool
    let recordsRatingsReviewsRefresh: Bool
    let popularityContextAppStoreID: Int64?
    let appleAdsWebSession: AppleAdsWebSession?
    let appStoreConnectCredentials: AppStoreConnectCredentials

    init(
        app: AppDetailRefreshAppSnapshot,
        workspace: AppDetailRefreshWorkspace,
        storefrontSelection: AppDetailRefreshStorefrontSelection,
        trackIdentityKeys: [String],
        trigger: String,
        refreshKeywords: Bool = true,
        refreshMetrics: Bool = true,
        refreshRatings: Bool = true,
        refreshReviews: Bool = true,
        recordsRatingsReviewsRefresh: Bool = true,
        popularityContextAppStoreID: Int64?,
        appleAdsWebSession: AppleAdsWebSession?,
        appStoreConnectCredentials: AppStoreConnectCredentials
    ) {
        self.app = app
        self.workspace = workspace
        self.storefrontSelection = storefrontSelection
        self.trackIdentityKeys = trackIdentityKeys
        self.trigger = trigger
        self.refreshKeywords = refreshKeywords
        self.refreshMetrics = refreshMetrics
        self.refreshRatings = refreshRatings
        self.refreshReviews = refreshReviews
        self.recordsRatingsReviewsRefresh = recordsRatingsReviewsRefresh
        self.popularityContextAppStoreID = popularityContextAppStoreID
        self.appleAdsWebSession = appleAdsWebSession
        self.appStoreConnectCredentials = appStoreConnectCredentials
    }
}

struct KeywordBackgroundRefreshOutcome: Sendable {
    let trackIdentityKey: String
    let error: OpenASOError?
}

private struct RankingPersistenceBatchOutcome: Sendable {
    let outcomes: [KeywordBackgroundRefreshOutcome]
    let statsRebuildRequests: Set<RankingStatsRebuildRequest>
    let successfulPageResults: [RankingRefreshPageResult]

    var failureCount: Int {
        outcomes.filter { $0.error != nil }.count
    }
}

struct AppDetailRefreshResult: Sendable {
    let keywordOutcomes: [KeywordBackgroundRefreshOutcome]
    let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
    let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
    let firstError: OpenASOError?
}

final class AppDetailRefreshService: Sendable {
    private static let rankingFetchConcurrency = 4
    private static let rankingPersistenceBatchSize = 5

    private let backgroundModelStore: BackgroundModelStore
    private let refreshCoordinator: RankingRefreshCoordinator
    private let keywordMetricsService: KeywordMetricsService
    private let appStorefrontRatingService: AppStorefrontRatingService
    private let appStorefrontReviewService: AppStorefrontReviewService
    private let appStoreConnectReviewService: AppStoreConnectReviewService
    private let progressStore: AppRefreshProgressStore?
    private let ratingsReviewsRefreshRecorder: (@Sendable (Date) async -> Void)?

    init(
        backgroundModelStore: BackgroundModelStore,
        refreshCoordinator: RankingRefreshCoordinator,
        keywordMetricsService: KeywordMetricsService,
        appStorefrontRatingService: AppStorefrontRatingService,
        appStorefrontReviewService: AppStorefrontReviewService,
        appStoreConnectReviewService: AppStoreConnectReviewService,
        progressStore: AppRefreshProgressStore? = nil,
        ratingsReviewsRefreshRecorder: (@Sendable (Date) async -> Void)? = nil
    ) {
        self.backgroundModelStore = backgroundModelStore
        self.refreshCoordinator = refreshCoordinator
        self.keywordMetricsService = keywordMetricsService
        self.appStorefrontRatingService = appStorefrontRatingService
        self.appStorefrontReviewService = appStorefrontReviewService
        self.appStoreConnectReviewService = appStoreConnectReviewService
        self.progressStore = progressStore
        self.ratingsReviewsRefreshRecorder = ratingsReviewsRefreshRecorder
    }

    func refresh(_ request: AppDetailRefreshRequest) async -> AppDetailRefreshResult {
        await progressStore?.beginRefresh(request)
        let keywordOutcomes: [KeywordBackgroundRefreshOutcome]
        let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
        let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]

        switch request.workspace {
        case .keywords:
            keywordOutcomes = await refreshKeywords(request)
            if request.refreshRatings || request.refreshReviews {
                (ratingOutcomes, reviewOutcomes) = await refreshRatingsAndReviews(request)
            } else {
                ratingOutcomes = []
                reviewOutcomes = []
            }
        case .ratings:
            if request.refreshRatings || request.refreshReviews {
                (ratingOutcomes, reviewOutcomes) = await refreshRatingsAndReviews(request)
            } else {
                ratingOutcomes = []
                reviewOutcomes = []
            }
            keywordOutcomes = await refreshKeywords(request)
        }

        let firstError = firstRefreshError(
            workspace: request.workspace,
            keywordOutcomes: keywordOutcomes,
            ratingOutcomes: ratingOutcomes,
            reviewOutcomes: reviewOutcomes
        )
        await progressStore?.updatePhase(.finishing)
        await progressStore?.finish(error: firstError)

        return AppDetailRefreshResult(
            keywordOutcomes: keywordOutcomes,
            ratingOutcomes: ratingOutcomes,
            reviewOutcomes: reviewOutcomes,
            firstError: firstError
        )
    }

    private func refreshKeywords(_ request: AppDetailRefreshRequest) async -> [KeywordBackgroundRefreshOutcome] {
        guard request.refreshKeywords, !request.trackIdentityKeys.isEmpty else {
            await progressStore?.updateStep(.keywords, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await progressStore?.updateStep(.metrics, status: .skipped, completed: 0, total: 0, failureCount: 0)
            return []
        }

        do {
            await progressStore?.updatePhase(.refreshingKeywords)
            let (rankingRequests, missingOutcomes) = try await backgroundModelStore.read { modelContext in
                let targetIdentityKeys = request.trackIdentityKeys
                let descriptor = FetchDescriptor<TrackedAppKeyword>(
                    predicate: #Predicate { track in
                        targetIdentityKeys.contains(track.identityKey)
                    }
                )
                let tracks = try modelContext.fetch(descriptor)
                let foundIdentityKeys = Set(tracks.map(\.identityKey))
                let missingOutcomes = request.trackIdentityKeys
                    .filter { !foundIdentityKeys.contains($0) }
                    .map { KeywordBackgroundRefreshOutcome(trackIdentityKey: $0, error: .appNotFound) }
                return (tracks.map(RankingRefreshRequest.init), missingOutcomes)
            }

            let missingFailureCount = missingOutcomes.count
            if rankingRequests.isEmpty {
                await progressStore?.updateStep(
                    .keywords,
                    status: missingFailureCount > 0 ? .failed : .skipped,
                    completed: missingFailureCount,
                    total: request.trackIdentityKeys.count,
                    failureCount: missingFailureCount
                )
            }

            let keywordOutcomes = await refreshRankings(
                rankingRequests,
                trigger: request.trigger,
                missingFailureCount: missingFailureCount,
                totalRequestedCount: request.trackIdentityKeys.count
            )

            if request.refreshMetrics {
                await progressStore?.updatePhase(.refreshingMetrics)
                _ = try await keywordMetricsService.refreshMetrics(
                    for: rankingRequests.map(\.identityKey),
                    popularityContextAppStoreID: request.popularityContextAppStoreID,
                    webSession: request.appleAdsWebSession,
                    using: backgroundModelStore,
                    progress: { completed, total, failureCount in
                        await self.progressStore?.updateStep(
                            .metrics,
                            status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                            completed: completed,
                            total: total,
                            failureCount: failureCount
                        )
                    }
                )
            } else {
                await progressStore?.updateStep(.metrics, status: .skipped, completed: 0, total: 0, failureCount: 0)
            }

            return missingOutcomes + keywordOutcomes
        } catch {
            let mappedError = OpenASOError.map(error)
            await progressStore?.updateStep(
                .keywords,
                status: .failed,
                completed: request.trackIdentityKeys.count,
                total: request.trackIdentityKeys.count,
                failureCount: request.trackIdentityKeys.count
            )
            return request.trackIdentityKeys.map {
                KeywordBackgroundRefreshOutcome(trackIdentityKey: $0, error: mappedError)
            }
        }
    }

    private func refreshRankings(
        _ rankingRequests: [RankingRefreshRequest],
        trigger: String,
        missingFailureCount: Int,
        totalRequestedCount: Int
    ) async -> [KeywordBackgroundRefreshOutcome] {
        guard !rankingRequests.isEmpty else { return [] }

        if trigger == "daily_refresh" {
            await refreshCoordinator.recordRefreshTriggered()
        }
        let rankingPageFetcher = await refreshCoordinator.makeRankingPageFetcher()
        await refreshCoordinator.captureKeywordRefreshStarted(trigger: trigger, trackCount: rankingRequests.count)
        await progressStore?.updateStep(
            .keywords,
            status: .running,
            completed: missingFailureCount,
            total: totalRequestedCount,
            failureCount: missingFailureCount
        )

        var outcomes: [KeywordBackgroundRefreshOutcome] = []
        var statsRebuildRequests = Set<RankingStatsRebuildRequest>()
        var pendingPageResults: [RankingRefreshPageResult] = []
        var completedCount = 0
        var failureCount = 0

        func flushPendingPageResults() async {
            guard !pendingPageResults.isEmpty else { return }

            let pageResults = pendingPageResults
            pendingPageResults.removeAll(keepingCapacity: true)
            let batchOutcome = await persistRankingPageBatch(pageResults)
            outcomes.append(contentsOf: batchOutcome.outcomes)
            statsRebuildRequests.formUnion(batchOutcome.statsRebuildRequests)
            failureCount += batchOutcome.failureCount
            for pageResult in batchOutcome.successfulPageResults {
                refreshCoordinator.scheduleTopRankingMetadataEnrichment(for: pageResult)
            }
        }

        await withTaskGroup(of: (RankingRefreshRequest, Result<RankingRefreshPageResult, OpenASOError>).self) { group in
            var nextRequestIndex = 0
            var activeFetchCount = 0

            func enqueueNextFetchIfPossible() {
                guard activeFetchCount < Self.rankingFetchConcurrency,
                      nextRequestIndex < rankingRequests.count else {
                    return
                }

                let rankingRequest = rankingRequests[nextRequestIndex]
                nextRequestIndex += 1
                activeFetchCount += 1
                group.addTask {
                    let result = await rankingPageFetcher(rankingRequest)
                    return (rankingRequest, result)
                }
            }

            for _ in 0..<min(Self.rankingFetchConcurrency, rankingRequests.count) {
                enqueueNextFetchIfPossible()
            }

            while let (rankingRequest, result) = await group.next() {
                activeFetchCount -= 1

                switch result {
                case .success(let pageResult):
                    pendingPageResults.append(pageResult)
                    if pendingPageResults.count >= Self.rankingPersistenceBatchSize {
                        await flushPendingPageResults()
                    }
                case .failure(let error):
                    try? await backgroundModelStore.write { modelContext in
                        _ = try refreshCoordinator.recordRefreshFailure(
                            identityKey: rankingRequest.identityKey,
                            error: error,
                            in: modelContext,
                            saveChanges: false
                        )
                    }
                    outcomes.append(KeywordBackgroundRefreshOutcome(trackIdentityKey: rankingRequest.identityKey, error: error))
                    failureCount += 1
                }

                completedCount += 1
                await progressStore?.updateStep(
                    .keywords,
                    status: completedCount >= rankingRequests.count
                        ? (failureCount + missingFailureCount > 0 ? .failed : .completed)
                        : .running,
                    completed: completedCount + missingFailureCount,
                    total: totalRequestedCount,
                    failureCount: failureCount + missingFailureCount
                )

                enqueueNextFetchIfPossible()
            }
        }

        await flushPendingPageResults()
        await progressStore?.updateStep(
            .keywords,
            status: failureCount + missingFailureCount > 0 ? .failed : .completed,
            completed: completedCount + missingFailureCount,
            total: totalRequestedCount,
            failureCount: failureCount + missingFailureCount
        )

        if !statsRebuildRequests.isEmpty {
            let requests = statsRebuildRequests
            try? await backgroundModelStore.write { modelContext in
                refreshCoordinator.rebuildDerivedStats(for: requests, in: modelContext)
            }
        }

        await refreshCoordinator.captureKeywordRefreshCompleted(
            trigger: trigger,
            trackCount: rankingRequests.count,
            failureCount: outcomes.filter { $0.error != nil }.count
        )
        return outcomes
    }

    private func persistRankingPageBatch(
        _ pageResults: [RankingRefreshPageResult]
    ) async -> RankingPersistenceBatchOutcome {
        do {
            return try await backgroundModelStore.write { modelContext in
                var outcomes: [KeywordBackgroundRefreshOutcome] = []
                var statsRebuildRequests = Set<RankingStatsRebuildRequest>()
                var successfulPageResults: [RankingRefreshPageResult] = []

                for pageResult in pageResults {
                    do {
                        _ = try refreshCoordinator.persistRankingPage(
                            pageResult,
                            in: modelContext,
                            rebuildDerivedStats: false,
                            saveChanges: false,
                            scheduleMetadataEnrichment: false
                        )
                        if let statsRebuildRequest = RankingStatsRebuildRequest(pageRequest: pageResult.request) {
                            statsRebuildRequests.insert(statsRebuildRequest)
                        }
                        successfulPageResults.append(pageResult)
                        outcomes.append(KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: pageResult.request.identityKey,
                            error: nil
                        ))
                    } catch {
                        let mappedError = OpenASOError.map(error)
                        _ = try? refreshCoordinator.recordRefreshFailure(
                            identityKey: pageResult.request.identityKey,
                            error: mappedError,
                            in: modelContext,
                            saveChanges: false
                        )
                        outcomes.append(KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: pageResult.request.identityKey,
                            error: mappedError
                        ))
                    }
                }

                return RankingPersistenceBatchOutcome(
                    outcomes: outcomes,
                    statsRebuildRequests: statsRebuildRequests,
                    successfulPageResults: successfulPageResults
                )
            }
        } catch {
            let mappedError = OpenASOError.map(error)
            try? await backgroundModelStore.write { modelContext in
                for pageResult in pageResults {
                    _ = try? refreshCoordinator.recordRefreshFailure(
                        identityKey: pageResult.request.identityKey,
                        error: mappedError,
                        in: modelContext,
                        saveChanges: false
                    )
                }
            }
            return RankingPersistenceBatchOutcome(
                outcomes: pageResults.map {
                    KeywordBackgroundRefreshOutcome(trackIdentityKey: $0.request.identityKey, error: mappedError)
                },
                statsRebuildRequests: [],
                successfulPageResults: []
            )
        }
    }

    private func refreshRatingsAndReviews(
        _ request: AppDetailRefreshRequest
    ) async -> ([AppStorefrontRatingRefreshOutcome], [AppStorefrontReviewRefreshOutcome]) {
        guard request.refreshRatings || request.refreshReviews else {
            await progressStore?.updateStep(.ratings, status: .skipped, completed: 0, total: 0, failureCount: 0)
            await progressStore?.updateStep(.reviews, status: .skipped, completed: 0, total: 0, failureCount: 0)
            return ([], [])
        }

        do {
            let storefrontCodes = request.storefrontSelection.codes
            let ratingOutcomes: [AppStorefrontRatingRefreshOutcome]
            if request.refreshRatings {
                await progressStore?.updatePhase(.refreshingRatings)
                ratingOutcomes = await appStorefrontRatingService.fetchRatingOutcomes(
                    appStoreID: request.app.appStoreID,
                    appName: request.app.name,
                    storefronts: storefrontCodes,
                    progress: { completed, total, failureCount in
                        await self.progressStore?.updateStep(
                            .ratings,
                            status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                            completed: completed,
                            total: total,
                            failureCount: failureCount
                        )
                    }
                )
                try await persistRatingOutcomes(ratingOutcomes, for: request.app)
            } else {
                await progressStore?.updateStep(.ratings, status: .skipped, completed: 0, total: 0, failureCount: 0)
                ratingOutcomes = []
            }

            let reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
            if request.refreshReviews {
                await progressStore?.updatePhase(.refreshingReviews)
                reviewOutcomes = try await refreshReviews(
                    request: request,
                    storefrontCodes: storefrontCodes
                )
            } else {
                await progressStore?.updateStep(.reviews, status: .skipped, completed: 0, total: 0, failureCount: 0)
                reviewOutcomes = []
            }
            let outcomes = (ratingOutcomes, reviewOutcomes)
            if request.recordsRatingsReviewsRefresh, didSuccessfullyRefreshRatingsOrReviews(outcomes) {
                await ratingsReviewsRefreshRecorder?(.now)
            }
            return outcomes
        } catch {
            let mappedError = OpenASOError.map(error)
            await progressStore?.updateStep(
                .ratings,
                status: .failed,
                completed: request.storefrontSelection.codes.count,
                total: request.storefrontSelection.codes.count,
                failureCount: max(1, request.storefrontSelection.codes.count)
            )
            let ratingOutcome = AppStorefrontRatingRefreshOutcome(
                storefront: "all",
                result: nil,
                error: mappedError
            )
            return ([ratingOutcome], [])
        }
    }

    private func didSuccessfullyRefreshRatingsOrReviews(
        _ outcomes: ([AppStorefrontRatingRefreshOutcome], [AppStorefrontReviewRefreshOutcome])
    ) -> Bool {
        let attemptedAnyRefresh = !outcomes.0.isEmpty || !outcomes.1.isEmpty
        guard attemptedAnyRefresh else { return false }

        return outcomes.0.allSatisfy { $0.error == nil }
            && outcomes.1.allSatisfy { $0.error == nil }
    }

    private func refreshReviews(
        request: AppDetailRefreshRequest,
        storefrontCodes: [String]
    ) async throws -> [AppStorefrontReviewRefreshOutcome] {
        guard
            request.appStoreConnectCredentials.isComplete,
            let bundleID = request.app.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty
        else {
            return try await refreshStorefrontReviews(request: request, storefrontCodes: storefrontCodes)
        }

        do {
            await progressStore?.updateStep(.reviews, status: .running, completed: 0, total: 1, failureCount: 0)
            let app = try await appStoreConnectReviewService.resolveApp(
                bundleID: bundleID,
                using: request.appStoreConnectCredentials
            )
            var storedCount = 0
            let fetchedCount = try await appStoreConnectReviewService.fetchReviewPages(
                appStoreConnectAppID: app.id,
                appStoreID: request.app.appStoreID,
                credentials: request.appStoreConnectCredentials,
            ) { pageReviews in
                let pageStoredCount = try await backgroundModelStore.write { modelContext in
                    let storeApp = try storeApp(for: request.app, in: modelContext)
                    return try appStoreConnectReviewService.upsert(pageReviews, storeApp: storeApp, in: modelContext)
                }
                storedCount += pageStoredCount
                return pageStoredCount == pageReviews.count
            }
            await progressStore?.updateStep(
                .reviews,
                status: .completed,
                completed: 1,
                total: 1,
                failureCount: 0
            )
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "app-store-connect",
                    fetchedReviews: fetchedCount,
                    storedReviews: storedCount,
                    error: nil
                )
            ]
        } catch OpenASOError.appNotFound {
            return try await refreshStorefrontReviews(request: request, storefrontCodes: storefrontCodes)
        } catch {
            await progressStore?.updateStep(
                .reviews,
                status: .failed,
                completed: 1,
                total: 1,
                failureCount: 1
            )
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "app-store-connect",
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: OpenASOError.map(error)
                )
            ]
        }
    }

    private func persistRatingOutcomes(
        _ outcomes: [AppStorefrontRatingRefreshOutcome],
        for app: AppDetailRefreshAppSnapshot
    ) async throws {
        try await backgroundModelStore.write { modelContext in
            let storeApp = try storeApp(for: app, in: modelContext)
            for outcome in outcomes {
                appStorefrontRatingService.persist(outcome, for: storeApp, in: modelContext)
            }
        }
    }

    private func refreshStorefrontReviews(
        request: AppDetailRefreshRequest,
        storefrontCodes: [String]
    ) async throws -> [AppStorefrontReviewRefreshOutcome] {
        let targetStorefronts = AppStorefrontReviewService.normalizedStorefronts(from: storefrontCodes)
        guard !targetStorefronts.isEmpty else {
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "all",
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: .providerUnavailable("No storefronts were available for reviews refresh.")
                )
            ]
        }

        var outcomes: [AppStorefrontReviewRefreshOutcome] = []
        var completedCount = 0
        var failureCount = 0
        await progressStore?.updateStep(.reviews, status: .running, completed: 0, total: targetStorefronts.count, failureCount: 0)

        for storefront in targetStorefronts {
            do {
                var storedCount = 0
                let fetchedCount = try await appStorefrontReviewService.fetchReviewPages(
                    appStoreID: request.app.appStoreID,
                    storefront: storefront
                ) { pageReviews in
                    let pageStoredCount = try await backgroundModelStore.write { modelContext in
                        let storeApp = try storeApp(for: request.app, in: modelContext)
                        return try appStorefrontReviewService.upsert(
                            pageReviews,
                            storeApp: storeApp,
                            in: modelContext
                        )
                    }
                    storedCount += pageStoredCount
                    return pageStoredCount == pageReviews.count
                }
                outcomes.append(AppStorefrontReviewRefreshOutcome(
                    storefront: storefront,
                    fetchedReviews: fetchedCount,
                    storedReviews: storedCount,
                    error: nil
                ))
            } catch {
                failureCount += 1
                outcomes.append(AppStorefrontReviewRefreshOutcome(
                    storefront: storefront,
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: OpenASOError.map(error)
                ))
            }

            completedCount += 1
            await progressStore?.updateStep(
                .reviews,
                status: completedCount >= targetStorefronts.count ? (failureCount > 0 ? .failed : .completed) : .running,
                completed: completedCount,
                total: targetStorefronts.count,
                failureCount: failureCount
            )
        }

        return outcomes
    }

    private func storeApp(
        for app: AppDetailRefreshAppSnapshot,
        in modelContext: ModelContext
    ) throws -> StoreApp {
        let targetAppStoreID = app.appStoreID
        let descriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { storeApp in
                storeApp.appStoreID == targetAppStoreID
            }
        )

        let storeApp = try modelContext.fetch(descriptor).first ?? StoreApp(
            appStoreID: app.appStoreID,
            bundleID: app.bundleID,
            name: app.name,
            subtitle: app.subtitle,
            sellerName: app.sellerName,
            iconURLString: nil,
            defaultPlatform: app.defaultPlatform
        )
        if storeApp.modelContext == nil {
            modelContext.insert(storeApp)
        }
        updateIfChanged(&storeApp.bundleID, app.bundleID)
        updateIfChanged(&storeApp.name, app.name)
        updateIfChanged(&storeApp.subtitle, app.subtitle)
        updateIfChanged(&storeApp.sellerName, app.sellerName)
        if storeApp.defaultPlatform != app.defaultPlatform {
            storeApp.defaultPlatform = app.defaultPlatform
        }
        return storeApp
    }

    private func updateIfChanged<Value: Equatable>(_ value: inout Value, _ newValue: Value) {
        if value != newValue {
            value = newValue
        }
    }

    private func firstRefreshError(
        workspace: AppDetailRefreshWorkspace,
        keywordOutcomes: [KeywordBackgroundRefreshOutcome],
        ratingOutcomes: [AppStorefrontRatingRefreshOutcome],
        reviewOutcomes: [AppStorefrontReviewRefreshOutcome]
    ) -> OpenASOError? {
        let keywordError = keywordOutcomes.first(where: { $0.error != nil })?.error
        let ratingError = ratingOutcomes.first(where: { $0.error != nil })?.error
        let reviewError = reviewOutcomes.first(where: { $0.error != nil })?.error

        switch workspace {
        case .keywords:
            return keywordError ?? ratingError ?? reviewError
        case .ratings:
            return ratingError ?? reviewError ?? keywordError
        }
    }
}
