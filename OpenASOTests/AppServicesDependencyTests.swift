import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct AppServicesDependencyTests {
    @Test
    func modelContainerFactoryUsesV1MigrationPlan() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)

        #expect(OpenASOSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(OpenASOMigrationPlan.schemas.count == 1)
        #expect(OpenASOMigrationPlan.schemas.first?.versionIdentifier == OpenASOSchemaV1.versionIdentifier)
        #expect(OpenASOSchemaV1.models.count == 17)
        #expect(container.migrationPlan != nil)
    }

    @Test
    func mockedServicesUseInMemoryAppleAdsStores() throws {
        let services = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                throw OpenASOError.providerUnavailable("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            }
        )

        let credentials = AppleAdsCredentials(
            clientID: "client",
            teamID: "team",
            keyID: "key",
            privateKey: "private",
            orgID: "org"
        )
        try services.appleAdsCredentialStore.saveAPICredentials(credentials)
        #expect(services.appleAdsCredentialStore.apiCredentials == credentials)

        let ascCredentials = AppStoreConnectCredentials(
            issuerID: "issuer",
            keyID: "asc-key",
            privateKey: "private"
        )
        try services.appStoreConnectCredentialStore.save(ascCredentials)
        #expect(services.appStoreConnectCredentialStore.credentials == ascCredentials)

        let loginCredentials = AppleAdsWebLoginCredentials(username: "person@example.com", password: "password")
        try services.appleAdsCredentialStore.saveWebLoginCredentials(loginCredentials)
        #expect(services.appleAdsCredentialStore.webLoginCredentials == loginCredentials)

        let session = AppleAdsWebSession(cookieHeader: "cookie=value", xsrfToken: "token", updatedAt: .now)
        try services.appleAdsWebSessionStore.save(session)
        #expect(services.appleAdsWebSessionStore.session == session)

        services.appleAdsCredentialStore.clearAPICredentials()
        services.appStoreConnectCredentialStore.clear()
        services.appleAdsCredentialStore.clearWebLoginCredentials()
        services.appleAdsWebSessionStore.clear()
        #expect(!services.appleAdsCredentialStore.hasCompleteAPICredentials)
        #expect(!services.appStoreConnectCredentialStore.hasCompleteCredentials)
        #expect(!services.appleAdsCredentialStore.hasWebLoginCredentials)
        #expect(!services.appleAdsWebSessionStore.hasSession)
    }

    @Test
    func freshServicesDoNotReadKeychainWithoutPresenceFlags() {
        let defaults = Self.makeDefaults()
        let keychain = RecordingKeychainService()

        _ = AppServices(
            httpClient: MockHTTPClient { request in
                throw OpenASOError.providerUnavailable("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            },
            defaults: defaults,
            keychain: keychain,
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false
        )

        #expect(keychain.dataRequests.isEmpty)
    }

    @Test
    func appServicesWiresGateOutsideObservationAndRecordsPhysicalRetry() async throws {
        let defaults = Self.makeDefaults()
        let observationClock = RefreshObservationClock(nowNanoseconds: { 1_000 })
        let recorder = RefreshMetricsRecorder(clock: observationClock)
        var requestCount = 0
        let transport = MockHTTPClient { request in
            requestCount += 1
            if requestCount == 1 {
                return (
                    Data(),
                    makeHTTPURLResponse(url: try #require(request.url), statusCode: 503)
                )
            }
            return (
                Data(#"{"results":[{"trackId":123,"trackName":"Example"}]}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }
        let policy = ProviderRequestPolicy(
            minimumIntervalNanoseconds: 0,
            maximumAttempts: 2,
            baseBackoffNanoseconds: 0,
            maximumBackoffNanoseconds: 0,
            maximumElapsedNanoseconds: 1_000_000_000,
            jitterFraction: 0
        )
        let services = AppServices(
            httpClient: transport,
            defaults: defaults,
            keychain: InMemoryKeychainService(),
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false,
            refreshObservationClock: observationClock,
            refreshMetricsRecorder: recorder,
            providerRequestGateMode: .enabled(ProviderRequestPolicies(default: policy))
        )
        let runID = await recorder.begin(
            trigger: .manual,
            workspace: .keywords,
            requestedTrackCount: 0,
            requestedStorefrontCount: 1
        )

        let resolved = try await RefreshObservationScope.$runID.withValue(runID) {
            try await services.appResolver.resolve(appStoreID: 123, storefrontCode: "US")
        }
        let summary = try #require(await recorder.finish(runID: runID))
        let provider = try #require(summary.providers[.iTunesStore])

        #expect(resolved.appStoreID == 123)
        #expect(requestCount == 2)
        #expect(provider.requestCount == 2)
        #expect(provider.retryCount == 1)
        #expect(provider.resultCounts[.serverFailure] == 1)
        #expect(provider.resultCounts[.success] == 1)
    }

    @Test
    func appServicesUsesWebRankingFirstAndFallsBackWithObservedContext() async throws {
        let defaults = Self.makeDefaults()
        let observationClock = RefreshObservationClock(nowNanoseconds: { 1_000 })
        let recorder = RefreshMetricsRecorder(clock: observationClock)
        var requestedURLs: [String] = []
        let transport = MockHTTPClient { request in
            let url = try #require(request.url)
            requestedURLs.append(url.absoluteString)

            switch url.host() {
            case "apps.apple.com":
                #expect(url.absoluteString == "https://apps.apple.com/us/iphone/search?term=notes")
                return (
                    Data(),
                    makeHTTPURLResponse(url: url, statusCode: 503)
                )
            case "itunes.apple.com":
                #expect(url.absoluteString == "https://itunes.apple.com/search?term=notes&entity=software&country=us&limit=10")
                return (
                    Data(#"{"results":[{"trackId":321,"bundleId":"com.example.fallback","trackName":"Fallback App","sellerName":"Example"}]}"#.utf8),
                    makeHTTPURLResponse(url: url, statusCode: 200)
                )
            default:
                throw OpenASOError.providerUnavailable("Unexpected ranking URL.")
            }
        }
        let services = AppServices(
            httpClient: transport,
            defaults: defaults,
            keychain: InMemoryKeychainService(),
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false,
            refreshObservationClock: observationClock,
            refreshMetricsRecorder: recorder,
            providerRequestGateMode: .disabled
        )
        let runID = await recorder.begin(
            trigger: .manual,
            workspace: .keywords,
            requestedTrackCount: 1,
            requestedStorefrontCount: 1
        )

        let page = try await RefreshObservationScope.$runID.withValue(runID) {
            try await services.rankingProvider.search(
                keyword: "notes",
                storefrontCode: "US",
                platform: .iphone,
                limit: 10
            )
        }
        let summary = try #require(await recorder.finish(runID: runID))
        let webProvider = try #require(summary.providers[.appStoreWeb])
        let fallbackProvider = try #require(summary.providers[.iTunesStore])

        #expect(requestedURLs.count == 2)
        #expect(page.items.map(\.appStoreID) == [321])
        #expect(page.source == .iTunesFallback)
        #expect(page.fallbackContext == SearchRankingFailureContext(
            provider: .appStoreWeb,
            category: .httpStatus(503)
        ))
        #expect(webProvider.requestCount == 1)
        #expect(webProvider.endpointCounts[.rankingSearch] == 1)
        #expect(webProvider.resultCounts[.serverFailure] == 1)
        #expect(fallbackProvider.requestCount == 1)
        #expect(fallbackProvider.endpointCounts[.rankingSearch] == 1)
        #expect(fallbackProvider.resultCounts[.success] == 1)
    }

    @Test
    func savedKeychainItemsLoadWhenPresenceFlagsExist() throws {
        let defaults = Self.makeDefaults()
        let keychain = InMemoryKeychainService()

        let appleAdsStore = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            loadsEnvironmentCredentials: false
        )
        let apiCredentials = AppleAdsCredentials(
            clientID: "client",
            teamID: "team",
            keyID: "key",
            privateKey: "private",
            orgID: "org"
        )
        try appleAdsStore.saveAPICredentials(apiCredentials)
        let webLoginCredentials = AppleAdsWebLoginCredentials(username: "person@example.com", password: "password")
        try appleAdsStore.saveWebLoginCredentials(webLoginCredentials)

        let webSessionStore = AppleAdsWebSessionStore(defaults: defaults, keychain: keychain)
        let session = AppleAdsWebSession(cookieHeader: "cookie=value", xsrfToken: "token", updatedAt: .now)
        try webSessionStore.save(session)

        let appStoreConnectStore = AppStoreConnectCredentialStore(defaults: defaults, keychain: keychain)
        let appStoreConnectCredentials = AppStoreConnectCredentials(
            issuerID: "issuer",
            keyID: "asc-key",
            privateKey: "asc-private"
        )
        try appStoreConnectStore.save(appStoreConnectCredentials)

        let loadedAppleAdsStore = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            loadsEnvironmentCredentials: false
        )
        let loadedWebSessionStore = AppleAdsWebSessionStore(defaults: defaults, keychain: keychain)
        let loadedAppStoreConnectStore = AppStoreConnectCredentialStore(defaults: defaults, keychain: keychain)

        #expect(loadedAppleAdsStore.apiCredentials == apiCredentials)
        #expect(loadedAppleAdsStore.webLoginCredentials == webLoginCredentials)
        #expect(loadedWebSessionStore.session == session)
        #expect(loadedAppStoreConnectStore.credentials == appStoreConnectCredentials)
    }

    @Test
    func cmPopularityClientBatchesTermsAtOneHundred() async throws {
        struct RequestBody: Decodable {
            let storefronts: [String]
            let terms: [String]
        }

        var requestBodies: [RequestBody] = []
        var requestHeaders: [String: String] = [:]
        let client = MockHTTPClient { request in
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "app-ads.apple.com")
            #expect(request.url?.path == "/cm/api/v2/keywords/popularities")
            #expect(request.url?.query == "adamId=123456789")
            #expect(request.httpMethod == "POST")

            requestHeaders = [
                "Accept": request.value(forHTTPHeaderField: "Accept") ?? "",
                "Content-Type": request.value(forHTTPHeaderField: "Content-Type") ?? "",
                "Cookie": request.value(forHTTPHeaderField: "Cookie") ?? "",
                "Origin": request.value(forHTTPHeaderField: "Origin") ?? "",
                "Referer": request.value(forHTTPHeaderField: "Referer") ?? "",
                "User-Agent": request.value(forHTTPHeaderField: "User-Agent") ?? "",
                "X-Requested-With": request.value(forHTTPHeaderField: "X-Requested-With") ?? "",
                "X-XSRF-TOKEN-CM": request.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") ?? ""
            ]

            let bodyData = try #require(request.httpBody)
            let body = try JSONDecoder().decode(RequestBody.self, from: bodyData)
            requestBodies.append(body)
            let responseItems = body.terms.enumerated().map { index, term in
                """
                {"name":"\(term)","popularity":\(index + 1)}
                """
            }
            let payload = """
            {
              "status": "success",
              "data": [\(responseItems.joined(separator: ","))]
            }
            """
            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }

        let session = AppleAdsWebSession(cookieHeader: "cookie=value; XSRF-TOKEN-CM=token", xsrfToken: "token", updatedAt: .now)
        let popularities = try await AppleAdsCMPopularityClient(httpClient: client).keywordPopularities(
            for: (1 ... 101).map { "term \($0)" },
            storefrontCode: "us",
            adamId: 123_456_789,
            session: session
        )

        #expect(requestBodies.map(\.terms.count) == [100, 1])
        #expect(requestBodies.allSatisfy { $0.storefronts == ["US"] })
        #expect(requestHeaders["Accept"] == "application/json")
        #expect(requestHeaders["Content-Type"] == "application/json")
        #expect(requestHeaders["Cookie"] == "cookie=value; XSRF-TOKEN-CM=token")
        #expect(requestHeaders["Origin"] == "https://app-ads.apple.com")
        #expect(requestHeaders["Referer"] == "https://app-ads.apple.com/")
        #expect(requestHeaders["User-Agent"]?.contains("Mozilla/5.0") == true)
        #expect(requestHeaders["X-Requested-With"] == "XMLHttpRequest")
        #expect(requestHeaders["X-XSRF-TOKEN-CM"] == "token")
        #expect(popularities["term 1"] == 1)
        #expect(popularities["term 100"] == 100)
        #expect(popularities["term 101"] == 1)
    }

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "com.thirdtech.openaso.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class RecordingKeychainService: KeychainService {
    private(set) var dataRequests: [(service: String, account: String)] = []

    func data(service: String, account: String) -> Data? {
        dataRequests.append((service: service, account: account))
        return nil
    }

    func save(_ data: Data, service: String, account: String) throws {}

    func delete(service: String, account: String) {}
}
