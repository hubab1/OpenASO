import Foundation
import Testing
@testable import OpenASO

struct AppleAdsPlatformServiceTests {
    @Test
    func coverageAccountsForEveryGeneratedOperation() {
        let coverage = AppleAdsPlatformCoverage.current

        #expect(coverage.clientVersion == "1.109.0")
        #expect(coverage.baseURL == "https://api.ads.apple.com/v1")
        #expect(coverage.families.reduce(0) { $0 + $1.operationCount } == coverage.operationCount)
        #expect(coverage.operationCount == 99)
    }

    @Test
    func verifiedConnectionAppliesSelectedAdAccountWithoutLosingCredentials() {
        let credentials = AppleAdsCredentials(
            clientID: "client",
            teamID: "team",
            keyID: "key",
            privateKey: "private"
        )
        let connection = AppleAdsPlatformConnection(
            userID: 10,
            orgID: 20,
            accounts: [
                AppleAdsPlatformAccount(
                    id: 30,
                    name: "Primary",
                    orgID: 20,
                    roles: ["API Account Manager"]
                )
            ],
            selectedAdAccountID: 30
        )

        let applied = connection.applying(to: credentials)

        #expect(applied.clientID == credentials.clientID)
        #expect(applied.privateKey == credentials.privateKey)
        #expect(applied.orgID == "20")
        #expect(applied.adAccountID == "30")
        #expect(applied.isComplete)
    }

    @Test
    func completedWeeklyWindowUsesPreviousSaturdayAndFourFullWeeks() throws {
        let date = try #require(
            ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")
        )

        let window = AppleAdsSearchTermPopularityWindow.recentCompletedWeeks(
            asOf: date,
            weekCount: 4
        )

