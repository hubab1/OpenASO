import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class AppServices {
    let appleAdsCredentialStore: AppleAdsCredentialStore
    let appleAdsWebSessionStore: AppleAdsWebSessionStore
    let appleAdsWebSessionManager: AppleAdsWebSessionManager
    let settingsStore: AppSettingsStore
    let analyticsService: AnalyticsService
    let refreshMetricsRecorder: RefreshMetricsRecorder
    let appStoreConnectCredentialStore: AppStoreConnectCredentialStore
    let appStoreConnectReviewService: AppStoreConnectReviewService
    private(set) var dailyRefreshScheduler: DailyRefreshScheduler?
    let headlessRefreshService: HeadlessRefreshService?
    let headlessRefreshObservationRecorder: HeadlessRefreshObservationRecorder
    private(set) var headlessRefreshSnapshot = HeadlessRefreshSnapshot.empty
    let storefrontCatalog: StorefrontCatalog
    let appResolver: any AppResolver
    let appStoreWebMetadataProvider: AppStoreWebMetadataProvider
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore
    let appMetadataRefreshService: AppMetadataRefreshService?
    let appMetadataRefreshProgressStore: AppMetadataRefreshProgressStore
    let screenshotDownloadService: ScreenshotDownloadService
    let screenshotDownloadProgressStore: ScreenshotDownloadProgressStore
    let appStorefrontRatingService: AppStorefrontRatingService
    let appStorefrontReviewService: AppStorefrontReviewService
    let aiService: any AIService
    let reviewTranslationService: ReviewTranslationService
    let reviewLanguageDetectionService: ReviewLanguageDetectionService
    let keywordMetricsService: KeywordMetricsService
    let keywordInsightsService: KeywordInsightsService
    let keywordSuggestionService: KeywordSuggestionService
    let rankedAppPricingService: RankedAppPricingService
    let visibleProductPricingService: VisibleProductPricingService
    let rankingProvider: any SearchRankingProvider
    let refreshCoordinator: RankingRefreshCoordinator
    let appDetailRefreshService: AppDetailRefreshService?
    let refreshProgressStore: AppRefreshProgressStore
    let mcpServerController: OpenASOMCPServerController
    let keywordResearchProjectStore: KeywordResearchProjectStore?
    let keywordResearchProjectCopyService: KeywordResearchProjectCopyService?
    let keywordResearchRankingWorkflow: KeywordResearchRankingWorkflow?
    let keywordResearchMetricsWorkflow: KeywordResearchMetricsWorkflow?
    private(set) var backgroundModelStore: BackgroundModelStore?
    private(set) var backgroundModelStoreRevision = 0

    init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        defaults: UserDefaults = .openASOShared,
        keychain: any KeychainService = SystemKeychainService(),
        namespace: AppNamespace = .current,
        aiService: (any AIService)? = nil,
        loadsEnvironmentCredentials: Bool = true,
        allowsIconNetworkFetches: Bool = true,
        backgroundModelStore: BackgroundModelStore? = nil,
        keywordResearchProjectStore: KeywordResearchProjectStore? = nil,
        keywordResearchProjectCopyService: KeywordResearchProjectCopyService? = nil,
        keywordResearchRankingWorkflow: KeywordResearchRankingWorkflow? = nil,
        keywordResearchMetricsWorkflow: KeywordResearchMetricsWorkflow? = nil,
        refreshObservationClock: RefreshObservationClock = .live,
        refreshMetricsRecorder: RefreshMetricsRecorder? = nil,
        providerRequestGateMode: ProviderRequestGateMode? = nil,
        providerRequestClock: ProviderRequestClock = .live,
        providerRequestRandomness: ProviderRequestRandomness = .live
    ) {
        let refreshMetricsRecorder = refreshMetricsRecorder ?? RefreshMetricsRecorder(
            clock: refreshObservationClock
        )
        let headlessRefreshObservationRecorder = HeadlessRefreshObservationRecorder()
        let httpClient = ProviderHTTPClientPipeline.make(
            transport: httpClient,
            mode: providerRequestGateMode ?? .production(defaults: defaults),
            refreshMetricsRecorder: refreshMetricsRecorder,
            refreshObservationClock: refreshObservationClock,
            providerRequestClock: providerRequestClock,
            providerRequestRandomness: providerRequestRandomness
        )
        let appleAdsCredentialStore = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace,
            loadsEnvironmentCredentials: loadsEnvironmentCredentials
        )
        let settingsStore = AppSettingsStore(defaults: defaults)
        let analyticsService = AnalyticsService(settingsStore: settingsStore)
        let appleAdsWebSessionStore = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let appStoreConnectCredentialStore = AppStoreConnectCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let appleAdsWebSessionManager = AppleAdsWebSessionManager(
            sessionStore: appleAdsWebSessionStore,
            settingsStore: settingsStore,
            credentialStore: appleAdsCredentialStore,
            httpClient: httpClient,
            namespace: namespace
        )
        let resolver = DefaultAppResolver(httpClient: httpClient)
        let appStoreWebMetadataProvider = AppStoreWebMetadataProvider(httpClient: httpClient)
        let catalogService = AppCatalogService(appResolver: resolver)
        let appIconStore = AppIconStore(
            namespace: namespace,
            allowsNetworkFetches: allowsIconNetworkFetches
        )
        let appMetadataRefreshService = backgroundModelStore.map { backgroundModelStore in
            AppMetadataRefreshService(
                appResolver: resolver,
                webMetadataProvider: appStoreWebMetadataProvider,
                store: SwiftDataAppMetadataRefreshStore(
                    backgroundModelStore: backgroundModelStore,
                    appCatalogService: catalogService
                ),
                iconInvalidator: appIconStore
            )
        }
        let appMetadataRefreshProgressStore = AppMetadataRefreshProgressStore(
            refreshOperation: { request, progress in
                guard let appMetadataRefreshService else {
                    throw OpenASOError.providerUnavailable(
                        "Metadata refresh needs an initialized workspace store."
                    )
                }
                return try await appMetadataRefreshService.refresh(
                    request,
                    progress: progress
                )
            }
        )
        let screenshotDownloadService = ScreenshotDownloadService()
        let screenshotDownloadProgressStore = ScreenshotDownloadProgressStore()
        let appStorefrontRatingService = AppStorefrontRatingService(httpClient: httpClient)
        let appStorefrontReviewService = AppStorefrontReviewService(
            httpClient: httpClient
        )
        let aiService = aiService ?? AIServiceRouter(providers: [
            FoundationModelsAIService()
        ])
        let reviewTranslationService = ReviewTranslationService(aiService: aiService)
        let reviewLanguageDetectionService = ReviewLanguageDetectionService()
        let appStoreConnectReviewService = AppStoreConnectReviewService(
            httpClient: httpClient,
            credentialStore: appStoreConnectCredentialStore
        )
        let keywordMetricsService = KeywordMetricsService(
            httpClient: httpClient,
            credentialStore: appleAdsCredentialStore,
            settingsStore: settingsStore,
            webSessionStore: appleAdsWebSessionStore
        )
        let keywordInsightsService = KeywordInsightsService()
        let rankedAppPricingService = RankedAppPricingService(httpClient: httpClient)
        let visibleProductPricingService = VisibleProductPricingService(
            httpClient: httpClient
        )
        let rankingProvider = SearchRankingProviderFactory.makeProduction(httpClient: httpClient)
        let mcpRankingRefreshScheduler = OpenASOMCPRankingRefreshScheduler()
        let refreshProgressStore = AppRefreshProgressStore()
        let storefrontCatalog = StorefrontCatalog()
        let keywordResearchProjectStore = keywordResearchProjectStore
            ?? backgroundModelStore.map {
                KeywordResearchProjectStore(backgroundModelStore: $0)
            }
        let keywordResearchProjectCopyService = keywordResearchProjectCopyService
            ?? backgroundModelStore.map {
                KeywordResearchProjectCopyService(backgroundModelStore: $0)
            }
        let metadataEnrichmentHandler: (@Sendable ([RankingMetadataEnrichmentRequest]) async -> Void)?
        if let backgroundModelStore {
            metadataEnrichmentHandler = { requests in
                for request in requests {
                    let shouldEnrich = (try? await backgroundModelStore.read { modelContext in
                        try catalogService.shouldEnrichStorefrontMetadata(
                            appStoreID: request.appStoreID,
                            storefrontCode: request.storefront,
                            platform: request.platform,
                            freshnessInterval: RankingRefreshCoordinator.metadataEnrichmentFreshnessInterval,
                            in: modelContext
                        )
                    }) ?? false
                    guard shouldEnrich else { continue }

                    let resolvedApp = try? await resolver.resolve(
                        appStoreID: request.appStoreID,
                        storefrontCode: request.storefront
                    )
                    let webMetadata = try? await appStoreWebMetadataProvider.fetch(
                        appStoreID: request.appStoreID,
                        storefrontCode: request.storefront
                    )
                    guard resolvedApp != nil || webMetadata != nil else {
                        continue
                    }

                    try? await backgroundModelStore.write { modelContext in
                        if let resolvedApp {
                            _ = try catalogService.upsertStoreApp(
                                from: resolvedApp,
                                storefrontCode: request.storefront,
                                in: modelContext
                            )
                        }
                        if let webMetadata {
                            let storeApp = try catalogService.upsertStoreApp(
                                from: webMetadata,
                                storefrontCode: request.storefront,
                                in: modelContext
                            )
                            if webMetadata.ratingCount != nil || webMetadata.averageRating != nil || webMetadata.ratingCounts != nil {
                                let result = AppStorefrontRatingResult(
                                    appStoreID: webMetadata.appStoreID,
                                    storefront: request.storefront,
                                    ratingCount: webMetadata.ratingCount,
                                    averageRating: webMetadata.averageRating,
                                    ratingCounts: webMetadata.ratingCounts,
                                    observedAt: .now,
                                    source: .appStorePage
                                )
                                appStorefrontRatingService.persist(
                                    AppStorefrontRatingRefreshOutcome(
                                        storefront: request.storefront,
                                        result: result,
                                        error: nil
                                    ),
                                    for: storeApp,
                                    in: modelContext
                                )
                            }
                        }
                        try modelContext.save()
                    }
                }
            }
        } else {
            metadataEnrichmentHandler = nil
        }
        let refreshCoordinator = RankingRefreshCoordinator(
            rankingProvider: rankingProvider,
            appCatalogService: catalogService,
            analyticsService: analyticsService,
            refreshTriggerRecorder: { date in
                await settingsStore.markRefreshTriggered(on: date)
            },
            metadataEnrichmentHandler: metadataEnrichmentHandler
        )
        let keywordResearchRankingWorkflow = keywordResearchRankingWorkflow
            ?? backgroundModelStore.map {
                KeywordResearchRankingWorkflow(
                    backgroundModelStore: $0,
                    rankingCoordinator: refreshCoordinator
                )
            }
        let keywordResearchMetricsWorkflow = keywordResearchMetricsWorkflow
            ?? backgroundModelStore.map {
                KeywordResearchMetricsWorkflow(
                    backgroundModelStore: $0,
                    metricsService: keywordMetricsService,
                    rankingCoordinator: refreshCoordinator,
                    configurationProvider: {
                        let session = appleAdsWebSessionStore.session
                        return KeywordResearchMetricsConfiguration(
                            contextAppStoreID: settingsStore.popularityContextAppStoreID,
                            webSession: session,
                            requiresReconnect: session.map {
                                appleAdsWebSessionStore.requiresReconnect(for: $0)
                            } ?? false
                        )
                    },
                    reconnectMarker: { attemptedSession in
                        appleAdsWebSessionStore.markReconnectRequired(for: attemptedSession)
                    }
                )
            }
        let appDetailRefreshService = backgroundModelStore.map {
            AppDetailRefreshService(
                backgroundModelStore: $0,
                refreshCoordinator: refreshCoordinator,
                keywordMetricsService: keywordMetricsService,
                appStorefrontRatingService: appStorefrontRatingService,
                appStorefrontReviewService: appStorefrontReviewService,
                appStoreConnectReviewService: appStoreConnectReviewService,
                progressStore: refreshProgressStore,
                refreshMetricsRecorder: refreshMetricsRecorder,
                ratingsReviewsRefreshRecorder: { date in
                    await settingsStore.markRatingsReviewsRefreshed(on: date)
                }
            )
        }
        let headlessRefreshService: HeadlessRefreshService?
        if let backgroundModelStore,
           let appMetadataRefreshService,
           let appDetailRefreshService {
            let planLoader = DailyRefreshPlanLoader(
                backgroundModelStore: backgroundModelStore
            )
            let appAdapter = HeadlessRefreshAppAdapter(
                refreshMetadata: { request in
                    try await appMetadataRefreshService.refresh(request)
                },
                refreshDetail: { request in
                    try await appDetailRefreshService.refreshCancellable(request)
                }
            )
            headlessRefreshService = HeadlessRefreshService(
                dependencies: HeadlessRefreshDependencies(
                    loadPlan: { request in
                        try Task.checkCancellation()
                        let configuration = try await MainActor.run {
                            DailyRefreshPlanConfiguration(
                                fallbackStorefrontCodes: try storefrontCatalog
                                    .bundledStorefronts()
                                    .map { storefront in
                                        storefront.code
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                            .lowercased()
                                    }
                                    .filter { !$0.isEmpty },
                                refreshRatingsAndReviews: request.refreshRatingsAndReviews,
                                popularityContextAppStoreID: settingsStore
                                    .popularityContextAppStoreID,
                                appleAdsWebSession: appleAdsWebSessionStore.session,
                                appStoreConnectCredentials: appStoreConnectCredentialStore
                                    .credentials
                            )
                        }
                        try Task.checkCancellation()
                        return try await planLoader.load(configuration: configuration)
                    },
                    refreshApp: { plan in
                        try await appAdapter.refresh(plan)
                    },
                    recordObservation: { observation in
                        await headlessRefreshObservationRecorder.record(observation)
                    }
                )
            )
        } else {
            headlessRefreshService = nil
        }
        self.appleAdsCredentialStore = appleAdsCredentialStore
        self.appleAdsWebSessionStore = appleAdsWebSessionStore
        self.appleAdsWebSessionManager = appleAdsWebSessionManager
        self.settingsStore = settingsStore
        self.analyticsService = analyticsService
        self.refreshMetricsRecorder = refreshMetricsRecorder
        self.appStoreConnectCredentialStore = appStoreConnectCredentialStore
        self.appStoreConnectReviewService = appStoreConnectReviewService
        self.dailyRefreshScheduler = nil
        self.headlessRefreshService = headlessRefreshService
        self.headlessRefreshObservationRecorder = headlessRefreshObservationRecorder
        self.storefrontCatalog = storefrontCatalog
        self.appResolver = resolver
        self.appStoreWebMetadataProvider = appStoreWebMetadataProvider
        self.appCatalogService = catalogService
        self.appIconStore = appIconStore
        self.appMetadataRefreshService = appMetadataRefreshService
        self.appMetadataRefreshProgressStore = appMetadataRefreshProgressStore
        self.screenshotDownloadService = screenshotDownloadService
        self.screenshotDownloadProgressStore = screenshotDownloadProgressStore
        self.appStorefrontRatingService = appStorefrontRatingService
        self.appStorefrontReviewService = appStorefrontReviewService
        self.aiService = aiService
        self.reviewTranslationService = reviewTranslationService
        self.reviewLanguageDetectionService = reviewLanguageDetectionService
        self.keywordMetricsService = keywordMetricsService
        self.keywordInsightsService = keywordInsightsService
        self.keywordSuggestionService = KeywordSuggestionService()
        self.rankedAppPricingService = rankedAppPricingService
        self.visibleProductPricingService = visibleProductPricingService
        self.rankingProvider = rankingProvider
        self.refreshCoordinator = refreshCoordinator
        self.appDetailRefreshService = appDetailRefreshService
        self.refreshProgressStore = refreshProgressStore
        self.keywordResearchProjectStore = keywordResearchProjectStore
        self.keywordResearchProjectCopyService = keywordResearchProjectCopyService
        self.keywordResearchRankingWorkflow = keywordResearchRankingWorkflow
        self.keywordResearchMetricsWorkflow = keywordResearchMetricsWorkflow
        self.mcpServerController = OpenASOMCPServerController(portProvider: {
            settingsStore.mcpServerPort
        }) {
            guard let backgroundModelStore, let keywordResearchProjectStore else {
                throw OpenASOError.providerUnavailable("OpenASO MCP needs an initialized workspace store.")
            }

            let mcpService = OpenASOMCPService(
                backgroundModelStore: backgroundModelStore,
                keywordResearchProjectStore: keywordResearchProjectStore,
                appResolver: resolver,
                appCatalogService: catalogService,
                httpClient: httpClient,
                screenshotDownloadService: screenshotDownloadService,
                rankingProvider: rankingProvider,
                rankingRefreshCoordinator: refreshCoordinator,
                rankingRefreshScheduler: mcpRankingRefreshScheduler,
                reviewService: appStorefrontReviewService,
                keywordMetricsService: keywordMetricsService,
                rankedAppPricingService: rankedAppPricingService,
                visibleProductPricingService: visibleProductPricingService,
                popularityContextAppStoreIDProvider: {
                    settingsStore.popularityContextAppStoreID
                },
                appleAdsWebSessionProvider: {
                    appleAdsWebSessionStore.session
                }
            )

            return await OpenASOMCPServerFactory(
                service: mcpService,
                configuration: OpenASOMCPServerConfiguration(version: "1.5.0")
            ).makeServer()
        }
        self.backgroundModelStore = backgroundModelStore
        self.backgroundModelStoreRevision = backgroundModelStore == nil ? 0 : 1
        if let headlessRefreshService {
            self.dailyRefreshScheduler = DailyRefreshScheduler(
                evaluateAndClaim: { date, calendar in
                    await settingsStore.evaluateAndClaimAutomaticRefresh(
                        at: date,
                        calendar: calendar
                    )
                },
                runHeadlessRefresh: { [weak self] request in
                    let summary = await headlessRefreshService.run(request)
                    await MainActor.run {
                        self?.recordHeadlessRefreshCompletion(summary)
                    }
                    return summary
                }
            )
        }
        self.appMetadataRefreshProgressStore.setRevisionHandler { [weak self] _, _ in
            self?.markBackgroundModelStoreChanged()
        }
    }

    func prepareBackgroundModelStore() async {
        await backgroundModelStore?.prepare()
    }

    func markBackgroundModelStoreChanged() {
        backgroundModelStoreRevision += 1
    }

    func recordHeadlessRefreshCompletion(_ summary: HeadlessRefreshRunSummary) {
        if summary.plannedAppCount > 0 {
            markBackgroundModelStoreChanged()
        }
        if summary.ratingsReviewsFullySucceeded {
            settingsStore.markRatingsReviewsRefreshed(on: summary.scheduledFor)
        }
    }

    func observeHeadlessRefreshes() async {
        let updates = await headlessRefreshObservationRecorder.updates()
        for await snapshot in updates {
            guard !Task.isCancelled else { return }
            headlessRefreshSnapshot = snapshot
        }
    }

    func refreshStaleKeywordPopularityAfterAppleAdsConnection() {
        guard let backgroundModelStore,
              let popularityContextAppStoreID = settingsStore.popularityContextAppStoreID,
              let webSession = appleAdsWebSessionStore.session,
              webSession.isComplete
        else {
            return
        }

        let keywordMetricsService = keywordMetricsService
        let refreshProgressStore = refreshProgressStore
        Task {
            let preparation: StalePopularityRefreshPreparation
            do {
                preparation = try await keywordMetricsService.prepareStalePopularityRefresh(
                    using: backgroundModelStore
                )
            } catch {
                let refreshID = refreshProgressStore.beginAppleAdsPopularityRefresh(total: 0)
                refreshProgressStore.finish(
                    refreshID: refreshID,
                    error: OpenASOError.map(error)
                )
                return
            }
            if preparation.clearedStatusCount > 0 {
                self.markBackgroundModelStoreChanged()
            }
            let trackIdentityKeys = preparation.trackIdentityKeys
            guard !trackIdentityKeys.isEmpty else { return }

            let refreshID = refreshProgressStore.beginAppleAdsPopularityRefresh(
                total: preparation.refreshQueryCount
            )
            do {
                let result = try await keywordMetricsService.refreshMetricsBatch(
                    for: trackIdentityKeys,
                    popularityContextAppStoreID: popularityContextAppStoreID,
                    webSession: webSession,
                    using: backgroundModelStore,
                    progress: { completed, total, failureCount in
                        await refreshProgressStore.updateStep(
                            .metrics,
                            status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                            completed: completed,
                            total: total,
                            failureCount: failureCount,
                            refreshID: refreshID
                        )
                    }
                )

                if !result.outcomes.isEmpty {
                    await MainActor.run {
                        self.markBackgroundModelStoreChanged()
                    }
                }
                refreshProgressStore.finish(
                    refreshID: refreshID,
                    error: result.firstErrorMessage.map(OpenASOError.providerUnavailable)
                )
            } catch {
                refreshProgressStore.finish(
                    refreshID: refreshID,
                    error: OpenASOError.map(error)
                )
            }
        }
    }

    static func preview(httpClient: HTTPClient, modelContainer: ModelContainer? = nil) -> AppServices {
        mocked(httpClient: httpClient, modelContainer: modelContainer)
    }

    static func appLaunch(modelContainer: ModelContainer? = nil) -> AppServices {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return mocked(httpClient: PreviewHTTPClient(), modelContainer: modelContainer)
        }

        let backgroundModelStore = modelContainer.map {
            BackgroundModelStore(modelContainer: $0)
        }

        return AppServices(backgroundModelStore: backgroundModelStore)
    }
}

extension AppServices {
    static func mocked(
        httpClient: HTTPClient,
        modelContainer: ModelContainer? = nil,
        allowsIconNetworkFetches: Bool = false
    ) -> AppServices {
        let backgroundModelStore = modelContainer.map {
            BackgroundModelStore(modelContainer: $0)
        }

        return AppServices(
            httpClient: httpClient,
            defaults: UserDefaults.previewSuite(),
            keychain: InMemoryKeychainService(),
            aiService: MockAIService { request, _ in
                """
                {"title":"Translated \(request.prompt.contains("Title:") ? "Review" : "Text")","content":"Preview translation"}
                """
            },
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: allowsIconNetworkFetches,
            backgroundModelStore: backgroundModelStore,
            providerRequestGateMode: .disabled
        )
    }
}

private extension UserDefaults {
    static func previewSuite() -> UserDefaults {
        let suiteName = "com.thirdtech.openaso.preview.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
