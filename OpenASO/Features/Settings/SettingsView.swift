import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    private let validatesOnAppear: Bool
    private let focusSection: AppleAdsSettingsFocusSection?
    private let initialConnectionState: AppleAdsConnectionState?

    @State private var clientID = ""
    @State private var teamID = ""
    @State private var keyID = ""
    @State private var privateKey = ""
    @State private var orgID = ""
    @State private var dailyRefreshTime = Date()
    @State private var webLoginUsername = ""
    @State private var webLoginPassword = ""
    @State private var connectionState: AppleAdsConnectionState
    @State private var isSavedLoginExpanded = false
    @State private var isSavedLoginHovered = false
    @State private var showsSavedLoginControls = false
    @State private var savedLoginStatus: VerificationStatus?
    @State private var dependencyStatus: AppleAdsWebSessionDependencyStatus?
    @State private var manualAppleAdsAppID = ""
    @State private var manualAppleAdsStatus: VerificationStatus?
    @State private var ascIssuerID = ""
    @State private var ascKeyID = ""
    @State private var ascPrivateKey = ""
    @State private var ascConnectionState: AppStoreConnectConnectionState = .notConnected
    @State private var ascStatus: VerificationStatus?
    @State private var isASCPrivateKeyDropTargeted = false
    @State private var isShowingAppStoreConnectHelp = false

    init(
        validatesOnAppear: Bool = false,
        focusSection: AppleAdsSettingsFocusSection? = nil,
        initialConnectionState: AppleAdsConnectionState? = nil
    ) {
        self.validatesOnAppear = validatesOnAppear
        self.focusSection = focusSection
        self.initialConnectionState = initialConnectionState
        _connectionState = State(initialValue: initialConnectionState ?? .notConnected)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Toggle("Automatic Refresh", isOn: automaticRefreshEnabled)

                    DatePicker("Refresh Time", selection: $dailyRefreshTime, displayedComponents: .hourAndMinute)
                        .disabled(!services.settingsStore.isAutomaticRefreshEnabled)
                        .onChange(of: dailyRefreshTime) { _, newValue in
                            services.settingsStore.saveRefreshTime(from: newValue)
                        }

                    if let lastRefreshTriggeredAt = services.settingsStore.lastRefreshTriggeredAt {
                        Text("Last triggered \(lastRefreshTriggeredAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No daily refresh has run yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Daily Refresh")
                } footer: {
                    Text("OpenASO refreshes stale keyword rankings once per local day after this time when automatic refresh is enabled.")
                }
                .id(AppleAdsSettingsFocusSection.dailyRefresh)

                mcpSection

                appleAdsSection
                .id(AppleAdsSettingsFocusSection.webSession)

                appStoreConnectSection
                    .id(AppleAdsSettingsFocusSection.appStoreConnect)

                analyticsSection
                    .id(AppleAdsSettingsFocusSection.analytics)
            }
            .formStyle(.grouped)
            .contentMargins(.vertical, 20, for: .scrollContent)
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .frame(
                minWidth: 460,
                idealWidth: 500,
                maxWidth: 540,
                minHeight: 700,
                idealHeight: 760,
                alignment: .topTrailing
            )
            .navigationTitle("Settings")
            .onAppear {
                loadCredentials()
                loadAppStoreConnectCredentials()
                loadDailyRefreshTime()
                loadWebLoginCredentials()
                loadDependencyStatus()
                showsSavedLoginControls = services.appleAdsCredentialStore.hasWebLoginCredentials
                    || services.appleAdsWebSessionStore.hasSession
                if initialConnectionState == nil {
                    connectionState = inferredConnectionState()
                }
                ascConnectionState = inferredAppStoreConnectConnectionState()
                let targetFocusSection = focusSection ?? services.settingsStore.requestedSettingsFocusSection
                if let targetFocusSection {
                    proxy.scrollTo(targetFocusSection, anchor: .top)
                    services.settingsStore.clearSettingsFocusRequest()
                }
                if validatesOnAppear {
                    validateAppleAdsAccess()
                }
                services.analyticsService.capture(.settingsOpened(focusSection: targetFocusSection?.analyticsValue ?? "none"))
            }
            .onChange(of: services.settingsStore.requestedSettingsFocusSection) { _, requestedSection in
                guard let requestedSection else { return }
                proxy.scrollTo(requestedSection, anchor: .top)
                services.settingsStore.clearSettingsFocusRequest()
            }
        }
    }

    private var analyticsSection: some View {
        Section {
            Toggle("Share Anonymous Analytics", isOn: analyticsEnabled)
        } header: {
            Text("Analytics")
        } footer: {
            #if OPENASO_OSS_BUILD
            Text("Off by default. When enabled, OpenASO sends anonymous product usage events to understand which features are used and how often. It does not collect identifying information or details about your apps, keywords, reviews, replies, credentials, search text, or countries.")
            #else
            Text("OpenASO sends anonymous product usage events to understand which features are used and how often. It does not collect identifying information or details about your apps, keywords, reviews, replies, credentials, search text, or countries.")
            #endif
        }
    }

    private var mcpSection: some View {
        Section {
            MCPServerStatusRow(state: services.mcpServerController.state)

            LabeledContent("HTTP Port") {
                HStack(spacing: 8) {
                    TextField("", value: mcpServerPortBinding, format: .number.grouping(.never))
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 82)

                    Stepper(
                        "HTTP Port",
                        value: mcpServerPortBinding,
                        in: MCPServerPort.minimum...MCPServerPort.maximum
                    )
                    .labelsHidden()
                }
            }
            .disabled(mcpPortControlsDisabled)

            HStack(spacing: 10) {
                Button(mcpPrimaryActionTitle, action: toggleMCPServer)
                    .disabled(services.mcpServerController.state.isBusy)

                if services.mcpServerController.state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let endpointURL = services.mcpServerController.state.endpointURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(endpointURL.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("MCP Server")
        } footer: {
            Text("Starts a local loopback MCP HTTP server for agents that can connect to an already-running app. Stop the server before changing the port. Stdio MCP clients should still launch the OpenASOMCP command-line target directly.")
        }
    }

    private var appStoreConnectSection: some View {
        Section {
            AppStoreConnectConnectionStatusRow(state: ascConnectionState)

            Button {
                isShowingAppStoreConnectHelp = true
            } label: {
                Label("How to create your API key", systemImage: "questionmark.circle")
                    .font(.callout)
            }
            .buttonStyle(.link)
            .popover(isPresented: $isShowingAppStoreConnectHelp, arrowEdge: .top) {
                AppStoreConnectAPIKeyHelpPopover()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Issuer ID")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Issuer ID", text: $ascIssuerID)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Key ID")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Key ID", text: $ascKeyID)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.leading)
            }

            ascPrivateKeyInput

            HStack(spacing: 10) {
                Button("Connect / Validate", action: validateAppStoreConnect)
                    .disabled(ascConnectionState.isBusy || !enteredAppStoreConnectCredentials.isComplete)

                if ascConnectionState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Clear Credentials", role: .destructive, action: clearAppStoreConnectCredentials)
                    .disabled(ascConnectionState.isBusy || !services.appStoreConnectCredentialStore.hasCompleteCredentials)
            }

            if let ascStatus {
                Label(ascStatus.message, systemImage: ascStatus.systemImage)
                    .foregroundStyle(ascStatus.tint)
                    .font(.caption)
            }
        } header: {
            Text("App Store Connect")
        } footer: {
            Text("OpenASO uses App Store Connect API keys only for apps visible to your App Store Connect account. The private key is stored in Keychain.")
        }
    }

    private var appleAdsSection: some View {
        Section {
            AppleAdsConnectionStatusRow(state: connectionState)

            HStack(spacing: 10) {
                Button(connectionState.primaryActionTitle, action: connectAppleAds)
                    .disabled(connectionState.isPrimaryActionDisabled)

                if connectionState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Check Status", action: validateAppleAdsAccess)
                    .disabled(connectionState.isBusy || !services.appleAdsWebSessionStore.hasSession)

                Button("Clear", role: .destructive, action: clearWebSession)
                    .disabled(connectionState.isBusy || !services.appleAdsWebSessionStore.hasSession)
            }

            if showsManualAppleAdsAppIDFallback {
                manualAppleAdsAppIDFallback
            }

            if showsSavedLoginControls {
                DisclosureGroup(isExpanded: $isSavedLoginExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if services.appleAdsCredentialStore.hasWebLoginCredentials {
                            Text("Saved login available.")
                                .foregroundStyle(.secondary)
                        }

                        TextField("Apple ID", text: $webLoginUsername)
                            .textContentType(.username)
                        SecureField("Password", text: $webLoginPassword)
                            .textContentType(.password)

                        HStack {
                            Button("Save Login", action: saveWebLoginCredentials)
                                .disabled(connectionState.isBusy || !enteredWebLoginCredentials.isComplete)

                            Button("Forget Saved Login", role: .destructive, action: clearWebLoginCredentials)
                                .disabled(connectionState.isBusy || !services.appleAdsCredentialStore.hasWebLoginCredentials)
                        }

                        if let savedLoginStatus {
                            Label(savedLoginStatus.message, systemImage: savedLoginStatus.systemImage)
                                .foregroundStyle(savedLoginStatus.tint)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 6)
                } label: {
                    Text("Saved Login")
                        .foregroundStyle(isSavedLoginHovered ? Color.accentColor : Color.primary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                isSavedLoginExpanded.toggle()
                            }
                        }
                        .onHover { isSavedLoginHovered = $0 }
                }
            }
        } header: {
            Text("Apple Ads")
        } footer: {
            Text("Connect Apple Ads to show keyword popularity in OpenASO. Your Apple Ads account needs access to at least one of your App Store apps. Saved login details are optional and kept in Keychain.")
        }
    }

    private var manualAppleAdsAppIDFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Store ID")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("6608976383", text: $manualAppleAdsAppID)
                    .textContentType(.oneTimeCode)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)

                Button("Use App ID", action: useManualAppleAdsAppID)
                    .disabled(connectionState.isBusy || manualAppleAdsAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let manualAppleAdsStatus {
                Label(manualAppleAdsStatus.message, systemImage: manualAppleAdsStatus.systemImage)
                    .foregroundStyle(manualAppleAdsStatus.tint)
                    .font(.caption)
            } else {
                Text("Enter the App Store ID for one of your apps to finish Apple Ads setup.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var ascPrivateKeyInput: some View {
        TextEditor(text: $ascPrivateKey)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)
            .contentMargins(.top, 8, for: .scrollContent)
            .frame(minHeight: 120)
            .overlay(alignment: .topLeading) {
                if ascPrivateKey.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Drop .p8 auth key here", systemImage: "doc.badge.plus")
                            .font(.callout.weight(.medium))
                        Text("You can also paste the private key text directly.")
                            .font(.caption)
                    }
                    .foregroundStyle(isASCPrivateKeyDropTargeted ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isASCPrivateKeyDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: isASCPrivateKeyDropTargeted ? 2 : 1, dash: [6, 4])
                    )
                    .allowsHitTesting(false)
            }
            .background(isASCPrivateKeyDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .onDrop(
                of: [UTType.fileURL.identifier, UTType.plainText.identifier, UTType.utf8PlainText.identifier],
                isTargeted: $isASCPrivateKeyDropTargeted,
                perform: handleASCPrivateKeyDrop
            )
            .onChange(of: ascPrivateKey) { oldValue, newValue in
                guard oldValue != newValue, let url = Self.ascPrivateKeyFileURL(from: newValue) else { return }
                loadASCPrivateKeyFile(at: url)
            }
            .accessibilityLabel("App Store Connect private key")
            .accessibilityHint("Paste private key text or drop a .p8 authentication key file.")
    }

    private func handleASCPrivateKeyDrop(_ providers: [NSItemProvider]) -> Bool {
        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    setASCPrivateKeyDropFailure(error.localizedDescription)
                    return
                }

                guard let url = Self.droppedFileURL(from: item) else {
                    setASCPrivateKeyDropFailure("OpenASO could not read the dropped file.")
                    return
                }

                loadASCPrivateKeyFile(at: url)
            }
            return true
        }

        if let textProvider = providers.first(where: { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
        }) {
            let typeIdentifier = textProvider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
                ? UTType.utf8PlainText.identifier
                : UTType.plainText.identifier
            textProvider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    setASCPrivateKeyDropFailure(error.localizedDescription)
                    return
                }

                guard let text = Self.droppedText(from: item) else {
                    setASCPrivateKeyDropFailure("OpenASO could not read the dropped text.")
                    return
                }

                if let url = Self.ascPrivateKeyFileURL(from: text) {
                    loadASCPrivateKeyFile(at: url)
                    return
                }

                Task { @MainActor in
                    ascPrivateKey = text
                    ascStatus = .success("Private key text added.")
                }
            }
            return true
        }

        return false
    }

    nonisolated private func loadASCPrivateKeyFile(at url: URL) {
        guard url.pathExtension.lowercased() == "p8" else {
            setASCPrivateKeyDropFailure("Drop an App Store Connect .p8 auth key file.")
            return
        }

        do {
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            guard let privateKey = String(data: data, encoding: .utf8), !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                setASCPrivateKeyDropFailure("The .p8 auth key file is empty or not valid UTF-8 text.")
                return
            }

            Task { @MainActor in
                ascPrivateKey = privateKey
                ascStatus = .success("Private key loaded from \(url.lastPathComponent).")
            }
        } catch {
            setASCPrivateKeyDropFailure(OpenASOError.map(error).localizedDescription)
        }
    }

    nonisolated private func setASCPrivateKeyDropFailure(_ message: String) {
        Task { @MainActor in
            ascStatus = .failure(message)
        }
    }

    nonisolated private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }

    nonisolated private static func droppedText(from item: NSSecureCoding?) -> String? {
        if let string = item as? String {
            return string
        }

        if let string = item as? NSString {
            return string as String
        }

        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }

        return nil
    }

    nonisolated private static func ascPrivateKeyFileURL(from text: String) -> URL? {
        let fileReference = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileReference.isEmpty, !fileReference.contains("\n"), !fileReference.contains("\r") else { return nil }

        let url: URL?
        if let parsedURL = URL(string: fileReference), parsedURL.isFileURL {
            url = parsedURL
        } else {
            url = URL(fileURLWithPath: (fileReference as NSString).expandingTildeInPath)
        }

        guard let url, url.pathExtension.lowercased() == "p8" else { return nil }
        return url
    }

    private var enteredCredentials: AppleAdsCredentials {
        AppleAdsCredentials(
            clientID: clientID,
            teamID: teamID,
            keyID: keyID,
            privateKey: privateKey,
            orgID: orgID
        )
    }

    private var enteredWebLoginCredentials: AppleAdsWebLoginCredentials {
        AppleAdsWebLoginCredentials(username: webLoginUsername, password: webLoginPassword)
    }

    private var enteredAppStoreConnectCredentials: AppStoreConnectCredentials {
        AppStoreConnectCredentials(
            issuerID: ascIssuerID,
            keyID: ascKeyID,
            privateKey: ascPrivateKey
        )
    }

    private var automaticRefreshEnabled: Binding<Bool> {
        Binding(
            get: { services.settingsStore.isAutomaticRefreshEnabled },
            set: { services.settingsStore.setAutomaticRefreshEnabled($0) }
        )
    }

    private var analyticsEnabled: Binding<Bool> {
        Binding(
            get: { services.settingsStore.isAnalyticsEnabled },
            set: { services.analyticsService.setAnalyticsEnabled($0) }
        )
    }

    private var showsManualAppleAdsAppIDFallback: Bool {
        switch connectionState {
        case .expiredSession, .noLinkedApps, .apiIssue:
            return true
        case .notConnected, .installingHelper, .openingBrowser, .detectingLinkedApp, .validatingSession, .connected, .dependencyIssue:
            return false
        }
    }

    private var mcpPrimaryActionTitle: String {
        switch services.mcpServerController.state {
        case .stopped, .failed:
            return "Start MCP Server"
        case .starting:
            return "Starting..."
        case .running:
            return "Stop MCP Server"
        case .stopping:
            return "Stopping..."
        }
    }

    private var mcpServerPortBinding: Binding<Int> {
        Binding {
            services.settingsStore.mcpServerPort
        } set: { port in
            services.settingsStore.saveMCPServerPort(port)
        }
    }

    private var mcpPortControlsDisabled: Bool {
        services.mcpServerController.state.isRunning || services.mcpServerController.state.isBusy
    }

    private func toggleMCPServer() {
        if services.mcpServerController.state.isRunning {
            services.mcpServerController.stop()
        } else {
            services.mcpServerController.start()
        }
    }

    private func loadCredentials() {
        let credentials = services.appleAdsCredentialStore.apiCredentials
        clientID = credentials.clientID
        teamID = credentials.teamID
        keyID = credentials.keyID
        privateKey = credentials.privateKey
        orgID = credentials.orgID
    }

    private func loadAppStoreConnectCredentials() {
        let credentials = services.appStoreConnectCredentialStore.credentials
        ascIssuerID = credentials.issuerID
        ascKeyID = credentials.keyID
        ascPrivateKey = credentials.privateKey
    }

    private func loadDailyRefreshTime() {
        dailyRefreshTime = services.settingsStore.refreshTimeDate()
    }

    private func loadWebLoginCredentials() {
        let credentials = services.appleAdsCredentialStore.webLoginCredentials
        webLoginUsername = credentials.username
        webLoginPassword = credentials.password
    }

    private func validateAppleAdsAccess() {
        guard services.appleAdsWebSessionStore.hasSession else {
            connectionState = .notConnected
            return
        }

        Task { @MainActor in
            do {
                try await detectAndValidateAppleAds()
            } catch {
                connectionState = AppleAdsConnectionState.classified(
                    error: error,
                    hasSession: services.appleAdsWebSessionStore.hasSession
                )
            }
        }
    }

    private func saveWebLoginCredentials() {
        do {
            try services.appleAdsCredentialStore.saveWebLoginCredentials(enteredWebLoginCredentials)
            loadWebLoginCredentials()
            savedLoginStatus = .success("Login saved for next time.")
            showsSavedLoginControls = true
        } catch {
            savedLoginStatus = .failure(OpenASOError.map(error).localizedDescription)
        }
    }

    private func clearWebLoginCredentials() {
        services.appleAdsCredentialStore.clearWebLoginCredentials()
        loadWebLoginCredentials()
        savedLoginStatus = .success("Saved login forgotten.")
    }

    private func loadDependencyStatus() {
        do {
            dependencyStatus = try services.appleAdsWebSessionManager.checkDependencyStatus()
        } catch {
            connectionState = .dependencyIssue(OpenASOError.map(error).localizedDescription)
        }
    }

    private func connectAppleAds() {
        Task { @MainActor in
            do {
                manualAppleAdsStatus = nil
                try await prepareAppleAdsHelperIfNeeded()
                connectionState = .openingBrowser
                _ = try await services.appleAdsWebSessionManager.refreshSession()
                showsSavedLoginControls = true
                try await detectAndValidateAppleAds()
            } catch {
                connectionState = AppleAdsConnectionState.classified(
                    error: error,
                    hasSession: services.appleAdsWebSessionStore.hasSession
                )
            }
        }
    }

    private func useManualAppleAdsAppID() {
        let trimmedAppID = manualAppleAdsAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appStoreID = Int64(trimmedAppID), appStoreID > 0 else {
            manualAppleAdsStatus = .failure("Enter a valid App Store ID.")
            return
        }

        Task { @MainActor in
            do {
                manualAppleAdsStatus = nil
                services.settingsStore.savePopularityContext(appStoreID: appStoreID, storefrontCode: nil)
                connectionState = .validatingSession
                _ = try await services.appleAdsWebSessionManager.validateSession(adamId: appStoreID)
                connectionState = .connected(updatedAt: services.appleAdsWebSessionStore.session?.updatedAt)
                services.refreshStaleKeywordPopularityAfterAppleAdsConnection()
                manualAppleAdsStatus = .success("Apple Ads is connected for App ID \(appStoreID).")
            } catch {
                services.settingsStore.clearPopularityContextAppStoreID()
                let message = OpenASOError.map(error).localizedDescription
                manualAppleAdsStatus = .failure(message)
                connectionState = AppleAdsConnectionState.classified(
                    error: error,
                    hasSession: services.appleAdsWebSessionStore.hasSession
                )
            }
        }
    }

    private func prepareAppleAdsHelperIfNeeded() async throws {
        let status = try services.appleAdsWebSessionManager.checkDependencyStatus()
        dependencyStatus = status
        guard status.state != .missingNode else {
            throw OpenASOError.providerUnavailable(status.message)
        }

        if !status.isReady {
            connectionState = .installingHelper
            dependencyStatus = try await services.appleAdsWebSessionManager.installDependencies()
        }
    }

    private func detectAndValidateAppleAds() async throws {
        connectionState = .detectingLinkedApp
        try await ensurePopularityContextApp()

        connectionState = .validatingSession
        _ = try await services.appleAdsWebSessionManager.validateSession()
        connectionState = .connected(updatedAt: services.appleAdsWebSessionStore.session?.updatedAt)
        services.refreshStaleKeywordPopularityAfterAppleAdsConnection()
    }

    private func ensurePopularityContextApp() async throws {
        guard services.settingsStore.popularityContextAppStoreID == nil
            || services.settingsStore.popularityContextStorefrontCode == nil
        else {
            return
        }

        let app = try await services.appleAdsWebSessionManager.resolveDefaultLinkedApp()
        services.settingsStore.savePopularityContext(
            appStoreID: app.adamId,
            storefrontCode: app.countryOrRegionCodes.first
        )
    }

    private func clearWebSession() {
        services.appleAdsWebSessionStore.clear()
        services.settingsStore.clearPopularityContextAppStoreID()
        manualAppleAdsAppID = ""
        manualAppleAdsStatus = nil
        connectionState = .notConnected
    }

    private func validateAppStoreConnect() {
        Task { @MainActor in
            do {
                ascConnectionState = .validating
                try services.appStoreConnectCredentialStore.save(enteredAppStoreConnectCredentials)
                loadAppStoreConnectCredentials()
                try await services.appStoreConnectReviewService.validateCredentials(services.appStoreConnectCredentialStore.credentials)
                ascConnectionState = .connected(updatedAt: .now)
                ascStatus = .success("App Store Connect is connected.")
            } catch {
                let message = OpenASOError.map(error).localizedDescription
                ascConnectionState = .apiIssue(message)
                ascStatus = .failure(message)
            }
        }
    }

    private func clearAppStoreConnectCredentials() {
        services.appStoreConnectCredentialStore.clear()
        loadAppStoreConnectCredentials()
        ascConnectionState = .notConnected
        ascStatus = .success("App Store Connect credentials cleared.")
    }

    private func inferredAppStoreConnectConnectionState() -> AppStoreConnectConnectionState {
        guard services.appStoreConnectCredentialStore.hasCompleteCredentials else {
            return .notConnected
        }

        return .connected(updatedAt: nil)
    }

    private func inferredConnectionState() -> AppleAdsConnectionState {
        if let dependencyStatus, dependencyStatus.state == .missingNode {
            return .dependencyIssue(dependencyStatus.message)
        }

        guard services.appleAdsWebSessionStore.hasSession else {
            return .notConnected
        }

        return .connected(updatedAt: services.appleAdsWebSessionStore.session?.updatedAt)
    }
}

