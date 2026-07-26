import Foundation

struct OpenASOMCPPageRequest: Sendable {
    let limit: Int
    let cursor: String?

    init(limit: Int?, cursor: String?) {
        self.limit = OpenASOMCPValidation.cappedLimit(limit, default: 50, maximum: 200)
        self.cursor = cursor
    }

    var offset: Int {
        OpenASOMCPValidation.offset(from: cursor)
    }
}

struct OpenASOMCPPage<Value: Codable & Sendable>: Codable, Sendable {
    let items: [Value]
    let nextCursor: String?
    let total: Int?

    init(items: [Value], nextCursor: String?, total: Int? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.total = total
    }
}

struct OpenASOMCPErrorDTO: Codable, Sendable, Equatable {
    let code: String
    let message: String

    init(_ error: OpenASOError) {
        self.code = error.code
        self.message = error.localizedDescription
    }

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

struct OpenASOMCPMutationSummary: Codable, Sendable, Equatable {
    var inserted: Int
    var updated: Int
    var skipped: Int
    var refreshed: Int
    var failed: Int

    static let empty = OpenASOMCPMutationSummary(
        inserted: 0,
        updated: 0,
        skipped: 0,
        refreshed: 0,
        failed: 0
    )
}

struct OpenASOMCPAppSummary: Codable, Identifiable, Sendable {
    let id: String
    let appStoreID: String
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let defaultStorefront: String
    let defaultPlatform: String
    let folder: String?
    let isTracked: Bool
    let isPinned: Bool
    let createdAt: Date?
    let keywordCount: Int
    let reviewCount: Int
    let screenshotCount: Int
    let latestRating: OpenASOMCPRatingSummary?
    let lastMetadataRefreshAt: Date?
}

struct OpenASOMCPResolvedApp: Codable, Identifiable, Sendable {
    let id: String
    let appStoreID: String
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let version: String?
    let primaryGenreName: String?
    let defaultPlatform: String
    let sellerURLString: String?
    let trackViewURLString: String?
    let screenshotURLs: [String]
    let ipadScreenshotURLs: [String]
    let appletvScreenshotURLs: [String]
}

struct OpenASOMCPAppDetectionResult: Codable, Sendable {
    let query: String
    let storefront: String
    let candidates: [OpenASOMCPResolvedApp]
    let recommendedAppStoreID: String?
    let requiresConfirmation: Bool
    let confirmationPrompt: String
}

struct OpenASOMCPAddTrackedAppResult: Codable, Sendable {
    let app: OpenASOMCPAppSummary
    let summary: OpenASOMCPMutationSummary
}

struct OpenASOMCPAppOverview: Codable, Sendable {
    let app: OpenASOMCPAppSummary
    let storefrontMetadata: [OpenASOMCPStorefrontMetadata]
    let ratings: [OpenASOMCPRatingSummary]
    let reviewSummary: OpenASOMCPReviewSummary
    let keywordSummary: OpenASOMCPKeywordOverviewSummary
    let screenshotSummary: OpenASOMCPScreenshotSummary
    let topCompetitors: [OpenASOMCPCompetitorSummary]
    let freshnessWarnings: [String]
}

struct OpenASOMCPStorefrontMetadata: Codable, Sendable {
    let storefront: String
    let name: String
    let subtitle: String?
    let sellerName: String?
    let descriptionText: String?
    let releaseNotes: String?
    let iconURLString: String?
    let version: String?
    let primaryGenreName: String?
    let source: String
    let isAvailable: Bool
    let lastFetchedAt: Date
    let screenshotCount: Int
}

struct OpenASOMCPRatingSummary: Codable, Sendable {
    let storefront: String
    let ratingCount: Int?
    let averageRating: Double?
    let oneStarRatingCount: Int?
    let twoStarRatingCount: Int?
    let threeStarRatingCount: Int?
    let fourStarRatingCount: Int?
    let fiveStarRatingCount: Int?
    let observedAt: Date
    let source: String
}

struct OpenASOMCPRatingSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let identityKey: String
    let appStoreID: String
    let storefront: String
    let ratingDate: String
    let ratingCount: Int?
    let averageRating: Double?
    let oneStarRatingCount: Int?
    let twoStarRatingCount: Int?
    let threeStarRatingCount: Int?
    let fourStarRatingCount: Int?
    let fiveStarRatingCount: Int?
    let observedAt: Date
    let submissionCount: Int
    let winningCount: Int
    let confidence: String?
    let source: String
}

struct OpenASOMCPReviewSummary: Codable, Sendable {
    let totalCount: Int
    let storefronts: [String]
    let latestReviewedAt: Date?
    let averageRating: Double?
}

