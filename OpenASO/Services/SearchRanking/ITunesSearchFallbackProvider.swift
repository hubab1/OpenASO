import Foundation

final class ITunesSearchFallbackProvider: SearchRankingProvider {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func search(keyword: String, storefrontCode: String, platform: AppPlatform, limit: Int) async throws -> SearchRankingPage {
        let validatedRequest = try SearchRankingRequestValidator.validate(
            keyword: keyword,
            storefrontCode: storefrontCode,
            platform: platform,
            limit: limit
        )

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: validatedRequest.keyword),
            URLQueryItem(
                name: "entity",
                value: ITunesRankingSupport.entity(for: validatedRequest.platform)
            ),
            URLQueryItem(name: "country", value: validatedRequest.storefrontCode),
            URLQueryItem(name: "limit", value: String(validatedRequest.limit))
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let data = try await validatedData(for: request, using: httpClient)
        guard let payloads = try? ITunesRankingSupport.decode(data) else {
            throw OpenASOError.decodingFailed
        }

        let items = payloads.enumerated().map { index, payload in
            payload.searchRankingItem(
                position: index + 1,
                platform: validatedRequest.platform
            )
        }

        return SearchRankingPage(items: items, source: .iTunesFallback)
    }
}

enum ITunesRankingSupport {
    static func entity(for platform: AppPlatform) -> String {
        switch platform {
        case .iphone:
            "software"
        case .ipad:
            "iPadSoftware"
        case .mac:
            "macSoftware"
        }
    }

    static func decode(_ data: Data) throws -> [ITunesRankingPayload] {
        try decoder.decode(ITunesRankingResponse.self, from: data).results
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct ITunesRankingResponse: Decodable {
    let results: [ITunesRankingPayload]
}

struct ITunesRankingPayload: Decodable {
    let trackId: Int64
    let bundleId: String?
    let trackName: String
    let subtitle: String?
    let sellerName: String?
    let artworkUrl100: String?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?
    let version: String?
    let primaryGenreId: Int?
    let primaryGenreName: String?
    let description: String?
    let releaseNotes: String?
    let languageCodesISO2A: [String]?
    let screenshotUrls: [String]?
    let ipadScreenshotUrls: [String]?
    let appletvScreenshotUrls: [String]?
    let userRatingCount: Int?
    let averageUserRating: Double?

    func searchRankingItem(
        position: Int,
        platform: AppPlatform
    ) -> SearchRankingItem {
        SearchRankingItem(
            position: position,
            appStoreID: trackId,
            bundleID: bundleId,
            name: trackName,
            subtitle: subtitle,
            sellerName: sellerName,
            iconURLString: artworkUrl100,
            releaseDate: releaseDate,
            currentVersionReleaseDate: currentVersionReleaseDate,
            version: version,
            primaryGenreID: primaryGenreId,
            primaryGenreName: primaryGenreName,
            descriptionText: description,
            releaseNotes: releaseNotes,
            supportedLanguageCodes: languageCodesISO2A ?? [],
            screenshotURLs: screenshotUrls ?? [],
            ipadScreenshotURLs: ipadScreenshotUrls ?? [],
            appletvScreenshotURLs: appletvScreenshotUrls ?? [],
            ratingCount: userRatingCount,
            averageRating: averageUserRating,
            platform: platform
        )
    }
}
