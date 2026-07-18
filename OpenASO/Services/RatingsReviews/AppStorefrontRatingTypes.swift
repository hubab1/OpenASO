import Foundation

struct ITunesLookupRatingsResponse: Decodable {
    let results: [ITunesLookupRatingsPayload]
}

struct ITunesLookupRatingsPayload: Decodable {
    let trackId: Int64
    let userRatingCount: Int?
    let averageUserRating: Double?
}

struct AppStorefrontRatingResult: Sendable {
    let appStoreID: Int64
    let storefront: String
    let ratingCount: Int?
    let averageRating: Double?
    let ratingCounts: AppStoreRatingCounts?
    let observedAt: Date
    let source: AppStorefrontSource
}

struct AppStorefrontRatingRefreshOutcome: Sendable {
    let storefront: String
    let result: AppStorefrontRatingResult?
    let error: OpenASOError?
    let unavailabilityReason: String?
    let clearsStoredRatings: Bool

    init(
        storefront: String,
        result: AppStorefrontRatingResult?,
        error: OpenASOError?,
        unavailabilityReason: String? = nil,
        clearsStoredRatings: Bool = false
    ) {
        self.storefront = storefront
        self.result = result
        self.error = error
        self.unavailabilityReason = unavailabilityReason
        self.clearsStoredRatings = clearsStoredRatings
    }
}

struct ParsedAppStorefrontRating: Sendable, Equatable {
    let ratingCount: Int?
    let averageRating: Double?
    let ratingCounts: AppStoreRatingCounts?
}

struct AppStoreRatingCounts: Sendable, Equatable, Hashable {
    let oneStar: Int?
    let twoStar: Int?
    let threeStar: Int?
    let fourStar: Int?
    let fiveStar: Int?

    init(
        oneStar: Int?,
        twoStar: Int?,
        threeStar: Int?,
        fourStar: Int?,
        fiveStar: Int?
    ) {
        self.oneStar = oneStar
        self.twoStar = twoStar
        self.threeStar = threeStar
        self.fourStar = fourStar
        self.fiveStar = fiveStar
    }

    init?(appStoreDescendingCounts values: [Int]) {
        guard values.count == 5 else { return nil }
        self.init(
            oneStar: values[4],
            twoStar: values[3],
            threeStar: values[2],
            fourStar: values[1],
            fiveStar: values[0]
        )
    }

    var total: Int? {
        let values = [oneStar, twoStar, threeStar, fourStar, fiveStar]
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }
}