struct OpenASOMCPReview: Codable, Sendable {
    let reviewKey: String
    let appStoreID: String
    let storefront: String
    let reviewID: String
    let reviewerName: String
    let title: String
    let content: String
    let rating: Int
    let reviewedAt: Date
    let version: String?
    let source: String
    let observedAt: Date
    let assumedLanguageCode: String?
    let developerResponseBody: String?
    let developerResponseState: String?
}

struct OpenASOMCPKeywordOverviewSummary: Codable, Sendable {
    let totalCount: Int
    let storefronts: [String]
    let latestRefreshAt: Date?
}

struct OpenASOMCPKeywordSummary: Codable, Identifiable, Sendable {
    let id: String
    let trackIdentityKey: String
    let appStoreID: String
    let keyword: String
    let queryKey: String
    let storefront: String
    let platform: String
    let latestRank: Int?
    let previousRank: Int?
    let rankDelta: Int?
    let resultCount: Int?
    let popularityScore: Int?
    let difficultyScore: Int?
    let notes: String
    let rankingStatusMessage: String?
    let popularityStatusMessage: String?
    let statusMessage: String?
    let lastRefreshAt: Date?
    let latestRankingSource: String?
    let latestRankingObservedAt: Date?
    let createdAt: Date
}

struct OpenASOMCPStoredRankedApp: Codable, Identifiable, Sendable {
    let id: String
    let position: Int
    let appStoreID: String
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
}

struct OpenASOMCPTrackedRankingSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let snapshotKey: String
    let trackIdentityKey: String
    let appStoreID: String
    let keyword: String
    let queryKey: String
    let storefront: String
    let platform: String
    let rank: Int?
    let searchedAt: Date
    let source: String
    let resultCount: Int
    let errorMessage: String?
    let rankedAppsAvailableCount: Int
    let rankedAppsTruncated: Bool
    let rankedApps: [OpenASOMCPStoredRankedApp]
}

struct OpenASOMCPRankingCrawlSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let observationKey: String
    let queryKey: String
    let keyword: String
    let storefront: String
    let platform: String
    let observedAt: Date
    let observedHour: Int
    let source: String
    let resultCount: Int
    let submissionCount: Int
    let winningCount: Int
    let confidence: String?
    let rankedAppsAvailableCount: Int
    let rankedAppsTruncated: Bool
    let rankedApps: [OpenASOMCPStoredRankedApp]
}

struct OpenASOMCPAddKeywordsResult: Codable, Sendable {
    let summary: OpenASOMCPMutationSummary
    let inserted: [OpenASOMCPKeywordSummary]
    let skipped: [OpenASOMCPSkippedKeyword]
}

struct OpenASOMCPSkippedKeyword: Codable, Sendable, Equatable {
    let keyword: String
    let storefront: String
    let platform: String
    let reason: String
}

struct OpenASOMCPKeywordNotesResult: Codable, Sendable {
    let track: OpenASOMCPKeywordSummary
    let summary: OpenASOMCPMutationSummary
}

struct OpenASOMCPKeywordScoreResult: Codable, Sendable {
    let appStoreID: String
    let storefronts: [String]
    let platform: String?
    let items: [OpenASOMCPKeywordScore]
    let summary: OpenASOMCPKeywordScoreSummary
    let notes: [String]
}

struct OpenASOMCPKeywordScoreSummary: Codable, Sendable {
    let totalCount: Int
    let defendCount: Int
    let attackCount: Int
    let longTailCount: Int
    let brandCount: Int
    let experimentalCount: Int
    let noisyCount: Int
}

struct OpenASOMCPKeywordScore: Codable, Sendable {
    let keyword: String
    let storefront: String
    let platform: String
    let latestRank: Int?
    let popularityScore: Int?
    let resultCount: Int?
    let priority: String
    let intent: String
    let noiseScore: Double
    let relevanceScore: Double
    let rationale: [String]
}

struct OpenASOMCPScreenshotSummary: Codable, Sendable {
    let totalCount: Int
    let storefronts: [String]
    let platforms: [String]
    let latestFetchedAt: Date?
}

struct OpenASOMCPScreenshot: Codable, Identifiable, Sendable {
    let id: String
    let appStoreID: String
    let storefront: String
    let platform: String
    let displayType: String
    let sortOrder: Int
    let urlString: String
    let width: Int?
    let height: Int?
    let source: String
    let lastFetchedAt: Date
}

