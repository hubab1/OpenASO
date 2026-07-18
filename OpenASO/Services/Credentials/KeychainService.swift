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
    typealias ReadFailureReporter = (KeychainReadFailure) -> Void

    private static let logger = Logger(subsystem: OpenASOLog.subsystem, category: "keychain")

    private let copyMatching: CopyMatching
    private let reportReadFailure: ReadFailureReporter

    init(
        copyMatching: @escaping CopyMatching = { query, result in
            SecItemCopyMatching(query, result)
        },
        reportReadFailure: @escaping ReadFailureReporter = { failure in
            SystemKeychainService.logReadFailure(failure)
        }
    ) {
        self.copyMatching = copyMatching
        self.reportReadFailure = reportReadFailure
    }

    func readData(service: String, account: String) -> KeychainReadResult {
        var query = keychainQuery(service: service, account: account)
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

        if case .failure(let failure) = result {
            reportReadFailure(failure)
        }
        return result
    }

    func save(_ data: Data, service: String, account: String) throws {
        let query = keychainQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess {
            return
        }

        guard status == errSecItemNotFound else {
            throw OpenASOError.providerUnavailable("Could not save item to Keychain.")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenASOError.providerUnavailable("Could not save item to Keychain.")
        }
    }

    func delete(service: String, account: String) {
        SecItemDelete(keychainQuery(service: service, account: account) as CFDictionary)
    }

    private func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
