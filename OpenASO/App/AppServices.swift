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
    let appStoreConnectCredentialStore: AppStoreConnectCredentialStore
    let appStoreConnectReviewService: AppStoreConnectReviewService
    let dailyRefreshScheduler: DailyRefreshScheduler
    let storefrontCatalog: StorefrontCatalog
    let appResolver: any AppResolver
    let appStoreWebMetadataProvider: AppStoreWebMetadataProvider
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore
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
    let rankingProvider: any SearchRankingProvider
    let refreshCoordinator: RankingRefreshCoordinator
    let appDetailRefreshService: AppDetailRefreshService?
    let refreshProgressStore: AppRefreshProgressStore
    let mcpServerController: OpenASOMCPServerController
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
        backgroundModelStore: BackgroundModelStore? = nil
    ) {
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
        let screenshotDownloadService = ScreenshotDownloadService()
        let screenshotDownloadProgressStore = ScreenshotDownloadProgressStore()
        let appStorefrontRatingService = AppStorefrontRatingService(
            httpClient: httpClient
        )
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
        let rankingProvider = ITunesSearchFallbackProvider(httpClient: httpClient)
        let refreshProgressStore = AppRefreshProgressStore()
        let storefrontCatalog = StorefrontCatalog()
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
        let appDetailRefreshService = backgroundModelStore.map {
            AppDetailRefreshService(
                backgroundModelStore: $0,
                refreshCoordinator: refreshCoordinator,
                keywordMetricsService: keywordMetricsService,
                appStorefrontRatingService: appStorefrontRatingService,
                appStorefrontReviewService: appStorefrontReviewService,
                appStoreConnectReviewService: appStoreConnectReviewService,
                progressStore: refreshProgressStore,
                ratingsReviewsRefreshRecorder: { date in
                    await settingsStore.markRatingsReviewsRefreshed(on: date)
                }
            )
        }

        self.appleAdsCredentialStore = appleAdsCredentialStore
        self.appleAdsWebSessionStore = appleAdsWebSessionStore
        self.appleAdsWebSessionManager = appleAdsWebSessionManager
        self.settingsStore = settingsStore
        self.analyticsService = analyticsService
        self.appStoreConnectCredentialStore = appStoreConnectCredentialStore
        self.appStoreConnectReviewService = appStoreConnectReviewService
        self.dailyRefreshScheduler = DailyRefreshScheduler(
            settingsStore: settingsStore,
            refreshCoordinator: refreshCoordinator,
            appDetailRefresh: appDetailRefreshService.map { service in
                { request in
                    await service.refresh(request)
                }
            },
            storefrontCodesProvider: {
                try storefrontCatalog.bundledStorefronts()
                    .map { $0.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            },
            popularityContextAppStoreIDProvider: {
                settingsStore.popularityContextAppStoreID
            },
            appleAdsWebSessionProvider: {
                appleAdsWebSessionStore.session
            },
            appStoreConnectCredentialsProvider: {
                appStoreConnectCredentialStore.credentials
            }
        )
        self.storefrontCatalog = storefrontCatalog
        self.appResolver = resolver
        self.appStoreWebMetadataProvider = appStoreWebMetadataProvider
        self.appCatalogService = catalogService
        self.appIconStore = AppIconStore(
            namespace: namespace,
            allowsNetworkFetches: allowsIconNetworkFetches
        )
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
        self.rankingProvider = rankingProvider
        self.refreshCoordinator = refreshCoordinator
        self.appDetailRefreshService = appDetailRefreshService
        self.refreshProgressStore = refreshProgressStore
        self.mcpServerController = OpenASOMCPServerController(portProvider: {
            settingsStore.mcpServerPort
        }) {
            guard let backgroundModelStore else {
                throw OpenASOError.providerUnavailable("OpenASO MCP needs an initialized workspace store.")
            }

            let mcpService = OpenASOMCPService(
                backgroundModelStore: backgroundModelStore,
                appResolver: resolver,
                appCatalogService: catalogService,
                httpClient: httpClient,
                screenshotDownloadService: screenshotDownloadService,
                rankingProvider: rankingProvider,
                rankingRefreshCoordinator: refreshCoordinator,
                reviewService: appStorefrontReviewService,
                keywordMetricsService: keywordMetricsService,
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
    }

    func prepareBackgroundModelStore() async {
        await backgroundModelStore?.prepare()
    }

    func markBackgroundModelStoreChanged() {
        backgroundModelStoreRevision += 1
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
            guard let trackIdentityKeys = try? await keywordMetricsService.stalePopularityTrackIdentityKeys(
                using: backgroundModelStore
            ), !trackIdentityKeys.isEmpty else {
                return
            }

            refreshProgressStore.beginAppleAdsPopularityRefresh(total: trackIdentityKeys.count)
            guard let outcomes = try? await keywordMetricsService.refreshMetrics(
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
                        failureCount: failureCount
                    )
                }
            ), !outcomes.isEmpty else {
                refreshProgressStore.finish(error: nil)
                return
            }

            await MainActor.run {
                self.markBackgroundModelStoreChanged()
            }
            let firstErrorMessage = outcomes.first { $0.errorMessage != nil }?.errorMessage
            refreshProgressStore.finish(error: firstErrorMessage.map(OpenASOError.providerUnavailable))
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
            backgroundModelStore: backgroundModelStore
        )
    }
}

private extension UserDefaults {
    static func previewSuite() -> UserDefaults {
        let suiteName = "com.thirdtech.openaso.preview.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
