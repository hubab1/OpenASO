import Foundation
import Observation
import OSLog

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
    private struct ReadState {
        let session: AppleAdsWebSession?
        let shouldRetryTransientFailure: Bool
    }

    private static let logger = Logger(subsystem: OpenASOLog.subsystem, category: "keychain")

    private let defaults: UserDefaults
    private let keychainItemPresence: KeychainItemPresenceStore
    private let keychain: any KeychainService
    private let keychainService: String
    private let reconnectRequiredDefaultsKey: String
    private static let sessionAccount = "web-session"

    private(set) var session: AppleAdsWebSession?
    private(set) var requiresReconnect: Bool
    private var shouldRetryTransientRead: Bool

    init(
        defaults: UserDefaults = .openASOShared,
        keychain: any KeychainService = SystemKeychainService(),
        namespace: AppNamespace = .current
    ) {
        let keychainItemPresence = KeychainItemPresenceStore(defaults: defaults)
        let keychainService = namespace.keychainService("apple-ads-web")
        let reconnectRequiredDefaultsKey = "appleAds.webSession.requiresReconnect.\(namespace.bundleIdentifier)"
        self.defaults = defaults
        self.keychainItemPresence = keychainItemPresence
        self.keychain = keychain
        self.keychainService = keychainService
        self.reconnectRequiredDefaultsKey = reconnectRequiredDefaultsKey
        if keychainItemPresence.contains(service: keychainService, account: Self.sessionAccount) {
            let state = Self.readState(
                service: keychainService,
                account: Self.sessionAccount,
                keychain: keychain
            )
            session = state.session
            shouldRetryTransientRead = state.shouldRetryTransientFailure
        } else {
            session = nil
            shouldRetryTransientRead = false
        }
        requiresReconnect = defaults.bool(forKey: reconnectRequiredDefaultsKey)
    }

    var hasSession: Bool {
        session?.isComplete == true
    }

    var hasPendingTransientReadRecovery: Bool {
        session == nil && shouldRetryTransientRead
    }

    /// Explicit action boundary for recovering a startup read that failed because the
    /// login Keychain was temporarily unavailable. Passive UI property reads stay pure.
    @discardableResult
    func recoverSessionIfNeeded() -> AppleAdsWebSession? {
        guard session == nil, shouldRetryTransientRead else { return session }
        let state = Self.readState(
            service: keychainService,
            account: Self.sessionAccount,
            keychain: keychain
        )
        if let recoveredSession = state.session {
            session = recoveredSession
        }
        shouldRetryTransientRead = state.shouldRetryTransientFailure
        return session
    }

    func save(_ session: AppleAdsWebSession) throws {
        let data = try JSONEncoder().encode(session)
        do {
            try keychain.save(data, service: keychainService, account: Self.sessionAccount)
            keychainItemPresence.markPresent(service: keychainService, account: Self.sessionAccount)
            self.session = session
            setReconnectRequired(false)
            shouldRetryTransientRead = false
        } catch {
            throw OpenASOError.providerUnavailable("Could not save Apple Ads web session to Keychain.")
        }
    }

    func requiresReconnect(for session: AppleAdsWebSession) -> Bool {
        requiresReconnect && self.session == session
    }

    func markReconnectRequired(for session: AppleAdsWebSession) {
        guard self.session == session else { return }
        setReconnectRequired(true)
    }

    func clearReconnectRequirement(for session: AppleAdsWebSession) {
        guard self.session == session else { return }
        setReconnectRequired(false)
    }

    func clear() {
        keychain.delete(service: keychainService, account: Self.sessionAccount)
        keychainItemPresence.markAbsent(service: keychainService, account: Self.sessionAccount)
        session = nil
        setReconnectRequired(false)
        shouldRetryTransientRead = false
    }

    private func setReconnectRequired(_ isRequired: Bool) {
        if isRequired {
            defaults.set(true, forKey: reconnectRequiredDefaultsKey)
        } else {
            defaults.removeObject(forKey: reconnectRequiredDefaultsKey)
        }
        requiresReconnect = isRequired
    }

    private static func readState(
        service: String,
        account: String,
        keychain: any KeychainService
    ) -> ReadState {
        switch keychain.readData(service: service, account: account) {
        case .success(let data):
            guard let session = try? JSONDecoder().decode(AppleAdsWebSession.self, from: data) else {
                logger.error("Stored Apple Ads web session could not be decoded; preserving the Keychain item")
                return ReadState(session: nil, shouldRetryTransientFailure: false)
            }
            return ReadState(session: session, shouldRetryTransientFailure: false)
        case .notFound:
            logger.warning("Apple Ads web-session presence marker exists, but its Keychain item was not found")
            return ReadState(session: nil, shouldRetryTransientFailure: false)
        case .failure(let failure):
            return ReadState(session: nil, shouldRetryTransientFailure: failure.isTransient)
        }
    }
}

