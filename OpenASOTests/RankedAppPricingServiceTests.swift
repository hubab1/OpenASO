import Foundation
import Testing
@testable import OpenASO

@MainActor
struct RankedAppPricingServiceTests {
    @Test
    func loadsFreePaidAndUnavailableAppsWithOneOrderedRequest() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_750_000_000)
        var requestCount = 0
        let client = MockHTTPClient { request in
            requestCount += 1
            let url = try #require(request.url)
            let components = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            #expect(components.scheme == "https")
            #expect(components.host == "itunes.apple.com")
            #expect(components.path == "/lookup")
            #expect(components.queryItems == [
                URLQueryItem(name: "id", value: "30,10,20"),
                URLQueryItem(name: "entity", value: "software"),
                URLQueryItem(name: "country", value: "gb"),
            ])
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 20)

            let data = Data(
                """
                {
                  "resultCount": 2,
                  "results": [
                    {
                      "trackId": 10,
                      "price": 0,
                      "formattedPrice": "Free",
                      "currency": "GBP"
                    },
                    {
                      "trackId": 30,
                      "price": 4.99,
                      "formattedPrice": "£4.99",
                      "currency": "GBP"
                    }
                  ]
                }
                """.utf8
            )
            return (data, makeHTTPURLResponse(url: url, statusCode: 200))
        }
        let service = RankedAppPricingService(httpClient: client, now: { observedAt })

        let results = try await service.prices(
            for: [30, 10, 20],
            storefrontCode: " GBR ",
            platform: .iphone
        )

        #expect(requestCount == 1)
        #expect(results.map(\.appStoreID) == [30, 10, 20])
        #expect(results.map(\.storefrontCode) == ["gb", "gb", "gb"])
        #expect(results.map(\.observedAt) == [observedAt, observedAt, observedAt])
        #expect(results[0].value == .paid(
            amount: Decimal(string: "4.99")!,
            displayPrice: "£4.99",
            currencyCode: "GBP"
        ))
        #expect(results[1].value == .free(displayPrice: "Free"))
        #expect(results[2].value == .unavailable)
    }

    @Test
    func deduplicatesIDsAndCachesUnavailableResults() async throws {
        let currentDate = Date(timeIntervalSince1970: 100)
        var requestedIDValues: [String] = []
        let client = MockHTTPClient { request in
            let url = try #require(request.url)
            let components = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            requestedIDValues.append(try #require(
                components.queryItems?.first(where: { $0.name == "id" })?.value
            ))
            return (
                Data(#"{"resultCount":0,"results":[]}"#.utf8),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let service = RankedAppPricingService(
            httpClient: client,
            freshnessInterval: 60,
            now: { currentDate }
        )

        let initial = try await service.prices(
            for: [10, 10, 20],
            storefrontCode: "us",
            platform: .iphone
        )
        let cached = try await service.prices(
            for: [20, 10],
            storefrontCode: "us",
            platform: .iphone
        )
        _ = try await service.prices(
            for: [10],
            storefrontCode: "us",
            platform: .iphone,
            forceRefresh: true
        )

        #expect(initial.map(\.appStoreID) == [10, 20])
        #expect(initial.allSatisfy { $0.value == .unavailable })
        #expect(cached.map(\.appStoreID) == [20, 10])
        #expect(requestedIDValues == ["10,20", "10"])
    }

    @Test
    func forceRefreshBypassesFreshCache() async throws {
        var requestCount = 0
        let client = MockHTTPClient { request in
            requestCount += 1
            let url = try #require(request.url)
            return (
                Data(
                    """
                    {"results":[{"trackId":10,"price":1.99,"formattedPrice":"$1.99","currency":"usd"}]}
                    """.utf8
                ),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }
        let service = RankedAppPricingService(httpClient: client)

        _ = try await service.prices(
            for: [10],
            storefrontCode: "us",
            platform: .iphone
        )
        _ = try await service.prices(
            for: [10],
            storefrontCode: "us",
            platform: .iphone,
            forceRefresh: true
        )

        #expect(requestCount == 2)
    }

    @Test
    func rejectsInvalidOrUnboundedRequestsBeforeNetworking() async {
        let client = MockHTTPClient { _ in
            Issue.record("Invalid requests must not reach the network.")
            throw OpenASOError.unexpectedResponse
        }
        let service = RankedAppPricingService(httpClient: client)

        await #expect(throws: RankedAppPricingError.invalidAppStoreID) {
            try await service.prices(
                for: [0],
                storefrontCode: "us",
                platform: .iphone
            )
        }
        await #expect(throws: RankedAppPricingError.invalidStorefront) {
            try await service.prices(
                for: [10],
                storefrontCode: "app-store-connect",
                platform: .iphone
            )
        }
        await #expect(throws: RankedAppPricingError.tooManyApps(maximum: 200)) {
            try await service.prices(
                for: Array(1 ... 201).map(Int64.init),
                storefrontCode: "us",
                platform: .iphone
            )
        }
    }

    @Test
    func rejectsUnexpectedAndDuplicateProviderIDs() async {
        for fixture in [
            #"{"results":[{"trackId":999,"price":0,"formattedPrice":"Free","currency":"USD"}]}"#,
            #"{"results":[{"trackId":10,"price":0},{"trackId":10,"price":0}]}"#,
        ] {
            let client = MockHTTPClient { request in
                let url = try #require(request.url)
                return (
                    Data(fixture.utf8),
                    makeHTTPURLResponse(url: url, statusCode: 200)
                )
            }
            let service = RankedAppPricingService(httpClient: client)

            await #expect(throws: RankedAppPricingError.malformedResponse) {
                try await service.prices(
                    for: [10],
                    storefrontCode: "us",
                    platform: .iphone
                )
            }
        }
    }
}
