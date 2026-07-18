import Foundation
import Observation

struct AppleAdsWebSession: Codable, Equatable, Sendable {
    var cookieHeader: String
    var xsrfToken: String
    var updatedAt: Date
    var accountName: String?
    var linkedApps: [AppleAdsPromotedApp]?

    init(
        cookieHeader: String,
        xsrfToken: String,
        updatedAt: Date,
        accountName: String? = nil,
        linkedApps: [AppleAdsPromotedApp]? = nil
    ) {
        self.cookieHeader = cookieHeader
        self.xsrfToken = xsrfToken
        self.updatedAt = updatedAt
        self.accountName = accountName
        self.linkedApps = linkedApps
    }

    var isComplete: Bool {
        !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !xsrfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AppleAdsWebSessionExpiredError: LocalizedError, Equatable, Sendable {
    static let message = "Apple Ads web session expired. Refresh it in Settings."

    var errorDescription: String? {
        Self.message
    }
}

private func appleAdsWebJSONResponse(
    for request: URLRequest,
    using client: HTTPClient
) async throws -> (data: Data, response: HTTPURLResponse) {
    try Task.checkCancellation()
    let (data, response) = try await client.data(for: request)
    try Task.checkCancellation()
    guard let httpResponse = response as? HTTPURLResponse else {
        throw OpenASOError.unexpectedResponse
    }

    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw AppleAdsWebSessionExpiredError()
    }

    if let responseURL = httpResponse.url,
       isAppleAdsSignInURL(responseURL) {
        throw AppleAdsWebSessionExpiredError()
    }

    if (300 ..< 400).contains(httpResponse.statusCode),
       let location = httpResponse.value(forHTTPHeaderField: "Location"),
       let baseURL = httpResponse.url ?? request.url,
       let redirectURL = URL(string: location, relativeTo: baseURL)?.absoluteURL,
       isAppleAdsSignInURL(redirectURL) {
        throw AppleAdsWebSessionExpiredError()
    }

    if (200 ..< 300).contains(httpResponse.statusCode),
       isHTMLResponse(data: data, response: httpResponse) {
        throw AppleAdsWebSessionExpiredError()
    }

    return (data, httpResponse)
}

private func isAppleAdsSignInURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    if ["account.apple.com", "appleid.apple.com", "idmsa.apple.com"].contains(host) {
        return true
    }

    guard host == "app-ads.apple.com" else { return false }

    let location = [url.path, url.query].compactMap(\.self).joined(separator: "?").lowercased()
    return ["/auth/", "/authenticate", "/login", "/sign-in", "/signin"].contains {
        location.contains($0)
    }
}

