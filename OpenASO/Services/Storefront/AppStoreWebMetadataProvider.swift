import Foundation

struct AppStoreWebMetadata: Sendable, Equatable {
    let appStoreID: Int64
    let storefront: String
    let name: String?
    let subtitle: String?
    let sellerName: String?
    let averageRating: Double?
    let ratingCount: Int?
    let ratingCounts: AppStoreRatingCounts?
    let screenshotGroups: [AppStoreWebScreenshotGroup]

    init(
        appStoreID: Int64,
        storefront: String,
        name: String?,
        subtitle: String?,
        sellerName: String?,
        averageRating: Double?,
        ratingCount: Int?,
        ratingCounts: AppStoreRatingCounts? = nil,
        screenshotGroups: [AppStoreWebScreenshotGroup]
    ) {
        self.appStoreID = appStoreID
        self.storefront = storefront
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.averageRating = averageRating
        self.ratingCount = ratingCount
        self.ratingCounts = ratingCounts
        self.screenshotGroups = screenshotGroups
    }
}

struct AppStoreWebScreenshotGroup: Sendable, Equatable {
    let platformRaw: String
    let displayTypeRaw: String
    let screenshots: [AppStoreWebScreenshot]
}

struct AppStoreWebScreenshot: Sendable, Equatable {
    let urlString: String
    let width: Int?
    let height: Int?
}

