import Foundation
import Observation

struct AppleAdsCredentials: Equatable, Sendable {
    var clientID: String
    var teamID: String
    var keyID: String
    var privateKey: String
    var orgID: String
    var adAccountID: String

    init(
        clientID: String,
        teamID: String,
        keyID: String,
        privateKey: String,
        orgID: String = "",
        adAccountID: String = ""
    ) {
        self.clientID = clientID
        self.teamID = teamID
        self.keyID = keyID
        self.privateKey = privateKey
        self.orgID = orgID
        self.adAccountID = adAccountID
    }

    var trimmed: AppleAdsCredentials {
        AppleAdsCredentials(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            teamID: teamID.trimmingCharacters(in: .whitespacesAndNewlines),
            keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines),
            orgID: orgID.trimmingCharacters(in: .whitespacesAndNewlines),
            adAccountID: adAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var isComplete: Bool {
        let credentials = trimmed
        return !credentials.clientID.isEmpty
            && !credentials.teamID.isEmpty
            && !credentials.keyID.isEmpty
            && !credentials.privateKey.isEmpty
            && !credentials.adAccountID.isEmpty
    }

    var canVerify: Bool {
        let credentials = trimmed
        return !credentials.clientID.isEmpty
            && !credentials.teamID.isEmpty
            && !credentials.keyID.isEmpty
            && !credentials.privateKey.isEmpty
    }

    var privateKeyValidationIssue: String? {
        let key = trimmed.privateKey
        guard !key.isEmpty else { return nil }

        if key.contains("-----BEGIN PUBLIC KEY-----") {
            return "This is a public key. Paste the matching private .p8 key so OpenASO can sign Apple Ads requests."
        }

        if key.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
            return "Encrypted private keys are not supported. Export the unencrypted Apple-issued .p8 key."
        }

        let hasPKCS8PrivateKey = key.contains("-----BEGIN PRIVATE KEY-----")
            && key.contains("-----END PRIVATE KEY-----")
        let hasECPrivateKey = key.contains("-----BEGIN EC PRIVATE KEY-----")
            && key.contains("-----END EC PRIVATE KEY-----")
        guard hasPKCS8PrivateKey || hasECPrivateKey else {
            return "Paste the complete Apple-issued private .p8 key, including its BEGIN and END lines."
        }

        return nil
    }
}

@MainActor
@Observable
final class AppleAdsCredentialStore {
    private enum DefaultsKey {
        static let clientID = "appleAds.clientID"
        static let teamID = "appleAds.teamID"
        static let keyID = "appleAds.keyID"
        static let orgID = "appleAds.orgID"
        static let adAccountID = "appleAds.adAccountID"
    }

    private let defaults: UserDefaults
    private let keychain: any KeychainService
    private let keychainItemPresence: KeychainItemPresenceStore
    private let keychainService: String
    private let privateKeyAccount = "private-key"
    private let webLoginKeychainService: String
    private let webLoginCredentialsAccount = "login-credentials"

    private(set) var apiCredentials: AppleAdsCredentials
    private(set) var webLoginCredentials: AppleAdsWebLoginCredentials

    init(
        defaults: UserDefaults = .openASOShared,
        keychain: any KeychainService = SystemKeychainService(),
        namespace: AppNamespace = .current,
        loadsEnvironmentCredentials: Bool = true
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.keychainService = namespace.keychainService("apple-ads")
        self.webLoginKeychainService = namespace.keychainService("apple-ads-web-login")
        let keychainItemPresence = KeychainItemPresenceStore(defaults: defaults)
        self.keychainItemPresence = keychainItemPresence
        let environment = loadsEnvironmentCredentials ? EnvironmentAppleAdsCredentials.load() : EnvironmentAppleAdsCredentials()
        self.apiCredentials = AppleAdsCredentials(
            clientID: defaults.string(forKey: DefaultsKey.clientID) ?? environment.clientID,
            teamID: defaults.string(forKey: DefaultsKey.teamID) ?? environment.teamID,
            keyID: defaults.string(forKey: DefaultsKey.keyID) ?? environment.keyID,
            privateKey: keychainItemPresence.contains(service: keychainService, account: privateKeyAccount)
                ? Self.readSecret(service: keychainService, account: privateKeyAccount, keychain: keychain) ?? environment.privateKey
                : environment.privateKey,
            orgID: defaults.string(forKey: DefaultsKey.orgID) ?? environment.orgID,
            adAccountID: defaults.string(forKey: DefaultsKey.adAccountID) ?? environment.adAccountID
        )
        self.webLoginCredentials = keychainItemPresence.contains(service: webLoginKeychainService, account: webLoginCredentialsAccount)
            ? Self.readWebLoginCredentials(
                service: webLoginKeychainService,
                account: webLoginCredentialsAccount,
                keychain: keychain
            ) ?? AppleAdsWebLoginCredentials(username: "", password: "")
            : AppleAdsWebLoginCredentials(username: "", password: "")
    }

