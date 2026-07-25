import Foundation

enum SearchRankingCrawl {
    static let fullKeywordRankingLimit = 200
}

struct ResolvedApp: Identifiable, Hashable, Sendable {
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?
    let version: String?
    let primaryGenreID: Int?
    let primaryGenreName: String?
    let supportedLanguageCodes: [String]
    let sellerURLString: String?
    let trackViewURLString: String?
    let screenshotURLs: [String]
    let ipadScreenshotURLs: [String]
    let appletvScreenshotURLs: [String]
    let defaultPlatform: AppPlatform

    init(
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String? = nil,
        sellerName: String?,
        iconURLString: String? = nil,
        releaseDate: Date? = nil,
        currentVersionReleaseDate: Date? = nil,
        version: String? = nil,
        primaryGenreID: Int? = nil,
        primaryGenreName: String? = nil,
        supportedLanguageCodes: [String] = [],
        sellerURLString: String? = nil,
        trackViewURLString: String? = nil,
        screenshotURLs: [String] = [],
        ipadScreenshotURLs: [String] = [],
        appletvScreenshotURLs: [String] = [],
        defaultPlatform: AppPlatform
    ) {
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.iconURLString = iconURLString
        self.releaseDate = releaseDate
        self.currentVersionReleaseDate = currentVersionReleaseDate
        self.version = version
        self.primaryGenreID = primaryGenreID
        self.primaryGenreName = primaryGenreName
        self.supportedLanguageCodes = supportedLanguageCodes
        self.sellerURLString = sellerURLString
        self.trackViewURLString = trackViewURLString
        self.screenshotURLs = screenshotURLs
        self.ipadScreenshotURLs = ipadScreenshotURLs
        self.appletvScreenshotURLs = appletvScreenshotURLs
        self.defaultPlatform = defaultPlatform
    }

    var id: Int64 { appStoreID }
}

struct SearchRankingItem: Identifiable, Hashable, Sendable {
    let position: Int
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?
    let version: String?
    let primaryGenreID: Int?
    let primaryGenreName: String?
    let descriptionText: String?
    let releaseNotes: String?
    let supportedLanguageCodes: [String]
    let screenshotURLs: [String]
    let ipadScreenshotURLs: [String]
    let appletvScreenshotURLs: [String]
    let ratingCount: Int?
    let averageRating: Double?
    let platform: AppPlatform

    init(
        position: Int,
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String? = nil,
        sellerName: String?,
        iconURLString: String? = nil,
        releaseDate: Date? = nil,
        currentVersionReleaseDate: Date? = nil,
        version: String? = nil,
        primaryGenreID: Int? = nil,
        primaryGenreName: String? = nil,
        descriptionText: String? = nil,
        releaseNotes: String? = nil,
        supportedLanguageCodes: [String] = [],
        screenshotURLs: [String] = [],
        ipadScreenshotURLs: [String] = [],
        appletvScreenshotURLs: [String] = [],
        ratingCount: Int? = nil,
        averageRating: Double? = nil,
        platform: AppPlatform = .iphone
    ) {
        self.position = position
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.iconURLString = iconURLString
        self.releaseDate = releaseDate
        self.currentVersionReleaseDate = currentVersionReleaseDate
        self.version = version
        self.primaryGenreID = primaryGenreID
        self.primaryGenreName = primaryGenreName
        self.descriptionText = descriptionText
        self.releaseNotes = releaseNotes
        self.supportedLanguageCodes = supportedLanguageCodes
        self.screenshotURLs = screenshotURLs
        self.ipadScreenshotURLs = ipadScreenshotURLs
        self.appletvScreenshotURLs = appletvScreenshotURLs
        self.ratingCount = ratingCount
        self.averageRating = averageRating
        self.platform = platform
    }

    var id: Int64 { appStoreID }
}

struct SearchRankingPage: Sendable {
    let items: [SearchRankingItem]
    let source: RankingSource
    let fallbackContext: SearchRankingFailureContext?