final class AppStoreWebMetadataProvider: Sendable {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
    }

    func fetch(appStoreID: Int64, storefrontCode: String) async throws -> AppStoreWebMetadata {
        let storefront = Self.normalizedStorefrontCode(storefrontCode)
        guard let url = URL(string: "https://apps.apple.com/\(storefront)/app/id\(appStoreID)") else {
            throw OpenASOError.invalidAppStoreID
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let data = try await validatedData(for: request, using: httpClient)
        return try Self.parse(data, appStoreID: appStoreID, storefrontCode: storefront)
    }

    static func parse(_ data: Data, appStoreID: Int64, storefrontCode: String) throws -> AppStoreWebMetadata {
        guard let html = String(data: data, encoding: .utf8),
              let serializedData = serializedServerData(from: html) else {
            throw OpenASOError.decodingFailed
        }

        let jsonData = Data(htmlDecoded(serializedData).utf8)
        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let pageData = primaryPageData(in: json),
              let lockup = primaryLockup(in: pageData, appStoreID: appStoreID) else {
            throw OpenASOError.decodingFailed
        }

        return AppStoreWebMetadata(
            appStoreID: appStoreID,
            storefront: normalizedStorefrontCode(storefrontCode),
            name: stringValue(pageData["title"]) ?? stringValue(lockup["title"]),
            subtitle: stringValue(lockup["subtitle"]) ?? stringValue(lockup["developerTagline"]),
            sellerName: stringValue(lockup["developerName"]) ?? stringValue(dictionary(lockup["developerAction"])?.value(forKey: "title")),
            averageRating: doubleValue(lockup["rating"]) ?? productRatingValue(in: pageData, key: "ratingAverage"),
            ratingCount: intValue(lockup["ratingCount"]) ?? productRatingCount(in: pageData),
            ratingCounts: productRatingCounts(in: pageData),
            screenshotGroups: screenshotGroups(in: pageData)
        )
    }

    private static func serializedServerData(from html: String) -> String? {
        let pattern = #"<script[^>]*id=["']serialized-server-data["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func primaryPageData(in json: [String: Any]) -> [String: Any]? {
        guard let dataEntries = json["data"] as? [[String: Any]] else {
            return nil
        }

        for entry in dataEntries {
            if let data = entry["data"] as? [String: Any],
               data["shelfMapping"] is [String: Any] || data["lockup"] is [String: Any] {
                return data
            }
        }
        return dataEntries.compactMap { $0["data"] as? [String: Any] }.first
    }

    private static func primaryLockup(in pageData: [String: Any], appStoreID: Int64) -> [String: Any]? {
        if let lockup = pageData["lockup"] as? [String: Any] {
            return lockup
        }

        let targetID = String(appStoreID)
        return firstDictionary(in: pageData) { dictionary in
            stringValue(dictionary["adamId"]) == targetID && stringValue(dictionary["$kind"]) == "Lockup"
        }
    }

    private static func screenshotGroups(in pageData: [String: Any]) -> [AppStoreWebScreenshotGroup] {
        guard let shelfMapping = pageData["shelfMapping"] as? [String: Any] else {
            return []
        }

        return shelfMapping.keys.sorted().compactMap { key in
            guard key.hasPrefix("product_media_"),
                  let shelf = shelfMapping[key] as? [String: Any],
                  let items = shelf["items"] as? [[String: Any]] else {
                return nil
            }

            let platformToken = key
                .replacingOccurrences(of: "product_media_", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let platformRaw = platformRawValue(for: platformToken)
            let screenshots = items.compactMap { item -> AppStoreWebScreenshot? in
                guard let artwork = artworkDictionary(in: item),
                      let urlString = artworkURLString(from: artwork) else {
                    return nil
                }
                return AppStoreWebScreenshot(
                    urlString: urlString,
                    width: intValue(artwork["width"]),
                    height: intValue(artwork["height"])
                )
            }

            guard !screenshots.isEmpty else { return nil }
            return AppStoreWebScreenshotGroup(
                platformRaw: platformRaw,
                displayTypeRaw: platformToken.isEmpty ? platformRaw : platformToken,
                screenshots: deduplicated(screenshots)
            )
        }
    }

    private static func artworkDictionary(in item: [String: Any]) -> [String: Any]? {
        if let screenshot = item["screenshot"] as? [String: Any] {
            return screenshot
        }
        if let artwork = item["artwork"] as? [String: Any] {
            return artwork
        }
        return firstDictionary(in: item) { dictionary in
            dictionary["template"] is String || dictionary["url"] is String
        }
    }

    private static func artworkURLString(from artwork: [String: Any]) -> String? {
        if let url = stringValue(artwork["url"]) {
            return url
        }
        guard var template = stringValue(artwork["template"]) else {
            return nil
        }

        let width = intValue(artwork["width"]).map(String.init) ?? "1242"
        let height = intValue(artwork["height"]).map(String.init) ?? "2688"
        template = template.replacingOccurrences(of: "{w}", with: width)
        template = template.replacingOccurrences(of: "{h}", with: height)
        template = template.replacingOccurrences(of: "{c}", with: "bb")
        template = template.replacingOccurrences(of: "{f}", with: "jpg")
        return template
    }

    private static func productRatingValue(in pageData: [String: Any], key: String) -> Double? {
        guard let ratingsItem = productRatingsItem(in: pageData) else {
            return nil
        }
        return doubleValue(ratingsItem[key])
    }

    private static func productRatingCount(in pageData: [String: Any]) -> Int? {
        guard let ratingsItem = productRatingsItem(in: pageData) else {
            return nil
        }
        return intValue(ratingsItem["totalNumberOfRatings"]) ?? intValue(ratingsItem["ratingCount"])
    }

    private static func productRatingCounts(in pageData: [String: Any]) -> AppStoreRatingCounts? {
        guard let ratingsItem = productRatingsItem(in: pageData),
              let values = intArrayValue(ratingsItem["ratingCounts"]) else {
            return nil
        }
        return AppStoreRatingCounts(appStoreDescendingCounts: values)
    }

    private static func productRatingsItem(in pageData: [String: Any]) -> [String: Any]? {
        guard let shelfMapping = pageData["shelfMapping"] as? [String: Any],
              let productRatings = shelfMapping["productRatings"] as? [String: Any],
              let items = productRatings["items"] as? [[String: Any]] else {
            return nil
        }
        return items.first
    }

    private static func firstDictionary(in value: Any, where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if predicate(dictionary) {
                return dictionary
            }

            for child in dictionary.values {
                if let match = firstDictionary(in: child, where: predicate) {
                    return match
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let match = firstDictionary(in: child, where: predicate) {
                    return match
                }
            }
        }
        return nil
    }

    private static func deduplicated(_ screenshots: [AppStoreWebScreenshot]) -> [AppStoreWebScreenshot] {
        var seen = Set<String>()
        return screenshots.filter { screenshot in
            seen.insert(screenshot.urlString).inserted
        }
    }

    private static func platformRawValue(for token: String) -> String {
        switch token {
        case "phone":
            return "iphone"
        case "pad":
            return "ipad"
        case "tv":
            return "tv"
        case "watch":
            return "watch"
        case "mac":
            return "mac"
        case "reality":
            return "vision"
        default:
            return token.isEmpty ? "iphone" : token
        }
    }

    private static func dictionary(_ value: Any?) -> NSDictionary? {
        value as? NSDictionary
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func intArrayValue(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any] else {
            return nil
        }
        let ints = values.compactMap(intValue)
        return ints.count == values.count ? ints : nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func normalizedStorefrontCode(_ storefrontCode: String) -> String {
        let normalized = storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "us" : normalized
    }

    private static func htmlDecoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
