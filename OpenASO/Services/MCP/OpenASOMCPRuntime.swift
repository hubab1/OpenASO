import Foundation
import MCP

enum OpenASOMCPRuntime {
    static func makeServer(
        configuration: OpenASOMCPServerConfiguration = OpenASOMCPServerConfiguration()
    ) async throws -> Server {
        let modelContainer = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: false)
        let backgroundModelStore = BackgroundModelStore(modelContainer: modelContainer)
        let httpClient = URLSessionHTTPClient()
        let appResolver = DefaultAppResolver(httpClient: httpClient)
        let appCatalogService = AppCatalogService(appResolver: appResolver)
        let rankingProvider = ITunesSearchFallbackProvider(httpClient: httpClient)
        let rankingRefreshCoordinator = await RankingRefreshCoordinator(
            rankingProvider: rankingProvider,
            appCatalogService: appCatalogService
        )
        let reviewService = AppStorefrontReviewService(httpClient: httpClient)
        let mcpService = OpenASOMCPService(
            backgroundModelStore: backgroundModelStore,
            appResolver: appResolver,
            appCatalogService: appCatalogService,
            httpClient: httpClient,
            screenshotDownloadService: ScreenshotDownloadService(),
            rankingProvider: rankingProvider,
            rankingRefreshCoordinator: rankingRefreshCoordinator,
            reviewService: reviewService
        )

        return await OpenASOMCPServerFactory(
            service: mcpService,
            configuration: configuration
        ).makeServer()
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
