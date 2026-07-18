import Foundation
import Testing
@testable import OpenASO

@MainActor
struct AppStoreWebRankingProviderTests {
    @Test
    func formsExactRequestAndParsesOnlyTheOrderedSearchShelf() async throws {
        let client = MockHTTPClient { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.scheme == "https")
            #expect(components.host == "apps.apple.com")
            #expect(components.path == "/gb/iphone/search")
            #expect(components.queryItems == [URLQueryItem(name: "term", value: "budget planner")])
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
            #expect(request.value(forHTTPHeaderField: "Accept")?.contains("text/html") == true)
            #expect(request.timeoutInterval == 20)

            return (
                Self.orderedFixture,
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }

        let provider = AppStoreWebRankingProvider(httpClient: client)
        let page = try await provider.search(
            keyword: "  budget planner\n",
            storefrontCode: " GB ",
            platform: .iphone,
            limit: 2
        )

        #expect(page.source == .appStoreWeb)
        #expect(page.fallbackContext == nil)
        #expect(page.items.map(\.appStoreID) == [10, 20])
        #expect(page.items.map(\.position) == [1, 2])
        #expect(page.items[0].name == "First App")
        #expect(page.items[0].bundleID == "com.example.first")
        #expect(page.items[0].sellerName == "Example Ltd")
        #expect(page.items[0].iconURLString == "https://example.com/icon/100x100bb.jpg")
        #expect(page.items[0].screenshotURLs == ["https://example.com/phone/1200x2400bb.jpg"])
        #expect(page.items[0].ipadScreenshotURLs == ["https://example.com/pad/2048x2732bb.jpg"])
        #expect(page.items[0].ratingCount == 105_000)
        #expect(page.items[0].averageRating == 4.8)
        #expect(page.items[1].name == "Event App")
        #expect(page.items[1].ratingCount == nil)
        #expect(page.items.allSatisfy { $0.platform == .iphone })
    }