    var hasCompleteAPICredentials: Bool {
        apiCredentials.isComplete
    }

    var hasWebLoginCredentials: Bool {
        webLoginCredentials.isComplete
    }

    func saveAPICredentials(_ credentials: AppleAdsCredentials) throws {
        let trimmedCredentials = credentials.trimmed
        defaults.set(trimmedCredentials.clientID, forKey: DefaultsKey.clientID)
        defaults.set(trimmedCredentials.teamID, forKey: DefaultsKey.teamID)
        defaults.set(trimmedCredentials.keyID, forKey: DefaultsKey.keyID)
        defaults.set(trimmedCredentials.orgID, forKey: DefaultsKey.orgID)
        defaults.set(trimmedCredentials.adAccountID, forKey: DefaultsKey.adAccountID)
        try Self.saveSecret(
            trimmedCredentials.privateKey,
            service: keychainService,
            account: privateKeyAccount,
            keychain: keychain
        )
        keychainItemPresence.markPresent(service: keychainService, account: privateKeyAccount)
        self.apiCredentials = trimmedCredentials
    }

    func clearAPICredentials() {
        defaults.removeObject(forKey: DefaultsKey.clientID)
        defaults.removeObject(forKey: DefaultsKey.teamID)
        defaults.removeObject(forKey: DefaultsKey.keyID)
        defaults.removeObject(forKey: DefaultsKey.orgID)
        defaults.removeObject(forKey: DefaultsKey.adAccountID)
        keychain.delete(service: keychainService, account: privateKeyAccount)
        keychainItemPresence.markAbsent(service: keychainService, account: privateKeyAccount)
        apiCredentials = AppleAdsCredentials(clientID: "", teamID: "", keyID: "", privateKey: "")
    }

    func saveWebLoginCredentials(_ credentials: AppleAdsWebLoginCredentials) throws {
        let trimmedCredentials = credentials.trimmed
        guard trimmedCredentials.isComplete else {
            throw OpenASOError.providerUnavailable("Enter your Apple ID username and password.")
        }

        let data = try JSONEncoder().encode(trimmedCredentials)
        do {
            try keychain.save(data, service: webLoginKeychainService, account: webLoginCredentialsAccount)
            keychainItemPresence.markPresent(service: webLoginKeychainService, account: webLoginCredentialsAccount)
            self.webLoginCredentials = trimmedCredentials
        } catch {
            throw OpenASOError.providerUnavailable("Could not save Apple Ads login credentials to Keychain.")
        }
    }

    func clearWebLoginCredentials() {
        keychain.delete(service: webLoginKeychainService, account: webLoginCredentialsAccount)
        keychainItemPresence.markAbsent(service: webLoginKeychainService, account: webLoginCredentialsAccount)
        webLoginCredentials = AppleAdsWebLoginCredentials(username: "", password: "")
    }

    private static func saveSecret(
        _ secret: String,
        service: String,
        account: String,
        keychain: any KeychainService
    ) throws {
        let secretData = Data(secret.utf8)
        do {
            try keychain.save(secretData, service: service, account: account)
        } catch {
            throw OpenASOError.providerUnavailable("Could not save Apple Ads private key to Keychain.")
        }
    }

    private static func readSecret(service: String, account: String, keychain: any KeychainService) -> String? {
        guard let data = keychain.data(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readWebLoginCredentials(
        service: String,
        account: String,
        keychain: any KeychainService
    ) -> AppleAdsWebLoginCredentials? {
        guard let data = keychain.data(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(AppleAdsWebLoginCredentials.self, from: data)
    }
}

private struct EnvironmentAppleAdsCredentials {
    var clientID = ""
    var teamID = ""
    var keyID = ""
    var privateKey = ""
    var orgID = ""
    var adAccountID = ""

    static func load() -> EnvironmentAppleAdsCredentials {
        let environment = ProcessInfo.processInfo.environment
        return EnvironmentAppleAdsCredentials(
            clientID: value(for: ["APPLE_SEARCH_ADS_CLIENT_ID", "clientId"], environment: environment),
            teamID: value(for: ["APPLE_SEARCH_ADS_TEAM_ID", "teamId"], environment: environment),
            keyID: value(for: ["APPLE_SEARCH_ADS_KEY_ID", "keyId"], environment: environment),
            privateKey: value(for: ["APPLE_SEARCH_ADS_PRIVATE_KEY", "privateKey"], environment: environment),
            orgID: value(for: ["APPLE_SEARCH_ADS_ORG_ID", "orgId"], environment: environment),
            adAccountID: value(
                for: ["APPLE_ADS_PLATFORM_AD_ACCOUNT_ID", "APPLE_SEARCH_ADS_AD_ACCOUNT_ID", "adAccountId"],
                environment: environment
            )
        )
    }

    private static func value(
        for names: [String],
        environment: [String: String]
    ) -> String {
        for name in names {
            if let value = environment[name], !value.isEmpty {
                return value
            }
        }
        return ""
    }
}
