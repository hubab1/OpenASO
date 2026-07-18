import Foundation

final class AppStoreWebRankingProvider: SearchRankingProvider {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
    }

    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        let validatedRequest = try SearchRankingRequestValidator.validate(
            keyword: keyword,
            storefrontCode: storefrontCode,
            platform: platform,
            limit: limit
        )
        let request = try Self.urlRequest(for: validatedRequest)

        try Task.checkCancellation()
        let (data, response) = try await httpClient.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchRankingProviderError.responseFailure(.nonHTTPResponse)
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw SearchRankingProviderError.httpStatus(httpResponse.statusCode)
        }

        let parsedResults = try Self.parse(data, request: validatedRequest)
        switch parsedResults {
        case .complete(let items):
            return SearchRankingPage(items: items, source: .appStoreWeb)
        case .requiresHydration(let orderedAppStoreIDs):
            let items = try await hydrate(
                orderedAppStoreIDs: orderedAppStoreIDs,
                request: validatedRequest
            )
            return SearchRankingPage(items: items, source: .appStoreWeb)
        }
    }

    private func hydrate(
        orderedAppStoreIDs: [Int64],
        request: ValidatedSearchRankingRequest
    ) async throws -> [SearchRankingItem] {
        guard !orderedAppStoreIDs.isEmpty else { return [] }
        guard orderedAppStoreIDs.count <= SearchRankingCrawl.fullKeywordRankingLimit else {
            throw SearchRankingProviderError.responseFailure(.pageShapeChanged)
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [
            URLQueryItem(
                name: "id",
                value: orderedAppStoreIDs.map(String.init).joined(separator: ",")
            ),
            URLQueryItem(
                name: "entity",
                value: ITunesRankingSupport.entity(for: request.platform)
            ),
            URLQueryItem(name: "country", value: request.storefrontCode),
        ]
        guard let url = components.url else {
            throw SearchRankingProviderError.responseFailure(.pageShapeChanged)
        }

        var lookupRequest = URLRequest(url: url, timeoutInterval: 20)
        lookupRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        try Task.checkCancellation()
        let data = try await validatedData(for: lookupRequest, using: httpClient)
        try Task.checkCancellation()

        let payloads: [ITunesRankingPayload]
        do {
            payloads = try ITunesRankingSupport.decode(data)
        } catch {
            throw SearchRankingProviderError.responseFailure(.decodingFailed)
        }

        let requestedIDs = Set(orderedAppStoreIDs)
        var payloadByID: [Int64: ITunesRankingPayload] = [:]
        for payload in payloads {
            guard requestedIDs.contains(payload.trackId),
                  payload.trackId > 0,
                  payloadByID.updateValue(payload, forKey: payload.trackId) == nil else {
                throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
            }
        }
        guard payloadByID.count == orderedAppStoreIDs.count else {
            throw SearchRankingProviderError.responseFailure(.lookupHydrationIncomplete)
        }

        try Task.checkCancellation()
        return try orderedAppStoreIDs.enumerated().map { index, appStoreID in
            guard let payload = payloadByID[appStoreID] else {
                throw SearchRankingProviderError.responseFailure(.lookupHydrationIncomplete)
            }
            return payload.searchRankingItem(
                position: index + 1,
                platform: request.platform
            )
        }
    }

    private static func urlRequest(
        for request: ValidatedSearchRankingRequest
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/\(request.storefrontCode)/\(pathComponent(for: request.platform))/search"
        components.queryItems = [URLQueryItem(name: "term", value: request.keyword)]

        guard let url = components.url else {
            throw SearchRankingProviderError.invalidStorefront
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: 20)
        urlRequest.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        urlRequest.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        return urlRequest
    }

    private static func pathComponent(for platform: AppPlatform) -> String {
        switch platform {
        case .iphone:
            "iphone"
        case .ipad:
            "ipad"
        case .mac:
            "mac"
        }
    }

    private static func parse(
        _ data: Data,
        request: ValidatedSearchRankingRequest
    ) throws -> ParsedSearchResults {
        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchRankingProviderError.responseFailure(.decodingFailed)
        }

        let serializedMatches = serializedServerDataMatches(in: html)
        guard !serializedMatches.isEmpty else {
            throw SearchRankingProviderError.responseFailure(.serializedServerDataMissing)
        }
        guard serializedMatches.count == 1 else {
            throw SearchRankingProviderError.responseFailure(.pageShapeChanged)
        }

        let jsonData = Data(htmlDecoded(serializedMatches[0]).utf8)
        let envelope: SearchResultsEnvelope
        do {
            envelope = try JSONDecoder().decode(SearchResultsEnvelope.self, from: jsonData)
        } catch {
            throw SearchRankingProviderError.responseFailure(.decodingFailed)
        }

        let expectedPlatform = pathComponent(for: request.platform)
        let matchingEntries = envelope.data.filter { entry in
            entry.intent?.kind == "SearchResultsPageIntent"
                && entry.intent?.term == request.keyword
                && entry.intent?.storefront.lowercased() == request.storefrontCode
                && entry.intent?.platform == expectedPlatform
        }
        guard !matchingEntries.isEmpty else {
            throw SearchRankingProviderError.responseFailure(.requestIntentMissing)
        }
        guard matchingEntries.count == 1 else {
            throw SearchRankingProviderError.responseFailure(.requestIntentAmbiguous)
        }

        let page = matchingEntries[0].page
        guard page.kind == "SearchResultsPage", let shelves = page.shelves else {
            throw SearchRankingProviderError.responseFailure(.pageShapeChanged)
        }

        let authoritativeShelves = shelves.filter { shelf in
            shelf.id == "SearchResults.shelfId"
                && shelf.kind == "Shelf"
                && shelf.contentType == "searchResult"
        }
        guard !authoritativeShelves.isEmpty else {
            throw SearchRankingProviderError.responseFailure(.authoritativeShelfMissing)
        }
        guard authoritativeShelves.count == 1 else {
            throw SearchRankingProviderError.responseFailure(.authoritativeShelfAmbiguous)
        }
        guard let results = authoritativeShelves[0].items else {
            throw SearchRankingProviderError.responseFailure(.pageShapeChanged)
        }

        var seenAppStoreIDs = Set<Int64>()
        var items: [SearchRankingItem] = []
        for result in results {
            switch result.kind {
            case "AppSearchResult":
                guard result.resultType == "content" else {
                    if result.resultType == "ad" { continue }
                    throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
                }
                fallthrough
            case "AppEventSearchResult":
                if result.kind == "AppEventSearchResult", result.resultType != "appEvent" {
                    throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
                }
                guard let lockup = result.lockup,
                      let appStoreID = lockup.appStoreID,
                      appStoreID > 0 else {
                    throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
                }
                guard seenAppStoreIDs.insert(appStoreID).inserted else { continue }
                guard let name = nonEmpty(lockup.title) else {
                    throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
                }

                let screenshots = screenshotURLs(from: lockup.screenshots)
                items.append(SearchRankingItem(
                    position: items.count + 1,
                    appStoreID: appStoreID,
                    bundleID: nonEmpty(lockup.bundleID),
                    name: name,
                    subtitle: nonEmpty(lockup.subtitle),
                    sellerName: nonEmpty(lockup.developerName),
                    iconURLString: artworkURLString(from: lockup.icon, width: 100, height: 100),
                    screenshotURLs: screenshots.iphone,
                    ipadScreenshotURLs: screenshots.ipad,
                    ratingCount: ratingCount(from: lockup.ratingCount),
                    averageRating: lockup.rating,
                    platform: request.platform
                ))
            case "EditorialSearchResult",
                 "DeveloperSearchResult",
                 "AppBundleSearchResult",
                 "InAppSearchResult",
                 "GroupingSearchResult":
                continue
            default:
                throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
            }
        }

        if items.count >= request.limit {
            return .complete(Array(items.prefix(request.limit)))
        }

        guard page.hasNextPageField else {
            throw SearchRankingProviderError.responseFailure(.pageShapeChanged)
        }
        guard let nextPage = page.nextPage else {
            return .complete(items)
        }
        guard let references = nextPage.results else {
            throw SearchRankingProviderError.responseFailure(.truncatedResults)
        }

        var seenReferenceIDs = Set<Int64>()
        var orderedAppStoreIDs: [Int64] = []
        for reference in references {
            switch reference.type {
            case "apps":
                guard let appStoreID = reference.appStoreID, appStoreID > 0 else {
                    throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
                }
                if seenReferenceIDs.insert(appStoreID).inserted {
                    orderedAppStoreIDs.append(appStoreID)
                }
            case "editorial-items", "app-bundles", "in-apps":
                continue
            default:
                throw SearchRankingProviderError.responseFailure(.malformedSearchResult)
            }
        }

        let renderedAppStoreIDs = items.map(\.appStoreID)
        let completeOrderedAppStoreIDs: [Int64]
        // Apple emits either the complete order or a continuation after the
        // rendered shelf. Reject partial overlap because its order is ambiguous.
        if orderedAppStoreIDs.starts(with: renderedAppStoreIDs) {
            completeOrderedAppStoreIDs = orderedAppStoreIDs
        } else {
            let renderedIDSet = Set(renderedAppStoreIDs)
            guard renderedIDSet.isDisjoint(with: orderedAppStoreIDs) else {
                throw SearchRankingProviderError.responseFailure(.pageShapeChanged)
            }
            completeOrderedAppStoreIDs = renderedAppStoreIDs + orderedAppStoreIDs
        }
        if completeOrderedAppStoreIDs.count == renderedAppStoreIDs.count {
            return .complete(items)
        }

        return .requiresHydration(
            Array(completeOrderedAppStoreIDs.prefix(request.limit))
        )
    }

    private static func serializedServerDataMatches(in html: String) -> [String] {
        let pattern = #"<script[^>]*id=["']serialized-server-data["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let fullRange = NSRange(html.startIndex ..< html.endIndex, in: html)
        return regex.matches(in: html, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: html) else {
                return nil
            }
            return String(html[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    private static func screenshotURLs(
        from groups: [SearchResultsLockup.Screenshots]?
    ) -> (iphone: [String], ipad: [String]) {
        var iphone: [String] = []
        var ipad: [String] = []

        for group in groups ?? [] {
            let urls = deduplicated(group.artwork.compactMap {
                artworkURLString(from: $0, width: $0.width, height: $0.height)
            })
            switch group.mediaPlatform?.appPlatform {
            case "phone":
                iphone.append(contentsOf: urls)
            case "pad":
                ipad.append(contentsOf: urls)
            default:
                continue
            }
        }

        return (deduplicated(iphone), deduplicated(ipad))
    }

    private static func artworkURLString(
        from artwork: SearchResultsArtwork?,
        width: Int?,
        height: Int?
    ) -> String? {
        guard let artwork else { return nil }
        if let url = nonEmpty(artwork.url) {
            return url
        }
        guard var template = nonEmpty(artwork.template) else { return nil }

        template = template.replacingOccurrences(of: "{w}", with: String(width ?? artwork.width ?? 100))
        template = template.replacingOccurrences(of: "{h}", with: String(height ?? artwork.height ?? 100))
        template = template.replacingOccurrences(of: "{c}", with: "bb")
        template = template.replacingOccurrences(of: "{f}", with: "jpg")
        return template
    }

    private static func ratingCount(from value: SearchResultsScalar?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .integer(let count):
            return count >= 0 ? count : nil
        case .double(let count):
            guard count.isFinite, count >= 0, count <= Double(Int.max) else { return nil }
            return Int(count.rounded())
        case .string(let rawValue):
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
            guard !normalized.isEmpty,
                  normalized.allSatisfy(\.isNumber),
                  let count = Int(normalized),
                  count >= 0 else {
                return nil
            }
            return count
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct SearchResultsEnvelope: Decodable {
    let data: [SearchResultsEntry]
}

private struct SearchResultsEntry: Decodable {
    let intent: SearchResultsIntent?
    let page: SearchResultsPagePayload

    private enum CodingKeys: String, CodingKey {
        case intent
        case page = "data"
    }
}

private struct SearchResultsIntent: Decodable {
    let term: String
    let storefront: String
    let platform: String
    let kind: String

    private enum CodingKeys: String, CodingKey {
        case term
        case storefront
        case platform
        case kind = "$kind"
    }
}

private struct SearchResultsPagePayload: Decodable {
    let kind: String?
    let shelves: [SearchResultsShelf]?
    let nextPage: SearchResultsNextPage?
    let hasNextPageField: Bool

    private enum CodingKeys: String, CodingKey {
        case kind = "$kind"
        case shelves
        case nextPage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        shelves = try container.decodeIfPresent([SearchResultsShelf].self, forKey: .shelves)
        nextPage = try container.decodeIfPresent(SearchResultsNextPage.self, forKey: .nextPage)
        hasNextPageField = container.contains(.nextPage)
    }
}

private struct SearchResultsNextPage: Decodable {
    let results: [SearchResultsReference]?
}

private struct SearchResultsReference: Decodable {
    let appStoreID: Int64?
    let type: String

    private enum CodingKeys: String, CodingKey {
        case appStoreID = "id"
        case type
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        if let stringID = try? container.decode(String.self, forKey: .appStoreID) {
            appStoreID = Int64(stringID)
        } else {
            appStoreID = try? container.decode(Int64.self, forKey: .appStoreID)
        }
    }
}

private struct SearchResultsShelf: Decodable {
    let id: String?
    let kind: String?
    let contentType: String?
    let items: [SearchResultsItem]?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind = "$kind"
        case contentType
        case items
    }
}

private struct SearchResultsItem: Decodable {
    let kind: String?
    let resultType: String?
    let lockup: SearchResultsLockup?

    private enum CodingKeys: String, CodingKey {
        case kind = "$kind"
        case resultType
        case lockup
    }
}

private struct SearchResultsLockup: Decodable {
    struct Screenshots: Decodable {
        struct MediaPlatform: Decodable {
            let appPlatform: String?
        }

        let artwork: [SearchResultsArtwork]
        let mediaPlatform: MediaPlatform?
    }

    let appStoreID: Int64?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let developerName: String?
    let icon: SearchResultsArtwork?
    let screenshots: [Screenshots]?
    let rating: Double?
    let ratingCount: SearchResultsScalar?

    private enum CodingKeys: String, CodingKey {
        case appStoreID = "adamId"
        case bundleID = "bundleId"
        case title
        case subtitle
        case developerName
        case icon
        case screenshots
        case rating
        case ratingCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .appStoreID) {
            appStoreID = Int64(stringID)
        } else {
            appStoreID = try? container.decode(Int64.self, forKey: .appStoreID)
        }
        bundleID = try? container.decode(String.self, forKey: .bundleID)
        title = try? container.decode(String.self, forKey: .title)
        subtitle = try? container.decode(String.self, forKey: .subtitle)
        developerName = try? container.decode(String.self, forKey: .developerName)
        icon = try? container.decode(SearchResultsArtwork.self, forKey: .icon)
        screenshots = try? container.decode([Screenshots].self, forKey: .screenshots)
        rating = try? container.decode(Double.self, forKey: .rating)
        ratingCount = try? container.decode(SearchResultsScalar.self, forKey: .ratingCount)
    }
}

private struct SearchResultsArtwork: Decodable {
    let url: String?
    let template: String?
    let width: Int?
    let height: Int?
}

private enum SearchResultsScalar: Decodable {
    case integer(Int)
    case double(Double)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

private enum ParsedSearchResults {
    case complete([SearchRankingItem])
    case requiresHydration([Int64])
}