    @Test
    func formsPlatformSpecificSearchPaths() async throws {
        var requestedPaths: [String] = []
        var returnedPlatforms: [AppPlatform] = []
        let client = MockHTTPClient { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path())
            let platform = try #require(url.pathComponents.dropLast().last)
            return (
                Self.singleResultFixture(platform: platform),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let provider = AppStoreWebRankingProvider(httpClient: client)

        returnedPlatforms.append(try await provider.search(
            keyword: "notes", storefrontCode: "us", platform: .iphone, limit: 1
        ).items[0].platform)
        returnedPlatforms.append(try await provider.search(
            keyword: "notes", storefrontCode: "us", platform: .ipad, limit: 1
        ).items[0].platform)
        returnedPlatforms.append(try await provider.search(
            keyword: "notes", storefrontCode: "us", platform: .mac, limit: 1
        ).items[0].platform)

        #expect(requestedPaths == [
            "/us/iphone/search",
            "/us/ipad/search",
            "/us/mac/search",
        ])
        #expect(returnedPlatforms == [.iphone, .ipad, .mac])
    }

    @Test
    func validEmptySearchDoesNotInvokeFallback() async throws {
        let client = MockHTTPClient { request in
            let url = try #require(request.url)
            return (
                Self.emptyFixture(platform: "iphone"),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let primary = AppStoreWebRankingProvider(httpClient: client)
        let fallback = ScriptedRankingProvider(behavior: .page(Self.fallbackPage))
        let provider = PrimaryFallbackSearchRankingProvider(primary: primary, fallback: fallback)

        let page = try await provider.search(
            keyword: "notes",
            storefrontCode: "us",
            platform: .iphone,
            limit: 10
        )

        #expect(page.items.isEmpty)
        #expect(page.source == .appStoreWeb)
        #expect(await fallback.callCount == 0)
    }

    @Test
    func rejectsDecoyShelvesAndChangedAuthoritativeShapes() async throws {
        let decoyClient = MockHTTPClient { request in
            let url = try #require(request.url)
            return (
                Self.decoyOnlyFixture,
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let changedItemClient = MockHTTPClient { request in
            let url = try #require(request.url)
            return (
                Self.changedItemFixture,
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let truncatedClient = MockHTTPClient { request in
            let url = try #require(request.url)
            return (
                Data(#"<script id="serialized-server-data">{"data":[</script>"#.utf8),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let incompleteShelfClient = MockHTTPClient { request in
            let url = try #require(request.url)
            return (
                Self.incompleteShelfFixture,
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }

        await Self.expectResponseFailure(.authoritativeShelfMissing) {
            _ = try await AppStoreWebRankingProvider(httpClient: decoyClient).search(
                keyword: "notes",
                storefrontCode: "us",
                platform: .iphone,
                limit: 10
            )
        }
        await Self.expectResponseFailure(.malformedSearchResult) {
            _ = try await AppStoreWebRankingProvider(httpClient: changedItemClient).search(
                keyword: "notes",
                storefrontCode: "us",
                platform: .iphone,
                limit: 10
            )
        }
        await Self.expectResponseFailure(.decodingFailed) {
            _ = try await AppStoreWebRankingProvider(httpClient: truncatedClient).search(
                keyword: "notes",
                storefrontCode: "us",
                platform: .iphone,
                limit: 10
            )
        }
        await Self.expectResponseFailure(.truncatedResults) {
            _ = try await AppStoreWebRankingProvider(httpClient: incompleteShelfClient).search(
                keyword: "notes",
                storefrontCode: "us",
                platform: .iphone,
                limit: 2
            )
        }
    }

    @Test
    func fallsBackOnlyForRecognizedPrimaryFailures() async throws {
        let recognizedFailures: [ScriptedRankingProvider.Behavior] = [
            .urlError(.cannotConnectToHost),
            .httpStatus(503),
            .response(.decodingFailed),
            .response(.authoritativeShelfMissing),
            .response(.truncatedResults),
        ]

        for failure in recognizedFailures {
            let primary = ScriptedRankingProvider(behavior: failure)
            let fallback = ScriptedRankingProvider(behavior: .page(Self.fallbackPage))
            let provider = PrimaryFallbackSearchRankingProvider(primary: primary, fallback: fallback)

            let page = try await provider.search(
                keyword: "notes",
                storefrontCode: "us",
                platform: .iphone,
                limit: 10
            )

            #expect(page.source == .iTunesFallback)
            #expect(page.fallbackContext?.provider == .appStoreWeb)
            #expect(await fallback.callCount == 1)
        }

        let unknownPrimary = ScriptedRankingProvider(behavior: .unknown)
        let unusedFallback = ScriptedRankingProvider(behavior: .page(Self.fallbackPage))
        let conservativeProvider = PrimaryFallbackSearchRankingProvider(
            primary: unknownPrimary,
            fallback: unusedFallback
        )
        do {
            _ = try await conservativeProvider.search(
                keyword: "notes",
                storefrontCode: "us",
                platform: .iphone,
                limit: 10
            )
            Issue.record("Expected the unknown primary failure to propagate.")
        } catch is UnknownRankingProviderError {
            // Expected: unknown errors are not assumed to be transport failures.
        }
        #expect(await unusedFallback.callCount == 0)
    }

    @Test
    func cancellationDeadlineAndValidationNeverInvokeFallback() async throws {
        for behavior in [
            ScriptedRankingProvider.Behavior.cancellation,
            .urlError(.timedOut),
        ] {
            let primary = ScriptedRankingProvider(behavior: behavior)
            let fallback = ScriptedRankingProvider(behavior: .page(Self.fallbackPage))
            let provider = PrimaryFallbackSearchRankingProvider(primary: primary, fallback: fallback)

            do {
                _ = try await provider.search(
                    keyword: "notes",
                    storefrontCode: "us",
                    platform: .iphone,
                    limit: 10
                )
                Issue.record("Expected cancellation or deadline to propagate.")
            } catch {
                if case .urlError(.timedOut) = behavior {
                    #expect((error as? URLError)?.code == .timedOut)
                } else {
                    #expect(error is CancellationError)
                }
            }
            #expect(await fallback.callCount == 0)
        }

        let neverPrimary = ScriptedRankingProvider(behavior: .page(Self.fallbackPage))
        let neverFallback = ScriptedRankingProvider(behavior: .page(Self.fallbackPage))
        let provider = PrimaryFallbackSearchRankingProvider(primary: neverPrimary, fallback: neverFallback)
        let invalidInputs: [(String, String, Int)] = [
            ("   ", "us", 10),
            ("notes", "not-a-storefront", 10),
            ("notes", "us", 0),
            ("notes", "us", SearchRankingCrawl.fullKeywordRankingLimit + 1),
        ]
        for (keyword, storefront, limit) in invalidInputs {
            do {
                _ = try await provider.search(
                    keyword: keyword,
                    storefrontCode: storefront,
                    platform: .iphone,
                    limit: limit
                )
                Issue.record("Expected request validation to fail.")
            } catch {
                #expect(error is OpenASOError || error is SearchRankingProviderError)
            }
        }
        #expect(await neverPrimary.callCount == 0)
        #expect(await neverFallback.callCount == 0)
    }

    @Test
    func macPrimaryFailureUsesTheMacSoftwareFallback() async throws {
        let primary = ScriptedRankingProvider(behavior: .httpStatus(503))
        let fallbackClient = MockHTTPClient { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://itunes.apple.com/search?term=notes&entity=macSoftware&country=us&limit=10")
            return (
                Data(#"{"results":[]}"#.utf8),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let fallback = ITunesSearchFallbackProvider(httpClient: fallbackClient)
        let provider = PrimaryFallbackSearchRankingProvider(primary: primary, fallback: fallback)

        let page = try await provider.search(
            keyword: "notes",
            storefrontCode: "us",
            platform: .mac,
            limit: 10
        )

        #expect(page.source == .iTunesFallback)
        #expect(page.items.isEmpty)
        #expect(page.fallbackContext == SearchRankingFailureContext(
            provider: .appStoreWeb,
            category: .httpStatus(503)
        ))
    }

    @Test
    func explicitlyUnsupportedFallbackSkipsProviderAndKeepsRedactedPrimaryContext() async throws {
        let primary = ScriptedRankingProvider(behavior: .urlError(.cannotConnectToHost))
        let fallback = ScriptedRankingProvider(behavior: .page(Self.fallbackPage))
        let provider = PrimaryFallbackSearchRankingProvider(
            primary: primary,
            fallback: fallback,
            fallbackSupportsPlatform: { _ in false }
        )

        do {
            _ = try await provider.search(
                keyword: "sensitive customer query",
                storefrontCode: "us",
                platform: .mac,
                limit: 10
            )
            Issue.record("Expected the explicitly unsupported fallback to be skipped.")
        } catch let error as SearchRankingProviderError {
            guard case .fallbackUnavailable(let platform, let primaryContext) = error else {
                Issue.record("Expected fallbackUnavailable, received \(error).")
                return
            }
            #expect(platform == .mac)
            #expect(primaryContext == SearchRankingFailureContext(
                provider: .appStoreWeb,
                category: .transport(code: URLError.Code.cannotConnectToHost.rawValue)
            ))
            #expect(!error.localizedDescription.contains("sensitive customer query"))
        }

        #expect(await fallback.callCount == 0)
    }

    @Test
    func doubleFailurePreservesOnlyRedactedContexts() async throws {
        let primary = ScriptedRankingProvider(behavior: .urlError(.cannotConnectToHost))
        let fallback = ScriptedRankingProvider(
            behavior: .openASO(.providerUnavailable("secret-token=do-not-report"))
        )
        let provider = PrimaryFallbackSearchRankingProvider(primary: primary, fallback: fallback)

        do {
            _ = try await provider.search(
                keyword: "sensitive customer query",
                storefrontCode: "us",
                platform: .iphone,
                limit: 10
            )
            Issue.record("Expected both providers to fail.")
        } catch let error as SearchRankingProviderError {
            guard case .allProvidersFailed(let primaryContext, let fallbackContext) = error else {
                Issue.record("Expected allProvidersFailed, received \(error).")
                return
            }
            #expect(primaryContext == SearchRankingFailureContext(
                provider: .appStoreWeb,
                category: .transport(code: URLError.Code.cannotConnectToHost.rawValue)
            ))
            #expect(fallbackContext == SearchRankingFailureContext(
                provider: .iTunesFallback,
                category: .provider
            ))
            #expect(!error.localizedDescription.contains("sensitive customer query"))
            #expect(!error.localizedDescription.contains("secret-token"))
        }
    }

    private static func expectResponseFailure(
        _ expected: SearchRankingResponseFailure,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected response failure \(expected.rawValue).")
        } catch let error as SearchRankingProviderError {
            guard case .responseFailure(let actual) = error else {
                Issue.record("Expected responseFailure, received \(error).")
                return
            }
            #expect(actual == expected)
        } catch {
            Issue.record("Expected SearchRankingProviderError, received \(error).")
        }
    }

    private static func emptyFixture(platform: String) -> Data {
        Data("""
        <script type="application/json" id="serialized-server-data">
        {"data":[{"intent":{"term":"notes","storefront":"us","platform":"\(platform)","$kind":"SearchResultsPageIntent"},"data":{"$kind":"SearchResultsPage","nextPage":null,"shelves":[{"id":"SearchResults.shelfId","$kind":"Shelf","contentType":"searchResult","items":[]}]}}]}
        </script>
        """.utf8)
    }

    private static func singleResultFixture(platform: String) -> Data {
        Data("""
        <script type="application/json" id="serialized-server-data">
        {"data":[{"intent":{"term":"notes","storefront":"us","platform":"\(platform)","$kind":"SearchResultsPageIntent"},"data":{"$kind":"SearchResultsPage","shelves":[{"id":"SearchResults.shelfId","$kind":"Shelf","contentType":"searchResult","items":[{"$kind":"AppSearchResult","resultType":"content","lockup":{"adamId":"10","title":"Notes"}}]}]}}]}
        </script>
        """.utf8)
    }

    private static let orderedFixture = Data("""
    <html><script type="application/json" id="serialized-server-data">
    {"data":[{"intent":{"term":"budget planner","storefront":"gb","platform":"iphone","$kind":"SearchResultsPageIntent"},"data":{"$kind":"SearchResultsPage","shelves":[
      {"id":"recommendations","$kind":"Shelf","contentType":"searchResult","items":[{"$kind":"AppSearchResult","resultType":"content","lockup":{"adamId":"999","title":"Decoy App"}}]},
      {"id":"SearchResults.shelfId","$kind":"Shelf","contentType":"searchResult","items":[
        {"$kind":"AppSearchResult","resultType":"content","lockup":{"adamId":"10","bundleId":"com.example.first","title":"First App","subtitle":"Plan things","developerName":"Example Ltd","rating":4.8,"ratingCount":"105000","icon":{"template":"https://example.com/icon/{w}x{h}{c}.{f}","width":1024,"height":1024},"screenshots":[{"artwork":[{"template":"https://example.com/phone/{w}x{h}{c}.{f}","width":1200,"height":2400}],"mediaPlatform":{"appPlatform":"phone"}},{"artwork":[{"template":"https://example.com/pad/{w}x{h}{c}.{f}","width":2048,"height":2732}],"mediaPlatform":{"appPlatform":"pad"}}]}},
        {"$kind":"EditorialSearchResult","resultType":"editorial"},
        {"$kind":"AppSearchResult","resultType":"content","lockup":{"adamId":"10","title":"Duplicate Must Not Win"}},
        {"$kind":"AppEventSearchResult","resultType":"appEvent","lockup":{"adamId":20,"title":"Event App","ratingCount":"2.4K"}},
        {"$kind":"AppSearchResult","resultType":"content","lockup":{"adamId":"30","title":"Beyond Limit"}}
      ]}
    ]}}]}
    </script></html>
    """.utf8)

    private static let decoyOnlyFixture = Data("""
    <script id="serialized-server-data">
    {"data":[{"intent":{"term":"notes","storefront":"us","platform":"iphone","$kind":"SearchResultsPageIntent"},"data":{"$kind":"SearchResultsPage","shelves":[{"id":"recommendations","$kind":"Shelf","contentType":"searchResult","items":[]}]}}]}
    </script>
    """.utf8)

    private static let changedItemFixture = Data("""
    <script id="serialized-server-data">
    {"data":[{"intent":{"term":"notes","storefront":"us","platform":"iphone","$kind":"SearchResultsPageIntent"},"data":{"$kind":"SearchResultsPage","shelves":[{"id":"SearchResults.shelfId","$kind":"Shelf","contentType":"searchResult","items":[{"$kind":"FutureSearchResult","resultType":"content","lockup":{"adamId":"10","title":"Unknown Shape"}}]}]}}]}
    </script>
    """.utf8)

    private static let incompleteShelfFixture = Data("""
    <script id="serialized-server-data">
    {"data":[{"intent":{"term":"notes","storefront":"us","platform":"iphone","$kind":"SearchResultsPageIntent"},"data":{"$kind":"SearchResultsPage","nextPage":{"contentOffsetWithinResultsShelf":1},"shelves":[{"id":"SearchResults.shelfId","$kind":"Shelf","contentType":"searchResult","items":[{"$kind":"AppSearchResult","resultType":"content","lockup":{"adamId":"10","title":"First App"}}]}]}}]}
    </script>
    """.utf8)

    private static let fallbackPage = SearchRankingPage(
        items: [SearchRankingItem(
            position: 1,
            appStoreID: 42,
            bundleID: "com.example.fallback",
            name: "Fallback App",
            sellerName: "Example",
            platform: .iphone
        )],
        source: .iTunesFallback
    )
}

private actor ScriptedRankingProvider: SearchRankingProvider {
    enum Behavior: Sendable {
        case page(SearchRankingPage)
        case urlError(URLError.Code)
        case httpStatus(Int)
        case response(SearchRankingResponseFailure)
        case openASO(OpenASOError)
        case cancellation
        case unknown
    }

    private let behavior: Behavior
    private(set) var callCount = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        callCount += 1
        switch behavior {
        case .page(let page):
            return page
        case .urlError(let code):
            throw URLError(code)
        case .httpStatus(let statusCode):
            throw SearchRankingProviderError.httpStatus(statusCode)
        case .response(let failure):
            throw SearchRankingProviderError.responseFailure(failure)
        case .openASO(let error):
            throw error
        case .cancellation:
            throw CancellationError()
        case .unknown:
            throw UnknownRankingProviderError()
        }
    }
}

private struct UnknownRankingProviderError: Error {}
