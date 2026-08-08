import SwiftUI

struct RootView: View {
    @Environment(AppServices.self) private var services

    @State private var selectedApp: TrackedApp?
    @State private var isPresentingKeywordResearch = false
    @State private var keywordResearchDetailModelCache =
        KeywordResearchProjectDetailModelCache()

    var body: some View {
        NavigationSplitView {
            RootSidebarView(selectedApp: $selectedApp)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            RootDetailView(selectedApp: selectedApp)
        }
        .navigationTitle("OpenASO")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPresentingKeywordResearch = true
                } label: {
                    Label("Keyword Research", systemImage: "magnifyingglass")
                }
                .help("Open the pre-live keyword research workspace")
            }
        }
        .sheet(isPresented: $isPresentingKeywordResearch) {
            KeywordResearchWorkspaceLauncher(
                detailModelCache: keywordResearchDetailModelCache
            )
        }
        .task {
            guard !Self.isRunningUnderTests else {
                return
            }
            await services.observeHeadlessRefreshes()
        }
        .task(id: services.inAppDailyRefreshConfiguration) {
            guard !Self.isRunningUnderTests else {
                return
            }
            guard !services.backgroundRefreshAgentController.isEnabled else {
                return
            }
            await services.dailyRefreshScheduler?.run()
        }
    }

    private static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private struct RootDetailView: View {
    let selectedApp: TrackedApp?

    @State private var isPresentingAddApp = false

    var body: some View {
        Group {
            if let selectedApp {
                AppDetailView(trackedApp: selectedApp)
            } else {
                ContentUnavailableView(
                    label: {
                        Label("Select an App", systemImage: "magnifyingglass")
                    },
                    description: {
                        Text("Choose an app from the sidebar or add a new one to start rank tracking.")
                    },
                    actions: {
                        Button {
                            isPresentingAddApp = true
                        } label: {
                            Label("Add App", systemImage: "plus")
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isPresentingAddApp) {
            AddAppSheet()
        }
    }
}
