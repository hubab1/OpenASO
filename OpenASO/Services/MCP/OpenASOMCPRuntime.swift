import Foundation
import MCP
import SwiftData

struct OpenASOMCPServerProvider: Sendable {
    private let makeServerImplementation: @MainActor @Sendable () async throws -> Server

    init(
        makeServer: @escaping @MainActor @Sendable () async throws -> Server
    ) {
        self.makeServerImplementation = makeServer
    }

    @MainActor
    func makeServer() async throws -> Server {
        try await makeServerImplementation()
    }
}

enum OpenASOMCPRuntime {
    static func run(
        serverProvider: OpenASOMCPServerProvider,
        transport: any Transport
    ) async throws {
        let server = try await serverProvider.makeServer()
        do {
            try await server.start(transport: transport)
            await withTaskCancellationHandler {
                await server.waitUntilCompleted()
            } onCancel: {
                Task {
                    await server.stop()
                }
            }
            await server.stop()
            try Task.checkCancellation()
        } catch {
            await server.stop()
            throw error
        }
    }

    static func runStdio(
        serverProvider: OpenASOMCPServerProvider
    ) async throws {
        try await run(
            serverProvider: serverProvider,
            transport: StdioTransport()
        )
    }

    // Retained for the dormant standalone target. The shipped app's --mcp-stdio
    // path supplies AppServices.mcpServerProvider so HTTP and stdio share dependencies.
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
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        namespace: AppNamespace = .current
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
        let appleAdsCredentialStore = await MainActor.run {
            let defaults = UserDefaults(suiteName: namespace.userDefaultsSuiteName) ?? .standard
            return AppleAdsCredentialStore(
                defaults: defaults,
                keychain: SystemKeychainService(),
                namespace: namespace
            )
        }
        let appleAdsPlatformAPI = OfficialAppleAdsPlatformAPI()
        let mcpService = OpenASOMCPService(
            backgroundModelStore: backgroundModelStore,
            keywordResearchProjectStore: keywordResearchProjectStore,
            appResolver: appResolver,
            appCatalogService: appCatalogService,
            httpClient: httpClient,
            screenshotDownloadService: ScreenshotDownloadService(),
            rankingProvider: rankingProvider,
            rankingRefreshCoordinator: rankingRefreshCoordinator,
            reviewService: reviewService,
            appleAdsPlatformAPI: appleAdsPlatformAPI,
            appleAdsCredentialsProvider: {
                appleAdsCredentialStore.apiCredentials
            }
        )
        return mcpService
    }

    static func runStdio(
        configuration: OpenASOMCPServerConfiguration = OpenASOMCPServerConfiguration()
    ) async throws {
        let serverProvider = OpenASOMCPServerProvider {
            try await makeServer(configuration: configuration)
        }
        try await runStdio(serverProvider: serverProvider)
    }
}
