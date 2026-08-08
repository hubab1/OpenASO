import Foundation
import SwiftData
import SwiftUI

@main
struct OpenASOApp: App {
    @State private var updaterController = SparkleUpdaterController()
    @State private var launchAlert: AppLaunchAlertContext?

    private let startupState: OpenASOStartupState

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

        let startupState = Self.makeStartupState()
        if executionMode == .mcpStdio {
            switch startupState {
            case .ready(_, let services):
                Self.runMCPStdioAndExit(serverProvider: services.mcpServerProvider)
            case .storeUnavailable(let error):
                Self.exitMCPStdio(with: error.diagnosticReport)
            }
        }

        self.startupState = startupState
        _launchAlert = State(initialValue: nil)
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
            case .ready(let modelContainer, let services):
                RootView()
                    .environment(services)
                    .modelContainer(modelContainer)
                    .frame(minWidth: 1000, minHeight: 760)
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
                    .frame(minWidth: 680, minHeight: 480)
            }
        }

        Settings {
            switch startupState {
            case .ready(let modelContainer, let services):
                SettingsView()
                    .environment(services)
                    .modelContainer(modelContainer)
            case .storeUnavailable(let error):
                PersistentStoreRecoveryView(error: error)
                    .frame(minWidth: 680, minHeight: 480)
            }
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
    case ready(modelContainer: ModelContainer, services: AppServices)
    case storeUnavailable(PersistentStoreError)
}

private struct AppLaunchAlertContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
