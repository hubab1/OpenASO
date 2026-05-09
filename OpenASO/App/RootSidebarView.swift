import AppKit
import SwiftData
import SwiftUI

struct RootSidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Binding var selectedApp: TrackedApp?

    @Query(sort: [
        SortDescriptor(\TrackedApp.sidebarSortOrder, order: .forward),
        SortDescriptor(\TrackedApp.appStoreID, order: .forward)
    ])
    private var trackedApps: [TrackedApp]
    @Query(sort: [
        SortDescriptor(\AppFolder.sortOrder, order: .forward),
        SortDescriptor(\AppFolder.name, order: .forward)
    ])
    private var appFolders: [AppFolder]
    @Query(sort: [
        SortDescriptor(\TrackedAppKeyword.appStoreID, order: .forward),
        SortDescriptor(\TrackedAppKeyword.term, order: .forward)
    ])
    private var trackedKeywords: [TrackedAppKeyword]

    @State private var isPresentingAddApp = false
    @State private var isPresentingNewFolder = false
    @State private var isPresentingRenameFolder = false
    @State private var folderName = ""
    @State private var selectedFolderColorRaw = SidebarFolderColor.defaultColor.rawValue
    @State private var folderPendingRename: AppFolder?
    @State private var folderPendingDeletion: AppFolder?
    @State private var updatingAppInfoIDs: Set<Int64> = []
    @State private var appPendingDeletion: TrackedApp?
    @State private var currentAlert: SidebarAlertContext?
    @State private var hoveredAppID: Int64?
    @State private var isPresentingMCPServer = false
    @State private var isMCPHovered = false
    @State private var isSettingsHovered = false

    private var unfiledApps: [TrackedApp] {
        sortedApps(in: nil)
    }

    private var keywordTrackCountsByAppStoreID: [Int64: Int] {
        Dictionary(grouping: trackedKeywords, by: \.appStoreID).mapValues(\.count)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            appList
            footer
        }
        .sheet(isPresented: $isPresentingAddApp) {
            AddAppSheet()
        }
        .sheet(isPresented: $isPresentingNewFolder) {
            NewFolderSheet(
                folderName: $folderName,
                selectedColorRaw: $selectedFolderColorRaw,
                createAction: createFolder,
                cancelAction: resetNewFolderForm
            )
        }
        .sheet(isPresented: $isPresentingMCPServer) {
            MCPServerSheet(
                controller: services.mcpServerController,
                settingsStore: services.settingsStore
            )
        }
        .alert("Rename Folder", isPresented: $isPresentingRenameFolder) {
            TextField("Folder Name", text: $folderName)

            Button("Rename") {
                renameFolder()
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Cancel", role: .cancel) {
                folderPendingRename = nil
                folderName = ""
            }
        }
        .task {
            if selectedApp == nil {
                selectedApp = trackedApps.first
            }
        }
        .task(id: trackedApps.count) {
            if selectedApp == nil || !trackedApps.contains(where: { $0.persistentModelID == selectedApp?.persistentModelID }) {
                selectedApp = trackedApps.first
            }
        }
        .alert(item: $currentAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            pendingDeletionTitle,
            isPresented: Binding(
                get: { appPendingDeletion != nil || folderPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        appPendingDeletion = nil
                        folderPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let appPendingDeletion {
                Button("Delete App", role: .destructive) {
                    deleteApp(appPendingDeletion)
                }
            }

            if let folderPendingDeletion {
                Button("Delete Folder", role: .destructive) {
                    deleteFolder(folderPendingDeletion)
                }
            }
        } message: {
            if let appPendingDeletion {
                Text("Delete \(appPendingDeletion.name) and its keyword tracks from OpenASO.")
            } else if let folderPendingDeletion {
                Text("Delete \(folderPendingDeletion.name). Apps inside it will remain tracked and move back to the main app list.")
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Apps")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                folderName = suggestedFolderName
                selectedFolderColorRaw = SidebarFolderColor.defaultColor.rawValue
                isPresentingNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("New Folder")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .dropDestination(for: String.self) { items, _ in
            moveDraggedApps(items, to: nil, before: nil)
        }
    }

    private var appList: some View {
        Group {
            if trackedApps.isEmpty && appFolders.isEmpty {
                ContentUnavailableView(
                    "No Apps Yet",
                    systemImage: "shippingbox",
                    description: Text("Add your first App Store app to begin tracking keywords across countries.")
                )
            } else {
                List(selection: $selectedApp) {
                    ForEach(appFolders) { folder in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { folder.isExpanded },
                                set: { isExpanded in
                                    folder.isExpanded = isExpanded
                                    saveSidebarChanges()
                                }
                            )
                        ) {
                            ForEach(sortedApps(in: folder)) { trackedApp in
                                appRow(for: trackedApp)
                            }
                        } label: {
                            folderLabel(for: folder)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            moveDraggedApps(items, to: folder, before: nil)
                        }
                        .contextMenu {
                            Button("Rename") {
                                folderPendingRename = folder
                                folderName = folder.name
                                isPresentingRenameFolder = true
                            }

                            Button("Delete Folder", role: .destructive) {
                                folderPendingDeletion = folder
                            }
                        }
                    }

                    ForEach(unfiledApps) { trackedApp in
                        appRow(for: trackedApp)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let activeRefresh = services.refreshProgressStore.activeRefresh {
                SidebarRefreshProgressView(
                    refresh: activeRefresh,
                    pendingAppRefreshCount: services.refreshProgressStore.pendingAppRefreshCount,
                    pendingKeywordTrackCount: services.refreshProgressStore.pendingKeywordTrackCount
                )
            }

            if let activeDownload = services.screenshotDownloadProgressStore.activeDownload {
                SidebarScreenshotDownloadProgressView(download: activeDownload)
            }

            Button {
                isPresentingAddApp = true
            } label: {
                HStack {
                    Text("Add App")
                    Spacer()
                    Image(systemName: "plus")
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15))
            )

            Button {
                isPresentingMCPServer = true
            } label: {
                SidebarUtilityRow(
                    title: "MCP Server",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    state: services.mcpServerController.state,
                    isHovered: isMCPHovered
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { isMCPHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isMCPHovered)
            .help(mcpHelpText)

            SettingsLink {
                HStack {
                    Label("Settings", systemImage: "gearshape")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSettingsHovered ? Color.primary.opacity(0.06) : Color.clear)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { isSettingsHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isSettingsHovered)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func folderLabel(for folder: AppFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(SidebarFolderColor.color(for: folder.colorRaw))

            Text(folder.name)
                .font(.headline)
                .lineLimit(1)
        }
    }

    private func appRow(for trackedApp: TrackedApp) -> some View {
        let appStoreID = trackedApp.appStoreID
        let draggableID = String(appStoreID)
        let keywordTrackCount = keywordTrackCountsByAppStoreID[appStoreID, default: 0]

        return HStack(spacing: 12) {
            AppIconView(
                appStoreID: trackedApp.appStoreID,
                size: 44,
                cornerRadius: 10
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(trackedApp.name)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(keywordTrackCount) keywords")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            PinIconButton(
                isPinned: trackedApp.isPinned,
                isVisible: trackedApp.isPinned || hoveredAppID == appStoreID,
                size: 26
            ) {
                togglePinned(trackedApp)
            }
        }
        .padding(.vertical, 4)
        .onHover { isHovering in
            hoveredAppID = isHovering ? appStoreID : nil
        }
        .draggable(draggableID)
        .dropDestination(for: String.self) { items, _ in
            moveDraggedApps(items, to: trackedApp.folder, before: trackedApp)
        }
        .contextMenu {
            Button("Update App Info") {
                updateAppInfo(for: trackedApp, storefrontCode: nil)
            }
            .disabled(updatingAppInfoIDs.contains(appStoreID))

            Button("Open in App Store") {
                openInAppStore(trackedApp)
            }

            Button("Open in Sensor Tower") {
                openInSensorTower(trackedApp)
            }

            Button(trackedApp.isPinned ? "Unpin App" : "Pin App") {
                togglePinned(trackedApp)
            }

            if trackedApp.folder != nil {
                Button("Remove from Folder") {
                    _ = moveDraggedApps([draggableID], to: nil, before: nil)
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                appPendingDeletion = trackedApp
            }
        }
        .tag(trackedApp)
    }

    private var pendingDeletionTitle: String {
        folderPendingDeletion == nil ? "Delete App?" : "Delete Folder?"
    }

    private var mcpHelpText: String {
        switch services.mcpServerController.state {
        case .running(let endpointURL):
            return "MCP server running at \(endpointURL.absoluteString)"
        case .starting:
            return "MCP server is starting"
        case .stopping:
            return "MCP server is stopping"
        case .failed(let message):
            return "MCP server failed: \(message)"
        case .stopped:
            return "Open MCP server controls"
        }
    }

    private var suggestedFolderName: String {
        var index = appFolders.count + 1
        var name = "New Folder"

        while appFolders.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            name = "New Folder \(index)"
            index += 1
        }

        return name
    }

    private var nextFolderSortOrder: Int {
        (appFolders.map(\.sortOrder).max() ?? -1) + 1
    }

    private var nextUnfiledAppSortOrder: Int {
        (unfiledApps.map(\.sidebarSortOrder).max() ?? -1) + 1
    }

    private func sortedApps(in folder: AppFolder?) -> [TrackedApp] {
        trackedApps
            .filter { trackedApp in
                switch (trackedApp.folder, folder) {
                case (nil, nil):
                    return true
                case let (trackedFolder?, folder?):
                    return trackedFolder.id == folder.id
                default:
                    return false
                }
            }
            .sorted { first, second in
                if first.isPinned != second.isPinned {
                    return first.isPinned && !second.isPinned
                }

                if first.sidebarSortOrder == second.sidebarSortOrder {
                    let nameComparison = first.name.localizedCaseInsensitiveCompare(second.name)
                    if nameComparison != .orderedSame {
                        return nameComparison == .orderedAscending
                    }

                    return first.appStoreID < second.appStoreID
                }
                return first.sidebarSortOrder < second.sidebarSortOrder
            }
    }

    private func createFolder() {
        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        modelContext.insert(AppFolder(
            name: trimmedName,
            sortOrder: nextFolderSortOrder,
            colorRaw: selectedFolderColorRaw
        ))
        resetNewFolderForm()
        saveSidebarChanges()
    }

    private func resetNewFolderForm() {
        folderName = ""
        selectedFolderColorRaw = SidebarFolderColor.defaultColor.rawValue
        isPresentingNewFolder = false
    }

    private func renameFolder() {
        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderPendingRename, !trimmedName.isEmpty else {
            return
        }

        folderPendingRename.name = trimmedName
        folderName = ""
        self.folderPendingRename = nil
        saveSidebarChanges()
    }

    private func moveDraggedApps(_ draggedAppIDs: [String], to folder: AppFolder?, before targetApp: TrackedApp?) -> Bool {
        guard !draggedAppIDs.isEmpty else {
            return false
        }

        let draggedApps = draggedAppIDs.compactMap { draggedAppID -> TrackedApp? in
            guard let appStoreID = Int64(draggedAppID) else {
                return nil
            }
            return trackedApps.first { $0.appStoreID == appStoreID }
        }
        guard !draggedApps.isEmpty else {
            return false
        }

        var destinationApps = sortedApps(in: folder)
            .filter { destinationApp in
                !draggedApps.contains { $0.persistentModelID == destinationApp.persistentModelID }
            }

        let insertionIndex: Int
        if let targetApp, let targetIndex = destinationApps.firstIndex(where: { $0.persistentModelID == targetApp.persistentModelID }) {
            insertionIndex = targetIndex
        } else {
            insertionIndex = destinationApps.endIndex
        }

        destinationApps.insert(contentsOf: draggedApps, at: insertionIndex)

        for draggedApp in draggedApps {
            draggedApp.folder = folder
        }

        normalizeSidebarOrder(for: destinationApps)
        normalizeSidebarOrder(for: sortedApps(in: nil))
        for appFolder in appFolders {
            normalizeSidebarOrder(for: sortedApps(in: appFolder))
        }

        saveSidebarChanges()
        return true
    }

    private func normalizeSidebarOrder(for apps: [TrackedApp]) {
        for (index, app) in apps.enumerated() {
            app.sidebarSortOrder = index
        }
    }

    private func saveSidebarChanges() {
        do {
            try modelContext.save()
        } catch {
            currentAlert = SidebarAlertContext(
                title: "Sidebar Update Failed",
                message: OpenASOError.map(error).localizedDescription
            )
        }
    }

    private func updateAppInfo(for trackedApp: TrackedApp, storefrontCode: String?) {
        let appStoreID = trackedApp.appStoreID
        guard !updatingAppInfoIDs.contains(appStoreID) else {
            return
        }

        updatingAppInfoIDs.insert(appStoreID)

        Task { @MainActor in
            defer {
                updatingAppInfoIDs.remove(appStoreID)
            }

            do {
                let resolvedApp = try await services.appResolver.resolve(
                    appStoreID: appStoreID,
                    storefrontCode: storefrontCode ?? "us"
                )
                let storeApp = try services.appCatalogService.upsertStoreApp(
                    from: resolvedApp,
                    storefrontCode: storefrontCode ?? "us",
                    in: modelContext
                )

                trackedApp.storeApp = storeApp
                trackedApp.bundleID = resolvedApp.bundleID
                trackedApp.name = resolvedApp.name
                trackedApp.subtitle = resolvedApp.subtitle
                trackedApp.sellerName = resolvedApp.sellerName
                trackedApp.defaultPlatform = resolvedApp.defaultPlatform

                await services.appIconStore.invalidate(appStoreID: appStoreID)
                try modelContext.save()
            } catch {
                currentAlert = SidebarAlertContext(
                    title: "Update App Info Failed",
                    message: OpenASOError.map(error).localizedDescription
                )
            }
        }
    }

    private func openInAppStore(_ trackedApp: TrackedApp) {
        guard let url = URL(string: "https://apps.apple.com/app/id\(trackedApp.appStoreID)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func openInSensorTower(_ trackedApp: TrackedApp) {
        guard let url = URL(string: "https://app.sensortower.com/overview/\(trackedApp.appStoreID)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func togglePinned(_ trackedApp: TrackedApp) {
        trackedApp.isPinned.toggle()
        saveSidebarChanges()
    }

    private func deleteFolder(_ folder: AppFolder) {
        var sortOrder = nextUnfiledAppSortOrder
        for trackedApp in sortedApps(in: folder) {
            trackedApp.folder = nil
            trackedApp.sidebarSortOrder = sortOrder
            sortOrder += 1
        }

        modelContext.delete(folder)
        folderPendingDeletion = nil
        saveSidebarChanges()
    }

    private func deleteApp(_ trackedApp: TrackedApp) {
        let trackedKeywords: [TrackedAppKeyword]
        do {
            trackedKeywords = try fetchTrackedKeywords(for: trackedApp)
        } catch {
            currentAlert = SidebarAlertContext(
                title: "Delete Failed",
                message: OpenASOError.map(error).localizedDescription
            )
            return
        }

        let keywordCount = trackedKeywords.count
        if selectedApp?.persistentModelID == trackedApp.persistentModelID {
            selectedApp = trackedApps.first { $0.persistentModelID != trackedApp.persistentModelID }
        }

        for track in trackedKeywords {
            modelContext.delete(track)
        }

        modelContext.delete(trackedApp)

        do {
            try modelContext.save()
            services.analyticsService.capture(.trackedAppRemoved(keywordCount: keywordCount))
        } catch {
            currentAlert = SidebarAlertContext(
                title: "Delete Failed",
                message: OpenASOError.map(error).localizedDescription
            )
        }
    }

    private func fetchTrackedKeywords(for trackedApp: TrackedApp) throws -> [TrackedAppKeyword] {
        let appStoreID = trackedApp.appStoreID
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.appStoreID == appStoreID
            }
        )
        return try modelContext.fetch(descriptor)
    }
}

private struct SidebarUtilityRow: View {
    let title: String
    let systemImage: String
    let state: OpenASOMCPServerController.State?
    let isHovered: Bool

    var body: some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let state {
                MCPServerStateAccessory(state: state)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        }
        .contentShape(.rect)
    }
}

private struct MCPServerStateAccessory: View {
    let state: OpenASOMCPServerController.State

    var body: some View {
        Group {
            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(accessibilityLabel)
    }

    private var systemImage: String {
        switch state {
        case .running:
            return "circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "circle"
        case .starting, .stopping:
            return "circle.dotted"
        }
    }

    private var tint: Color {
        switch state {
        case .running:
            return .green
        case .failed:
            return .red
        case .starting, .stopping:
            return .orange
        case .stopped:
            return .secondary
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .running:
            return "MCP server running"
        case .failed:
            return "MCP server failed"
        case .starting:
            return "MCP server starting"
        case .stopping:
            return "MCP server stopping"
        case .stopped:
            return "MCP server stopped"
        }
    }
}

private struct SidebarAlertContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SidebarRefreshProgressView: View {
    let refresh: AppRefreshProgress
    let pendingAppRefreshCount: Int
    let pendingKeywordTrackCount: Int

    private var progressValue: Double {
        Double(refresh.completedUnits)
    }

    private var progressTotal: Double {
        Double(max(refresh.totalUnits, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .opacity(refresh.phase == .completed || refresh.phase == .failed ? 0 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(refresh.appName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(statusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }

            ProgressView(value: progressValue, total: progressTotal)
                .controlSize(.small)

            VStack(spacing: 6) {
                SidebarRefreshProgressRow(title: "Keywords & Metrics", progress: refresh.keywordAndMetricsProgress)
                SidebarRefreshProgressRow(title: "Ratings", progress: refresh.ratingsProgress)
                SidebarRefreshProgressRow(title: "Reviews", progress: refresh.reviewsProgress)
                SidebarPendingAppRefreshesRow(appCount: pendingAppRefreshCount)
                SidebarPendingKeywordAdditionsRow(trackCount: pendingKeywordTrackCount)
            }

            if let errorMessage = refresh.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        "\(statusTitle), \(refresh.appName), \(refresh.completedUnits) of \(refresh.totalUnits) steps complete"
    }

    private var statusTitle: String {
        switch refresh.trigger {
        case "after_add_app":
            return addedAppStatusTitle
        case "after_add_keyword":
            return addedKeywordStatusTitle
        case "after_import_keywords":
            return importedKeywordStatusTitle
        case "manual_all":
            return refresh.phase == .completed ? "All apps refreshed" : refresh.phase == .failed ? "Refresh all failed" : "Refreshing all apps"
        case "daily_refresh":
            return refresh.phase == .completed ? "Daily refresh complete" : refresh.phase == .failed ? "Daily refresh failed" : "Running daily refresh"
        case "apple_ads_connection":
            return refresh.phase == .completed ? "Popularity refreshed" : refresh.phase == .failed ? "Popularity refresh failed" : "Refreshing keyword popularity"
        default:
            return refresh.phase.title
        }
    }

    private var addedAppStatusTitle: String {
        switch refresh.phase {
        case .preparing:
            return "Setting up app data"
        case .refreshingRatings:
            return "Fetching ratings"
        case .refreshingReviews:
            return "Fetching reviews"
        case .finishing:
            return "Finishing app setup"
        case .completed:
            return "App data ready"
        case .failed:
            return "App data update failed"
        case .refreshingKeywords, .refreshingMetrics:
            return refresh.phase.title
        }
    }

    private var addedKeywordStatusTitle: String {
        switch refresh.phase {
        case .preparing:
            return "Preparing keyword data"
        case .refreshingKeywords:
            return "Fetching keyword rankings"
        case .refreshingMetrics:
            return "Fetching keyword metrics"
        case .finishing:
            return "Finishing keyword data"
        case .completed:
            return "Keyword data ready"
        case .failed:
            return "Keyword data update failed"
        case .refreshingRatings, .refreshingReviews:
            return refresh.phase.title
        }
    }

    private var importedKeywordStatusTitle: String {
        switch refresh.phase {
        case .preparing:
            return "Preparing imported keywords"
        case .refreshingKeywords:
            return "Fetching imported rankings"
        case .refreshingMetrics:
            return "Fetching imported metrics"
        case .finishing:
            return "Finishing imported keywords"
        case .completed:
            return "Imported keywords ready"
        case .failed:
            return "Imported keyword update failed"
        case .refreshingRatings, .refreshingReviews:
            return refresh.phase.title
        }
    }
}

private struct SidebarPendingAppRefreshesRow: View {
    let appCount: Int

    var body: some View {
        if appCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text("Queued app refreshes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                Text("\(appCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SidebarPendingKeywordAdditionsRow: View {
    let trackCount: Int

    var body: some View {
        if trackCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text("Queued keyword tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                Text("\(trackCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SidebarRefreshProgressRow: View {
    let title: String
    let progress: AppRefreshStepProgress

    var body: some View {
        if progress.isVisible {
            HStack(spacing: 8) {
                Image(systemName: statusImageName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 12)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(progress.failureCount > 0 ? .orange : .secondary)
            }
        }
    }

    private var summary: String {
        guard progress.total > 0 else {
            return progress.status.title
        }
        if progress.failureCount > 0 {
            return "\(progress.completed)/\(progress.total) \(progress.failureCount) failed"
        }
        return "\(progress.completed)/\(progress.total)"
    }

    private var statusImageName: String {
        switch progress.status {
        case .pending:
            return "circle"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle.fill"
        case .skipped:
            return "minus.circle"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch progress.status {
        case .pending, .skipped:
            return .secondary
        case .running:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }
}

private struct SidebarScreenshotDownloadProgressView: View {
    let download: ScreenshotDownloadProgress

    private var tint: Color {
        switch download.phase {
        case .running:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }

    private var systemImage: String {
        switch download.phase {
        case .running:
            return "arrow.down.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(download.phase.title)
                        .font(.caption.weight(.semibold))
                    Text(download.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            ProgressView(value: download.progressValue, total: download.progressTotal)
                .tint(tint)

            Text(download.message ?? download.summaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.18))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(download.phase.title), \(download.title), \(download.summaryText)")
    }
}

private struct NewFolderSheet: View {
    @Binding var folderName: String
    @Binding var selectedColorRaw: String

    let createAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Folder")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Folder Name", text: $folderName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                ForEach(SidebarFolderColor.allCases) { folderColor in
                    Button {
                        selectedColorRaw = folderColor.rawValue
                    } label: {
                        ZStack {
                            Circle()
                                .fill(folderColor.color)
                                .frame(width: 24, height: 24)

                            if selectedColorRaw == folderColor.rawValue {
                                Circle()
                                    .stroke(.primary, lineWidth: 2)
                                    .frame(width: 32, height: 32)
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(folderColor.accessibilityName)
                    .help(folderColor.accessibilityName)
                }
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel, action: cancelAction)

                Button("Create", action: createAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

private enum SidebarFolderColor: String, CaseIterable, Identifiable {
    case blue
    case cyan
    case green
    case orange
    case pink

    static let defaultColor: SidebarFolderColor = .blue

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue:
            return .blue
        case .cyan:
            return .cyan
        case .green:
            return .green
        case .orange:
            return .orange
        case .pink:
            return .pink
        }
    }

    var accessibilityName: String {
        switch self {
        case .blue:
            return "Blue"
        case .cyan:
            return "Cyan"
        case .green:
            return "Green"
        case .orange:
            return "Orange"
        case .pink:
            return "Pink"
        }
    }

    static func color(for rawValue: String) -> Color {
        (SidebarFolderColor(rawValue: rawValue) ?? defaultColor).color
    }
}
