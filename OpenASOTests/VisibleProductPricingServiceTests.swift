import Foundation
import Testing
@testable import OpenASO

@MainActor
struct VisibleProductPricingServiceTests {
    @Test
    func parsesLocalizedVisibleProductsAndPreservesNativePrices() throws {
        let observedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let result = try VisibleProductPricingService.parse(
            Data(Self.html(
                annotation: """
                {
                  "$kind": "Annotation",
                  "title": "In-App-Käufe",
                  "summary": "Ja",
                  "items": [
                    {
                      "$kind": "AnnotationItem",
                      "textPairs": [
                        ["Pay-As-You-Go", "5,99 €"],
                        ["Pro Annual Savings", "69,99 €"]
                      ]
                    }
                  ]
                }
                """,
                appStoreID: 1_358_823_008
            ).utf8),
            appStoreID: 1_358_823_008,
            storefrontCode: "DE",
            observedAt: observedAt
        )

        #expect(result.appStoreID == 1_358_823_008)
        #expect(result.storefrontCode == "de")
        #expect(result.observedAt == observedAt)
        #expect(result.isPotentiallyIncomplete)
        #expect(!result.isTruncated)
        #expect(result.products == [
            VisibleProductPrice(name: "Pay-As-You-Go", displayPrice: "5,99 €"),
            VisibleProductPrice(name: "Pro Annual Savings", displayPrice: "69,99 €"),
        ])
    }

    @Test
    func returnsEmptyPotentiallyIncompleteResultWhenNoVisibleListExists() throws {
        let result = try VisibleProductPricingService.parse(
            Data(Self.html(annotation: nil).utf8),
            appStoreID: 10,
            storefrontCode: "us",
            observedAt: .distantPast
        )

        #expect(result.products.isEmpty)
        #expect(result.isPotentiallyIncomplete)
        #expect(!result.isTruncated)
    }

    @Test
    func parsesV3PairsWhenLegacyPairsAreAbsent() throws {
        let result = try VisibleProductPricingService.parse(
            Data(Self.html(
                annotation: """
                {
                  "$kind": "Annotation",
                  "title": "In-App Purchases",
                  "items_V3": [
                    {
                      "$kind": "textPair",
                      "leadingText": "Lifetime",
                      "trailingText": "$29.99"
                    },
                    {"$kind": "button", "style": "infer"}
                  ]
                }
                """
            ).utf8),
            appStoreID: 10,
            storefrontCode: "us",
            observedAt: .distantPast
        )

        #expect(result.products == [
            VisibleProductPrice(name: "Lifetime", displayPrice: "$29.99")
        ])
    }

    @Test
    func deduplicatesAndCapsVisibleProducts() throws {
        let pairs = (
            (1 ... 22).map { #"["Product \#($0)","$\#($0).99"]"# }
                + [#"["Product 1","$1.99"]"#]
        ).joined(separator: ",")
        let annotation = """
        {
          "$kind": "Annotation",
          "items": [{"$kind": "AnnotationItem", "textPairs": [\(pairs)]}]
        }
        """

        let result = try VisibleProductPricingService.parse(
            Data(Self.html(annotation: annotation).utf8),
            appStoreID: 10,
            storefrontCode: "us",
            observedAt: .distantPast
        )

        #expect(result.products.count == VisibleProductPricingService.maximumProductCount)
        #expect(result.products.first?.name == "Product 1")
        #expect(result.products.last?.name == "Product 20")
        #expect(result.isTruncated)
    }

    @Test
    func fetchesOnDemandThenUsesCacheUntilForced() async throws {
        var requestCount = 0
        let client = MockHTTPClient { request in
            requestCount += 1
            #expect(request.url?.absoluteString == "https://apps.apple.com/gb/app/id10")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
            return (
                Data(Self.html(
                    annotation: """
                    {
                      "$kind": "Annotation",
                      "items": [{"textPairs": [["Monthly", "£4.99"]]}]
                    }
                    """
                ).utf8),
                makeHTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200
                )
            )
        }
        let service = VisibleProductPricingService(httpClient: client)

        let initial = try await service.products(
            for: 10,
            storefrontCode: "GBR"
        )
        let cached = try await service.products(
            for: 10,
            storefrontCode: "gb"
        )
        let refreshed = try await service.products(
            for: 10,
            storefrontCode: "gb",
            forceRefresh: true
        )

        #expect(initial.products == [
            VisibleProductPrice(name: "Monthly", displayPrice: "£4.99")
        ])
        #expect(cached == initial)
        #expect(refreshed.products == initial.products)
        #expect(requestCount == 2)
    }

    @Test
    func rejectsInvalidInputsAndAmbiguousProductAnnotations() async {
        let client = MockHTTPClient { request in
            Issue.record("Unexpected request: \(String(describing: request.url))")
            throw OpenASOError.networkUnavailable
        }
        let service = VisibleProductPricingService(httpClient: client)

        await #expect(throws: VisibleProductPricingError.invalidAppStoreID) {
            _ = try await service.products(for: 0, storefrontCode: "us")
        }
        await #expect(throws: VisibleProductPricingError.invalidStorefront) {
            _ = try await service.products(for: 10, storefrontCode: "../us")
        }

        let ambiguousHTML = """
        <script id="serialized-server-data">
        {
          "data": [
            {"$kind":"Annotation","items":[{"textPairs":[["A","$1"]]}]},
            {"$kind":"Annotation","items":[{"textPairs":[["B","$2"]]}]}
          ]
        }
        </script>
        """
        #expect(throws: VisibleProductPricingError.malformedResponse) {
            _ = try VisibleProductPricingService.parse(
                Data(ambiguousHTML.utf8),
                appStoreID: 10,
                storefrontCode: "us",
                observedAt: .distantPast
            )
        }
        #expect(throws: VisibleProductPricingError.malformedResponse) {
            _ = try VisibleProductPricingService.parse(
                Data(Self.html(annotation: nil, appStoreID: 11).utf8),
                appStoreID: 10,
                storefrontCode: "us",
                observedAt: .distantPast
            )
        }
    }

    private static func html(
        annotation: String?,
        appStoreID: Int64 = 10
    ) -> String {
        let annotationValue = annotation ?? """
        {
          "$kind": "Annotation",
          "title": "Languages",
          "items": [{"title": "English"}]
        }
        """
        return """
        <!doctype html>
        <script type="application/json" id="serialized-server-data">
        {
          "data": [
            {
              "data": {
                "$kind": "ShelfBasedProductPage",
                "lockup": {"$kind": "Lockup", "adamId": "\(appStoreID)"},
                "shelfMapping": {
                  "information": {
                    "items": [\(annotationValue)]
                  }
                }
              }
            }
          ]
        }
        </script>
        """
    }
}
