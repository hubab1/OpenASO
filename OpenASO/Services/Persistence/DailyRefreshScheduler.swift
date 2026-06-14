import Foundation
import SwiftData

struct DailyRefreshScheduleConfiguration: Hashable {
    let isAutomaticRefreshEnabled: Bool
    let refreshTimeMinutes: Int
}

@MainActor
@Observable
final class DailyRefreshScheduler {
    private let settingsStore: AppSettingsStore
    private let refreshCoordinator: RankingRefreshCoordinator
    private let appDetailRefresh: ((AppDetailRefreshRequest) async -> AppDetailRefreshResult)?
    private let storefrontCodesProvider: () throws -> [String]
    private let popularityContextAppStoreIDProvider: () -> Int64?
    private let appleAdsWebSessionProvider: () -> AppleAdsWebSession?
    private let appStoreConnectCredentialsProvider: () -> AppStoreConnectCredentials
    private let scheduledLoop: ScheduledLoop
    private let timing: DailyRefreshSchedulerTiming

    private(set) var isRefreshing = false
    private(set) var lastOutcome: DailyRefreshOutcome?

    init(
        settingsStore: AppSettingsStore,
        refreshCoordinator: RankingRefreshCoordinator,
        appDetailRefresh: ((AppDetailRefreshRequest) async -> AppDetailRefreshResult)? = nil,
        storefrontCodesProvider: @escaping () throws -> [String] = { [] },
        popularityContextAppStoreIDProvider: @escaping () -> Int64? = { nil },
        appleAdsWebSessionProvider: @escaping () -> AppleAdsWebSession? = { nil },
        appStoreConnectCredentialsProvider: @escaping () -> AppStoreConnectCredentials = {
            AppStoreConnectCredentials(issuerID: "", keyID: "", privateKey: "")
        },
        scheduledLoop: ScheduledLoop = ScheduledLoop(),
        timing: DailyRefreshSchedulerTiming = .live
    ) {
        self.settingsStore = settingsStore
        self.refreshCoordinator = refreshCoordinator
        self.appDetailRefresh = appDetailRefresh
        self.storefrontCodesProvider = storefrontCodesProvider
        self.popularityContextAppStoreIDProvider = popularityContextAppStoreIDProvider
        self.appleAdsWebSessionProvider = appleAdsWebSessionProvider
        self.appStoreConnectCredentialsProvider = appStoreConnectCredentialsProvider
        self.scheduledLoop = scheduledLoop
        self.timing = timing
    }

    func run(in modelContext: ModelContext) async {
        await scheduledLoop.run {
            _ = await triggerIfNeeded(in: modelContext)
        } sleepUntilNextRun: {
            await sleepUntilNextCheck()
        }
    }

    @discardableResult
    func triggerIfNeeded(
        in modelContext: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) async -> Bool {
        guard !isRefreshing, settingsStore.shouldTriggerRefresh(at: now, calendar: calendar) else {
            return false
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }
        settingsStore.markRefreshTriggered(on: now)
        if let appDetailRefresh {
            await refreshApps(
                in: modelContext,
                now: now,
                calendar: calendar,
                appDetailRefresh: appDetailRefresh
            )
            return true
        }

        let outcomes = await refreshCoordinator.refreshStaleTracks(in: modelContext)
        let failureCount = outcomes.filter { $0.error != nil }.count
        lastOutcome = DailyRefreshOutcome(
            triggeredAt: now,
            refreshedCount: outcomes.count,
            failureCount: failureCount
        )
        return true
    }

    private func refreshApps(
        in modelContext: ModelContext,
        now: Date,
        calendar: Calendar,
        appDetailRefresh: (AppDetailRefreshRequest) async -> AppDetailRefreshResult
    ) async {
        do {
            let storefrontCodes = try storefrontCodesProvider()
            let shouldRefreshRatingsReviews = !settingsStore.hasRefreshedRatingsReviews(on: now, calendar: calendar)
            let requests = try dailyRefreshRequests(
                in: modelContext,
                storefrontCodes: storefrontCodes,
                refreshRatingsReviews: shouldRefreshRatingsReviews
            )
            var failureCount = 0
            var didAttemptRatingsReviews = false
            var didRefreshRatingsReviewsSuccessfully = shouldRefreshRatingsReviews

            for request in requests {
                let result = await appDetailRefresh(request)
                if result.firstError != nil {
                    failureCount += 1
                }

                if request.refreshRatings || request.refreshReviews {
                    didAttemptRatingsReviews = true
                    let ratingsSucceeded = result.ratingOutcomes.allSatisfy { $0.error == nil }
                    let reviewsSucceeded = result.reviewOutcomes.allSatisfy { $0.error == nil }
                    didRefreshRatingsReviewsSuccessfully = didRefreshRatingsReviewsSuccessfully
                        && ratingsSucceeded
                        && reviewsSucceeded
                }
            }

            if didAttemptRatingsReviews, didRefreshRatingsReviewsSuccessfully {
                settingsStore.markRatingsReviewsRefreshed(on: now)
            }

            lastOutcome = DailyRefreshOutcome(
                triggeredAt: now,
                refreshedCount: requests.count,
                failureCount: failureCount
            )
        } catch {
            lastOutcome = DailyRefreshOutcome(
                triggeredAt: now,
                refreshedCount: 0,
                failureCount: 1
            )
        }
    }