private func isHTMLResponse(data: Data, response: HTTPURLResponse) -> Bool {
    if response.value(forHTTPHeaderField: "Content-Type")?
        .lowercased()
        .contains("text/html") == true {
        return true
    }

    let prefix = String(decoding: data.prefix(1_024), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        .lowercased()
    return prefix.hasPrefix("<!doctype html")
        || prefix.hasPrefix("<html")
        || prefix.hasPrefix("<head")
        || prefix.hasPrefix("<body")
}

private func validatedAppleAdsWebData(
    for request: URLRequest,
    using client: HTTPClient
) async throws -> Data {
    let result = try await appleAdsWebJSONResponse(for: request, using: client)
    switch result.response.statusCode {
    case 200 ..< 300:
        return result.data
    case 404:
        throw OpenASOError.appNotFound
    case 429:
        throw OpenASOError.rateLimited
    default:
        throw OpenASOError.providerUnavailable("HTTP \(result.response.statusCode)")
    }
}

private func shouldStopAppleAdsWebFallback(for error: Error) -> Bool {
    error is AppleAdsWebSessionExpiredError
        || error is CancellationError
        || (error as? URLError)?.code == .cancelled
}

struct AppleAdsWebLoginCredentials: Codable, Equatable, Sendable {
    var username: String
    var password: String

    var trimmed: AppleAdsWebLoginCredentials {
        AppleAdsWebLoginCredentials(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    var isComplete: Bool {
        let credentials = trimmed
        return !credentials.username.isEmpty && !credentials.password.isEmpty
    }
}

@MainActor
@Observable
final class AppleAdsWebSessionStore {
    private let keychainItemPresence: KeychainItemPresenceStore
    private let keychain: any KeychainService
    private let keychainService: String
    private let sessionAccount = "web-session"

    private(set) var session: AppleAdsWebSession?

    init(
        defaults: UserDefaults = .openASOShared,
        keychain: any KeychainService = SystemKeychainService(),
        namespace: AppNamespace = .current
    ) {
        self.keychainItemPresence = KeychainItemPresenceStore(defaults: defaults)
        self.keychain = keychain
        self.keychainService = namespace.keychainService("apple-ads-web")
        session = keychainItemPresence.contains(service: keychainService, account: sessionAccount)
            ? Self.readSession(service: keychainService, account: sessionAccount, keychain: keychain)
            : nil
    }

    var hasSession: Bool {
        session?.isComplete == true
    }

    func save(_ session: AppleAdsWebSession) throws {
        let data = try JSONEncoder().encode(session)
        do {
            try keychain.save(data, service: keychainService, account: sessionAccount)
            keychainItemPresence.markPresent(service: keychainService, account: sessionAccount)
            self.session = session
        } catch {
            throw OpenASOError.providerUnavailable("Could not save Apple Ads web session to Keychain.")
        }
    }

    func clear() {
        keychain.delete(service: keychainService, account: sessionAccount)
        keychainItemPresence.markAbsent(service: keychainService, account: sessionAccount)
        session = nil
    }

    private static func readSession(
        service: String,
        account: String,
        keychain: any KeychainService
    ) -> AppleAdsWebSession? {
        guard let data = keychain.data(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(AppleAdsWebSession.self, from: data)
    }
}

@MainActor
final class AppleAdsWebSessionManager {
    private let sessionStore: AppleAdsWebSessionStore
    private let settingsStore: AppSettingsStore
    private let credentialStore: AppleAdsCredentialStore
    private let httpClient: HTTPClient
    private let dependencyManager: AppleAdsWebSessionDependencyManager
    private let namespace: AppNamespace
    private var capturedLinkedApps: [AppleAdsPromotedApp] = []
    private var capturedAccountName: String?

    init(
        sessionStore: AppleAdsWebSessionStore,
        settingsStore: AppSettingsStore,
        credentialStore: AppleAdsCredentialStore,
        httpClient: HTTPClient,
        namespace: AppNamespace = .current
    ) {
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.httpClient = httpClient
        self.dependencyManager = AppleAdsWebSessionDependencyManager(namespace: namespace)
        self.namespace = namespace
    }

    func refreshSession() async throws -> AppleAdsWebSession {
        let dependencyStatus = try dependencyManager.checkStatus()
        guard dependencyStatus.isReady else {
            throw OpenASOError.providerUnavailable(dependencyStatus.message)
        }

        let helperURL = try helperScriptURL()
        let profileURL = try profileDirectoryURL()
        let loginCredentials = credentialStore.webLoginCredentials.trimmed
        let output = try await runNodeHelper(
            scriptURL: helperURL,
            profileURL: profileURL,
            dependencyStatus: dependencyStatus,
            loginCredentials: loginCredentials.isComplete ? loginCredentials : nil
        )
        guard output.status == "success" else {
            throw OpenASOError.providerUnavailable(output.message ?? "Apple Ads browser session was not captured.")
        }

        let session = AppleAdsWebSession(
            cookieHeader: output.cookieHeader,
            xsrfToken: output.xsrfToken,
            updatedAt: .now,
            accountName: output.accountName,
            linkedApps: output.linkedApps
        )
        try sessionStore.save(session)
        capturedLinkedApps = output.linkedApps ?? []
        capturedAccountName = output.accountName
        return session
    }

    func validateSession(adamId: Int64? = nil, keyword: String = "workout") async throws -> Int {
        guard let session = sessionStore.session, session.isComplete else {
            throw OpenASOError.providerUnavailable("Connect an Apple Ads web session first.")
        }

        guard let adamId = adamId ?? settingsStore.popularityContextAppStoreID else {
            throw OpenASOError.providerUnavailable("Reconnect Apple Ads in Settings so OpenASO can detect a linked app.")
        }

        let storefrontCode = settingsStore.popularityContextStorefrontCode ?? "US"
        guard let popularity = try await AppleAdsCMPopularityClient(httpClient: httpClient)
            .keywordPopularity(for: keyword, storefrontCode: storefrontCode, adamId: adamId, session: session)
        else {
            throw OpenASOError.providerUnavailable("Apple Ads web session worked, but the keyword returned no popularity.")
        }

        return popularity
    }

    func resolveDefaultLinkedApp() async throws -> AppleAdsPromotedApp {
        guard let session = sessionStore.session, session.isComplete else {
            throw OpenASOError.providerUnavailable("Connect an Apple Ads web session first.")
        }

        if let app = capturedLinkedApps.first ?? session.linkedApps?.first {
            return app
        }

        let reportingApps = try await fetchReportingCampaignApps(using: session)
        if let app = reportingApps.first {
            return app
        }

        let apps = try await fetchCampaignApps(using: session)
        if let app = apps.first {
            return app
        }

        if let accountName = capturedAccountName ?? session.accountName,
           let app = try await fetchSellerApps(named: accountName).first {
            return app
        }

        throw OpenASOError.providerUnavailable("Apple Ads needs at least one app with an Apple Ads campaign linked to this account to fetch popularity and difficulty data.")
    }

    func checkDependencyStatus() throws -> AppleAdsWebSessionDependencyStatus {
        try dependencyManager.checkStatus()
    }

    func installDependencies() async throws -> AppleAdsWebSessionDependencyStatus {
        try await dependencyManager.install()
        return try dependencyManager.checkStatus()
    }

    private func helperScriptURL() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("script/apple_ads_web_session.js"),
            Bundle.main.resourceURL?.appendingPathComponent("apple_ads_web_session.js")
        ].compactMap(\.self)

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw OpenASOError.providerUnavailable("Missing script/apple_ads_web_session.js.")
        }

        return url
    }

    private func profileDirectoryURL() throws -> URL {
        let baseURL = try namespace.applicationSupportDirectoryURL()
        let profileURL = baseURL
            .appendingPathComponent("AppleAdsBrowserProfile", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        return profileURL
    }

    private func fetchCampaignApps(using session: AppleAdsWebSession) async throws -> [AppleAdsPromotedApp] {
        let endpoints = [
            "https://app-ads.apple.com/cm/api/v5/campaigns",
            "https://app-ads.apple.com/cm/api/v4/campaigns",
            "https://app-ads.apple.com/cm/api/v2/campaigns"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }

            do {
                let data = try await data(forWebRequestTo: url, session: session)
                let apps = try Self.campaignApps(from: data)
                if !apps.isEmpty {
                    return apps
                }
            } catch {
                if shouldStopAppleAdsWebFallback(for: error) {
                    throw error
                }
                continue
            }
        }

        return []
    }

    private func fetchReportingCampaignApps(using session: AppleAdsWebSession) async throws -> [AppleAdsPromotedApp] {
        guard let url = URL(string: "https://app-ads.apple.com/reporting/graphql") else {
            throw OpenASOError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(session.xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN-CM")
        request.setValue("https://app-ads.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://app-ads.apple.com/cm/app", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONEncoder().encode(Self.reportingCampaignAppsRequest())

        do {
            let data = try await validatedAppleAdsWebData(for: request, using: httpClient)
            let response = try JSONDecoder().decode(ReportingCampaignAppsResponse.self, from: data)
            return Self.reportingCampaignApps(from: response)
        } catch {
            if shouldStopAppleAdsWebFallback(for: error) {
                throw error
            }
            return []
        }
    }

    private func data(forWebRequestTo url: URL, session: AppleAdsWebSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(session.xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN-CM")
        request.setValue("https://app-ads.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://app-ads.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        return try await validatedAppleAdsWebData(for: request, using: httpClient)
    }

    private func fetchSellerApps(named sellerName: String) async throws -> [AppleAdsPromotedApp] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: sellerName),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "limit", value: "25")
        ]

        guard let url = components.url else {
            throw OpenASOError.unexpectedResponse
        }

        let data = try await validatedData(for: URLRequest(url: url), using: httpClient)
        let response = try JSONDecoder().decode(ITunesSoftwareSearchResponse.self, from: data)
        let normalizedSellerName = Self.normalizedName(sellerName)
        var seenAppIDs: Set<Int64> = []
        return response.results.compactMap { result in
            guard Self.normalizedName(result.sellerName) == normalizedSellerName,
                  seenAppIDs.insert(result.trackId).inserted
            else {
                return nil
            }

            return AppleAdsPromotedApp(
                adamId: result.trackId,
                appName: result.trackName,
                developerName: result.sellerName,
                countryOrRegionCodes: [result.country ?? "US"]
            )
        }
    }

    private static func campaignApps(from data: Data) throws -> [AppleAdsPromotedApp] {
        let json = try JSONSerialization.jsonObject(with: data)
        var apps: [AppleAdsPromotedApp] = []
        var seenAppIDs: Set<Int64> = []

        func collect(from value: Any) {
            if let dictionary = value as? [String: Any] {
                if let adamId = int64Value(dictionary["adamId"]),
                   deletedValue(dictionary["deleted"]) != true,
                   seenAppIDs.insert(adamId).inserted {
                    apps.append(
                        AppleAdsPromotedApp(
                            adamId: adamId,
                            appName: stringValue(dictionary["appName"])
                                ?? stringValue(dictionary["app"] as? [String: Any], key: "name")
                                ?? "App ID \(adamId)",
                            developerName: "",
                            countryOrRegionCodes: stringArrayValue(dictionary["countriesOrRegions"])
                        )
                    )
                }

                for child in dictionary.values {
                    collect(from: child)
                }
                return
            }

            if let array = value as? [Any] {
                for child in array {
                    collect(from: child)
                }
            }
        }

        collect(from: json)
        return apps
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private static func deletedValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            return Bool(value)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else {
            return nil
        }

        return string
    }

    private static func stringValue(_ dictionary: [String: Any]?, key: String) -> String? {
        stringValue(dictionary?[key])
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        (value as? [Any])?
            .compactMap { stringValue($0) } ?? []
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func reportingCampaignAppsRequest(now: Date = .now) -> ReportingGraphQLRequest {
        let calendar = Calendar(identifier: .gregorian)
        let endDate = now
        let startDate = calendar.date(byAdding: .day, value: -7, to: endDate) ?? endDate
        return ReportingGraphQLRequest(
            operationName: "getReportsByCampaign",
            variables: ReportingGraphQLVariables(
                reportOptions: ReportingReportOptions(
                    filter: ReportingReportFilter(
                        startTime: reportDateString(from: startDate),
                        endTime: reportDateString(from: endDate),
                        timeZone: "UTC",
                        returnGrandTotals: true,
                        returnRowTotals: true,
                        selector: ReportingSelector(
                            pagination: ReportingPagination(offset: 0, limit: 50),
                            orderBy: [
                                ReportingOrder(field: "localSpend", sortOrder: "DESCENDING")
                            ]
                        ),
                        returnRecordsWithNoMetrics: true
                    )
                )
            ),
            query: Self.reportingCampaignAppsQuery
        )
    }

    private static func reportDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static var reportingCampaignAppsQuery: String {
        """
        query getReportsByCampaign($reportOptions: CampaignsReportOptions!) {
          reportingV5 {
            getReportsByCampaign(reportOptions: $reportOptions) {
              row {
                metadata {
                  ... on ReportingCampaign {
                    countriesOrRegions
                    app {
                      appName
                      adamId
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
        }
        """
    }

    private static func reportingCampaignApps(from response: ReportingCampaignAppsResponse) -> [AppleAdsPromotedApp] {
        var apps: [AppleAdsPromotedApp] = []
        var seenAppIDs: Set<Int64> = []

        for row in response.data?.reportingV5?.getReportsByCampaign?.row ?? [] {
            guard let metadata = row.metadata,
                  let app = metadata.app,
                  let adamId = Int64(app.adamId),
                  seenAppIDs.insert(adamId).inserted
            else {
                continue
            }

            apps.append(
                AppleAdsPromotedApp(
                    adamId: adamId,
                    appName: app.appName ?? "App ID \(adamId)",
                    developerName: "",
                    countryOrRegionCodes: metadata.countriesOrRegions ?? []
                )
            )
        }

        return apps
    }

    private func runNodeHelper(
        scriptURL: URL,
        profileURL: URL,
        dependencyStatus: AppleAdsWebSessionDependencyStatus,
        loginCredentials: AppleAdsWebLoginCredentials?
    ) async throws -> HelperOutput {
        let inputData = try JSONEncoder().encode(
            HelperInput(loginCredentials: loginCredentials)
        )

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperOutput, any Error>) in
            let process = Process()
            process.executableURL = dependencyStatus.nodeURL
            process.arguments = [
                scriptURL.path,
                "--profile-dir",
                profileURL.path,
                "--timeout-ms",
                "300000"
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin
            process.environment = dependencyStatus.processEnvironment

            process.terminationHandler = { process in
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus != 0 {
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: OpenASOError.providerUnavailable(
                            message?.isEmpty == false ? message! : "Apple Ads browser helper failed."
                        )
                    )
                    return
                }

                do {
                    let output = try JSONDecoder().decode(HelperOutput.self, from: outputData)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: OpenASOError.decodingFailed)
                }
            }

            do {
                try process.run()
                stdin.fileHandleForWriting.write(inputData)
                stdin.fileHandleForWriting.closeFile()
            } catch {
                continuation.resume(
                    throwing: OpenASOError.providerUnavailable(
                        "Could not launch Apple Ads browser helper."
                    )
                )
            }
        }
    }
}

struct AppleAdsWebSessionDependencyStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case missingNode
        case missingPlaywright
        case missingBrowser
    }

    let state: State
    let nodeURL: URL?
    let helperDirectoryURL: URL
    let browserDirectoryURL: URL

    var isReady: Bool {
        state == .ready && nodeURL != nil
    }

    var message: String {
        switch state {
        case .ready:
            return "Apple Ads browser helper is installed."
        case .missingNode:
            return "Node.js is required to install and run the Apple Ads browser helper."
        case .missingPlaywright:
            return "Playwright is not installed for OpenASO. Click Connect Apple Ads."
        case .missingBrowser:
            return "Playwright Chromium is not installed for OpenASO. Click Connect Apple Ads."
        }
    }

    var processEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["NODE_PATH"] = helperDirectoryURL
            .appendingPathComponent("node_modules", isDirectory: true)
            .path
        environment["PLAYWRIGHT_BROWSERS_PATH"] = browserDirectoryURL.path
        return environment
    }
}

final class AppleAdsWebSessionDependencyManager: Sendable {
    private let namespace: AppNamespace

    init(namespace: AppNamespace = .current) {
        self.namespace = namespace
    }

    func checkStatus() throws -> AppleAdsWebSessionDependencyStatus {
        let helperDirectoryURL = try helperDirectoryURL()
        let browserDirectoryURL = Self.browserDirectoryURL(helperDirectoryURL: helperDirectoryURL)
        let nodeURL = Self.nodeRuntime()?.nodeURL
        guard nodeURL != nil else {
            return AppleAdsWebSessionDependencyStatus(
                state: .missingNode,
                nodeURL: nil,
                helperDirectoryURL: helperDirectoryURL,
                browserDirectoryURL: browserDirectoryURL
            )
        }

        let playwrightURL = helperDirectoryURL
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("playwright", isDirectory: true)
        guard FileManager.default.fileExists(atPath: playwrightURL.path) else {
            return AppleAdsWebSessionDependencyStatus(
                state: .missingPlaywright,
                nodeURL: nodeURL,
                helperDirectoryURL: helperDirectoryURL,
                browserDirectoryURL: browserDirectoryURL
            )
        }

        guard hasChromiumBrowser(in: browserDirectoryURL) else {
            return AppleAdsWebSessionDependencyStatus(
                state: .missingBrowser,
                nodeURL: nodeURL,
                helperDirectoryURL: helperDirectoryURL,
                browserDirectoryURL: browserDirectoryURL
            )
        }

        return AppleAdsWebSessionDependencyStatus(
            state: .ready,
            nodeURL: nodeURL,
            helperDirectoryURL: helperDirectoryURL,
            browserDirectoryURL: browserDirectoryURL
        )
    }