struct OpenASOMCPScreenshotExportResult: Codable, Sendable {
    let destinationDirectoryPath: String
    let summary: OpenASOMCPMutationSummary
    let completed: [OpenASOMCPScreenshotExportedFile]
    let failed: [OpenASOMCPScreenshotExportFailure]
}

struct OpenASOMCPScreenshotExportedFile: Codable, Sendable {
    let screenshotID: String
    let urlString: String
    let relativePath: String
    let filePath: String
    let byteCount: Int
    let metadata: [String: String]
}

struct OpenASOMCPScreenshotExportFailure: Codable, Sendable {
    let screenshotID: String
    let urlString: String
    let relativePath: String?
    let errorDescription: String
    let metadata: [String: String]
}

struct OpenASOMCPAppPricingComparison: Codable, Sendable, Equatable {
    let generatedAt: Date
    let appStoreIDs: [String]
    let storefronts: [String]
    let platform: String
    let basePrices: [OpenASOMCPAppStorefrontPrice]
    let visibleProducts: [OpenASOMCPVisibleProductPricing]
    let failures: [OpenASOMCPPricingFailure]
    let notes: [String]
}

struct OpenASOMCPAppStorefrontPrice: Codable, Sendable, Equatable {
    let appStoreID: String
    let storefront: String
    let kind: String
    let amount: Decimal?
    let displayPrice: String?
    let currencyCode: String?
    let observedAt: Date
    let source: String
}

struct OpenASOMCPVisibleProductPricing: Codable, Sendable, Equatable {
    let appStoreID: String
    let storefront: String
    let products: [OpenASOMCPVisibleProductPrice]
    let observedAt: Date
    let isPotentiallyIncomplete: Bool
    let isTruncated: Bool
    let source: String
}

struct OpenASOMCPVisibleProductPrice: Codable, Sendable, Equatable {
    let name: String
    let displayPrice: String
}

struct OpenASOMCPPricingFailure: Codable, Sendable, Equatable {
    let scope: String
    let appStoreID: String?
    let storefront: String
    let error: OpenASOMCPErrorDTO
}

struct OpenASOMCPWebsiteMarkdownResult: Codable, Sendable {
    let sourceURLString: String
    let markdownURLString: String
    let markdown: String
    let byteCount: Int
    let fetchedAt: Date
}

struct OpenASOMCPAppWebsiteMarkdownResult: Codable, Sendable {
    let app: OpenASOMCPResolvedApp
    let discoveredURLs: [String]
    let selectedURLString: String?
    let markdownResult: OpenASOMCPWebsiteMarkdownResult?
    let statusMessage: String?
}

struct OpenASOMCPCompetitorSummary: Codable, Identifiable, Sendable {
    let id: String
    let appStoreID: String
    let name: String
    let sellerName: String?
    let bundleID: String?
    let iconURLString: String?
    let sharedKeywordCount: Int
    let occurrenceCount: Int
    let bestRank: Int
    let averageRank: Double
    let latestObservedAt: Date
    let evidence: [OpenASOMCPCompetitorKeywordEvidence]
}

struct OpenASOMCPCompetitorKeywordEvidence: Codable, Sendable, Hashable {
    let queryKey: String
    let keyword: String
    let storefront: String
    let platform: String
    let bestRank: Int
    let latestRank: Int
    let latestObservedAt: Date
    let source: String
}

struct OpenASOMCPRankingFallbackContext: Codable, Sendable, Equatable {
    let provider: String
    let category: String
    let transportCode: Int?
    let httpStatus: Int?
    let responseFailure: String?
}

struct OpenASOMCPRankingProvenance: Codable, Sendable, Equatable {
    let source: String
    let storefront: String
    let platform: String
    let fetchedAt: Date
    let fallbackContext: OpenASOMCPRankingFallbackContext?
}

struct OpenASOMCPRankedApp: Codable, Identifiable, Sendable {
    let id: String
    let appStoreID: String
    let position: Int
    let name: String
    let subtitle: String?
    let sellerName: String?
    let bundleID: String?
    let iconURLString: String?
    let primaryGenreName: String?
    let ratingCount: Int?
    let averageRating: Double?
    let screenshotURLs: [String]
}

struct OpenASOMCPKeywordRankingEvidence: Codable, Sendable {
    let keyword: String
    let storefront: String
    let platform: String
    let resultCount: Int
    let source: String
    let observedAt: Date
    let fallbackContext: OpenASOMCPRankingFallbackContext?
    let targetRank: Int?
    let topRatedAppCount: Int
    let maximumRatingCount: Int?
    let topApps: [OpenASOMCPRankedApp]
}

