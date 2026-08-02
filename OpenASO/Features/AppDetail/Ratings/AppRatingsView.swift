import SwiftData
import SwiftUI

struct AppRatingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings

    let appStoreID: Int64
    let bundleID: String?
    let selectedStorefrontFilter: StorefrontFilter
    let searchText: String
    let refreshToken: Int

    @State private var storefrontDefinitions: [StorefrontDefinition] = []
    @State private var latestRatings: [RatingLatestValue] = []
    @State private var ratingSnapshots: [RatingSnapshotValue] = []
    @State private var isLoadingRatings = false
    @State private var appStoreConnectStatus = RatingsAppStoreConnectStatus.notConnected
    @State private var metric = RatingsMetric.ratingCount

    private var dashboardModel: RatingsDashboardModel {
        RatingsDashboardModel(
            appStoreID: appStoreID,
            selectedStorefrontFilter: selectedStorefrontFilter,
            searchText: searchText,
            metric: metric,
            latestRatings: latestRatings,
            ratingSnapshots: ratingSnapshots,
            storefrontDefinitions: storefrontDefinitions
        )
    }

    var body: some View {
        let dashboardModel = dashboardModel

        HSplitView {
            RatingsSidebar(
                rows: dashboardModel.rows,
                totalRatingCount: dashboardModel.totalRatingCount,
                totalRatingCountTrend: dashboardModel.totalRatingCountTrend,
                averageRating: dashboardModel.averageRating,
                averageRatingTrend: dashboardModel.averageRatingTrend,
                historyPoints: dashboardModel.historyPoints,
                metric: $metric
            )
            .frame(minWidth: 300, idealWidth: 480, maxWidth: 620)

            RatingsReviewsView(
                appStoreID: appStoreID,
                selectedStorefrontFilter: selectedStorefrontFilter,
                searchText: searchText,
                refreshToken: refreshToken,
                backgroundModelStore: services.backgroundModelStore,
                backgroundModelStoreRevision: services.backgroundModelStoreRevision,
                appStoreConnectStatus: appStoreConnectStatus,
                storefrontDefinitions: storefrontDefinitions,
                replyService: services.appStoreConnectReviewService,
                translationService: services.reviewTranslationService,
                analyticsService: services.analyticsService,
                openAppStoreConnectSettings: {
                    services.settingsStore.requestSettingsFocus(.appStoreConnect)
                    openSettings()
                }
            )
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            loadStorefrontDefinitionsIfNeeded()
        }
        .task(id: ratingsReloadID) {
            await loadRatings(reset: true)
        }
        .task(id: appStoreConnectReloadID) {
            await updateAppStoreConnectStatus()
        }
    }

    private var ratingsReloadID: String {
        "\(appStoreID)::\(refreshToken)::backgroundStore:\(services.backgroundModelStoreRevision)"
    }

    private var appStoreConnectReloadID: String {
        [
            String(appStoreID),
            bundleID ?? "",
            String(services.appStoreConnectCredentialStore.hasCompleteCredentials),
            services.appStoreConnectCredentialStore.credentials.issuerID,
            services.appStoreConnectCredentialStore.credentials.keyID,
            String(refreshToken)
        ].joined(separator: "::")
    }

    private func loadStorefrontDefinitionsIfNeeded() {
        guard storefrontDefinitions.isEmpty else { return }
        storefrontDefinitions = ((try? services.storefrontCatalog.bundledStorefronts()) ?? []).map {
            StorefrontDefinition(
                code: $0.code.lowercased(),
                name: $0.name,
                flagEmoji: $0.flagEmoji,
                title: "\($0.flagEmoji) \($0.name)"
            )
        }
    }

    private func loadRatings(reset: Bool) async {
        guard let backgroundModelStore = services.backgroundModelStore, !isLoadingRatings else {
            return
        }

        isLoadingRatings = true
        defer { isLoadingRatings = false }

        let targetAppStoreID = appStoreID
        do {
            let data = try await backgroundModelStore.read { modelContext in
                try Self.fetchRatingsDashboardData(
                    appStoreID: targetAppStoreID,
                    in: modelContext
                )
            }

            latestRatings = data.latestRatings
            ratingSnapshots = data.ratingSnapshots.sorted { $0.observedAt < $1.observedAt }
        } catch {
            latestRatings = reset ? [] : latestRatings
            ratingSnapshots = reset ? [] : ratingSnapshots
        }
    }

    private func updateAppStoreConnectStatus() async {
        guard services.appStoreConnectCredentialStore.hasCompleteCredentials else {
            appStoreConnectStatus = .notConnected
            return
        }

        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else {
            appStoreConnectStatus = .publicOnly("This tracked app has no bundle ID, so ownership cannot be checked.")
            return
        }

        do {
            _ = try await services.appStoreConnectReviewService.resolveApp(bundleID: bundleID)
            appStoreConnectStatus = .owned
        } catch OpenASOError.appNotFound {
            appStoreConnectStatus = .publicOnly("This app is not visible in your App Store Connect account.")
        } catch {
            appStoreConnectStatus = .error(OpenASOError.map(error).localizedDescription)
        }
    }

    nonisolated private static func fetchRatingsDashboardData(
        appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> RatingsDashboardData {
        let targetAppStoreID = appStoreID
        let latestDescriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                latest.appStoreID == targetAppStoreID
            },
            sortBy: [SortDescriptor(\.storefront, order: .forward)]
        )
        let snapshotDescriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { snapshot in
                snapshot.appStoreID == targetAppStoreID
            },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )

        let latestRatings = try modelContext.fetch(latestDescriptor).map(RatingLatestValue.init)
        let ratingSnapshots = try modelContext.fetch(snapshotDescriptor).map(RatingSnapshotValue.init)

        return RatingsDashboardData(
            latestRatings: latestRatings,
            ratingSnapshots: ratingSnapshots
        )
    }
}

