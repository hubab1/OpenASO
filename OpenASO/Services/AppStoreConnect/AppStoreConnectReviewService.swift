import Foundation
import SwiftData

@MainActor
final class AppStoreConnectReviewService: Sendable {
    nonisolated private let httpClient: HTTPClient
    private let credentialStore: AppStoreConnectCredentialStore

    init(httpClient: HTTPClient, credentialStore: AppStoreConnectCredentialStore) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
    }

    func validateCredentials(_ credentials: AppStoreConnectCredentials) async throws {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/apps")!
        components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        var request = try Self.authorizedRequest(url: try Self.url(from: components), credentials: credentials)
        request.timeoutInterval = 20
        _ = try await validatedData(for: request, using: httpClient)
    }

    func resolveApp(bundleID: String) async throws -> AppStoreConnectApp {
        try await Self.resolveApp(bundleID: bundleID, credentials: credentialStore.credentials, httpClient: httpClient)
    }

    nonisolated
    func resolveApp(bundleID: String, using credentials: AppStoreConnectCredentials) async throws -> AppStoreConnectApp {
        try await Self.resolveApp(bundleID: bundleID, credentials: credentials, httpClient: httpClient)
    }

    nonisolated
    func fetchReviews(
        appStoreConnectAppID: String,
        appStoreID: Int64,
        credentials: AppStoreConnectCredentials
    ) async throws -> [AppStorefrontReviewResult] {
        try await Self.fetchReviews(
            appStoreConnectAppID: appStoreConnectAppID,
            appStoreID: appStoreID,
            credentials: credentials,
            httpClient: httpClient
        )
    }

    nonisolated
    func fetchReviewPages(
        appStoreConnectAppID: String,
        appStoreID: Int64,
        credentials: AppStoreConnectCredentials,
        handlePage: ([AppStorefrontReviewResult]) async throws -> Bool
    ) async throws -> Int {
        try await Self.fetchReviewPages(
            appStoreConnectAppID: appStoreConnectAppID,
            appStoreID: appStoreID,
            credentials: credentials,
            httpClient: httpClient,
            handlePage: handlePage
        )
    }

    func refreshReviews(
        for storeApp: StoreApp,
        in modelContext: ModelContext,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void)? = nil
    ) async -> [AppStorefrontReviewRefreshOutcome] {
        await progress?(0, 1, 0)
        guard let bundleID = storeApp.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else {
            await progress?(1, 1, 1)
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "app-store-connect",
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: .providerUnavailable("This app does not have a bundle ID, so App Store Connect ownership cannot be checked.")
                )
            ]
        }

        do {
            let app = try await Self.resolveApp(bundleID: bundleID, credentials: credentialStore.credentials, httpClient: httpClient)
            var storedCount = 0
            var fetchedCount = 0
            var seenReviewIDs = Set<String>()
            var nextURL: URL? = try Self.makeReviewsURL(appStoreConnectAppID: app.id)

            while let url = nextURL {
                let page = try await Self.fetchReviewPage(
                    url: url,
                    appStoreID: storeApp.appStoreID,
                    credentials: credentialStore.credentials,
                    httpClient: httpClient
                )
                let pageReviews = page.reviews.filter { review in
                    seenReviewIDs.insert(review.reviewID).inserted
                }
                guard !pageReviews.isEmpty else {
                    break
                }

                fetchedCount += pageReviews.count
                let pageStoredCount = try upsert(pageReviews, storeApp: storeApp, in: modelContext)
                storedCount += pageStoredCount
                try modelContext.save()
                guard pageStoredCount == pageReviews.count else {
                    break
                }
                nextURL = page.nextURL
            }

            await progress?(1, 1, 0)
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "app-store-connect",
                    fetchedReviews: fetchedCount,
                    storedReviews: storedCount,
                    error: nil
                )
            ]
        } catch {
            await progress?(1, 1, 1)
            return [
                AppStorefrontReviewRefreshOutcome(
                    storefront: "app-store-connect",
                    fetchedReviews: 0,
                    storedReviews: 0,
                    error: OpenASOError.map(error)
                )
            ]
        }
    }

    @MainActor
    func reply(to review: AppStoreReviewValue, body: String, in modelContext: ModelContext) async throws -> AppStoreConnectReviewResponseValue {
        guard let ascReviewID = review.ascReviewID else {
            throw OpenASOError.providerUnavailable("This review is not available through App Store Connect.")
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw OpenASOError.providerUnavailable("Enter a reply before sending.")
        }

        let response = try await Self.postResponse(
            reviewID: ascReviewID,
            body: trimmedBody,
            credentials: credentialStore.credentials,
            httpClient: httpClient
        )
        try updateStoredResponse(
            reviewKey: review.reviewKey,
            response: response,
            body: trimmedBody,
            in: modelContext
        )
        try modelContext.save()
        return response
    }

    func makeReplyRequest(reviewID: String, body: String, credentials: AppStoreConnectCredentials) throws -> URLRequest {
        try Self.makeReplyRequest(reviewID: reviewID, body: body, credentials: credentials)
    }

    nonisolated private static func makeReplyRequest(
        reviewID: String,
        body: String,
        credentials: AppStoreConnectCredentials
    ) throws -> URLRequest {
        var request = try authorizedRequest(
            url: URL(string: "https://api.appstoreconnect.apple.com/v1/customerReviewResponses")!,
            credentials: credentials
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AppStoreConnectCreateResponseRequest(reviewID: reviewID, body: body))
        return request
    }

    nonisolated func decodeReviews(data: Data, appStoreID: Int64) throws -> [AppStorefrontReviewResult] {
        try Self.decodeReviews(data: data, appStoreID: appStoreID)
    }

    nonisolated private static func decodeReviews(data: Data, appStoreID: Int64) throws -> [AppStorefrontReviewResult] {
        try decodeReviewPage(data: data, appStoreID: appStoreID).reviews
    }

    nonisolated private static func decodeReviewPage(data: Data, appStoreID: Int64) throws -> AppStoreConnectReviewPage {
        let payload = try Self.decode(AppStoreConnectReviewsResponse.self, from: data)
        let responsesByReviewID = payload.responsesByReviewID
        let reviews: [AppStorefrontReviewResult] = payload.data.compactMap { review in
            guard let rating = review.attributes.rating else { return nil }
            let response = responsesByReviewID[review.id]
            return AppStorefrontReviewResult(
                appStoreID: appStoreID,
                storefront: StorefrontCatalog.normalizedStorefrontCode(review.attributes.territory),
                reviewID: review.id,
                reviewerName: review.attributes.reviewerNickname ?? "App Store User",
                title: review.attributes.title ?? "Review",
                content: review.attributes.body ?? "",
                rating: rating,
                reviewedAt: review.attributes.createdDate ?? .now,
                version: review.attributes.appVersionString,
                source: .appStoreConnect,
                observedAt: .now,
                ascReviewID: review.id,
                developerResponseID: response?.id,
                developerResponseBody: response?.attributes.responseBody,
                developerResponseState: response?.attributes.state,
                developerResponseModifiedAt: response?.attributes.lastModifiedDate
            )
        }
        return AppStoreConnectReviewPage(
            reviews: reviews,
            nextURL: payload.links?.next.flatMap(URL.init(string:))
        )
    }

    nonisolated private static func resolveApp(
        bundleID: String,
        credentials: AppStoreConnectCredentials,
        httpClient: HTTPClient
    ) async throws -> AppStoreConnectApp {
        guard credentials.isComplete else {
            throw OpenASOError.providerUnavailable("Enter App Store Connect issuer ID, key ID, and private key.")
        }

        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/apps")!
        components.queryItems = [
            URLQueryItem(name: "filter[bundleId]", value: bundleID),
            URLQueryItem(name: "limit", value: "1")
        ]
        var request = try authorizedRequest(url: try url(from: components), credentials: credentials)
        request.timeoutInterval = 20

        let data = try await validatedData(for: request, using: httpClient)
        let response = try Self.decode(AppStoreConnectAppsResponse.self, from: data)
        guard let app = response.data.first else {
            throw OpenASOError.appNotFound
        }
        return app
    }

    nonisolated private static func fetchReviews(
        appStoreConnectAppID: String,
        appStoreID: Int64,
        credentials: AppStoreConnectCredentials,
        httpClient: HTTPClient
    ) async throws -> [AppStorefrontReviewResult] {
        var reviews: [AppStorefrontReviewResult] = []
        _ = try await fetchReviewPages(
            appStoreConnectAppID: appStoreConnectAppID,
            appStoreID: appStoreID,
            credentials: credentials,
            httpClient: httpClient
        ) { pageReviews in
            reviews.append(contentsOf: pageReviews)
            return true
        }
        return reviews
    }

    nonisolated private static func fetchReviewPages(
        appStoreConnectAppID: String,
        appStoreID: Int64,
        credentials: AppStoreConnectCredentials,
        httpClient: HTTPClient,
        handlePage: ([AppStorefrontReviewResult]) async throws -> Bool
    ) async throws -> Int {
        var nextURL: URL? = try makeReviewsURL(appStoreConnectAppID: appStoreConnectAppID)
        var seenReviewIDs = Set<String>()
        var fetchedCount = 0

        while let url = nextURL {
            let page = try await fetchReviewPage(
                url: url,
                appStoreID: appStoreID,
                credentials: credentials,
                httpClient: httpClient
            )
            let newReviews = page.reviews.filter { review in
                seenReviewIDs.insert(review.reviewID).inserted
            }
            guard !newReviews.isEmpty else {
                break
            }

            fetchedCount += newReviews.count
            let shouldContinue = try await handlePage(newReviews)
            guard shouldContinue else {
                break
            }
            nextURL = page.nextURL
        }

        return fetchedCount
    }

    nonisolated private static func makeReviewsURL(appStoreConnectAppID: String) throws -> URL {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/apps/\(appStoreConnectAppID)/customerReviews")!
        components.queryItems = [
            URLQueryItem(name: "include", value: "response"),
            URLQueryItem(name: "sort", value: "-createdDate"),
            URLQueryItem(name: "limit", value: "200")
        ]
        return try url(from: components)
    }

    nonisolated private static func fetchReviewPage(
        url: URL,
        appStoreID: Int64,
        credentials: AppStoreConnectCredentials,
        httpClient: HTTPClient
    ) async throws -> AppStoreConnectReviewPage {
        var request = try authorizedRequest(url: url, credentials: credentials)
        request.timeoutInterval = 20

        let data = try await validatedData(for: request, using: httpClient)
        return try Self.decodeReviewPage(data: data, appStoreID: appStoreID)
    }

    nonisolated private static func postResponse(
        reviewID: String,
        body: String,
        credentials: AppStoreConnectCredentials,
        httpClient: HTTPClient
    ) async throws -> AppStoreConnectReviewResponseValue {
        let request = try makeReplyRequest(reviewID: reviewID, body: body, credentials: credentials)
        let data = try await validatedData(for: request, using: httpClient)
        let payload = try Self.decode(AppStoreConnectReviewResponseEnvelope.self, from: data)
        return AppStoreConnectReviewResponseValue(
            id: payload.data.id,
            body: payload.data.attributes.responseBody ?? body,
            state: payload.data.attributes.state,
            lastModifiedDate: payload.data.attributes.lastModifiedDate ?? .now
        )
    }

    nonisolated func upsert(
        _ results: [AppStorefrontReviewResult],
        storeApp: StoreApp,
        in modelContext: ModelContext
    ) throws -> Int {
        let existingReviews = try fetchReviews(for: results, in: modelContext)
        var storedCount = 0
        for result in results {
            let reviewKey = AppStorefrontReview.makeReviewKey(
                appStoreID: result.appStoreID,
                storefront: result.storefront,
                reviewID: result.reviewID
            )
            let review: AppStorefrontReview
            if let existing = existingReviews.byReviewKey[reviewKey] {
                review = existing
            } else if let existing = existingReviews.byAppStoreConnectReviewID[result.reviewID] {
                review = existing
                review.reviewKey = reviewKey
            } else {
                review = AppStorefrontReview(
                    appStoreID: result.appStoreID,
                    storefront: result.storefront,
                    reviewID: result.reviewID,
                    reviewerName: result.reviewerName,
                    title: result.title,
                    content: result.content,
                    rating: result.rating,
                    reviewedAt: result.reviewedAt,
                    version: result.version,
                    source: result.source,
                    observedAt: result.observedAt,
                    storeApp: storeApp
                )
                modelContext.insert(review)
                storedCount += 1
            }

            if review.title != result.title || review.content != result.content {
                review.clearTranslation()
            }

            Self.updateIfChanged(&review.reviewerName, result.reviewerName)
            Self.updateIfChanged(&review.storefront, StorefrontCatalog.normalizedStorefrontCode(result.storefront))
            Self.updateIfChanged(&review.title, result.title)
            Self.updateIfChanged(&review.content, result.content)
            Self.updateIfChanged(&review.rating, result.rating)
            Self.updateIfChanged(&review.reviewedAt, result.reviewedAt)
            Self.updateIfChanged(&review.version, result.version)
            if review.source != result.source {
                review.source = result.source
            }
            Self.updateIfChanged(&review.observedAt, result.observedAt)
            if review.storeApp?.persistentModelID != storeApp.persistentModelID {
                review.storeApp = storeApp
            }
            Self.updateIfChanged(&review.ascReviewID, result.ascReviewID)
            Self.updateIfChanged(&review.developerResponseID, result.developerResponseID)
            Self.updateIfChanged(&review.developerResponseBody, result.developerResponseBody)
            Self.updateIfChanged(&review.developerResponseState, result.developerResponseState)
            Self.updateIfChanged(&review.developerResponseModifiedAt, result.developerResponseModifiedAt)
        }

        return storedCount
    }

    nonisolated private static func updateIfChanged<Value: Equatable>(_ value: inout Value, _ newValue: Value) {
        if value != newValue {
            value = newValue
        }
    }

    private struct ExistingReviews {
        let byReviewKey: [String: AppStorefrontReview]
        let byAppStoreConnectReviewID: [String: AppStorefrontReview]
    }

    nonisolated private func fetchReviews(
        for results: [AppStorefrontReviewResult],
        in modelContext: ModelContext
    ) throws -> ExistingReviews {
        let reviewKeys = results.map {
            AppStorefrontReview.makeReviewKey(
                appStoreID: $0.appStoreID,
                storefront: $0.storefront,
                reviewID: $0.reviewID
            )
        }
        let ascReviewIDs = results.map(\.reviewID)

        var reviews: [AppStorefrontReview] = []
        if !reviewKeys.isEmpty {
            let descriptor = FetchDescriptor<AppStorefrontReview>(
                predicate: #Predicate { review in
                    reviewKeys.contains(review.reviewKey)
                }
            )
            reviews.append(contentsOf: try modelContext.fetch(descriptor))
        }
        if let appStoreID = results.first?.appStoreID, !ascReviewIDs.isEmpty {
            let targetAppStoreID = appStoreID
            let descriptor = FetchDescriptor<AppStorefrontReview>(
                predicate: #Predicate { review in
                    review.appStoreID == targetAppStoreID && ascReviewIDs.contains(review.reviewID)
                }
            )
            reviews.append(contentsOf: try modelContext.fetch(descriptor))
        }

        return ExistingReviews(
            byReviewKey: Dictionary(reviews.map { ($0.reviewKey, $0) }, uniquingKeysWith: { first, _ in first }),
            byAppStoreConnectReviewID: Dictionary(reviews.map { ($0.reviewID, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private func updateStoredResponse(
        reviewKey: String,
        response: AppStoreConnectReviewResponseValue,
        body: String,
        in modelContext: ModelContext
    ) throws {
        guard let review = try fetchReview(reviewKey: reviewKey, in: modelContext) else { return }
        review.developerResponseID = response.id
        review.developerResponseBody = response.body.isEmpty ? body : response.body
        review.developerResponseState = response.state
        review.developerResponseModifiedAt = response.lastModifiedDate
    }

    nonisolated private func fetchReview(reviewKey: String, in modelContext: ModelContext) throws -> AppStorefrontReview? {
        let targetReviewKey = reviewKey
        let descriptor = FetchDescriptor<AppStorefrontReview>(
            predicate: #Predicate { review in
                review.reviewKey == targetReviewKey
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    nonisolated private func fetchAppStoreConnectReview(
        appStoreID: Int64,
        reviewID: String,
        in modelContext: ModelContext
    ) throws -> AppStorefrontReview? {
        let targetAppStoreID = appStoreID
        let targetReviewID = reviewID
        let sourceRaw = AppStorefrontReviewSource.appStoreConnect.rawValue
        let descriptor = FetchDescriptor<AppStorefrontReview>(
            predicate: #Predicate { review in
                review.appStoreID == targetAppStoreID
                    && review.reviewID == targetReviewID
                    && review.sourceRaw == sourceRaw
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    nonisolated private static func authorizedRequest(url: URL, credentials: AppStoreConnectCredentials) throws -> URLRequest {
        guard credentials.isComplete else {
            throw OpenASOError.providerUnavailable("Enter App Store Connect issuer ID, key ID, and private key.")
        }

        let token = try AppStoreConnectJWT(
            issuerID: credentials.trimmed.issuerID,
            keyID: credentials.trimmed.keyID,
            privateKey: credentials.trimmed.privateKey
        ).signed()
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated private static func url(from components: URLComponents) throws -> URL {
        guard let url = components.url else {
            throw OpenASOError.unexpectedResponse
        }
        return url
    }

    nonisolated private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try makeDecoder().decode(type, from: data)
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct AppStoreConnectApp: Decodable, Equatable, Sendable {
    let id: String
}

struct AppStoreConnectReviewResponseValue: Equatable, Sendable {
    let id: String
    let body: String
    let state: String?
    let lastModifiedDate: Date
}

private struct AppStoreConnectAppsResponse: Decodable {
    let data: [AppStoreConnectApp]
}

private struct AppStoreConnectReviewsResponse: Decodable {
    let data: [AppStoreConnectReviewResource]
    let included: [AppStoreConnectIncludedResource]?
    let links: AppStoreConnectLinks?

    var responsesByReviewID: [String: AppStoreConnectReviewResponseResource] {
        Dictionary(
            uniqueKeysWithValues: (included ?? []).compactMap { included in
                guard case .response(let response) = included,
                      let reviewID = response.relationships?.review?.data?.id else {
                    return nil
                }
                return (reviewID, response)
            }
        )
    }
}

private struct AppStoreConnectReviewPage {
    let reviews: [AppStorefrontReviewResult]
    let nextURL: URL?
}

private struct AppStoreConnectLinks: Decodable {
    let next: String?
}

private struct AppStoreConnectReviewResource: Decodable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        let rating: Int?
        let title: String?
        let body: String?
        let reviewerNickname: String?
        let createdDate: Date?
        let territory: String?
        let appVersionString: String?
    }
}

private enum AppStoreConnectIncludedResource: Decodable {
    case response(AppStoreConnectReviewResponseResource)
    case unsupported

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .type) == "customerReviewResponses" {
            self = .response(try AppStoreConnectReviewResponseResource(from: decoder))
        } else {
            self = .unsupported
        }
    }
}

private struct AppStoreConnectReviewResponseEnvelope: Decodable {
    let data: AppStoreConnectReviewResponseResource
}

private struct AppStoreConnectReviewResponseResource: Decodable {
    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    struct Attributes: Decodable {
        let responseBody: String?
        let state: String?
        let lastModifiedDate: Date?
    }

    struct Relationships: Decodable {
        let review: ReviewRelationship?
    }

    struct ReviewRelationship: Decodable {
        let data: RelationshipData?
    }

    struct RelationshipData: Decodable {
        let id: String
    }
}

private struct AppStoreConnectCreateResponseRequest: Encodable {
    let data: DataResource

    init(reviewID: String, body: String) {
        self.data = DataResource(
            attributes: Attributes(responseBody: body),
            relationships: Relationships(
                review: ReviewRelationship(data: RelationshipData(type: "customerReviews", id: reviewID))
            )
        )
    }

    struct DataResource: Encodable {
        let type = "customerReviewResponses"
        let attributes: Attributes
        let relationships: Relationships
    }

    struct Attributes: Encodable {
        let responseBody: String
    }

    struct Relationships: Encodable {
        let review: ReviewRelationship
    }

    struct ReviewRelationship: Encodable {
        let data: RelationshipData
    }

    struct RelationshipData: Encodable {
        let type: String
        let id: String
    }
}
