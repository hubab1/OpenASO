import Foundation
import OSLog
import SwiftData

final class AppStorefrontRatingService: Sendable {
    private static let fetchConcurrency = 4
    private let fetcher: AppStorefrontRatingFetcher

    init(httpClient: HTTPClient) {
        self.fetcher = AppStorefrontRatingFetcher(httpClient: httpClient)
    }

    @MainActor
    func refreshRatings(
        for storeApp: StoreApp,
        storefronts: [String],
        in modelContext: ModelContext,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async -> [AppStorefrontRatingRefreshOutcome] {
        let outcomes: [AppStorefrontRatingRefreshOutcome]
        do {
            outcomes = try await fetchRatingOutcomes(
                appStoreID: storeApp.appStoreID,
                appName: storeApp.name,
                storefronts: storefronts,
                progress: progress
            )
        } catch {
            return []
        }

        for outcome in outcomes {
            persist(outcome, for: storeApp, in: modelContext)
        }
        try? modelContext.save()
        OpenASOLog.ratings.info(
            "Finished ratings refresh appStoreID=\(storeApp.appStoreID, privacy: .public) successes=\(outcomes.filter { $0.error == nil }.count, privacy: .public) failures=\(outcomes.filter { $0.error != nil }.count, privacy: .public)"
        )
        return outcomes
    }

    func fetchRatingOutcomes(
        appStoreID: Int64,
        appName: String,
        storefronts: [String],
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async throws -> [AppStorefrontRatingRefreshOutcome] {
        try Task.checkCancellation()
        let targetStorefronts = Self.normalizedStorefronts(from: storefronts)

        guard !targetStorefronts.isEmpty else {
            let error = OpenASOError.providerUnavailable("No storefronts were available for ratings refresh.")
            OpenASOLog.ratings.error(
                "Ratings refresh aborted appStoreID=\(appStoreID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return [
                AppStorefrontRatingRefreshOutcome(storefront: "all", result: nil, error: error)
            ]
        }

        OpenASOLog.ratings.info(
            "Starting ratings refresh appStoreID=\(appStoreID, privacy: .public) appName=\(appName, privacy: .public) requestedStorefronts=\(storefronts.count, privacy: .public) normalizedStorefronts=\(targetStorefronts.count, privacy: .public)"
        )

        var completedCount = 0
        var failureCount = 0
        await progress?(0, targetStorefronts.count, 0)
        try Task.checkCancellation()
        var outcomesByIndex: [Int: AppStorefrontRatingRefreshOutcome] = [:]
        outcomesByIndex.reserveCapacity(targetStorefronts.count)

        try await withThrowingTaskGroup(of: (Int, AppStorefrontRatingRefreshOutcome).self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < targetStorefronts.count else { return }
                let index = nextIndex
                let storefront = targetStorefronts[index]
                nextIndex += 1
                group.addTask {
                    let outcome = try await self.fetchOutcome(
                        appStoreID: appStoreID,
                        storefront: storefront
                    )
                    return (index, outcome)
                }
            }

            for _ in 0..<min(Self.fetchConcurrency, targetStorefronts.count) {
                enqueueNext()
            }

            while let (index, outcome) = try await group.next() {
                try Task.checkCancellation()
                outcomesByIndex[index] = outcome
                completedCount += 1
                if outcome.error != nil {
                    failureCount += 1
                }
                await progress?(completedCount, targetStorefronts.count, failureCount)
                enqueueNext()
            }
        }

        return targetStorefronts.indices.compactMap { outcomesByIndex[$0] }
    }

    private func fetchOutcome(
        appStoreID: Int64,
        storefront: String
    ) async throws -> AppStorefrontRatingRefreshOutcome {
        try Task.checkCancellation()
        do {
            OpenASOLog.ratings.debug(
                "Refreshing ratings storefront=\(storefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public)"
            )
            let result = try await fetcher.fetchRatings(
                appStoreID: appStoreID,
                storefront: storefront
            )
            try Task.checkCancellation()
            OpenASOLog.ratings.info(
                "Fetched ratings storefront=\(storefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) ratingCount=\(result.ratingCount.map(String.init) ?? "nil", privacy: .public) averageRating=\(result.averageRating.map { String(format: "%.2f", $0) } ?? "nil", privacy: .public)"
            )
            return AppStorefrontRatingRefreshOutcome(storefront: storefront, result: result, error: nil)
        } catch let unavailable as AppStorefrontRatingStorefrontUnavailable {
            try Task.checkCancellation()
            OpenASOLog.ratings.info(
                "Ratings unavailable in storefront storefront=\(storefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) reason=\(unavailable.localizedDescription, privacy: .public)"
            )
            return AppStorefrontRatingRefreshOutcome(
                storefront: storefront,
                result: nil,
                error: nil,
                unavailabilityReason: unavailable.localizedDescription,
                clearsStoredRatings: true
            )
        } catch let mismatch as AppStorefrontRatingStorefrontMismatch {
            try Task.checkCancellation()
            let mappedError = OpenASOError.providerUnavailable(mismatch.localizedDescription)
            OpenASOLog.ratings.error(
                "Ratings storefront mismatch storefront=\(storefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) actualStorefront=\(mismatch.actual, privacy: .public) finalURL=\(mismatch.finalURL ?? "nil", privacy: .public)"
            )
            return AppStorefrontRatingRefreshOutcome(
                storefront: storefront,
                result: nil,
                error: mappedError,
                clearsStoredRatings: true
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let mappedError = OpenASOError.map(error)
            OpenASOLog.ratings.error(
                "Ratings refresh failed storefront=\(storefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) error=\(mappedError.localizedDescription, privacy: .public)"
            )
            return AppStorefrontRatingRefreshOutcome(
                storefront: storefront,
                result: nil,
                error: mappedError
            )
        }
    }

    func persist(
        _ outcome: AppStorefrontRatingRefreshOutcome,
        for storeApp: StoreApp,
        in modelContext: ModelContext
    ) {
        if let result = outcome.result {
            upsert(
                result,
                ratingDate: nil,
                submissionCount: 1,
                winningCount: 1,
                confidence: "single_source",
                for: storeApp,
                in: modelContext
            )
        }

        if outcome.clearsStoredRatings {
            clearRatings(appStoreID: storeApp.appStoreID, storefront: outcome.storefront, in: modelContext)
        }
    }

    func fetchRatings(appStoreID: Int64, storefront: String) async throws -> AppStorefrontRatingResult {
        try await fetcher.fetchRatings(
            appStoreID: appStoreID,
            storefront: storefront
        )
    }

    private static func normalizedStorefronts(from storefronts: [String]) -> [String] {
        let normalizedStorefronts = storefronts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Array(Set(normalizedStorefronts)).sorted()
    }

    private func upsert(
        _ result: AppStorefrontRatingResult,
        ratingDate: String?,
        submissionCount: Int,
        winningCount: Int,
        confidence: String?,
        for storeApp: StoreApp,
        in modelContext: ModelContext
    ) {
        let resolvedRatingDate = ratingDate ?? LatestAppRating.ratingDateString(for: result.observedAt)
        let snapshotKey = AppDailyRating.makeIdentityKey(
            appStoreID: result.appStoreID,
            storefront: result.storefront,
            ratingDate: resolvedRatingDate
        )
        let snapshot: AppDailyRating
        if let existing = try? fetchSnapshot(identityKey: snapshotKey, in: modelContext) {
            snapshot = existing
            guard result.observedAt >= existing.observedAt else {
                return
            }
        } else {
            snapshot = AppDailyRating(
                appStoreID: result.appStoreID,
                storefront: result.storefront,
                ratingCount: result.ratingCount,
                averageRating: result.averageRating,
                oneStarRatingCount: result.ratingCounts?.oneStar,
                twoStarRatingCount: result.ratingCounts?.twoStar,
                threeStarRatingCount: result.ratingCounts?.threeStar,
                fourStarRatingCount: result.ratingCounts?.fourStar,
                fiveStarRatingCount: result.ratingCounts?.fiveStar,
                ratingDate: resolvedRatingDate,
                observedAt: result.observedAt,
                submissionCount: submissionCount,
                winningCount: winningCount,
                confidence: confidence,
                source: result.source,
                storeApp: storeApp
            )
            modelContext.insert(snapshot)
        }
        snapshot.ratingCount = result.ratingCount
        snapshot.averageRating = result.averageRating
        if let ratingCounts = result.ratingCounts {
            snapshot.oneStarRatingCount = ratingCounts.oneStar
            snapshot.twoStarRatingCount = ratingCounts.twoStar
            snapshot.threeStarRatingCount = ratingCounts.threeStar
            snapshot.fourStarRatingCount = ratingCounts.fourStar
            snapshot.fiveStarRatingCount = ratingCounts.fiveStar
        }
        snapshot.ratingDate = resolvedRatingDate
        snapshot.observedAt = result.observedAt
        snapshot.submissionCount = submissionCount
        snapshot.winningCount = winningCount
        snapshot.confidenceRaw = confidence
        snapshot.source = result.source
        snapshot.storeApp = storeApp

        let identityKey = LatestAppRating.makeIdentityKey(
            appStoreID: result.appStoreID,
            storefront: result.storefront
        )
        let latest: LatestAppRating
        if let existing = try? fetchLatest(identityKey: identityKey, in: modelContext) {
            latest = existing
            guard result.observedAt >= existing.observedAt else {
                return
            }
        } else {
            latest = LatestAppRating(
                appStoreID: result.appStoreID,
                storefront: result.storefront,
                ratingCount: result.ratingCount,
                averageRating: result.averageRating,
                oneStarRatingCount: result.ratingCounts?.oneStar,
                twoStarRatingCount: result.ratingCounts?.twoStar,
                threeStarRatingCount: result.ratingCounts?.threeStar,
                fourStarRatingCount: result.ratingCounts?.fourStar,
                fiveStarRatingCount: result.ratingCounts?.fiveStar,
                ratingDate: resolvedRatingDate,
                observedAt: result.observedAt,
                submissionCount: submissionCount,
                winningCount: winningCount,
                confidence: confidence,
                source: result.source,
                storeApp: storeApp
            )
            modelContext.insert(latest)
        }

        latest.ratingCount = result.ratingCount
        latest.averageRating = result.averageRating
        if let ratingCounts = result.ratingCounts {
            latest.oneStarRatingCount = ratingCounts.oneStar
            latest.twoStarRatingCount = ratingCounts.twoStar
            latest.threeStarRatingCount = ratingCounts.threeStar
            latest.fourStarRatingCount = ratingCounts.fourStar
            latest.fiveStarRatingCount = ratingCounts.fiveStar
        }
        latest.ratingDate = resolvedRatingDate
        latest.observedAt = result.observedAt
        latest.submissionCount = submissionCount
        latest.winningCount = winningCount
        latest.confidenceRaw = confidence
        latest.source = result.source
        latest.storeApp = storeApp
    }

    private func fetchLatest(identityKey: String, in modelContext: ModelContext) throws -> LatestAppRating? {
        let targetIdentityKey = identityKey
        let descriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                latest.identityKey == targetIdentityKey
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchSnapshot(identityKey: String, in modelContext: ModelContext) throws -> AppDailyRating? {
        let targetIdentityKey = identityKey
        let descriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { snapshot in
                snapshot.identityKey == targetIdentityKey
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func clearRatings(appStoreID: Int64, storefront: String, in modelContext: ModelContext) {
        let targetAppStoreID = appStoreID
        let targetStorefront = storefront
        let latestDescriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                latest.appStoreID == targetAppStoreID && latest.storefront == targetStorefront
            }
        )
        let snapshotDescriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { snapshot in
                snapshot.appStoreID == targetAppStoreID && snapshot.storefront == targetStorefront
            }
        )

        let latest = (try? modelContext.fetch(latestDescriptor)) ?? []
        let snapshots = (try? modelContext.fetch(snapshotDescriptor)) ?? []
        for value in latest {
            modelContext.delete(value)
        }
        for value in snapshots {
            modelContext.delete(value)
        }
        OpenASOLog.ratings.info(
            "Cleared ratings storefront=\(storefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) latest=\(latest.count, privacy: .public) snapshots=\(snapshots.count, privacy: .public)"
        )
    }
}

private struct AppStorefrontRatingFetcher: Sendable {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func fetchRatings(
        appStoreID: Int64,
        storefront: String
    ) async throws -> AppStorefrontRatingResult {
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        do {
            return try await fetchRatingsOnce(
                request: try makeITunesLookupRequest(appStoreID: appStoreID, storefront: normalizedStorefront),
                appStoreID: appStoreID,
                storefront: normalizedStorefront,
                source: .iTunesSearch
            )
        } catch let unavailable as AppStorefrontRatingStorefrontUnavailable {
            OpenASOLog.ratings.info(
                "iTunes Lookup found no app in storefront storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) reason=\(unavailable.localizedDescription, privacy: .public)"
            )
            throw unavailable
        } catch where isRefreshCancellation(error) {
            throw error
        } catch {
            OpenASOLog.ratings.warning(
                "iTunes Lookup ratings fetch failed storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) error=\(OpenASOError.map(error).localizedDescription, privacy: .public); falling back to App Store page"
            )
        }

        return try await fetchRatingsOnce(
            request: try makeAppStoreRequest(appStoreID: appStoreID, storefront: normalizedStorefront),
            appStoreID: appStoreID,
            storefront: normalizedStorefront,
            source: .appStorePage
        )
    }

    private func fetchRatingsOnce(
        request: URLRequest,
        appStoreID: Int64,
        storefront normalizedStorefront: String,
        source: AppStorefrontSource
    ) async throws -> AppStorefrontRatingResult {
        let (data, response) = try await httpClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            OpenASOLog.ratings.error(
                "Ratings response was not HTTP storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public)"
            )
            throw OpenASOError.unexpectedResponse
        }
        let finalURL = httpResponse.url
        OpenASOLog.ratings.debug(
            "Ratings response source=\(source.rawValue, privacy: .public) storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) finalURL=\(finalURL?.absoluteString ?? "nil", privacy: .public)"
        )
        try validateRatingResponse(httpResponse)

        switch source {
        case .iTunesSearch:
            return try parseITunesLookupRatings(
                data: data,
                appStoreID: appStoreID,
                storefront: normalizedStorefront
            )
        case .appStorePage:
            return try parseAppStorePageRatings(
                data: data,
                appStoreID: appStoreID,
                storefront: normalizedStorefront,
                finalURL: finalURL
            )
        }
    }

    private func parseITunesLookupRatings(
        data: Data,
        appStoreID: Int64,
        storefront normalizedStorefront: String
    ) throws -> AppStorefrontRatingResult {
        let response: ITunesLookupRatingsResponse
        do {
            response = try Self.decoder.decode(ITunesLookupRatingsResponse.self, from: data)
        } catch {
            OpenASOLog.ratings.error(
                "iTunes Lookup ratings response was not decodable storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw OpenASOError.decodingFailed
        }

        guard let payload = response.results.first else {
            throw AppStorefrontRatingStorefrontUnavailable(
                storefront: normalizedStorefront,
                appStoreID: appStoreID
            )
        }

        guard payload.trackId == appStoreID else {
            throw OpenASOError.unexpectedResponse
        }

        guard payload.userRatingCount != nil || payload.averageUserRating != nil else {
            throw OpenASOError.providerUnavailable("iTunes Lookup did not include ratings.")
        }

        return AppStorefrontRatingResult(
            appStoreID: appStoreID,
            storefront: normalizedStorefront,
            ratingCount: payload.userRatingCount,
            averageRating: payload.averageUserRating,
            ratingCounts: nil,
            observedAt: .now,
            source: .iTunesSearch
        )
    }

    private func parseAppStorePageRatings(
        data: Data,
        appStoreID: Int64,
        storefront normalizedStorefront: String,
        finalURL: URL?
    ) throws -> AppStorefrontRatingResult {
        guard let html = String(data: data, encoding: .utf8) else {
            OpenASOLog.ratings.error(
                "Ratings response was not UTF-8 storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw OpenASOError.unexpectedResponse
        }

        let parser = AppStorefrontRatingParser()
        if let actualStorefront = parser.storefrontCode(html: html, responseURL: finalURL),
           actualStorefront != normalizedStorefront {
            throw AppStorefrontRatingStorefrontMismatch(
                expected: normalizedStorefront,
                actual: actualStorefront,
                finalURL: finalURL?.absoluteString
            )
        }

        guard let parsed = parser.parse(html: html) else {
            OpenASOLog.ratings.error(
                "Ratings parser found no values storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) htmlBytes=\(data.count, privacy: .public) sample=\(String(html.prefix(240)), privacy: .private)"
            )
            throw OpenASOError.providerUnavailable("App Store page did not include parseable ratings.")
        }
        OpenASOLog.ratings.debug(
            "Parsed ratings storefront=\(normalizedStorefront, privacy: .public) appStoreID=\(appStoreID, privacy: .public) ratingCount=\(parsed.ratingCount.map(String.init) ?? "nil", privacy: .public) averageRating=\(parsed.averageRating.map { String(format: "%.2f", $0) } ?? "nil", privacy: .public)"
        )

        return AppStorefrontRatingResult(
            appStoreID: appStoreID,
            storefront: normalizedStorefront,
            ratingCount: parsed.ratingCount,
            averageRating: parsed.averageRating,
            ratingCounts: parsed.ratingCounts,
            observedAt: .now,
            source: .appStorePage
        )
    }

    private func makeITunesLookupRequest(appStoreID: Int64, storefront: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [
            URLQueryItem(name: "id", value: String(appStoreID)),
            URLQueryItem(name: "country", value: storefront.lowercased())
        ]

        guard let url = components.url else {
            throw OpenASOError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json,text/javascript,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeAppStoreRequest(appStoreID: Int64, storefront: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/\(storefront)/app/id\(appStoreID)"
        components.queryItems = [
            URLQueryItem(name: "l", value: "en-US")
        ]

        guard let url = components.url else {
            throw OpenASOError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private func validateRatingResponse(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200 ..< 300:
            return
        case 404:
            throw OpenASOError.appNotFound
        case 429:
            throw OpenASOError.rateLimited
        case 500 ..< 600:
            throw OpenASOError.providerUnavailable("HTTP \(response.statusCode)")
        default:
            throw OpenASOError.providerUnavailable("HTTP \(response.statusCode)")
        }
    }
}

private func isRefreshCancellation(_ error: any Error) -> Bool {
    if error is CancellationError {
        return true
    }
    return (error as? URLError)?.code == .cancelled
}

private struct AppStorefrontRatingStorefrontMismatch: LocalizedError {
    let expected: String
    let actual: String
    let finalURL: String?

    var errorDescription: String? {
        "App Store served \(actual.uppercased()) ratings for \(expected.uppercased())."
    }
}

private struct AppStorefrontRatingStorefrontUnavailable: LocalizedError {
    let storefront: String
    let appStoreID: Int64

    var errorDescription: String? {
        "App \(appStoreID) is not available in \(storefront.uppercased())."
    }
}

private extension AppStorefrontRatingFetcher {
    static let decoder = JSONDecoder()
}
