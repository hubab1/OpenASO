import Foundation
import Testing
@testable import OpenASO

@MainActor
struct ITunesSearchFallbackProviderTests {
    @Test
    func returnsOrderedResultsFromITunesSearchAPI() async throws {
        let client = MockHTTPClient { request in
            #expect(request.url?.absoluteString.contains("itunes.apple.com/search") == true)
            #expect(URLComponents(
                url: try #require(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "entity" })?.value == "software")

            let payload = """
            {
              "results": [
                {
                  "trackId": 361309726,
                  "bundleId": "com.apple.Pages",
                  "trackName": "Pages: Create Documents",
                  "subtitle": "Documents that stand apart",
                  "sellerName": "Apple",
                  "artworkUrl100": "https://example.com/pages-100.png",
                  "releaseDate": "2010-04-01T20:36:57Z",
                  "currentVersionReleaseDate": "2026-04-09T17:00:45Z",
                  "languageCodesISO2A": ["EN", "FR"],
                  "screenshotUrls": ["https://example.com/pages-iphone-1.png"],
                  "ipadScreenshotUrls": ["https://example.com/pages-ipad-1.png"],
                  "averageUserRating": 4.65041,
                  "userRatingCount": 513197
                },
                {
                  "trackId": 842842640,
                  "bundleId": "com.google.Docs",
                  "trackName": "Google Docs",
                  "sellerName": "Google",
                  "artworkUrl100": "https://example.com/google-docs-100.png"
                }
              ]
            }
            """
            return (
                Data(payload.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }

        let provider = ITunesSearchFallbackProvider(httpClient: client)
        let page = try await provider.search(keyword: "pages", storefrontCode: "us", platform: .iphone, limit: 10)

        #expect(page.source == .iTunesFallback)
        #expect(page.items.count == 2)
        #expect(page.items[0].position == 1)
        #expect(page.items[1].position == 2)
        #expect(page.items[0].subtitle == "Documents that stand apart")
        #expect(page.items[0].iconURLString == "https://example.com/pages-100.png")
        #expect(page.items[0].releaseDate == Self.date("2010-04-01T20:36:57Z"))
        #expect(page.items[0].currentVersionReleaseDate == Self.date("2026-04-09T17:00:45Z"))
        #expect(page.items[0].averageRating == 4.65041)
        #expect(page.items[0].ratingCount == 513197)
        #expect(page.items[0].supportedLanguageCodes == ["EN", "FR"])
        #expect(page.items[0].screenshotURLs == ["https://example.com/pages-iphone-1.png"])
        #expect(page.items[0].ipadScreenshotURLs == ["https://example.com/pages-ipad-1.png"])
    }

    @Test
    func usesTheDocumentedEntityForEachRequestedPlatform() async throws {
        let scenarios: [(platform: AppPlatform, entity: String)] = [
            (.iphone, "software"),
            (.ipad, "iPadSoftware"),
            (.mac, "macSoftware"),
        ]

        for scenario in scenarios {
            let client = MockHTTPClient { request in
                let url = try #require(request.url)
                #expect(url.absoluteString == "https://itunes.apple.com/search?term=notes&entity=\(scenario.entity)&country=gb&limit=7")
                let payload = """
                {
                  "results": [
                    {
                      "trackId": 123,
                      "bundleId": "com.example.notes",
                      "trackName": "Notes",
                      "sellerName": "Example"
                    }
                  ]
                }
                """
                return (
                    Data(payload.utf8),
                    makeHTTPURLResponse(url: url, statusCode: 200)
                )
            }
            let provider = ITunesSearchFallbackProvider(httpClient: client)

            let page = try await provider.search(
                keyword: " notes ",
                storefrontCode: " GB ",
                platform: scenario.platform,
                limit: 7
            )

            #expect(page.source == .iTunesFallback)
            #expect(page.items.map(\.platform) == [scenario.platform])
        }
    }

    @Test
    func appIconStoreRequestsMZStaticArtworkAtRenderedPixelSize() {
        let apiURL = "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/3f/85/8b/icon.png/100x100bb.jpg"

        let sizedURL = AppIconStore.sizedArtworkURLString(apiURL, pixelSize: 120)

        #expect(sizedURL == "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/3f/85/8b/icon.png/120x120bb.jpg")
    }

    @Test
    func appIconStorePreservesMZStaticArtworkQueryWhenSizing() {
        let apiURL = "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/3f/85/8b/icon.png/100x100bb.jpg?source=search"

        let sizedURL = AppIconStore.sizedArtworkURLString(apiURL, pixelSize: 80)

        #expect(sizedURL == "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/3f/85/8b/icon.png/80x80bb.jpg?source=search")
    }

    @Test
    func appIconStoreLeavesNonMZStaticArtworkURLsUnchanged() {
        let iconURL = "https://example.com/pages-100.png"

        let sizedURL = AppIconStore.sizedArtworkURLString(iconURL, pixelSize: 120)

        #expect(sizedURL == iconURL)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