struct OpenASOMCPKeywordCandidate: Codable, Identifiable, Sendable {
    let id: String
    let keyword: String
    let storefront: String
    let platform: String
    let sources: [String]
    let reason: String
    let confidence: Double
    let isTracked: Bool
    let popularityScore: Int?
    let targetRank: Int?
    let resultCount: Int?
    let topRatedAppCount: Int
    let maximumRatingCount: Int?
    let topApps: [OpenASOMCPRankedApp]
    let rankingProvenance: OpenASOMCPRankingProvenance?
}

struct OpenASOMCPKeywordVerificationError: Codable, Sendable, Equatable {
    let keyword: String
    let storefront: String
    let platform: String
    let error: OpenASOMCPErrorDTO
}

struct OpenASOMCPKeywordSuggestionResult: Codable, Sendable {
    let app: OpenASOMCPAppSummary
    let generatedAt: Date
    let candidates: [OpenASOMCPKeywordCandidate]
    let errors: [OpenASOMCPKeywordVerificationError]
}

struct OpenASOMCPReviewRefreshOutcomeDTO: Codable, Sendable {
    let appStoreID: String
    let storefront: String
    let fetchedReviews: Int
    let storedReviews: Int
    let reachedLimit: Bool
    let error: OpenASOMCPErrorDTO?
}

struct OpenASOMCPReviewRefreshResult: Codable, Sendable {
    let summary: OpenASOMCPMutationSummary
    let outcomes: [OpenASOMCPReviewRefreshOutcomeDTO]
    let reviewLimitPerStorefront: Int
    let notes: [String]
}

struct OpenASOMCPReviewDownloadOutcomeDTO: Codable, Sendable {
    let appStoreID: String
    let storefront: String
    let fetchedReviews: Int
    let storedReviews: Int
    let batchCount: Int
    let exhausted: Bool
    let error: OpenASOMCPErrorDTO?
}

struct OpenASOMCPReviewDownloadResult: Codable, Sendable {
    let summary: OpenASOMCPMutationSummary
    let outcomes: [OpenASOMCPReviewDownloadOutcomeDTO]
    let batchPageCount: Int
    let notes: [String]
}

struct OpenASOMCPKeywordRefreshOutcome: Codable, Sendable {
    let track: OpenASOMCPKeywordSummary
    let rankingProvenance: OpenASOMCPRankingProvenance?
    let error: OpenASOMCPErrorDTO?
}

struct OpenASOMCPKeywordRefreshBatchSummary: Codable, Sendable, Equatable {
    let skipped: Int
    let errors: [OpenASOMCPErrorDTO]
}

struct OpenASOMCPKeywordRefreshResult: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case summary
        case outcomes
        case batchSummary
        case notes
    }

    let summary: OpenASOMCPMutationSummary
    let outcomes: [OpenASOMCPKeywordRefreshOutcome]
    let batchSummary: OpenASOMCPKeywordRefreshBatchSummary?
    let notes: [String]

    init(
        summary: OpenASOMCPMutationSummary,
        outcomes: [OpenASOMCPKeywordRefreshOutcome],
        batchSummary: OpenASOMCPKeywordRefreshBatchSummary? = nil,
        notes: [String] = []
    ) {
        self.summary = summary
        self.outcomes = outcomes
        self.batchSummary = batchSummary
        self.notes = notes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(OpenASOMCPMutationSummary.self, forKey: .summary)
        outcomes = try container.decode([OpenASOMCPKeywordRefreshOutcome].self, forKey: .outcomes)
        batchSummary = try container.decodeIfPresent(OpenASOMCPKeywordRefreshBatchSummary.self, forKey: .batchSummary)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(outcomes, forKey: .outcomes)
        try container.encodeIfPresent(batchSummary, forKey: .batchSummary)
        if !notes.isEmpty {
            try container.encode(notes, forKey: .notes)
        }
    }
}

struct OpenASOMCPCompetitorReviewRefreshResult: Codable, Sendable {
    let competitors: [OpenASOMCPCompetitorSummary]
    let summary: OpenASOMCPMutationSummary
    let outcomes: [OpenASOMCPReviewRefreshOutcomeDTO]
    let reviewLimitPerStorefront: Int
    let notes: [String]
}

struct OpenASOMCPCompetitorScreenshotExportFailure: Codable, Sendable {
    let competitor: OpenASOMCPCompetitorSummary
    let error: OpenASOMCPErrorDTO
}