#Preview("Ratings Dashboard") {
    AppRatingsPreview()
}

private struct AppRatingsPreview: View {
    private let previewContainer: OpenASOPreviewContainer<Void>

    init() {
        self.previewContainer = OpenASOPreviewContainer(seed: Self.seed)
    }

    var body: some View {
        AppRatingsView(
            appStoreID: 6448311069,
            bundleID: "com.openai.chat",
            selectedStorefrontFilter: .all,
            searchText: "",
            refreshToken: 0
        )
        .openASOPreviewEnvironment(previewContainer)
        .frame(width: 1180, height: 720)
    }

    private static func seed(in modelContext: ModelContext) {
        let storeApp = StoreApp(
            appStoreID: 6448311069,
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            sellerName: "OpenAI",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)

        let rows: [(storefront: String, count: Int, previousCount: Int, rating: Double, previousRating: Double)] = [
            ("us", 1_024_420, 1_024_390, 4.83, 4.81),
            ("gb", 284_210, 284_260, 4.78, 4.79),
            ("ca", 196_440, 196_418, 4.72, 4.70),
            ("de", 152_806, 152_730, 4.64, 4.62),
            ("jp", 118_920, 118_940, 4.51, 4.54),
            ("au", 96_315, 96_270, 4.75, 4.73),
            ("fr", 88_120, 88_110, 4.58, 4.57),
            ("br", 74_890, 74_950, 4.69, 4.70),
            ("it", 68_420, 68_420, 4.20, 4.20),
            ("es", 64_810, 64_810, 4.201, 4.20),
            ("mx", 61_230, 61_230, 4.199, 4.20),
            ("nl", 58_940, 58_940, 4.204, 4.20),
            ("se", 56_770, 56_770, 4.205, 4.20),
            ("in", 54_120, 54_120, 4.195, 4.20)
        ]

        for row in rows {
            modelContext.insert(
                LatestAppRating(
                    appStoreID: storeApp.appStoreID,
                    storefront: row.storefront,
                    ratingCount: row.count,
                    averageRating: row.rating,
                    observedAt: date(hoursAgo: 1),
                    storeApp: storeApp
                )
            )

            modelContext.insert(
                AppDailyRating(
                    appStoreID: storeApp.appStoreID,
                    storefront: row.storefront,
                    ratingCount: row.previousCount,
                    averageRating: row.previousRating,
                    observedAt: date(daysAgo: 1),
                    storeApp: storeApp
                )
            )

            modelContext.insert(
                AppDailyRating(
                    appStoreID: storeApp.appStoreID,
                    storefront: row.storefront,
                    ratingCount: row.count,
                    averageRating: row.rating,
                    observedAt: date(hoursAgo: 1),
                    storeApp: storeApp
                )
            )

            modelContext.insert(
                AppDailyRating(
                    appStoreID: storeApp.appStoreID,
                    storefront: row.storefront,
                    ratingCount: row.previousCount - 120,
                    averageRating: row.previousRating - 0.01,
                    observedAt: date(daysAgo: 2),
                    storeApp: storeApp
                )
            )
        }

        let reviewRows: [(storefront: String, reviewID: String, reviewer: String, title: String, content: String, rating: Int, daysAgo: Int)] = [
            ("us", "11001", "Maya", "Reliable every day", "The app opens quickly and the answers are useful for drafting and research. Voice mode has also been solid.", 5, 1),
            ("us", "11002", "Jordan", "Good but expensive", "The core product is excellent, but I would like clearer limits before I hit them during work.", 4, 8),
            ("gb", "11003", "Priya", "Sync issues", "My chats sometimes lag between devices. The content quality is good when everything catches up.", 3, 18),
            ("ca", "11004", "Noah", "Best assistant app", "It has become the main place I outline docs, summarize long emails, and check code snippets.", 5, 42)
        ]

        for reviewRow in reviewRows {
            modelContext.insert(
                AppStorefrontReview(
                    appStoreID: storeApp.appStoreID,
                    storefront: reviewRow.storefront,
                    reviewID: reviewRow.reviewID,
                    reviewerName: reviewRow.reviewer,
                    title: reviewRow.title,
                    content: reviewRow.content,
                    rating: reviewRow.rating,
                    reviewedAt: date(daysAgo: reviewRow.daysAgo),
                    version: "1.2026.120",
                    storeApp: storeApp
                )
            )
        }

        try? modelContext.save()
    }

    private static func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    }

    private static func date(hoursAgo: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: -hoursAgo, to: .now) ?? .now
    }
}
