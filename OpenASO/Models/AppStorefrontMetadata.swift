import Foundation
import SwiftData

extension OpenASOSchemaV1 {
@Model
final class AppStorefrontMetadata {
    #Index<AppStorefrontMetadata>(
        [\.storefront],
        [\.storefront, \.appStoreID],
        [\.appStoreID]
    )

    @Attribute(.unique) var identityKey: String
    var appStoreID: Int64
    var storefront: String
    var defaultPlatformRaw: String
    var name: String
    var subtitle: String?
    var sellerName: String?
    var descriptionText: String?
    var releaseNotes: String?
    var iconURLString: String?
    var version: String?
    var releaseDate: Date?
    var currentVersionReleaseDate: Date?
    var primaryGenreID: Int?
    var primaryGenreName: String?
    var storefrontLanguageCode: String?
    var servedLanguageCode: String?
    var isLocalized: Bool?
    var isAvailable: Bool
    var sourceRaw: String
    var lastFetchedAt: Date

    var storeApp: StoreApp
    @Relationship(deleteRule: .cascade) var screenshots: [AppStoreScreenshot]

    init(
        appStoreID: Int64,
        storefront: String,
        defaultPlatform: AppPlatform,
        name: String,
        subtitle: String? = nil,
        sellerName: String? = nil,
        descriptionText: String? = nil,
        releaseNotes: String? = nil,
        iconURLString: String? = nil,
        version: String? = nil,
        releaseDate: Date? = nil,
        currentVersionReleaseDate: Date? = nil,
        primaryGenreID: Int? = nil,
        primaryGenreName: String? = nil,
        storefrontLanguageCode: String? = nil,
        servedLanguageCode: String? = nil,
        isLocalized: Bool? = nil,
        isAvailable: Bool = true,
        source: AppStorefrontMetadataSource,
        lastFetchedAt: Date = .now,
        storeApp: StoreApp
    ) {
        let normalizedStorefront = Self.normalizedStorefront(storefront)
        self.identityKey = Self.makeIdentityKey(appStoreID: appStoreID, storefront: normalizedStorefront)
        self.appStoreID = appStoreID
        self.storefront = normalizedStorefront
        self.defaultPlatformRaw = defaultPlatform.rawValue
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.descriptionText = descriptionText
        self.releaseNotes = releaseNotes
        self.iconURLString = iconURLString
        self.version = version
        self.releaseDate = releaseDate
        self.currentVersionReleaseDate = currentVersionReleaseDate
        self.primaryGenreID = primaryGenreID
        self.primaryGenreName = primaryGenreName
        self.storefrontLanguageCode = storefrontLanguageCode
        self.servedLanguageCode = servedLanguageCode
        self.isLocalized = isLocalized
        self.isAvailable = isAvailable
        self.sourceRaw = source.rawValue
        self.lastFetchedAt = lastFetchedAt
        self.storeApp = storeApp
        self.screenshots = []
    }

    static func makeIdentityKey(appStoreID: Int64, storefront: String) -> String {
        [
            String(appStoreID),
            normalizedStorefront(storefront)
        ].joined(separator: "::")
    }

    static func normalizedStorefront(_ storefront: String) -> String {
        storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var defaultPlatform: AppPlatform {
        get { AppPlatform(rawValue: defaultPlatformRaw) ?? .iphone }
        set { defaultPlatformRaw = newValue.rawValue }
    }

    var source: AppStorefrontMetadataSource {
        get { AppStorefrontMetadataSource(rawValue: sourceRaw) ?? .iTunesSearch }
        set { sourceRaw = newValue.rawValue }
    }
}
}

typealias AppStorefrontMetadata = OpenASOSchemaV1.AppStorefrontMetadata

enum AppStorefrontMetadataSource: String, Codable, Sendable {
    case iTunesSearch
    case iTunesLookup
    case appStoreWeb
    case appStoreWebSearch
}
