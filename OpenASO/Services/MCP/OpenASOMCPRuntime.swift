import Foundation
import MCP
import SwiftData

enum OpenASOMCPRuntime {
    static func makeServer(
        configuration: OpenASOMCPServerConfiguration = OpenASOMCPServerConfiguration()
    ) async throws -> Server {
        let modelContainer = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: false)
        let refreshObservationClock = RefreshObservationClock.live
        let refreshMetricsRecorder = RefreshMetricsRecorder(clock: refreshObservationClock)
        let httpClient = ProviderHTTPClientPipeline.make(
            transport: URLSessionHTTPClient(),
            mode: .production(defaults: .standard),
            refreshMetricsRecorder: refreshMetricsRecorder,
            refreshObservationClock: refreshObservationClock
        )
        let mcpService = await makeService(
            modelContainer: modelContainer,
            httpClient: httpClient
        )

        return await OpenASOMCPServerFactory(
            service: mcpService,
            configuration: configuration
        ).makeServer()
    }

    /// Builds the standalone runtime's dependency graph around an injected
    /// container. Tests use this seam with an in-memory store so they never
    /// open the user's workspace.
    static func makeService(
        modelContainer: ModelContainer,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) async -> OpenASOMCPService {
        let backgroundModelStore = BackgroundModelStore(modelContainer: modelContainer)
        let keywordResearchProjectStore = KeywordResearchProjectStore(
            backgroundModelStore: backgroundModelStore
        )
        let appResolver = DefaultAppResolver(httpClient: httpClient)
        let appCatalogService = AppCatalogService(appResolver: appResolver)
        let rankingProvider = SearchRankingProviderFactory.makeProduction(httpClient: httpClient)
        let rankingRefreshCoordinator = await RankingRefreshCoordinator(
            rankingProvider: rankingProvider,
            appCatalogService: appCatalogService
        )
        let reviewService = AppStorefrontReviewService(httpClient: httpClient)
        let mcpService = OpenASOMCPService(
            backgroundModelStore: backgroundModelStore,
            keywordResearchProjectStore: keywordResearchProjectStore,
            appResolver: appResolver,
            appCatalogService: appCatalogService,
            httpClient: httpClient,
            screenshotDownloadService: ScreenshotDownloadService(),
            rankingProvider: rankingProvider,
            rankingRefreshCoordinator: rankingRefreshCoordinator,
            reviewService: reviewService
        )
        return mcpService
    }

    static func runStdio(
        configuration: OpenASOMCPServerConfiguration = OpenASOMCPServerConfiguration()
    ) async throws {
        let server = try await makeServer(configuration: configuration)
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
