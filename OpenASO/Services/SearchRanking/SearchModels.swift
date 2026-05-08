import Foundation

struct ResolvedApp: Identifiable, Hashable, Sendable {
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?
    let version: String?
    let primaryGenreID: Int?
    let primaryGenreName: String?
    let supportedLanguageCodes: [String]
    let sellerURLString: String?
    let trackViewURLString: String?
    let screenshotURLs: [String]
    let ipadScreenshotURLs: [String]
    let appletvScreenshotURLs: [String]
    let defaultPlatform: AppPlatform

    init(
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String? = nil,
        sellerName: String?,
        iconURLString: String? = nil,
        releaseDate: Date? = nil,
        currentVersionReleaseDate: Date? = nil,
        version: String? = nil,
        primaryGenreID: Int? = nil,
        primaryGenreName: String? = nil,
        supportedLanguageCodes: [String] = [],
        sellerURLString: String? = nil,
        trackViewURLString: String? = nil,
        screenshotURLs: [String] = [],
        ipadScreenshotURLs: [String] = [],
        appletvScreenshotURLs: [String] = [],
        defaultPlatform: AppPlatform
    ) {
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.iconURLString = iconURLString
        self.releaseDate = releaseDate
        self.currentVersionReleaseDate = currentVersionReleaseDate
        self.version = version
        self.primaryGenreID = primaryGenreID
        self.primaryGenreName = primaryGenreName
        self.supportedLanguageCodes = supportedLanguageCodes
        self.sellerURLString = sellerURLString
        self.trackViewURLString = trackViewURLString
        self.screenshotURLs = screenshotURLs
        self.ipadScreenshotURLs = ipadScreenshotURLs
        self.appletvScreenshotURLs = appletvScreenshotURLs
        self.defaultPlatform = defaultPlatform
    }

    var id: Int64 { appStoreID }
}

struct SearchRankingItem: Identifiable, Hashable, Sendable {
    let position: Int
    let appStoreID: Int64
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?
    let version: String?
    let primaryGenreID: Int?
    let primaryGenreName: String?
    let descriptionText: String?
    let releaseNotes: String?
    let supportedLanguageCodes: [String]
    let screenshotURLs: [String]
    let ipadScreenshotURLs: [String]
    let appletvScreenshotURLs: [String]
    let ratingCount: Int?
    let averageRating: Double?
    let platform: AppPlatform

    init(
        position: Int,
        appStoreID: Int64,
        bundleID: String?,
        name: String,
        subtitle: String? = nil,
        sellerName: String?,
        iconURLString: String? = nil,
        releaseDate: Date? = nil,
        currentVersionReleaseDate: Date? = nil,
        version: String? = nil,
        primaryGenreID: Int? = nil,
        primaryGenreName: String? = nil,
        descriptionText: String? = nil,
        releaseNotes: String? = nil,
        supportedLanguageCodes: [String] = [],
        screenshotURLs: [String] = [],
        ipadScreenshotURLs: [String] = [],
        appletvScreenshotURLs: [String] = [],
        ratingCount: Int? = nil,
        averageRating: Double? = nil,
        platform: AppPlatform = .iphone
    ) {
        self.position = position
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.iconURLString = iconURLString
        self.releaseDate = releaseDate
        self.currentVersionReleaseDate = currentVersionReleaseDate
        self.version = version
        self.primaryGenreID = primaryGenreID
        self.primaryGenreName = primaryGenreName
        self.descriptionText = descriptionText
        self.releaseNotes = releaseNotes
        self.supportedLanguageCodes = supportedLanguageCodes
        self.screenshotURLs = screenshotURLs
        self.ipadScreenshotURLs = ipadScreenshotURLs
        self.appletvScreenshotURLs = appletvScreenshotURLs
        self.ratingCount = ratingCount
        self.averageRating = averageRating
        self.platform = platform
    }

    var id: Int64 { appStoreID }
}

struct SearchRankingPage: Sendable {
    let items: [SearchRankingItem]
    let source: RankingSource

    var resultCount: Int {
        items.count
    }
}
