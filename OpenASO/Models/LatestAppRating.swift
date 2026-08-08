import Foundation
import SwiftData

extension OpenASOSchemaV1 {
@Model
final class LatestAppRating {
    #Index<LatestAppRating>(
        [\.storefront],
        [\.storefront, \.appStoreID],
        [\.appStoreID]
    )

    @Attribute(.unique) var identityKey: String
    var appStoreID: Int64
    var storefront: String
    var ratingCount: Int?
    var averageRating: Double?
    var oneStarRatingCount: Int?
    var twoStarRatingCount: Int?
    var threeStarRatingCount: Int?
    var fourStarRatingCount: Int?
    var fiveStarRatingCount: Int?
    var ratingDate: String
    var observedAt: Date
    var submissionCount: Int
    var winningCount: Int
    var confidenceRaw: String?
    var sourceRaw: String

    @Relationship(deleteRule: .nullify, inverse: \StoreApp.storefrontLatest)
    var storeApp: StoreApp?

    init(
        appStoreID: Int64,
        storefront: String,
        ratingCount: Int?,
        averageRating: Double?,
        oneStarRatingCount: Int? = nil,
        twoStarRatingCount: Int? = nil,
        threeStarRatingCount: Int? = nil,
        fourStarRatingCount: Int? = nil,
        fiveStarRatingCount: Int? = nil,
        ratingDate: String? = nil,
        observedAt: Date = .now,
        submissionCount: Int = 1,
        winningCount: Int = 1,
        confidence: String? = nil,
        source: AppStorefrontSource = .appStorePage,
        storeApp: StoreApp? = nil
    ) {
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.identityKey = Self.makeIdentityKey(appStoreID: appStoreID, storefront: normalizedStorefront)
        self.appStoreID = appStoreID
        self.storefront = normalizedStorefront
        self.ratingCount = ratingCount
        self.averageRating = averageRating
        self.oneStarRatingCount = oneStarRatingCount
        self.twoStarRatingCount = twoStarRatingCount
        self.threeStarRatingCount = threeStarRatingCount
        self.fourStarRatingCount = fourStarRatingCount
        self.fiveStarRatingCount = fiveStarRatingCount
        self.ratingDate = ratingDate ?? Self.ratingDateString(for: observedAt)
        self.observedAt = observedAt
        self.submissionCount = submissionCount
        self.winningCount = winningCount
        self.confidenceRaw = confidence
        self.sourceRaw = source.rawValue
        self.storeApp = storeApp
    }

    static func makeIdentityKey(appStoreID: Int64, storefront: String) -> String {
        [
            String(appStoreID),
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "::")
    }

    var source: AppStorefrontSource {
        get { AppStorefrontSource(rawValue: sourceRaw) ?? .appStorePage }
        set { sourceRaw = newValue.rawValue }
    }

    static func utcDayString(for date: Date) -> String {
        dateString(for: date)
    }

    static func ratingDateString(for date: Date) -> String {
        let calendar = utcCalendar
        let hour = calendar.component(.hour, from: date)
        let bucketDate = hour < 12
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        return dateString(for: bucketDate)
    }

    private static func dateString(for date: Date) -> String {
        let components = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
}

typealias LatestAppRating = OpenASOSchemaV1.LatestAppRating

enum AppStorefrontSource: String, Codable, Sendable {
    case appStorePage
    case iTunesSearch
}