    func install() async throws {
        let helperDirectoryURL = try helperDirectoryURL()
        let browserDirectoryURL = Self.browserDirectoryURL(helperDirectoryURL: helperDirectoryURL)
        guard let nodeRuntime = Self.nodeRuntime() else {
            throw OpenASOError.providerUnavailable("Node.js is required to install and run the Apple Ads browser helper.")
        }
        guard let npmCommand = Self.npmCommand(for: nodeRuntime) else {
            throw OpenASOError.providerUnavailable("npm is required to install the Apple Ads browser helper. Install Node.js with npm, then try again.")
        }

        try FileManager.default.createDirectory(at: helperDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: browserDirectoryURL, withIntermediateDirectories: true)
        try writePackageJSON(in: helperDirectoryURL)
        try await run(
            executableURL: npmCommand.executableURL,
            arguments: npmCommand.arguments + ["install", "--omit=dev"],
            workingDirectoryURL: helperDirectoryURL,
            environment: [:],
            additionalPathDirectories: nodeRuntime.pathDirectories
        )
        try await run(
            executableURL: nodeRuntime.nodeURL,
            arguments: [
                helperDirectoryURL
                    .appendingPathComponent("node_modules/playwright/cli.js")
                    .path,
                "install",
                "chromium"
            ],
            workingDirectoryURL: helperDirectoryURL,
            environment: [
                "PLAYWRIGHT_BROWSERS_PATH": browserDirectoryURL.path
            ],
            additionalPathDirectories: nodeRuntime.pathDirectories
        )
    }

