import Foundation
import OSLog
import Security

enum KeychainReadFailure: Equatable, Sendable {
    case status(OSStatus)
    case unexpectedResultType

    var isTransient: Bool {
        switch self {
        case .status(let status):
            // These conditions can clear when the login Keychain becomes available or
            // user interaction is possible again; other statuses need explicit action.
            status == errSecInteractionNotAllowed || status == errSecNotAvailable
        case .unexpectedResultType:
            false
        }
    }
}

enum KeychainReadResult: Equatable, Sendable {
    case success(Data)
    case notFound
    case failure(KeychainReadFailure)
}

protocol KeychainService {
    func readData(service: String, account: String) -> KeychainReadResult
    func save(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String)
}

extension KeychainService {
    func data(service: String, account: String) -> Data? {
        guard case .success(let data) = readData(service: service, account: account) else {
            return nil
        }
        return data
    }
}

struct SystemKeychainService: KeychainService {
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias Update = (CFDictionary, CFDictionary) -> OSStatus
    typealias Add = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias Delete = (CFDictionary) -> OSStatus
    typealias ReadFailureReporter = (KeychainReadFailure) -> Void

    private static let logger = Logger(subsystem: OpenASOLog.subsystem, category: "keychain")

    private let copyMatching: CopyMatching
    private let update: Update
    private let add: Add
    private let delete: Delete
    private let reportReadFailure: ReadFailureReporter

    init(
        copyMatching: @escaping CopyMatching = { query, result in
            SecItemCopyMatching(query, result)
        },
        update: @escaping Update = { query, attributes in
            SecItemUpdate(query, attributes)
        },
        add: @escaping Add = { query, result in
            SecItemAdd(query, result)
        },
        delete: @escaping Delete = { query in
            SecItemDelete(query)
        },
        reportReadFailure: @escaping ReadFailureReporter = { failure in
            SystemKeychainService.logReadFailure(failure)
        }
    ) {
        self.copyMatching = copyMatching
        self.update = update
        self.add = add
        self.delete = delete
        self.reportReadFailure = reportReadFailure
    }

    func readData(service: String, account: String) -> KeychainReadResult {
        let protectedResult = readData(
            query: keychainQuery(
                service: service,
                account: account,
                usesDataProtectionKeychain: true
            )
        )
        guard protectedResult == .notFound else {
            reportFailureIfNeeded(protectedResult)
            return protectedResult
        }

        let legacyResult = readData(
            query: keychainQuery(
                service: service,
                account: account,
                usesDataProtectionKeychain: false
            )
        )
        if case .success(let data) = legacyResult,
           (try? saveToDataProtectionKeychain(data, service: service, account: account)) == true
        {
            _ = delete(keychainQuery(
                service: service,
                account: account,
                usesDataProtectionKeychain: false
            ) as CFDictionary)
        }
        reportFailureIfNeeded(legacyResult)
        return legacyResult
    }

    private func readData(query baseQuery: [String: Any]) -> KeychainReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        let result: KeychainReadResult

        switch status {
        case errSecSuccess:
            if let data = item as? Data {
                result = .success(data)
            } else {
                result = .failure(.unexpectedResultType)
            }
        case errSecItemNotFound:
            result = .notFound
        default:
            result = .failure(.status(status))
        }

        return result
    }

    private func reportFailureIfNeeded(_ result: KeychainReadResult) {
        if case .failure(let failure) = result {
            reportReadFailure(failure)
        }
    }

    func save(_ data: Data, service: String, account: String) throws {
        guard try saveToDataProtectionKeychain(data, service: service, account: account) else {
            try saveToLegacyKeychain(data, service: service, account: account)
            return
        }
    }

    /// Returns `false` when this signed process cannot use the Data Protection Keychain and the
    /// caller should use the encrypted login Keychain instead.
    private func saveToDataProtectionKeychain(
        _ data: Data,
        service: String,
        account: String
    ) throws -> Bool {
        let query = keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: true
        )
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = update(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess {
            return true
        }

        if Self.shouldUseLegacyWriteFallback(for: status) {
            return false
        }

        guard status == errSecItemNotFound else {
            throw OpenASOError.providerUnavailable("Could not save item to Keychain.")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = add(addQuery as CFDictionary, nil)
        if Self.shouldUseLegacyWriteFallback(for: addStatus) {
            return false
        }
        guard addStatus == errSecSuccess else {
            throw OpenASOError.providerUnavailable("Could not save item to Keychain.")
        }
        return true
    }

    /// Directly distributed and local builds can lack the application identifier entitlement
    /// required by the Data Protection Keychain. In that case, use the encrypted macOS login
    /// Keychain that `readData` already supports.
    nonisolated static func shouldUseLegacyWriteFallback(for status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
    }

    private func saveToLegacyKeychain(_ data: Data, service: String, account: String) throws {
        let query = keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: false
        )
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw OpenASOError.providerUnavailable("Could not save item to Keychain.")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard add(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw OpenASOError.providerUnavailable("Could not save item to Keychain.")
        }
    }

    func delete(service: String, account: String) {
        _ = delete(keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: true
        ) as CFDictionary)
        _ = delete(keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: false
        ) as CFDictionary)
    }

    private func keychainQuery(
        service: String,
        account: String,
        usesDataProtectionKeychain: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func logReadFailure(_ failure: KeychainReadFailure) {
        switch failure {
        case .status(let status):
            let description = SecCopyErrorMessageString(status, nil).map { String($0) } ?? "unknown error"
            if failure.isTransient {
                logger.warning(
                    "Keychain read temporarily unavailable status=\(status, privacy: .public) description=\(description, privacy: .public)"
                )
            } else {
                logger.error(
                    "Keychain read failed status=\(status, privacy: .public) description=\(description, privacy: .public)"
                )
            }
        case .unexpectedResultType:
            logger.error("Keychain read returned an unexpected result type")
        }
    }
}

final class InMemoryKeychainService: KeychainService {
    private var storage: [Key: Data] = [:]

    func readData(service: String, account: String) -> KeychainReadResult {
        guard let data = storage[Key(service: service, account: account)] else {
            return .notFound
        }
        return .success(data)
    }

    func save(_ data: Data, service: String, account: String) throws {
        storage[Key(service: service, account: account)] = data
    }

    func delete(service: String, account: String) {
        storage.removeValue(forKey: Key(service: service, account: account))
    }

    private struct Key: Hashable {
        var service: String
        var account: String
    }
}

struct KeychainItemPresenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func contains(service: String, account: String) -> Bool {
        defaults.bool(forKey: defaultsKey(service: service, account: account))
    }

    func markPresent(service: String, account: String) {
        defaults.set(true, forKey: defaultsKey(service: service, account: account))
    }

    func markAbsent(service: String, account: String) {
        defaults.removeObject(forKey: defaultsKey(service: service, account: account))
    }

    private func defaultsKey(service: String, account: String) -> String {
        "keychain.containsItem.\(service).\(account)"
    }
}