        #expect(window.start == "2026-07-12")
        #expect(window.end == "2026-08-08")
    }

    @Test
    func searchTermPopularityIdentityAndNormalizationAreStable() {
        let row = AppleAdsSearchTermPopularity(
            searchTerm: "  Focus  ",
            countryOrRegion: "US",
            genre: "Productivity",
            week: "2026-08-02",
            month: nil,
            rankInGenre: 3,
            popularityInGenre: 87,
            popularity1to100: 72,
            popularity1to5: 4
        )

        #expect(row.normalizedSearchTerm == "focus")
        #expect(row.id == "US|focus|2026-08-02|Productivity")
    }

    @Test
    func searchTermPopularityRequestOmitsRejectedGeneratedSortingProperty() throws {
        let request = try OfficialAppleAdsPlatformAPI.searchTermPopularityRequest(
            countryCode: "US",
            searchTerms: ["focus"],
            window: .init(start: "2026-07-12", end: "2026-08-08"),
            offset: 0,
            pageSize: 5_000
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["sorting"] == nil)
        #expect(String(decoding: data, as: UTF8.self).contains("\"order\"") == false)
    }

    @Test
    func campaignSummariesDecodeAppleFractionalSecondDates() throws {
        let data = Data(
            #"""
            [
              {
                "displayStatus": "ON_HOLD",
                "id": 1899370629,
                "modificationTime": "2026-08-06T17:28:28.018",
                "name": "China Search Results",
                "promotedObjectId": "6608976383",
                "status": "PAUSED"
              }
            ]
            """#.utf8
        )

        let campaign = try #require(
            OfficialAppleAdsPlatformAPI.campaignSummaries(
                fromEncodedObjects: data
            ).first
        )

        #expect(campaign.id == 1_899_370_629)
        #expect(campaign.name == "China Search Results")
        #expect(campaign.status == "PAUSED")
        #expect(campaign.displayStatus == "ON_HOLD")
        #expect(campaign.promotedObjectID == "6608976383")
        #expect(campaign.modifiedAt != nil)
    }

    @Test
    func credentialValidationRejectsPublicKeyBeforeVerification() {
        let credentials = AppleAdsCredentials(
            clientID: "client",
            teamID: "team",
            keyID: "key",
            privateKey: """
            -----BEGIN PUBLIC KEY-----
            cHVibGlj
            -----END PUBLIC KEY-----
            """
        )

        #expect(credentials.canVerify)
        #expect(credentials.privateKeyValidationIssue?.contains("public key") == true)
    }

    @Test
    func credentialValidationAcceptsPrivatePEMEnvelope() {
        let credentials = AppleAdsCredentials(
            clientID: "client",
            teamID: "team",
            keyID: "key",
            privateKey: """
            -----BEGIN PRIVATE KEY-----
            cHJpdmF0ZQ==
            -----END PRIVATE KEY-----
            """
        )

        #expect(credentials.privateKeyValidationIssue == nil)
    }

    @Test
    func environmentCredentialsLoadFromConfiguredDotEnvAndPrivateKeyFile() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let privateKeyURL = temporaryDirectory.appendingPathComponent("apple-ads-private-key.p8")
        let privateKey = """
        -----BEGIN PRIVATE KEY-----
        cHJpdmF0ZQ==
        -----END PRIVATE KEY-----
        """
        try privateKey.write(to: privateKeyURL, atomically: true, encoding: .utf8)

        let environmentURL = temporaryDirectory.appendingPathComponent(".env")
        try """
        APPLE_SEARCH_ADS_CLIENT_ID=client-from-file
        APPLE_SEARCH_ADS_TEAM_ID=team-from-file
        APPLE_SEARCH_ADS_KEY_ID=key-from-file
        APPLE_SEARCH_ADS_PRIVATE_KEY_PATH=\(privateKeyURL.path)
        APPLE_SEARCH_ADS_ORG_ID=20
        APPLE_ADS_PLATFORM_AD_ACCOUNT_ID=30
        """.write(to: environmentURL, atomically: true, encoding: .utf8)

        let credentials = EnvironmentAppleAdsCredentials.load(environment: [
            "OPENASO_ENV_FILE": environmentURL.path,
            "APPLE_SEARCH_ADS_CLIENT_ID": "client-from-process",
        ])

        #expect(credentials.clientID == "client-from-process")
        #expect(credentials.teamID == "team-from-file")
        #expect(credentials.keyID == "key-from-file")
        #expect(credentials.privateKey == privateKey)
        #expect(credentials.orgID == "20")
        #expect(credentials.adAccountID == "30")
    }

    @Test
    func environmentCredentialsDecodeEscapedPrivateKeyNewlines() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let environmentURL = temporaryDirectory.appendingPathComponent(".env")
        try #"APPLE_SEARCH_ADS_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\ncHJpdmF0ZQ==\n-----END PRIVATE KEY-----""#
            .write(to: environmentURL, atomically: true, encoding: .utf8)

        let credentials = EnvironmentAppleAdsCredentials.load(environment: [
            "OPENASO_ENV_FILE": environmentURL.path,
        ])

        #expect(credentials.privateKey == """
        -----BEGIN PRIVATE KEY-----
        cHJpdmF0ZQ==
        -----END PRIVATE KEY-----
        """)
    }

    @MainActor
    @Test
    func credentialStorePersistsAdAccountAndKeepsPrivateKeyInKeychain() throws {
        let suiteName = "com.thirdtech.openaso.tests.apple-ads-platform.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = InMemoryKeychainService()
        let namespace = AppNamespace(bundleIdentifier: suiteName)
        let credentials = AppleAdsCredentials(
            clientID: "client",
            teamID: "team",
            keyID: "key",
            privateKey: "private",
            orgID: "20",
            adAccountID: "30"
        )

        let store = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace,
            loadsEnvironmentCredentials: false
        )
        try store.saveAPICredentials(credentials)
        let reloaded = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace,
            loadsEnvironmentCredentials: false
        )

        #expect(reloaded.apiCredentials == credentials)
        #expect(defaults.string(forKey: "appleAds.adAccountID") == "30")
        #expect(defaults.string(forKey: "appleAds.privateKey") == nil)
    }

    @Test
    func mcpRegistryExposesOfficialClientReadTools() {
        let names = Set(OpenASOMCPServerFactory.availableTools.map(\.name))

        #expect(names.contains("apple_ads_platform_capabilities"))
        #expect(names.contains("apple_ads_platform_status"))
        #expect(names.contains("apple_ads_platform_search_apps"))
        #expect(names.contains("apple_ads_platform_list_campaigns"))
        #expect(names.contains("apple_ads_search_term_popularity"))
    }
}
