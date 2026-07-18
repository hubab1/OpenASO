import Foundation
import OSLog

enum OpenASOLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.thirdtech.openaso"

    static let appDetail = Logger(subsystem: subsystem, category: "app-detail")
    static let ratings = Logger(subsystem: subsystem, category: "ratings")
    static let refresh = Logger(subsystem: subsystem, category: "refresh-observability")
}

enum OpenASOError: LocalizedError, Equatable, Sendable {
    case emptyQuery
    case invalidAppStoreID
    case appNotFound
    case networkUnavailable
    case rateLimited
    case decodingFailed
    case unexpectedResponse
    case primaryProviderUnavailable
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Enter a search term before starting a lookup."
        case .invalidAppStoreID:
            return "The App Store ID is invalid."
        case .appNotFound:
            return "No matching app could be found."
        case .networkUnavailable:
            return "The network appears to be unavailable."
        case .rateLimited:
            return "Apple is rate-limiting the request. Try again shortly."
        case .decodingFailed:
            return "The response format changed and could not be decoded."
        case .unexpectedResponse:
            return "The provider returned an unexpected response."
        case .primaryProviderUnavailable:
            return "The closest-to-App-Store provider did not return usable results."
        case .providerUnavailable(let message):
            return message
        }
    }

    static func map(_ error: Error) -> OpenASOError {
        if let error = error as? OpenASOError {
            return error
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost:
                return .networkUnavailable
            default:
                return .providerUnavailable(urlError.localizedDescription)
            }
        }

        return .providerUnavailable(error.localizedDescription)
    }
}