struct OpenASOMCPCompetitorScreenshotExportResult: Codable, Sendable {
    let competitors: [OpenASOMCPCompetitorSummary]
    let summary: OpenASOMCPMutationSummary
    let exports: [OpenASOMCPScreenshotExportResult]
    let failures: [OpenASOMCPCompetitorScreenshotExportFailure]
    let notes: [String]
}

struct OpenASOMCPLandscapeCompetitor: Codable, Identifiable, Sendable {
    let id: String
    let app: OpenASOMCPRankedApp
    let occurrenceCount: Int
    let bestRank: Int
    let averageRank: Double
    let totalRatingCount: Int
    let evidenceKeywords: [String]
    let recentReviews: [OpenASOMCPReview]
    let screenshots: [OpenASOMCPScreenshot]
}

struct OpenASOMCPKeywordLandscapeResult: Codable, Sendable {
    let app: OpenASOMCPAppSummary
    let generatedAt: Date
    let seedKeywords: [String]
    let verifiedKeywords: [OpenASOMCPKeywordCandidate]
    let competitors: [OpenASOMCPLandscapeCompetitor]
    let notes: [String]
    let errors: [OpenASOMCPKeywordVerificationError]
}

struct OpenASOMCPLocalizationResearchContext: Codable, Sendable {
    let appStoreID: String
    let generatedAt: Date
    let baselineStorefront: String
    let storefronts: [String]
    let platform: String
    let apps: [OpenASOMCPLocalizationAppContext]
    let notes: [String]
    let errors: [OpenASOMCPLocalizationFetchError]
}

struct OpenASOMCPLocalizationAppContext: Codable, Identifiable, Sendable {
    let id: String
    let role: String
    let app: OpenASOMCPAppSummary
    let supportedLanguageCodes: [String]
    let supportedLanguageCodesSource: String?
    let supportedLanguageCodesFetchedAt: Date?
    let baseline: OpenASOMCPLocalizationMetadataSnapshot?
    let storefronts: [OpenASOMCPLocalizationStorefrontContext]
    let screenshotExport: OpenASOMCPScreenshotExportResult?
    let notes: [String]
}

struct OpenASOMCPLocalizationStorefrontContext: Codable, Sendable {
    let storefront: String
    let languageCode: String?
    let metadata: OpenASOMCPLocalizationMetadataSnapshot?
    let baselineMetadata: OpenASOMCPLocalizationMetadataSnapshot?
    let comparison: OpenASOMCPLocalizationMetadataComparison
    let screenshots: [OpenASOMCPScreenshot]
    let baselineScreenshots: [OpenASOMCPScreenshot]
    let screenshotComparisons: [OpenASOMCPLocalizationScreenshotComparison]
    let exportedScreenshots: [OpenASOMCPScreenshotExportedFile]
    let notes: [String]
}

struct OpenASOMCPLocalizationMetadataSnapshot: Codable, Sendable {
    let storefront: String
    let name: String
    let subtitle: String?
    let descriptionText: String?
    let releaseNotes: String?
    let primaryGenreName: String?
    let version: String?
    let source: String
    let isAvailable: Bool
    let lastFetchedAt: Date
    let screenshotCount: Int
}

struct OpenASOMCPLocalizationMetadataComparison: Codable, Sendable {
    let nameDiffersFromUS: Bool
    let subtitleDiffersFromUS: Bool
    let descriptionDiffersFromUS: Bool
}

struct OpenASOMCPLocalizationScreenshotComparison: Codable, Sendable {
    let platform: String
    let displayType: String
    let screenshotURLsDifferFromUS: Bool
    let screenshotURLAddedCount: Int
    let screenshotURLRemovedCount: Int
    let screenshotURLSharedCount: Int
    let hasStorefrontScreenshots: Bool
    let hasBaselineScreenshots: Bool
    let storefrontScreenshotURLs: [String]
    let baselineScreenshotURLs: [String]
}

struct OpenASOMCPLocalizationFetchError: Codable, Sendable, Equatable {
    let appStoreID: String
    let storefront: String
    let error: OpenASOMCPErrorDTO
}

extension OpenASOError {
    var code: String {
        switch self {
        case .emptyQuery:
            return "empty_query"
        case .invalidAppStoreID:
            return "invalid_app_store_id"
        case .appNotFound:
            return "app_not_found"
        case .networkUnavailable:
            return "network_unavailable"
        case .rateLimited:
            return "rate_limited"
        case .decodingFailed:
            return "decoding_failed"
        case .unexpectedResponse:
            return "unexpected_response"
        case .primaryProviderUnavailable:
            return "primary_provider_unavailable"
        case .providerUnavailable:
            return "provider_unavailable"
        }
    }
}