    private func dailyRefreshRequests(
        in modelContext: ModelContext,
        storefrontCodes: [String],
        refreshRatingsReviews: Bool
    ) throws -> [AppDetailRefreshRequest] {
        let apps = try modelContext.fetch(FetchDescriptor<TrackedApp>())
        let normalizedStorefrontCodes = Array(Set(storefrontCodes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()

        return apps.map { app in
            // Only refresh ratings/reviews for the storefronts this app actually
            // tracks keywords in. Falling back to the full catalog made the daily
            // refresh fan out across every bundled storefront, which timed out for
            // anyone tracking keywords in more than a handful of countries.
            let appStorefrontCodes = Self.ratingsReviewsStorefrontCodes(
                for: app,
                fallback: normalizedStorefrontCodes
            )

            return AppDetailRefreshRequest(
                app: AppDetailRefreshAppSnapshot(
                    appStoreID: app.appStoreID,
                    bundleID: app.bundleID,
                    name: app.name,
                    subtitle: app.subtitle,
                    sellerName: app.sellerName,
                    defaultPlatform: app.defaultPlatform
                ),
                workspace: .keywords,
                storefrontSelection: .all(codes: appStorefrontCodes),
                trackIdentityKeys: app.keywordTracks.map(\.identityKey),
                trigger: "daily_refresh",
                refreshRatings: refreshRatingsReviews,
                refreshReviews: refreshRatingsReviews,
                recordsRatingsReviewsRefresh: false,
                popularityContextAppStoreID: popularityContextAppStoreIDProvider(),
                appleAdsWebSession: appleAdsWebSessionProvider(),
                appStoreConnectCredentials: appStoreConnectCredentialsProvider()
            )
        }
    }

    /// The storefronts whose ratings/reviews should be refreshed for `app`.
    ///
    /// Scoped to the countries the app actually tracks keywords in. Apps with no
    /// tracked keywords fall back to `fallback` (the full storefront catalog) so
    /// existing behavior is preserved for them.
    static func ratingsReviewsStorefrontCodes(
        for app: TrackedApp,
        fallback: [String]
    ) -> [String] {
        let trackedStorefrontCodes = Array(Set(app.keywordTracks.map {
            $0.storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
        return trackedStorefrontCodes.isEmpty ? fallback : trackedStorefrontCodes
    }

    func nextCheckSleepNanoseconds(now: Date? = nil) -> UInt64 {
        let referenceDate = now ?? timing.now()
        let nextCheckDate = settingsStore.nextRefreshCheckDate(after: referenceDate)
        let seconds = max(1, min(nextCheckDate.timeIntervalSince(referenceDate), 60 * 60 * 24))
        return UInt64(seconds * 1_000_000_000)
    }

    private func sleepUntilNextCheck() async {
        do {
            try await timing.sleepNanoseconds(nextCheckSleepNanoseconds())
        } catch {
            return
        }
    }
}

@MainActor
struct ScheduledLoop {
    func run(
        operation: () async -> Void,
        sleepUntilNextRun: () async -> Void
    ) async {
        while !Task.isCancelled {
            await operation()
            guard !Task.isCancelled else {
                return
            }
            await sleepUntilNextRun()
        }
    }
}

@MainActor
struct DailyRefreshSchedulerTiming {
    var now: () -> Date
    var sleepNanoseconds: (UInt64) async throws -> Void

    static let live = DailyRefreshSchedulerTiming(
        now: { .now },
        sleepNanoseconds: { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}

struct DailyRefreshOutcome: Equatable {
    let triggeredAt: Date
    let refreshedCount: Int
    let failureCount: Int
}