    init(
        items: [SearchRankingItem],
        source: RankingSource,
        fallbackContext: SearchRankingFailureContext? = nil
    ) {
        self.items = items
        self.source = source
        self.fallbackContext = fallbackContext
    }

    var resultCount: Int {
        items.count
    }
}

enum SearchRankingResponseFailure: String, Equatable, Sendable {
    case serializedServerDataMissing
    case decodingFailed
    case nonHTTPResponse
    case requestIntentMissing
    case requestIntentAmbiguous
    case pageShapeChanged
    case authoritativeShelfMissing
    case authoritativeShelfAmbiguous
    case malformedSearchResult
    case truncatedResults
    case lookupHydrationIncomplete
}

enum SearchRankingFailureCategory: Equatable, Sendable {
    case transport(code: Int?)
    case httpStatus(Int)
    case response(SearchRankingResponseFailure)
    case provider
    case other
}

struct SearchRankingFailureContext: Equatable, Sendable {
    enum Provider: String, Equatable, Sendable {
        case appStoreWeb
        case iTunesFallback
    }

    let provider: Provider
    let category: SearchRankingFailureCategory
}

enum SearchRankingProviderError: LocalizedError, Sendable {
    case invalidStorefront
    case invalidLimit
    case unsupportedPlatform(AppPlatform)
    case httpStatus(Int)
    case responseFailure(SearchRankingResponseFailure)
    case fallbackUnavailable(platform: AppPlatform, primary: SearchRankingFailureContext)
    case allProvidersFailed(
        primary: SearchRankingFailureContext,
        fallback: SearchRankingFailureContext
    )

    var errorDescription: String? {
        switch self {
        case .invalidStorefront:
            return "Enter a valid two-letter App Store storefront code."
        case .invalidLimit:
            return "The ranking result limit must be between 1 and \(SearchRankingCrawl.fullKeywordRankingLimit)."
        case .unsupportedPlatform(let platform):
            return "This ranking provider does not support \(platform.displayName)."
        case .httpStatus(let statusCode):
            return "The ranking provider returned HTTP \(statusCode)."
        case .responseFailure:
            return "The ranking provider response format changed and could not be decoded safely."
        case .fallbackUnavailable(let platform, let primary):
            return "The primary ranking provider failed (\(Self.summary(primary.category))), and no fallback supports \(platform.displayName)."
        case .allProvidersFailed(let primary, let fallback):
            return "The primary ranking provider failed (\(Self.summary(primary.category))), and the fallback also failed (\(Self.summary(fallback.category)))."
        }
    }

    private static func summary(_ category: SearchRankingFailureCategory) -> String {
        switch category {
        case .transport(let code):
            return code.map { "transport \($0)" } ?? "transport"
        case .httpStatus(let statusCode):
            return "HTTP \(statusCode)"
        case .response(let failure):
            return "response \(failure.rawValue)"
        case .provider:
            return "provider"
        case .other:
            return "other"
        }
    }
}

struct ValidatedSearchRankingRequest: Sendable {
    let keyword: String
    let storefrontCode: String
    let platform: AppPlatform
    let limit: Int
}

enum SearchRankingRequestValidator {
    static func validate(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) throws -> ValidatedSearchRankingRequest {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKeyword.isEmpty else {
            throw OpenASOError.emptyQuery
        }

        let normalizedStorefront = StorefrontCatalog.normalizedStorefrontCode(storefrontCode)
        guard normalizedStorefront.utf8.count == 2,
              normalizedStorefront.utf8.allSatisfy({ (97 ... 122).contains($0) }) else {
            throw SearchRankingProviderError.invalidStorefront
        }

        guard (1 ... SearchRankingCrawl.fullKeywordRankingLimit).contains(limit) else {
            throw SearchRankingProviderError.invalidLimit
        }

        return ValidatedSearchRankingRequest(
            keyword: normalizedKeyword,
            storefrontCode: normalizedStorefront,
            platform: platform,
            limit: limit
        )
    }
}