private struct MCPServerStatusRow: View {
    let state: OpenASOMCPServerController.State

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    private var title: String {
        switch state {
        case .stopped:
            return "MCP server is stopped"
        case .starting:
            return "MCP server is starting"
        case .running:
            return "MCP server is running"
        case .stopping:
            return "MCP server is stopping"
        case .failed:
            return "MCP server failed to start"
        }
    }

    private var detail: String {
        switch state {
        case .stopped:
            return "Start it to accept local MCP HTTP connections."
        case .starting:
            return "Opening a local loopback server."
        case .running(let endpointURL):
            return endpointURL.absoluteString
        case .stopping:
            return "Closing the local server."
        case .failed(let message):
            return message
        }
    }

    private var systemImage: String {
        switch state {
        case .stopped:
            return "power"
        case .starting, .stopping:
            return "hourglass"
        case .running:
            return "point.3.connected.trianglepath.dotted"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch state {
        case .stopped:
            return .secondary
        case .starting, .stopping:
            return .orange
        case .running:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct AppStoreConnectAPIKeyHelpPopover: View {
    private static let appStoreConnectKeysURL = URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Create an App Store Connect API Key", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("OpenASO needs three values from a Team API key generated in App Store Connect. The key is only downloadable once, so keep the .p8 file in a safe place.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                stepRow(number: 1, text: "Sign in to App Store Connect with an Account Holder or Admin Apple ID.")
                stepRow(number: 2, text: "Go to Users and Access → Integrations → App Store Connect API → Team Keys.")
                stepRow(number: 3, text: "Click the + button, name the key, and pick a role (Admin or Developer is recommended).")
                stepRow(number: 4, text: "Press Generate, then download the .p8 file. You can only download it once.")
                stepRow(number: 5, text: "Copy the Issuer ID shown at the top of the Team Keys page.")
                stepRow(number: 6, text: "Copy the Key ID from the row of the key you just created.")
                stepRow(number: 7, text: "Paste the Issuer ID and Key ID below, then drop the .p8 file (or paste its contents) into the private key field.")
            }

            Divider()

            Link(destination: Self.appStoreConnectKeysURL) {
                Label("Open App Store Connect Keys", systemImage: "arrow.up.right.square")
            }

            Text("OpenASO stores the private key in the macOS Keychain and never sends it anywhere besides Apple's servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