    private func writePackageJSON(in helperDirectoryURL: URL) throws {
        let packageURL = helperDirectoryURL.appendingPathComponent("package.json")
        let package = """
        {
          "private": true,
          "dependencies": {
            "playwright": "^1.56.0"
          }
        }
        """
        try package.write(to: packageURL, atomically: true, encoding: .utf8)
    }

    private func hasChromiumBrowser(in browserDirectoryURL: URL) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: browserDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        return children.contains { $0.lastPathComponent.hasPrefix("chromium") }
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String],
        additionalPathDirectories: [URL] = []
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectoryURL
            process.environment = Self.processEnvironment(
                merging: environment,
                additionalPathDirectories: additionalPathDirectories
            )

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                    return
                }

                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let message = [
                    String(data: errorData, encoding: .utf8),
                    String(data: outputData, encoding: .utf8)
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                continuation.resume(
                    throwing: OpenASOError.providerUnavailable(
                        message.isEmpty ? "Apple Ads browser helper install failed." : message
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: OpenASOError.providerUnavailable(
                        "Apple Ads browser helper install failed: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func helperDirectoryURL() throws -> URL {
        let baseURL = try namespace.applicationSupportDirectoryURL()
        return baseURL
            .appendingPathComponent("WebSessionHelper", isDirectory: true)
    }

    private static func browserDirectoryURL(helperDirectoryURL: URL) -> URL {
        helperDirectoryURL.appendingPathComponent("playwright-browsers", isDirectory: true)
    }

    private static func nodeRuntime() -> NodeRuntime? {
        bundledNodeRuntime() ?? systemNodeRuntime()
    }

    private static func bundledNodeRuntime() -> NodeRuntime? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let runtimeURL = resourceURL
            .appendingPathComponent("NodeRuntime", isDirectory: true)
            .appendingPathComponent(nodeRuntimePlatformDirectoryName, isDirectory: true)
        let nodeURL = runtimeURL.appendingPathComponent("bin/node")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else {
            return nil
        }

        return NodeRuntime(
            nodeURL: nodeURL,
            npmCLIURL: runtimeURL.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js"),
            pathDirectories: [runtimeURL.appendingPathComponent("bin", isDirectory: true)]
        )
    }

    private static func systemNodeRuntime() -> NodeRuntime? {
        guard let nodeURL = systemNodeURL() else {
            return nil
        }

        return NodeRuntime(
            nodeURL: nodeURL,
            npmCLIURL: nil,
            pathDirectories: [nodeURL.deletingLastPathComponent()]
        )
    }

    private static func systemNodeURL() -> URL? {
        [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private static func npmCommand(for nodeRuntime: NodeRuntime) -> ProcessCommand? {
        if let npmCLIURL = nodeRuntime.npmCLIURL,
           FileManager.default.fileExists(atPath: npmCLIURL.path) {
            return ProcessCommand(executableURL: nodeRuntime.nodeURL, arguments: [npmCLIURL.path])
        }

        guard let npmURL = systemNPMURL() else {
            return nil
        }

        return ProcessCommand(executableURL: npmURL, arguments: [])
    }

    private static func systemNPMURL() -> URL? {
        [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm"
        ]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private static var nodeRuntimePlatformDirectoryName: String {
        #if arch(arm64)
        return "darwin-arm64"
        #elseif arch(x86_64)
        return "darwin-x64"
        #else
        return ""
        #endif
    }

    private static func processEnvironment(
        merging environment: [String: String],
        additionalPathDirectories: [URL]
    ) -> [String: String] {
        var processEnvironment = ProcessInfo.processInfo.environment
        let path = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        processEnvironment["PATH"] = (
            additionalPathDirectories.map(\.path) + [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                path
            ]
        ).joined(separator: ":")
        return processEnvironment.merging(environment) { _, new in new }
    }
}

private struct NodeRuntime {
    let nodeURL: URL
    let npmCLIURL: URL?
    let pathDirectories: [URL]
}

private struct ProcessCommand {
    let executableURL: URL
    let arguments: [String]
}

private struct HelperInput: Encodable {
    let loginCredentials: AppleAdsWebLoginCredentials?
}

private struct HelperOutput: Decodable {
    let status: String
    let cookieHeader: String
    let xsrfToken: String
    let message: String?
    let linkedApps: [AppleAdsPromotedApp]?
    let accountName: String?
}

private struct ITunesSoftwareSearchResponse: Decodable {
    let results: [ITunesSoftwareSearchResult]
}

private struct ITunesSoftwareSearchResult: Decodable {
    let trackId: Int64
    let trackName: String
    let sellerName: String
    let country: String?
}

private struct ReportingGraphQLRequest: Encodable {
    let operationName: String
    let variables: ReportingGraphQLVariables
    let query: String
}

private struct ReportingGraphQLVariables: Encodable {
    let reportOptions: ReportingReportOptions
}

private struct ReportingReportOptions: Encodable {
    let filter: ReportingReportFilter
}

private struct ReportingReportFilter: Encodable {
    let startTime: String
    let endTime: String
    let timeZone: String
    let returnGrandTotals: Bool
    let returnRowTotals: Bool
    let selector: ReportingSelector
    let returnRecordsWithNoMetrics: Bool
}

private struct ReportingSelector: Encodable {
    let pagination: ReportingPagination
    let orderBy: [ReportingOrder]
}

private struct ReportingPagination: Encodable {
    let offset: Int
    let limit: Int
}

private struct ReportingOrder: Encodable {
    let field: String
    let sortOrder: String
}

private struct ReportingCampaignAppsResponse: Decodable {
    let data: ReportingCampaignAppsData?
}

private struct ReportingCampaignAppsData: Decodable {
    let reportingV5: ReportingV5?
}

private struct ReportingV5: Decodable {
    let getReportsByCampaign: ReportingCampaignRows?
}

private struct ReportingCampaignRows: Decodable {
    let row: [ReportingCampaignRow]?
}

private struct ReportingCampaignRow: Decodable {
    let metadata: ReportingCampaignMetadata?
}

private struct ReportingCampaignMetadata: Decodable {
    let countriesOrRegions: [String]?
    let app: ReportingCampaignApp?
}

private struct ReportingCampaignApp: Decodable {
    let appName: String?
    let adamId: String
}

struct AppleAdsCMPopularityClient {
    static let maxTermsPerRequest = 100

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func keywordPopularity(
        for keyword: String,
        storefrontCode: String,
        adamId: Int64,
        session: AppleAdsWebSession
    ) async throws -> Int? {
        try await keywordPopularities(
            for: [keyword],
            storefrontCode: storefrontCode,
            adamId: adamId,
            session: session
        )[Self.normalizedKeywordKey(keyword)]
    }

    func keywordPopularities(
        for keywords: [String],
        storefrontCode: String,
        adamId: Int64,
        session: AppleAdsWebSession
    ) async throws -> [String: Int] {
        let terms = Self.uniqueTerms(from: keywords)
        guard !terms.isEmpty else { return [:] }

        var popularities: [String: Int] = [:]
        for batch in terms.chunked(into: Self.maxTermsPerRequest) {
            let response = try await keywordPopularitiesBatch(
                for: batch,
                storefrontCode: storefrontCode,
                adamId: adamId,
                session: session
            )
            for keyword in response.data {
                popularities[Self.normalizedKeywordKey(keyword.name)] = keyword.popularity
            }
        }

        return popularities
    }

    private func keywordPopularitiesBatch(
        for keywords: [String],
        storefrontCode: String,
        adamId: Int64,
        session: AppleAdsWebSession
    ) async throws -> KeywordPopularityCMResponse {
        var components = URLComponents(string: "https://app-ads.apple.com/cm/api/v2/keywords/popularities")!
        components.queryItems = [
            URLQueryItem(name: "adamId", value: String(adamId))
        ]

        guard let url = components.url else {
            throw OpenASOError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(session.xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN-CM")
        request.setValue("https://app-ads.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://app-ads.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONEncoder().encode(
            KeywordPopularityCMRequest(
                storefronts: [storefrontCode.uppercased()],
                terms: keywords
            )
        )

        let data = try await popularityData(
            for: request,
            storefrontCode: storefrontCode,
            using: httpClient
        )
        let response = try JSONDecoder().decode(KeywordPopularityCMResponse.self, from: data)
        if let message = response.error?.errors.first?.message {
            throw OpenASOError.providerUnavailable(message)
        }

        if let status = response.status,
           status.localizedCaseInsensitiveCompare("success") != .orderedSame {
            throw OpenASOError.providerUnavailable("Apple Ads returned status \(status).")
        }

        return response
    }

    private func popularityData(
        for request: URLRequest,
        storefrontCode: String,
        using client: HTTPClient
    ) async throws -> Data {
        let result = try await appleAdsWebJSONResponse(for: request, using: client)

        switch result.response.statusCode {
        case 200 ..< 300:
            return result.data
        case 400:
            throw OpenASOError.providerUnavailable(
                "Apple Ads does not support keyword popularity in \(storefrontDisplayName(for: storefrontCode))."
            )
        case 404:
            throw OpenASOError.appNotFound
        case 429:
            throw OpenASOError.rateLimited
        default:
            throw OpenASOError.providerUnavailable("HTTP \(result.response.statusCode)")
        }
    }

    private func storefrontDisplayName(for storefrontCode: String) -> String {
        let normalizedCode = storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return Locale.current.localizedString(forRegionCode: normalizedCode) ?? normalizedCode
    }

    private static func uniqueTerms(from keywords: [String]) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for keyword in keywords {
            let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }

            let key = normalizedKeywordKey(term)
            guard seen.insert(key).inserted else { continue }
            terms.append(term)
        }
        return terms
    }

    static func normalizedKeywordKey(_ keyword: String) -> String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct KeywordPopularityCMRequest: Encodable {
    let storefronts: [String]
    let terms: [String]
}

private struct KeywordPopularityCMResponse: Decodable {
    let status: String?
    let data: [KeywordPayload]
    let error: ErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case status
        case data
        case error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        data = try container.decodeIfPresent([KeywordPayload].self, forKey: .data) ?? []
        error = try container.decodeIfPresent(ErrorPayload.self, forKey: .error)
    }

    struct KeywordPayload: Decodable {
        let name: String
        let popularity: Int
    }

    struct ErrorPayload: Decodable {
        let errors: [ErrorItem]
    }

    struct ErrorItem: Decodable {
        let message: String
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
