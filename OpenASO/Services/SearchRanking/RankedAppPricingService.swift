import Foundation

enum RankedAppPriceValue: Equatable, Hashable, Sendable {
    case free(displayPrice: String)
    case paid(amount: Decimal, displayPrice: String, currencyCode: String)
    case unavailable

    var displayPrice: String? {
        switch self {
        case .free(let displayPrice), .paid(_, let displayPrice, _):
            displayPrice
        case .unavailable:
            nil
        }
    }
}

struct RankedAppPriceResult: Equatable, Hashable, Sendable {
    let appStoreID: Int64
    let storefrontCode: String
    let value: RankedAppPriceValue
    let observedAt: Date
}

enum RankedAppPricingError: LocalizedError, Equatable, Sendable {
    case invalidAppStoreID
    case invalidStorefront
    case tooManyApps(maximum: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidAppStoreID:
            "One or more App Store IDs are invalid."
        case .invalidStorefront:
            "Choose a supported App Store storefront."
        case .tooManyApps(let maximum):
            "Pricing can be loaded for at most \(maximum) apps at once."
        case .malformedResponse:
            "The App Store pricing response could not be verified."
        }
    }
}

actor RankedAppPricingService {
    static let maximumAppCount = SearchRankingCrawl.fullKeywordRankingLimit
    static let defaultFreshnessInterval: TimeInterval = 6 * 60 * 60

    private struct CacheKey: Hashable {
        let appStoreID: Int64
        let storefrontCode: String
        let platform: AppPlatform
    }

    private struct CacheEntry {
        let result: RankedAppPriceResult
        let fetchedAt: Date
    }

    private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        let trackId: Int64
        let price: Decimal?
        let formattedPrice: String?
        let currency: String?
    }

    private let httpClient: any HTTPClient
    private let freshnessInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]

    init(
        httpClient: any HTTPClient,
        freshnessInterval: TimeInterval = RankedAppPricingService.defaultFreshnessInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.freshnessInterval = max(0, freshnessInterval)
        self.now = now
    }

    func prices(
        for appStoreIDs: [Int64],
        storefrontCode: String,
        platform: AppPlatform,
        forceRefresh: Bool = false
    ) async throws -> [RankedAppPriceResult] {
        let orderedIDs = try Self.validatedAppStoreIDs(appStoreIDs)
        guard !orderedIDs.isEmpty else { return [] }

        let storefront = try Self.validatedStorefrontCode(storefrontCode)
        let requestDate = now()
        let staleIDs = forceRefresh
            ? orderedIDs
            : orderedIDs.filter { appStoreID in
                let key = CacheKey(
                    appStoreID: appStoreID,
                    storefrontCode: storefront,
                    platform: platform
                )
                guard let entry = cache[key] else { return true }
                return requestDate.timeIntervalSince(entry.fetchedAt) >= freshnessInterval
            }

        if !staleIDs.isEmpty {
            let refreshedResults = try await fetchPrices(
                appStoreIDs: staleIDs,
                storefrontCode: storefront,
                platform: platform,
                observedAt: requestDate
            )
            for result in refreshedResults {
                let key = CacheKey(
                    appStoreID: result.appStoreID,
                    storefrontCode: storefront,
                    platform: platform
                )
                cache[key] = CacheEntry(result: result, fetchedAt: requestDate)
            }
        }

        return try orderedIDs.map { appStoreID in
            let key = CacheKey(
                appStoreID: appStoreID,
                storefrontCode: storefront,
                platform: platform
            )
            guard let result = cache[key]?.result else {
                throw RankedAppPricingError.malformedResponse
            }
            return result
        }
    }

    private func fetchPrices(
        appStoreIDs: [Int64],
        storefrontCode: String,
        platform: AppPlatform,
        observedAt: Date
    ) async throws -> [RankedAppPriceResult] {
        let request = try Self.lookupRequest(
            appStoreIDs: appStoreIDs,
            storefrontCode: storefrontCode,
            platform: platform
        )

        try Task.checkCancellation()
        let data = try await validatedData(for: request, using: httpClient)
        try Task.checkCancellation()

        let response: LookupResponse
        do {
            response = try JSONDecoder().decode(LookupResponse.self, from: data)
        } catch {
            throw RankedAppPricingError.malformedResponse
        }

        let requestedIDs = Set(appStoreIDs)
        var resultByID: [Int64: LookupResult] = [:]
        for result in response.results {
            guard requestedIDs.contains(result.trackId),
                  resultByID.updateValue(result, forKey: result.trackId) == nil else {
                throw RankedAppPricingError.malformedResponse
            }
        }

        try Task.checkCancellation()
        return appStoreIDs.map { appStoreID in
            RankedAppPriceResult(
                appStoreID: appStoreID,
                storefrontCode: storefrontCode,
                value: Self.priceValue(from: resultByID[appStoreID]),
                observedAt: observedAt
            )
        }
    }

    private static func lookupRequest(
        appStoreIDs: [Int64],
        storefrontCode: String,
        platform: AppPlatform
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [
            URLQueryItem(name: "id", value: appStoreIDs.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "entity", value: ITunesRankingSupport.entity(for: platform)),
            URLQueryItem(name: "country", value: storefrontCode),
        ]
        guard let url = components.url else {
            throw RankedAppPricingError.malformedResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validatedAppStoreIDs(_ appStoreIDs: [Int64]) throws -> [Int64] {
        guard appStoreIDs.allSatisfy({ $0 > 0 }) else {
            throw RankedAppPricingError.invalidAppStoreID
        }

        var seenIDs = Set<Int64>()
        let orderedIDs = appStoreIDs.filter { seenIDs.insert($0).inserted }
        guard orderedIDs.count <= maximumAppCount else {
            throw RankedAppPricingError.tooManyApps(maximum: maximumAppCount)
        }
        return orderedIDs
    }

    private static func validatedStorefrontCode(_ storefrontCode: String) throws -> String {
        let normalizedCode = StorefrontCatalog.normalizedStorefrontCode(storefrontCode)
        guard normalizedCode.count == 2,
              normalizedCode.unicodeScalars.allSatisfy(CharacterSet.lowercaseLetters.contains) else {
            throw RankedAppPricingError.invalidStorefront
        }
        return normalizedCode
    }

    private static func priceValue(from result: LookupResult?) -> RankedAppPriceValue {
        guard let result,
              let amount = result.price,
              amount >= 0 else {
            return .unavailable
        }

        let displayPrice = result.formattedPrice?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if amount == 0 {
            if let displayPrice, !displayPrice.isEmpty {
                return .free(displayPrice: displayPrice)
            }
            return .free(displayPrice: "Free")
        }

        let currencyCode = result.currency?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard let displayPrice,
              !displayPrice.isEmpty,
              let currencyCode,
              !currencyCode.isEmpty else {
            return .unavailable
        }
        return .paid(
            amount: amount,
            displayPrice: displayPrice,
            currencyCode: currencyCode
        )
    }
}
