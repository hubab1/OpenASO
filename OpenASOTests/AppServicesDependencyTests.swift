import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct AppServicesDependencyTests {
    @Test
    func modelContainerFactoryUsesAppendOnlyV3MigrationPlan() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)

        #expect(OpenASOSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(OpenASOSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(OpenASOSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
        #expect(OpenASOMigrationPlan.schemas.count == 3)
        #expect(OpenASOMigrationPlan.schemas.first?.versionIdentifier == OpenASOSchemaV1.versionIdentifier)
        #expect(OpenASOMigrationPlan.schemas.last?.versionIdentifier == OpenASOSchemaV3.versionIdentifier)
        #expect(OpenASOSchemaV1.models.count == 17)
        #expect(OpenASOSchemaV2.models.count == 18)
        #expect(OpenASOSchemaV3.models.count == 19)
        #expect(OpenASOMigrationPlan.stages.count == 2)
        #expect(container.migrationPlan != nil)
    }

    @Test
    func failedPersistentStoreOpenPreservesStoreAndSidecars() throws {
        for simulatedFailure in SimulatedPersistentStoreFailure.allCases {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "OpenASO-PersistentStoreTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: rootURL)
            }

            let storeURL = rootURL.appendingPathComponent("default.store", isDirectory: false)
            let artifacts = [
                (storeURL, Data("database-\(simulatedFailure.rawValue)".utf8)),
                (
                    storeURL.deletingPathExtension().appendingPathExtension("store-wal"),
                    Data("wal-\(simulatedFailure.rawValue)".utf8)
                ),
                (
                    storeURL.deletingPathExtension().appendingPathExtension("store-shm"),
                    Data("shm-\(simulatedFailure.rawValue)".utf8)
                )
            ]
            for (url, data) in artifacts {
                try data.write(to: url)
            }

            var openAttemptCount = 0
            var persistentStoreError: PersistentStoreError?
            do {
                _ = try ModelContainerFactory.makePersistentModelContainer(at: storeURL) { _, _ in
                    openAttemptCount += 1
                    throw simulatedFailure
                }
            } catch let error as PersistentStoreError {
                persistentStoreError = error
            } catch {
                #expect(Bool(false), "Unexpected error type: \(String(reflecting: error))")
            }

            #expect(openAttemptCount == 1)
            #expect(persistentStoreError?.storeURL == storeURL)
            #expect(persistentStoreError?.diagnosticReport.contains(storeURL.path(percentEncoded: false)) == true)
            for (url, expectedData) in artifacts {
                #expect(FileManager.default.fileExists(atPath: url.path))
                #expect(try Data(contentsOf: url) == expectedData)
            }
        }
    }

    @Test
    func inMemoryOpenFailureIsNotReportedAsPersistentStoreFailure() {
        #expect(throws: SimulatedPersistentStoreFailure.self) {
            _ = try ModelContainerFactory.makeModelContainer(
                isStoredInMemoryOnly: true,
                opener: { _, _ in
                    throw SimulatedPersistentStoreFailure.transient
                }
            )
        }
    }

    @Test
    func applicationSupportLookupFailureDoesNotFallBackToTemporaryStorage() {
        #expect(throws: SimulatedDirectoryLookupFailure.self) {
            _ = try AppNamespace.containerBaseURL(
                bundleIdentifier: "com.thirdtech.openaso.tests.persistence",
                applicationSupportDirectoryURL: {
                    throw SimulatedDirectoryLookupFailure.unavailable
                }
            )
        }
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
    func headlessDailyRefreshWiringRequiresABackgroundStore() throws {
        let transport = MockHTTPClient { request in
            throw OpenASOError.providerUnavailable(
                "Unexpected request to \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        let servicesWithoutStore = AppServices.mocked(httpClient: transport)

        #expect(servicesWithoutStore.headlessRefreshService == nil)
        #expect(servicesWithoutStore.dailyRefreshScheduler == nil)

        let container = try ModelContainerFactory.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let servicesWithStore = AppServices.mocked(
            httpClient: transport,
            modelContainer: container
        )

        #expect(servicesWithStore.headlessRefreshService != nil)
        #expect(servicesWithStore.dailyRefreshScheduler != nil)

        let revisionBeforeCompletion = servicesWithStore.backgroundModelStoreRevision
        let instant = Date(timeIntervalSince1970: 1_000)
        servicesWithStore.recordHeadlessRefreshCompletion(
            HeadlessRefreshRunSummary(
                runID: UUID(),
                activeRunID: nil,
                scheduledFor: instant,
                startedAt: instant,
                finishedAt: instant,
                disposition: .partialFailure,
                plannedAppCount: 1,
                completedAppCount: 1,
                successfulAppCount: 0,
                partialFailureAppCount: 1,
                failedAppCount: 0,
                ratingsReviewsAttempted: false,
                ratingsReviewsFullySucceeded: false,
                issue: HeadlessRefreshIssue(kind: .appRefreshFailed)
            )
        )
        #expect(
            servicesWithStore.backgroundModelStoreRevision
                == revisionBeforeCompletion + 1
        )
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
    func reconnectRequirementPersistsByNamespaceWithoutClearingSession() throws {
        let defaults = Self.makeDefaults()
        let keychain = InMemoryKeychainService()
        let namespace = AppNamespace(bundleIdentifier: "com.thirdtech.openaso.tests.reconnect-a")
        let otherNamespace = AppNamespace(bundleIdentifier: "com.thirdtech.openaso.tests.reconnect-b")
        let session = AppleAdsWebSession(
            cookieHeader: "cookie=value",
            xsrfToken: "token",
            updatedAt: .now,
            accountName: "Example Account"
        )
        let store = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        try store.save(session)

        store.markReconnectRequired(for: session)

        #expect(store.requiresReconnect)
        #expect(store.session == session)
        #expect(store.hasSession)

        let reloadedStore = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let otherStore = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: otherNamespace
        )
        #expect(reloadedStore.requiresReconnect)
        #expect(reloadedStore.session == session)
        #expect(!otherStore.requiresReconnect)

        reloadedStore.clearReconnectRequirement(for: session)
        #expect(!reloadedStore.requiresReconnect)
        #expect(reloadedStore.session == session)

        reloadedStore.markReconnectRequired(for: session)
        reloadedStore.clear()
        #expect(!reloadedStore.requiresReconnect)
        #expect(!reloadedStore.hasSession)
    }

    @Test
    func reconnectRequirementOnlyMutatesTheSessionRevisionThatWasObserved() throws {
        let defaults = Self.makeDefaults()
        let keychain = InMemoryKeychainService()
        let namespace = AppNamespace(bundleIdentifier: "com.thirdtech.openaso.tests.reconnect-race")
        let store = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let oldSession = AppleAdsWebSession(
            cookieHeader: "cookie=old",
            xsrfToken: "old-token",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let currentSession = AppleAdsWebSession(
            cookieHeader: "cookie=current",
            xsrfToken: "current-token",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        try store.save(oldSession)
        try store.save(currentSession)
        store.markReconnectRequired(for: oldSession)
        #expect(!store.requiresReconnect)

        store.markReconnectRequired(for: currentSession)
        #expect(store.requiresReconnect)

        store.clearReconnectRequirement(for: oldSession)
        #expect(store.requiresReconnect)

        store.clearReconnectRequirement(for: currentSession)
        #expect(!store.requiresReconnect)
    }

    @Test
    func sessionValidationMarksExpiryAndSuccessClearsItWithoutDiscardingConnectionData() async throws {
        let defaults = Self.makeDefaults()
        let keychain = InMemoryKeychainService()
        let namespace = AppNamespace(bundleIdentifier: "com.thirdtech.openaso.tests.validation")
        let sessionStore = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let credentialStore = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace,
            loadsEnvironmentCredentials: false
        )
        let settingsStore = AppSettingsStore(defaults: defaults)
        let loginCredentials = AppleAdsWebLoginCredentials(
            username: "person@example.com",
            password: "password"
        )
        let session = AppleAdsWebSession(
            cookieHeader: "cookie=value",
            xsrfToken: "token",
            updatedAt: .now,
            accountName: "Example Account"
        )
        try credentialStore.saveWebLoginCredentials(loginCredentials)
        try sessionStore.save(session)
        settingsStore.savePopularityContext(appStoreID: 123_456_789, storefrontCode: "GB")

        let expiredManager = AppleAdsWebSessionManager(
            sessionStore: sessionStore,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            httpClient: MockHTTPClient { request in
                let url = try #require(request.url)
                return (Data(), makeHTTPURLResponse(url: url, statusCode: 401))
            },
            namespace: namespace
        )

        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await expiredManager.validateSession(adamId: 987_654_321)
        }
        #expect(sessionStore.requiresReconnect)
        #expect(sessionStore.session == session)
        #expect(credentialStore.webLoginCredentials == loginCredentials)
        #expect(settingsStore.popularityContextAppStoreID == 123_456_789)
        #expect(settingsStore.popularityContextStorefrontCode == "GB")

        let successfulManager = AppleAdsWebSessionManager(
            sessionStore: sessionStore,
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            httpClient: MockHTTPClient { request in
                let url = try #require(request.url)
                let payload = #"{"status":"success","data":[{"name":"workout","popularity":57}]}"#
                return (Data(payload.utf8), makeHTTPURLResponse(url: url, statusCode: 200))
            },
            namespace: namespace
        )

        let popularity = try await successfulManager.validateSession(adamId: 987_654_321)

        #expect(popularity == 57)
        #expect(!sessionStore.requiresReconnect)
        #expect(sessionStore.session == session)
        #expect(credentialStore.webLoginCredentials == loginCredentials)
        #expect(settingsStore.popularityContextAppStoreID == 123_456_789)
        #expect(settingsStore.popularityContextStorefrontCode == "GB")
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

    @Test
    func cmPopularityClientClassifiesUnauthorizedAsExpiredSession() async {
        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await cmPopularities(statusCode: 401)
        }
    }

    @Test
    func cmPopularityClientClassifiesForbiddenAsExpiredSession() async {
        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await cmPopularities(statusCode: 403)
        }
    }

    @Test
    func cmPopularityClientClassifiesHTMLWhereJSONIsExpectedAsExpiredSession() async {
        let payload = "  \n\u{FEFF}<!DoCtYpE html><html><body>Sign in</body></html>"

        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await cmPopularities(
                data: Data(payload.utf8),
                statusCode: 200
            )
        }
    }

    @Test
    func cmPopularityClientClassifiesAppleSignInRedirectAsExpiredSession() async {
        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await cmPopularities(
                statusCode: 302,
                headerFields: ["Location": "https://idmsa.apple.com/appleauth/auth/signin"]
            )
        }
    }

    @Test
    func cmPopularityClientClassifiesFollowedAppleSignInRedirectAsExpiredSession() async throws {
        let loginURL = try #require(URL(string: "https://appleid.apple.com/auth/authorize"))

        await #expect(throws: AppleAdsWebSessionExpiredError()) {
            _ = try await cmPopularities(statusCode: 200, responseURL: loginURL)
        }
    }

    @Test
    func cmPopularityClientDoesNotTreatHTMLTextInsideJSONAsExpiredSession() async throws {
        let payload = #"{"status":"success","data":[{"name":"<html keyword","popularity":57}]}"#

        let popularities = try await cmPopularities(data: Data(payload.utf8), statusCode: 200)

        #expect(popularities["<html keyword"] == 57)
    }

    @Test
    func cmPopularityClientPreservesNonAuthenticationHTTPFailures() async {
        await #expect(throws: OpenASOError.appNotFound) {
            _ = try await cmPopularities(statusCode: 404)
        }
        await #expect(throws: OpenASOError.rateLimited) {
            _ = try await cmPopularities(statusCode: 429)
        }
        await #expect(throws: OpenASOError.providerUnavailable("HTTP 500")) {
            _ = try await cmPopularities(
                data: Data("<html>Server error</html>".utf8),
                statusCode: 500,
                headerFields: ["Content-Type": "text/html"]
            )
        }
    }

    @Test
    func cmPopularityClientPreservesCancellation() async {
        let taskCancellationClient = MockHTTPClient { _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            _ = try await self.cmPopularities(using: taskCancellationClient)
        }

        let urlCancellationClient = MockHTTPClient { _ in
            throw URLError(.cancelled)
        }
        await #expect(throws: URLError.self) {
            _ = try await self.cmPopularities(using: urlCancellationClient)
        }
    }

    @Test
    func cmPopularityClientPreservesTransportFailures() async {
        let client = MockHTTPClient { _ in
            throw URLError(.timedOut)
        }

        await #expect(throws: URLError.self) {
            _ = try await self.cmPopularities(using: client)
        }
    }

    @Test
    func cmPopularityClientRejectsNonHTTPResponses() async throws {
        let client = MockHTTPClient { request in
            let url = try #require(request.url)
            return (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }

        await #expect(throws: OpenASOError.unexpectedResponse) {
            _ = try await self.cmPopularities(using: client)
        }
    }

    private func cmPopularities(
        data: Data = Data(#"{"status":"success","data":[{"name":"focus","popularity":50}]}"#.utf8),
        statusCode: Int,
        responseURL: URL? = nil,
        headerFields: [String: String]? = nil
    ) async throws -> [String: Int] {
        let client = MockHTTPClient { request in
            let requestURL = try #require(request.url)
            return (
                data,
                makeHTTPURLResponse(
                    url: responseURL ?? requestURL,
                    statusCode: statusCode,
                    headerFields: headerFields
                )
            )
        }
        return try await cmPopularities(using: client)
    }

    private func cmPopularities(using client: HTTPClient) async throws -> [String: Int] {
        try await AppleAdsCMPopularityClient(httpClient: client).keywordPopularities(
            for: ["focus"],
            storefrontCode: "us",
            adamId: 123_456_789,
            session: AppleAdsWebSession(
                cookieHeader: "cookie=value; XSRF-TOKEN-CM=token",
                xsrfToken: "token",
                updatedAt: .now
            )
        )
    }

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "com.thirdtech.openaso.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private enum SimulatedPersistentStoreFailure: String, Error, CaseIterable, Sendable {
    case corrupt
    case incompatible
    case transient
}

private enum SimulatedDirectoryLookupFailure: Error {
    case unavailable
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