@MainActor
final class AppleAdsWebSessionManager {
    private let sessionStore: AppleAdsWebSessionStore
    private let settingsStore: AppSettingsStore
    private let credentialStore: AppleAdsCredentialStore
    private let httpClient: HTTPClient
    private let loginController: AppleAdsWebLoginController
    private let namespace: AppNamespace
    private var capturedLinkedApps: [AppleAdsPromotedApp] = []
    private var capturedAccountName: String?

    init(
        sessionStore: AppleAdsWebSessionStore,
        settingsStore: AppSettingsStore,
        credentialStore: AppleAdsCredentialStore,
        httpClient: HTTPClient,
        namespace: AppNamespace = .current,
        loginController: AppleAdsWebLoginController = AppleAdsWebLoginController()
    ) {
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.httpClient = httpClient
        self.loginController = loginController
        self.namespace = namespace
    }

    /// Signs in through the in-app WebKit window and stores the captured session.
    func refreshSession() async throws -> AppleAdsWebSession {
        let capture = try await loginController.captureSession()
        let session = AppleAdsWebSession(
            cookieHeader: capture.cookieHeader,
            xsrfToken: capture.xsrfToken,
            updatedAt: .now,
            accountName: capture.accountName,
            linkedApps: nil
        )
        try sessionStore.save(session)
        capturedLinkedApps = []
        capturedAccountName = capture.accountName
        return session
    }

    /// Removes what the retired Playwright helper left behind: the bundled Chromium, its browser
    /// profile, and the Apple ID password that only ever existed to drive that automated browser.
    func purgeLegacyBrowserHelperArtifacts() {
        credentialStore.clearWebLoginCredentials()

        guard let baseURL = try? namespace.applicationSupportDirectoryURL() else { return }

        for directoryName in ["AppleAdsBrowserProfile", "WebSessionHelper"] {
            let directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { continue }
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    /// Stores a session the user signed in for in their own browser and pasted here.
    func connectUsingPastedCookies(_ pastedText: String) throws -> AppleAdsWebSession {
        let session = try AppleAdsPastedSession.session(from: pastedText)
        try sessionStore.save(session)
        capturedLinkedApps = []
        capturedAccountName = nil
        return session
    }

    func validateSession(adamId: Int64? = nil, keyword: String = "workout") async throws -> Int {
        guard let session = sessionStore.recoverSessionIfNeeded(), session.isComplete else {
            throw OpenASOError.providerUnavailable("Connect an Apple Ads web session first.")
        }

        guard let adamId = adamId ?? settingsStore.popularityContextAppStoreID else {
            throw OpenASOError.providerUnavailable("Reconnect Apple Ads in Settings so OpenASO can detect a linked app.")
        }

        let storefrontCode = settingsStore.popularityContextStorefrontCode ?? "US"
        do {
            guard let popularity = try await AppleAdsCMPopularityClient(httpClient: httpClient)
                .keywordPopularity(for: keyword, storefrontCode: storefrontCode, adamId: adamId, session: session)
            else {
                throw OpenASOError.providerUnavailable("Apple Ads web session worked, but the keyword returned no popularity.")
            }

            sessionStore.clearReconnectRequirement(for: session)
            return popularity
        } catch let error as AppleAdsWebSessionExpiredError {
            sessionStore.markReconnectRequired(for: session)
            throw error
        } catch {
            throw error
        }
    }

    func resolveDefaultLinkedApp() async throws -> AppleAdsPromotedApp {
        guard let session = sessionStore.recoverSessionIfNeeded(), session.isComplete else {
            throw OpenASOError.providerUnavailable("Connect an Apple Ads web session first.")
        }

        do {
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
        } catch let error as AppleAdsWebSessionExpiredError {
            sessionStore.markReconnectRequired(for: session)
            throw error
        }
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
