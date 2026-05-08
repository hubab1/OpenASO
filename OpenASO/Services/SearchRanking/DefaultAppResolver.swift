import Foundation

final class DefaultAppResolver: AppResolver {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        guard appStoreID > 0 else {
            throw OpenASOError.invalidAppStoreID
        }

        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(appStoreID)),
            URLQueryItem(name: "country", value: storefrontCode.lowercased())
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let data = try await validatedData(for: request, using: httpClient)

        guard let response = try? Self.decoder.decode(ITunesAppResponse.self, from: data) else {
            throw OpenASOError.decodingFailed
        }

        guard let app = response.results.first else {
            throw OpenASOError.appNotFound
        }

        return app.resolvedApp
    }

    func searchApps(named query: String, storefrontCode: String, limit: Int = 25) async throws -> [ResolvedApp] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw OpenASOError.emptyQuery
        }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmedQuery),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: storefrontCode.lowercased()),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let data = try await validatedData(for: request, using: httpClient)

        guard let response = try? Self.decoder.decode(ITunesAppResponse.self, from: data) else {
            throw OpenASOError.decodingFailed
        }

        return response.results.map(\.resolvedApp)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct ITunesAppResponse: Decodable {
    let results: [ITunesAppPayload]
}

private struct ITunesAppPayload: Decodable {
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
    let languageCodesISO2A: [String]?
    let sellerUrl: String?
    let trackViewUrl: String?
    let screenshotUrls: [String]?
    let ipadScreenshotUrls: [String]?
    let appletvScreenshotUrls: [String]?

    var resolvedApp: ResolvedApp {
        ResolvedApp(
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
            supportedLanguageCodes: languageCodesISO2A ?? [],
            sellerURLString: sellerUrl,
            trackViewURLString: trackViewUrl,
            screenshotURLs: screenshotUrls ?? [],
            ipadScreenshotURLs: ipadScreenshotUrls ?? [],
            appletvScreenshotURLs: appletvScreenshotUrls ?? [],
            defaultPlatform: .iphone
        )
    }
}
