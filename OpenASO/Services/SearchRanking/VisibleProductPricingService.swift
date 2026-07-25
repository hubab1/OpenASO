import Foundation

struct VisibleProductPrice: Equatable, Hashable, Sendable {
    let name: String
    let displayPrice: String
}

struct VisibleProductPriceResult: Equatable, Hashable, Sendable {
    let appStoreID: Int64
    let storefrontCode: String
    let products: [VisibleProductPrice]
    let observedAt: Date
    let isPotentiallyIncomplete: Bool
    let isTruncated: Bool
}

enum VisibleProductPricingError: LocalizedError, Equatable, Sendable {
    case invalidAppStoreID
    case invalidStorefront
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidAppStoreID:
            "The App Store ID is invalid."
        case .invalidStorefront:
            "Choose a supported App Store storefront."
        case .malformedResponse:
            "The App Store purchase list could not be verified."
        }
    }
}

actor VisibleProductPricingService {
    static let maximumProductCount = 20
    static let defaultFreshnessInterval: TimeInterval = 6 * 60 * 60

    private struct CacheKey: Hashable {
        let appStoreID: Int64
        let storefrontCode: String
    }

    private struct CacheEntry {
        let result: VisibleProductPriceResult
        let fetchedAt: Date
    }

    private let httpClient: any HTTPClient
    private let freshnessInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]

    init(
        httpClient: any HTTPClient,
        freshnessInterval: TimeInterval = VisibleProductPricingService.defaultFreshnessInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.freshnessInterval = max(0, freshnessInterval)
        self.now = now
    }

    func products(
        for appStoreID: Int64,
        storefrontCode: String,
        forceRefresh: Bool = false
    ) async throws -> VisibleProductPriceResult {
        guard appStoreID > 0 else {
            throw VisibleProductPricingError.invalidAppStoreID
        }
        let storefront = try Self.validatedStorefrontCode(storefrontCode)
        let key = CacheKey(appStoreID: appStoreID, storefrontCode: storefront)
        let requestDate = now()

        if !forceRefresh,
           let entry = cache[key],
           requestDate.timeIntervalSince(entry.fetchedAt) < freshnessInterval {
            return entry.result
        }

        let request = try Self.request(
            appStoreID: appStoreID,
            storefrontCode: storefront
        )
        try Task.checkCancellation()
        let data = try await validatedData(for: request, using: httpClient)
        try Task.checkCancellation()

        let result = try Self.parse(
            data,
            appStoreID: appStoreID,
            storefrontCode: storefront,
            observedAt: requestDate
        )
        cache[key] = CacheEntry(result: result, fetchedAt: requestDate)
        return result
    }

    static func parse(
        _ data: Data,
        appStoreID: Int64,
        storefrontCode: String,
        observedAt: Date
    ) throws -> VisibleProductPriceResult {
        guard appStoreID > 0 else {
            throw VisibleProductPricingError.invalidAppStoreID
        }
        let storefront = try validatedStorefrontCode(storefrontCode)
        guard let html = String(data: data, encoding: .utf8),
              let serializedData = serializedServerData(from: html) else {
            throw VisibleProductPricingError.malformedResponse
        }

        let jsonData = Data(htmlDecoded(serializedData).utf8)
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw VisibleProductPricingError.malformedResponse
        }
        guard containsAppLockup(in: json, appStoreID: appStoreID) else {
            throw VisibleProductPricingError.malformedResponse
        }

        var candidates: [[String: Any]] = []
        collectProductAnnotations(in: json, into: &candidates)
        guard candidates.count <= 1 else {
            throw VisibleProductPricingError.malformedResponse
        }

        let allProducts = try candidates.first.map(products(in:)) ?? []
        var seenProducts = Set<VisibleProductPrice>()
        let deduplicatedProducts = allProducts.filter {
            seenProducts.insert($0).inserted
        }
        let products = Array(deduplicatedProducts.prefix(maximumProductCount))

        return VisibleProductPriceResult(
            appStoreID: appStoreID,
            storefrontCode: storefront,
            products: products,
            observedAt: observedAt,
            isPotentiallyIncomplete: true,
            isTruncated: deduplicatedProducts.count > maximumProductCount
        )
    }

    private static func request(
        appStoreID: Int64,
        storefrontCode: String
    ) throws -> URLRequest {
        guard let url = URL(
            string: "https://apps.apple.com/\(storefrontCode)/app/id\(appStoreID)"
        ) else {
            throw VisibleProductPricingError.malformedResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                + "Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        return request
    }

    private static func products(
        in annotation: [String: Any]
    ) throws -> [VisibleProductPrice] {
        var products: [VisibleProductPrice] = []
        if let items = annotation["items"] as? [[String: Any]] {
            for item in items {
                guard let rawPairs = item["textPairs"] else { continue }
                guard let pairs = rawPairs as? [Any] else {
                    throw VisibleProductPricingError.malformedResponse
                }

                for rawPair in pairs {
                    guard let pair = rawPair as? [Any],
                          pair.count == 2,
                          let name = stringValue(pair[0]),
                          let displayPrice = stringValue(pair[1]) else {
                        throw VisibleProductPricingError.malformedResponse
                    }
                    products.append(
                        VisibleProductPrice(
                            name: name,
                            displayPrice: displayPrice
                        )
                    )
                }
            }
        }
        if !products.isEmpty {
            return products
        }

        for item in annotation["items_V3"] as? [[String: Any]] ?? [] {
            guard stringValue(item["$kind"]) == "textPair" else { continue }
            guard let name = stringValue(item["leadingText"]),
                  let displayPrice = stringValue(item["trailingText"]) else {
                throw VisibleProductPricingError.malformedResponse
            }
            products.append(
                VisibleProductPrice(
                    name: name,
                    displayPrice: displayPrice
                )
            )
        }
        return products
    }

    private static func serializedServerData(from html: String) -> String? {
        let pattern = #"<script[^>]*id=["']serialized-server-data["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[captureRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collectProductAnnotations(
        in value: Any,
        into matches: inout [[String: Any]]
    ) {
        guard matches.count < 2 else { return }
        if let dictionary = value as? [String: Any] {
            if isProductAnnotation(dictionary) {
                matches.append(dictionary)
            }
            for child in dictionary.values {
                collectProductAnnotations(in: child, into: &matches)
                guard matches.count < 2 else { return }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                collectProductAnnotations(in: child, into: &matches)
                guard matches.count < 2 else { return }
            }
        }
    }

    private static func containsAppLockup(
        in value: Any,
        appStoreID: Int64
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            if stringValue(dictionary["$kind"]) == "Lockup",
               stringValue(dictionary["adamId"]) == String(appStoreID) {
                return true
            }
            return dictionary.values.contains {
                containsAppLockup(in: $0, appStoreID: appStoreID)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                containsAppLockup(in: $0, appStoreID: appStoreID)
            }
        }
        return false
    }

    private static func isProductAnnotation(
        _ dictionary: [String: Any]
    ) -> Bool {
        guard stringValue(dictionary["$kind"]) == "Annotation" else {
            return false
        }
        let hasLegacyPairs = (dictionary["items"] as? [[String: Any]])?
            .contains { $0["textPairs"] is [Any] } == true
        let hasV3Pairs = (dictionary["items_V3"] as? [[String: Any]])?
            .contains { stringValue($0["$kind"]) == "textPair" } == true
        return hasLegacyPairs || hasV3Pairs
    }

    private static func htmlDecoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validatedStorefrontCode(
        _ storefrontCode: String
    ) throws -> String {
        let normalizedCode = StorefrontCatalog.normalizedStorefrontCode(storefrontCode)
        guard normalizedCode.count == 2,
              normalizedCode.unicodeScalars.allSatisfy(
                CharacterSet.lowercaseLetters.contains
              ) else {
            throw VisibleProductPricingError.invalidStorefront
        }
        return normalizedCode
    }
}
