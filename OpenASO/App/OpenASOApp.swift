import Foundation
import SwiftData
import SwiftUI

@main
struct OpenASOApp: App {
    @State private var updaterController = SparkleUpdaterController()
    @State private var launchAlert: AppLaunchAlertContext?

    @State private var startupState: OpenASOStartupState = .preparing
    @State private var isPreparingStartup = false

    init() {
        let executionMode = OpenASOExecutionMode(
            arguments: ProcessInfo.processInfo.arguments
        )
        if executionMode.suppressesApplicationUI {
            _ = NSApplication.shared.setActivationPolicy(.prohibited)
        }

        if executionMode == .backgroundRefresh {
            Self.runBackgroundRefreshAndExit()
        }

        if executionMode == .mcpStdio {
            switch Self.makeStartupState() {
            case .ready(_, let services):
                Self.runMCPStdioAndExit(serverProvider: services.mcpServerProvider)
            case .storeUnavailable(let error):
                Self.exitMCPStdio(with: error.diagnosticReport)
            case .preparing:
                preconditionFailure("Synchronous startup cannot return a preparing state.")
            }
        }

        _launchAlert = State(initialValue: nil)
    }

    private func prepareStartupIfNeeded() async {
        guard case .preparing = startupState, !isPreparingStartup else { return }
        isPreparingStartup = true
        defer { isPreparingStartup = false }
        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<ModelContainer, PersistentStoreError> in
            do {
                return .success(try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: false))
            } catch let error as PersistentStoreError {
                return .failure(error)
            } catch {
                return .failure(.unexpected(diagnosticDescription: String(reflecting: error)))
            }
        }.value
        switch result {
        case .success(let container):
            startupState = .ready(modelContainer: container, services: AppServices.appLaunch(modelContainer: container))
        case .failure(let error):
            startupState = .storeUnavailable(error)
        }
    }

    private static func makeStartupState() -> OpenASOStartupState {
        do {
            let modelContainer = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: false)
            let services = AppServices.appLaunch(modelContainer: modelContainer)
            return .ready(modelContainer: modelContainer, services: services)
        } catch let error as PersistentStoreError {
            return .storeUnavailable(error)
        } catch {
            return .storeUnavailable(.unexpected(
                diagnosticDescription: String(reflecting: error)
            ))
        }
    }

    private static func runBackgroundRefreshAndExit() -> Never {
        Task { @MainActor in
            Foundation.exit(await BackgroundRefreshRuntime.runOnce())
        }
        RunLoop.main.run()
        fatalError("The background refresh run loop stopped unexpectedly.")
    }

    private static func runMCPStdioAndExit(
        serverProvider: OpenASOMCPServerProvider
    ) -> Never {
        Task.detached {
            let exitCode: Int32
            do {
                try await OpenASOMCPRuntime.runStdio(serverProvider: serverProvider)
                exitCode = 0
            } catch {
                let description = (error as? PersistentStoreError)?.diagnosticReport
                    ?? String(reflecting: error)
                FileHandle.standardError.write(Data("OpenASO MCP server failed: \(description)\n".utf8))
                exitCode = 1
            }
            Foundation.exit(exitCode)
        }
        dispatchMain()
    }

    private static func exitMCPStdio(with diagnostic: String) -> Never {
        FileHandle.standardError.write(Data("OpenASO MCP server failed: \(diagnostic)\n".utf8))
        Foundation.exit(1)
    }

    var body: some Scene {
        WindowGroup("OpenASO") {
            switch startupState {
            case .preparing:
                ProgressView("Preparing your workspace…")
                    .frame(idealWidth: 1000, idealHeight: 760)
                    .task { await prepareStartupIfNeeded() }
            case .ready(let modelContainer, let services):
                RootView()
                    .environment(services)
                    .modelContainer(modelContainer)
                    .frame(idealWidth: 1000, idealHeight: 760)
                    .task {
                        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                            await services.backgroundRefreshAgentController.reconcile(
                                isEnabled: services.settingsStore.isAutomaticRefreshEnabled
                            )
                        }
                        services.analyticsService.capture(.appLaunched())
                        await services.prepareBackgroundModelStore()
                        launchAlert = await Self.seedStorefrontCatalogIfNeeded(using: services)
                    }
                    .alert(item: $launchAlert) { alert in
                        Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            dismissButton: .default(Text("OK"))
                        )
                    }
            case .storeUnavailable(let error):
                PersistentStoreRecoveryView(error: error)
                    .frame(idealWidth: 680, idealHeight: 480)
            }
        }
        .defaultWindowPlacement { content, context in
            let idealSize = content.sizeThatFits(.unspecified)
            let visibleRect = context.defaultDisplay.visibleRect
            let fittedSize = CGSize(
                width: min(idealSize.width, visibleRect.width),
                height: min(idealSize.height, visibleRect.height)
            )
            return WindowPlacement(size: fittedSize)
        }

        Settings {
            switch startupState {
            case .preparing:
                ProgressView("Preparing your workspace…")
                    .frame(idealWidth: 680, idealHeight: 480)
                    .task { await prepareStartupIfNeeded() }
            case .ready(let modelContainer, let services):
                SettingsView()
                    .environment(services)
                    .modelContainer(modelContainer)
            case .storeUnavailable(let error):
                PersistentStoreRecoveryView(error: error)
                    .frame(idealWidth: 680, idealHeight: 480)
            }
        }
        .defaultWindowPlacement { content, context in
            let idealSize = content.sizeThatFits(.unspecified)
            let visibleRect = context.defaultDisplay.visibleRect
            let fittedSize = CGSize(
                width: min(idealSize.width, visibleRect.width),
                height: min(idealSize.height, visibleRect.height)
            )
            return WindowPlacement(size: fittedSize)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...", action: updaterController.checkForUpdates)
                    .keyboardShortcut("u", modifiers: [.command, .option])
            }
        }
    }

    private static func seedStorefrontCatalogIfNeeded(using services: AppServices) async -> AppLaunchAlertContext? {
        do {
            guard let backgroundModelStore = services.backgroundModelStore else {
                throw OpenASOError.providerUnavailable("The background model store is unavailable.")
            }

            try await services.storefrontCatalog.seedIfNeeded(using: backgroundModelStore)
            return nil
        } catch {
            return AppLaunchAlertContext(
                title: "Country List Failed",
                message: OpenASOError.map(error).localizedDescription
            )
        }
    }
}

private enum OpenASOStartupState {
    case preparing
    case ready(modelContainer: ModelContainer, services: AppServices)
    case storeUnavailable(PersistentStoreError)
}

private struct AppLaunchAlertContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
