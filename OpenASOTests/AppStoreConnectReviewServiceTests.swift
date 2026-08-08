import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct AppStoreConnectReviewServiceTests {
    @Test
    func credentialStoreSavesAndClearsCredentials() throws {
        let store = AppStoreConnectCredentialStore(defaults: .previewSuiteForTests(), keychain: InMemoryKeychainService())
        let credentials = AppStoreConnectCredentials(
            issuerID: "issuer",
            keyID: "key",
            privateKey: "private"
        )

        try store.save(credentials)
        #expect(store.credentials == credentials)
        #expect(store.hasCompleteCredentials)

        store.clear()
        #expect(!store.hasCompleteCredentials)
        #expect(store.credentials == AppStoreConnectCredentials(issuerID: "", keyID: "", privateKey: ""))
    }

    @Test
    func jwtUsesAppStoreConnectAudienceAndTwentyMinuteMaximumLifetime() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try AppStoreConnectJWT(
            issuerID: "issuer",
            keyID: "ABC123",
            privateKey: Self.privateKey,
            issuedAt: issuedAt,
            lifetime: 60 * 60
        ).signed()

        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try JSONSerialization.jsonObject(with: try Data(base64URLString: parts[0])) as? [String: Any]
        let payload = try JSONSerialization.jsonObject(with: try Data(base64URLString: parts[1])) as? [String: Any]

        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["kid"] as? String == "ABC123")
        #expect(header?["typ"] as? String == "JWT")
        #expect(payload?["iss"] as? String == "issuer")
        #expect(payload?["aud"] as? String == "appstoreconnect-v1")
        #expect(payload?["iat"] as? Int == 1_800_000_000)
        #expect(payload?["exp"] as? Int == 1_800_001_200)
    }

    @Test
    func decodesReviewsWithIncludedResponse() throws {
        let service = makeService()
        let payload = """
        {
          "data": [
            {
              "type": "customerReviews",
              "id": "review-1",
              "attributes": {
                "rating": 4,
                "title": "Good app",
                "body": "Useful for my team.",
                "reviewerNickname": "Maya",
                "createdDate": "2026-05-01T12:00:00Z",
                "territory": "USA",
                "appVersionString": "1.2.3"
              }
            }
          ],
          "included": [
            {
              "type": "customerReviewResponses",
              "id": "response-1",
              "attributes": {
                "responseBody": "Thanks for the feedback.",
                "state": "PUBLISHED",
                "lastModifiedDate": "2026-05-02T12:00:00Z"
              },
              "relationships": {
                "review": {
                  "data": {
                    "type": "customerReviews",
                    "id": "review-1"
                  }
                }
              }
            }
          ]
        }
        """

        let reviews = try service.decodeReviews(data: Data(payload.utf8), appStoreID: 123)
        let review = try #require(reviews.first)

        #expect(review.appStoreID == 123)
        #expect(review.storefront == "us")
        #expect(review.reviewID == "review-1")
        #expect(review.source == .appStoreConnect)
        #expect(review.developerResponseID == "response-1")
        #expect(review.developerResponseBody == "Thanks for the feedback.")
        #expect(review.developerResponseState == "PUBLISHED")
    }

    @Test
    func replyRequestUsesCreateResponseShape() throws {
        let service = makeService()
        let request = try service.makeReplyRequest(
            reviewID: "review-1",
            body: "Thanks for the feedback.",
            credentials: AppStoreConnectCredentials(issuerID: "issuer", keyID: "key", privateKey: Self.privateKey)
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.appstoreconnect.apple.com/v1/customerReviewResponses")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let data = body?["data"] as? [String: Any]
        let attributes = data?["attributes"] as? [String: Any]
        let relationships = data?["relationships"] as? [String: Any]
        let review = relationships?["review"] as? [String: Any]
        let reviewData = review?["data"] as? [String: Any]

        #expect(data?["type"] as? String == "customerReviewResponses")
        #expect(attributes?["responseBody"] as? String == "Thanks for the feedback.")
        #expect(reviewData?["type"] as? String == "customerReviews")
        #expect(reviewData?["id"] as? String == "review-1")
    }

    @Test
    func refreshReviewsResolvesOwnedAppFetchesReviewsAndPersistsResponses() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let storeApp = makeStoreApp()
        modelContext.insert(storeApp)
        try modelContext.save()

        var requestedPaths: [String] = []
        let service = try makeService { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)

            if url.path == "/v1/apps" {
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(components.queryItems?.contains(URLQueryItem(name: "filter[bundleId]", value: "com.example.app")) == true)
                return (Data(Self.appResponseJSON(id: "asc-app-1").utf8), makeHTTPURLResponse(url: url, statusCode: 200))
            }

            if url.path == "/v1/apps/asc-app-1/customerReviews" {
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(components.queryItems?.contains(URLQueryItem(name: "include", value: "response")) == true)
                #expect(components.queryItems?.contains(URLQueryItem(name: "sort", value: "-createdDate")) == true)
                #expect(components.queryItems?.contains(URLQueryItem(name: "limit", value: "200")) == true)
                return (Data(Self.reviewsResponseJSON().utf8), makeHTTPURLResponse(url: url, statusCode: 200))
            }

            throw OpenASOError.providerUnavailable("Unexpected request to \(url.absoluteString)")
        }

        let outcomes = await service.refreshReviews(for: storeApp, in: modelContext)

        let outcome = try #require(outcomes.first)
        #expect(outcome.error == nil)
        #expect(outcome.fetchedReviews == 2)
        #expect(outcome.storedReviews == 2)
        #expect(requestedPaths == ["/v1/apps", "/v1/apps/asc-app-1/customerReviews"])

        let reviews = try modelContext.fetch(FetchDescriptor<AppStorefrontReview>())
        #expect(reviews.count == 2)

        let reviewWithResponse = try #require(reviews.first { $0.reviewID == "review-1" })
        #expect(reviewWithResponse.source == .appStoreConnect)
        #expect(reviewWithResponse.storefront == "us")
        #expect(reviewWithResponse.ascReviewID == "review-1")
        #expect(reviewWithResponse.developerResponseID == "response-1")
        #expect(reviewWithResponse.developerResponseBody == "Thanks for the feedback.")
        #expect(reviewWithResponse.developerResponseState == "PUBLISHED")

        let reviewWithoutResponse = try #require(reviews.first { $0.reviewID == "review-2" })
        #expect(reviewWithoutResponse.source == .appStoreConnect)
        #expect(reviewWithoutResponse.storefront == "gb")
        #expect(reviewWithoutResponse.developerResponseID == nil)
        #expect(storeApp.reviews.count == 2)
    }

    @Test
    func refreshReviewsPaginatesAndStoresUnknownReviewsBeforeKnownReview() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let storeApp = makeStoreApp()
        let existingReview = AppStorefrontReview(
            appStoreID: storeApp.appStoreID,
            storefront: "gbr",
            reviewID: "review-2",
            reviewerName: "Noah",
            title: "Already stored",
            content: "Stored from an earlier refresh.",
            rating: 2,
            reviewedAt: try #require(Self.date("2026-05-03T12:00:00Z")),
            source: .appStoreConnect,
            storeApp: storeApp
        )
        existingReview.ascReviewID = "review-2"
        modelContext.insert(storeApp)
        modelContext.insert(existingReview)
        try modelContext.save()

        var requestedReviewCursors: [String?] = []
        let service = try makeService { request in
            let url = try #require(request.url)
            if url.path == "/v1/apps" {
                return (Data(Self.appResponseJSON(id: "asc-app-1").utf8), makeHTTPURLResponse(url: url, statusCode: 200))
            }

            if url.path == "/v1/apps/asc-app-1/customerReviews" {
                let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "cursor" })?
                    .value
                requestedReviewCursors.append(cursor)

                if cursor == "page2" {
                    return (
                        Data(Self.reviewsResponseJSON(ids: ["review-3", "review-2"], next: "https://api.appstoreconnect.apple.com/v1/apps/asc-app-1/customerReviews?cursor=page3").utf8),
                        makeHTTPURLResponse(url: url, statusCode: 200)
                    )
                }

                return (
                    Data(Self.reviewsResponseJSON(ids: ["review-1"], next: "https://api.appstoreconnect.apple.com/v1/apps/asc-app-1/customerReviews?cursor=page2").utf8),
                    makeHTTPURLResponse(url: url, statusCode: 200)
                )
            }

            throw OpenASOError.providerUnavailable("Unexpected request to \(url.absoluteString)")
        }

        let outcomes = await service.refreshReviews(for: storeApp, in: modelContext)

        let outcome = try #require(outcomes.first)
        #expect(outcome.error == nil)
        #expect(outcome.fetchedReviews == 3)
        #expect(outcome.storedReviews == 2)
        #expect(requestedReviewCursors.count == 2)
        #expect(requestedReviewCursors[0] == nil)
        #expect(requestedReviewCursors[1] == "page2")

        let reviews = try modelContext.fetch(FetchDescriptor<AppStorefrontReview>())
        #expect(reviews.count == 3)
        #expect(reviews.contains { $0.reviewID == "review-1" })
        #expect(reviews.contains { $0.reviewID == "review-3" })
    }

    @Test
    func refreshReviewsUpdatesExistingReviewAndClearsStaleTranslationWhenTextChanges() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let storeApp = makeStoreApp()
        let review = AppStorefrontReview(
            appStoreID: storeApp.appStoreID,
            storefront: "usa",
            reviewID: "review-1",
            reviewerName: "Maya",
            title: "Good app",
            content: "Useful for my team.",
            rating: 4,
            reviewedAt: try #require(Self.date("2026-05-01T12:00:00Z")),
            source: .appStoreConnect,
            storeApp: storeApp
        )
        review.storefront = "usa"
        review.reviewKey = "\(storeApp.appStoreID)::usa::review-1"
        review.ascReviewID = "review-1"
        review.translatedTitle = "Translated title"
        review.translatedContent = "Translated content"
        review.translationLanguage = "English"
        review.translatedAt = Date(timeIntervalSince1970: 10)
        review.translationProviderRaw = AIProvider.appleFoundationModels.rawValue
        review.translationModelID = AIModelID.Apple.default.rawValue
        modelContext.insert(storeApp)
        modelContext.insert(review)
        try modelContext.save()

        let service = try makeService { request in
            let url = try #require(request.url)
            if url.path == "/v1/apps" {
                return (Data(Self.appResponseJSON(id: "asc-app-1").utf8), makeHTTPURLResponse(url: url, statusCode: 200))
            }

            if url.path == "/v1/apps/asc-app-1/customerReviews" {
                return (Data(Self.reviewsResponseJSON(title: "Still good", body: "Useful for my team every day.").utf8), makeHTTPURLResponse(url: url, statusCode: 200))
            }

            throw OpenASOError.providerUnavailable("Unexpected request to \(url.absoluteString)")
        }

        let outcomes = await service.refreshReviews(for: storeApp, in: modelContext)

        let outcome = try #require(outcomes.first)
        #expect(outcome.error == nil)
        #expect(outcome.fetchedReviews == 2)
        #expect(outcome.storedReviews == 1)

        let storedReview = try #require(try modelContext.fetch(FetchDescriptor<AppStorefrontReview>()).first { $0.reviewID == "review-1" })
        #expect(storedReview.storefront == "us")
        #expect(storedReview.reviewKey == AppStorefrontReview.makeReviewKey(appStoreID: storeApp.appStoreID, storefront: "us", reviewID: "review-1"))
        #expect(storedReview.title == "Still good")
        #expect(storedReview.content == "Useful for my team every day.")
        #expect(storedReview.developerResponseID == "response-1")
        #expect(storedReview.translatedTitle == nil)
        #expect(storedReview.translatedContent == nil)
        #expect(storedReview.translationLanguage == nil)
        #expect(storedReview.translatedAt == nil)
        #expect(storedReview.translationProviderRaw == nil)
        #expect(storedReview.translationModelID == nil)
    }

    @Test
    func replyPostsResponseAndUpdatesStoredReview() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let storeApp = makeStoreApp()
        let review = AppStorefrontReview(
            appStoreID: storeApp.appStoreID,
            storefront: "usa",
            reviewID: "review-1",
            reviewerName: "Maya",
            title: "Good app",
            content: "Useful for my team.",
            rating: 4,
            reviewedAt: try #require(Self.date("2026-05-01T12:00:00Z")),
            source: .appStoreConnect,
            storeApp: storeApp
        )
        review.ascReviewID = "review-1"
        modelContext.insert(storeApp)
        modelContext.insert(review)
        try modelContext.save()

        var didPostReply = false
        let service = try makeService { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "POST")
            #expect(url.path == "/v1/customerReviewResponses")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let bodyData = try #require(request.httpBody)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            let data = body?["data"] as? [String: Any]
            let attributes = data?["attributes"] as? [String: Any]
            let relationships = data?["relationships"] as? [String: Any]
            let review = relationships?["review"] as? [String: Any]
            let reviewData = review?["data"] as? [String: Any]
            #expect(attributes?["responseBody"] as? String == "Thanks!")
            #expect(reviewData?["id"] as? String == "review-1")
            didPostReply = true

            return (Data(Self.replyResponseJSON().utf8), makeHTTPURLResponse(url: url, statusCode: 201))
        }

        let response = try await service.reply(to: AppStoreReviewValue(review), body: "  Thanks!  ", in: modelContext)

        #expect(didPostReply)
        #expect(response.id == "response-2")
        #expect(response.body == "Thanks!")
        #expect(response.state == "PUBLISHED")

        let storedReview = try #require(try modelContext.fetch(FetchDescriptor<AppStorefrontReview>()).first)
        #expect(storedReview.developerResponseID == "response-2")
        #expect(storedReview.developerResponseBody == "Thanks!")
        #expect(storedReview.developerResponseState == "PUBLISHED")
        let expectedModifiedAt = try #require(Self.date("2026-05-04T12:00:00Z"))
        #expect(storedReview.developerResponseModifiedAt == expectedModifiedAt)
    }

    @Test
    func refreshReviewsReportsMissingBundleIDWithoutNetwork() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let storeApp = makeStoreApp(bundleID: nil)
        modelContext.insert(storeApp)
        try modelContext.save()

        let service = try makeService { request in
            throw OpenASOError.providerUnavailable("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
        }

        let outcomes = await service.refreshReviews(for: storeApp, in: modelContext)

        let outcome = try #require(outcomes.first)
        #expect(outcome.fetchedReviews == 0)
        #expect(outcome.storedReviews == 0)
        #expect(outcome.error?.errorDescription?.contains("bundle ID") == true)
        #expect(try modelContext.fetch(FetchDescriptor<AppStorefrontReview>()).isEmpty)
    }

    @Test
    func refreshReviewsMapsInvisibleASCAppToAppNotFoundOutcome() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let storeApp = makeStoreApp()
        modelContext.insert(storeApp)
        try modelContext.save()

        var requestedPaths: [String] = []
        let service = try makeService { request in
            let url = try #require(request.url)
            requestedPaths.append(url.path)
            if url.path == "/v1/apps" {
                return (Data(#"{ "data": [] }"#.utf8), makeHTTPURLResponse(url: url, statusCode: 200))
            }
            throw OpenASOError.providerUnavailable("Unexpected request to \(url.absoluteString)")
        }

        let outcomes = await service.refreshReviews(for: storeApp, in: modelContext)

        let outcome = try #require(outcomes.first)
        #expect(outcome.fetchedReviews == 0)
        #expect(outcome.storedReviews == 0)
        #expect(outcome.error == .appNotFound)
        #expect(requestedPaths == ["/v1/apps"])
        #expect(try modelContext.fetch(FetchDescriptor<AppStorefrontReview>()).isEmpty)
    }

    @Test
    func resolveAppCachesOwnershipForRepeatedScreenVisits() async throws {
        var requestCount = 0
        let service = try makeService { request in
            requestCount += 1
            let url = try #require(request.url)
            return (
                Data(Self.appResponseJSON(id: "asc-app-1").utf8),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        }

        let first = try await service.resolveApp(bundleID: "com.example.app")
        let second = try await service.resolveApp(bundleID: "com.example.app")

        #expect(first == second)
        #expect(requestCount == 1)
    }

    private func makeService() -> AppStoreConnectReviewService {
        let store = AppStoreConnectCredentialStore(defaults: .previewSuiteForTests(), keychain: InMemoryKeychainService())
        return AppStoreConnectReviewService(
            httpClient: MockHTTPClient { request in
                throw OpenASOError.providerUnavailable("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
            },
            credentialStore: store
        )
    }

    private func makeService(
        handler: @escaping (URLRequest) throws -> (Data, URLResponse)
    ) throws -> AppStoreConnectReviewService {
        let store = AppStoreConnectCredentialStore(defaults: .previewSuiteForTests(), keychain: InMemoryKeychainService())
        try store.save(AppStoreConnectCredentials(issuerID: "issuer", keyID: "key", privateKey: Self.privateKey))
        return AppStoreConnectReviewService(httpClient: MockHTTPClient(handler: handler), credentialStore: store)
    }

    private func makeModelContainer() throws -> ModelContainer {
        try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
    }

    private func makeStoreApp(bundleID: String? = "com.example.app") -> StoreApp {
        StoreApp(
            appStoreID: 123,
            bundleID: bundleID,
            name: "Example",
            sellerName: "Example Inc.",
            iconURLString: nil,
            defaultPlatform: .iphone
        )
    }

    private static func appResponseJSON(id: String) -> String {
        """
        {
          "data": [
            {
              "type": "apps",
              "id": "\(id)"
            }
          ]
        }
        """
    }

    private static func reviewsResponseJSON(
        title: String = "Good app",
        body: String = "Useful for my team."
    ) -> String {
        """
        {
          "data": [
            {
              "type": "customerReviews",
              "id": "review-1",
              "attributes": {
                "rating": 4,
                "title": "\(title)",
                "body": "\(body)",
                "reviewerNickname": "Maya",
                "createdDate": "2026-05-01T12:00:00Z",
                "territory": "USA",
                "appVersionString": "1.2.3"
              }
            },
            {
              "type": "customerReviews",
              "id": "review-2",
              "attributes": {
                "rating": 2,
                "title": "Needs work",
                "body": "Please improve launch time.",
                "reviewerNickname": "Noah",
                "createdDate": "2026-05-03T12:00:00Z",
                "territory": "GBR",
                "appVersionString": "1.2.4"
              }
            }
          ],
          "included": [
            {
              "type": "customerReviewResponses",
              "id": "response-1",
              "attributes": {
                "responseBody": "Thanks for the feedback.",
                "state": "PUBLISHED",
                "lastModifiedDate": "2026-05-02T12:00:00Z"
              },
              "relationships": {
                "review": {
                  "data": {
                    "type": "customerReviews",
                    "id": "review-1"
                  }
                }
              }
            }
          ]
        }
        """
    }

    private static func reviewsResponseJSON(ids: [String], next: String?) -> String {
        let territories = ["review-1": "USA", "review-2": "GBR", "review-3": "CAN"]
        let reviewJSON = ids.enumerated().map { index, id in
            """
            {
              "type": "customerReviews",
              "id": "\(id)",
              "attributes": {
                "rating": \(index == 0 ? 5 : 2),
                "title": "Review \(id)",
                "body": "Body \(id)",
                "reviewerNickname": "Reviewer \(id)",
                "createdDate": "2026-05-0\(index + 1)T12:00:00Z",
                "territory": "\(territories[id] ?? "USA")",
                "appVersionString": "1.2.\(index)"
              }
            }
            """
        }
        .joined(separator: ",")
        let linksJSON = next.map { #","links":{"next":"\#($0)"}"# } ?? ""

        return """
        {
          "data": [
            \(reviewJSON)
          ]\(linksJSON)
        }
        """
    }

    private static func replyResponseJSON() -> String {
        """
        {
          "data": {
            "type": "customerReviewResponses",
            "id": "response-2",
            "attributes": {
              "responseBody": "Thanks!",
              "state": "PUBLISHED",
              "lastModifiedDate": "2026-05-04T12:00:00Z"
            }
          }
        }
        """
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static let privateKey = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIM2/+v/sUp+rKfUFKSaY3cDxp3E9Azvop6KV9VmlWgJ+oAoGCCqGSM49
    AwEHoUQDQgAETxX0A2qcgToC8eMpiyHyaM6G3/pdF4LcTCOd6W++qk7nO0Yjhnf3
    +JXc/3El4VXTjD1ZNEqLxFWE1tLOktEQMg==
    -----END EC PRIVATE KEY-----
    """
}

private extension Data {
    init(base64URLString: String) throws {
        var base64 = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: base64) else {
            throw OpenASOError.unexpectedResponse
        }
        self = data
    }
}

private extension UserDefaults {
    static func previewSuiteForTests() -> UserDefaults {
        UserDefaults(suiteName: "com.thirdtech.openaso.tests.\(UUID().uuidString)") ?? .standard
    }
}
