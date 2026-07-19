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

struct OpenASOMCPEstimatedKeywordDifficultySummary: Codable, Equatable, Sendable {
    let state: String
    let score: Int?
    let confidenceScore: Int?
    let confidence: String?
    let unavailableReason: String?
    let estimationSource: String
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let rankingSource: String
    let rankingFetchedAt: Date
    let computedAt: Date
    let isStale: Bool
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
    let estimatedDifficulty: OpenASOMCPEstimatedKeywordDifficultySummary?
    let notes: String
    let rankingStatusMessage: String?
    let popularityStatusMessage: String?
    let statusMessage: String?
    let lastRefreshAt: Date?
    let latestRankingSource: String?
    let latestRankingObservedAt: Date?
    let createdAt: Date
}

struct OpenASOMCPEstimatedKeywordDifficultyFallback: Codable, Equatable, Sendable {
    let provider: String
    let category: String
    let transportCode: Int?
    let httpStatus: Int?
    let responseFailure: String?
}

struct OpenASOMCPEstimatedKeywordDifficultyEvidence: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(position)::\(appStoreID)" }

    let position: Int
    let appStoreID: String
    let title: String
    let subtitle: String?
    let ratingCount: Int?
    let ratingAuthorityScore: Int?
    let titleTokenCoveragePercentage: Int?
    let combinedTokenCoveragePercentage: Int?
    let metadataMatchScore: Int?
    let exactTitlePhraseMatch: Bool
    let exactSubtitlePhraseMatch: Bool
}

/// A read-only, app-scoped view of the stored local heuristic and its bounded
/// evidence. `state == "missing"` is distinct from an unavailable estimate.
struct OpenASOMCPEstimatedKeywordDifficulty: Codable, Equatable, Sendable {
    let appStoreID: String
    let keyword: String
    let queryKey: String
    let storefront: String
    let platform: String
    let state: String
    let calculationID: String?
    let score: Int?
    let confidenceScore: Int?
    let confidence: String?
    let unavailableReason: String?
    let estimationSource: String?
    let algorithmIdentifier: String?
    let algorithmVersion: Int?
    let requestedResultLimit: Int?
    let providerResultCount: Int?
    let consideredResultCount: Int?
    let ratedResultCount: Int?
    let weightedRatingCoveragePercentage: Int?
    let maximumRatingCount: Int?
    let medianRatingCount: Int?
    let ratingAuthorityScore: Int?
    let metadataSaturationScore: Int?
    let exactTitlePhraseMatchCount: Int?
    let exactSubtitlePhraseMatchCount: Int?
    let rankingSource: String?
    let rankingFetchedAt: Date?
    let computedAt: Date?
    let isStale: Bool?
    let fallback: OpenASOMCPEstimatedKeywordDifficultyFallback?
    let notes: [String]
    let availableEvidenceCount: Int
    let returnedEvidenceCount: Int
    let evidenceTruncated: Bool
    let evidence: [OpenASOMCPEstimatedKeywordDifficultyEvidence]
}

enum OpenASOMCPKeywordMarketOutputLimits {
    static let maximumEncodedJSONBytes = 2_000_000
    static let maximumKeywordUTF8Bytes = 200
    static let maximumFailureMessageUTF8Bytes = 512
    static let maximumProvenanceUTF8Bytes = 128
    static let maximumReasonUTF8Bytes = 256

    static func bounded(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> (value: String, wasTruncated: Bool) {
        guard value.utf8.count > maximumUTF8Bytes else {
            return (value, false)
        }
        guard maximumUTF8Bytes > 0 else { return ("", true) }

        let suffix = "…"
        let suffixBytes = suffix.utf8.count
        let contentLimit = max(maximumUTF8Bytes - suffixBytes, 0)
        var output = ""
        var outputBytes = 0
        for character in value {
            let fragment = String(character)
            let fragmentBytes = fragment.utf8.count
            guard outputBytes + fragmentBytes <= contentLimit else { break }
            output.append(character)
            outputBytes += fragmentBytes
        }
        if suffixBytes <= maximumUTF8Bytes {
            output.append(suffix)
        }
        return (output, true)
    }

    static func partialReasons(
        _ reasons: [String],
        outputWasTruncated: Bool
    ) -> [String] {
        guard outputWasTruncated, !reasons.contains("output_truncated") else {
            return reasons
        }
        return (reasons + ["output_truncated"]).sorted()
    }
}

private struct OpenASOMCPKeywordMarketProjection {
    private(set) var wasTruncated = false

    mutating func string(_ value: String, maximumUTF8Bytes: Int) -> String {
        let result = OpenASOMCPKeywordMarketOutputLimits.bounded(
            value,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        wasTruncated = wasTruncated || result.wasTruncated
        return result.value
    }

    mutating func optionalString(
        _ value: String?,
        maximumUTF8Bytes: Int
    ) -> String? {
        value.map { string($0, maximumUTF8Bytes: maximumUTF8Bytes) }
    }
}

struct OpenASOMCPKeywordMarketRankingEvidence: Codable, Equatable, Sendable {
    let rank: Int?
    let searchedAt: Date
    let source: String
    let resultCount: Int
}

struct OpenASOMCPKeywordMarketRankingFailure: Codable, Equatable, Sendable {
    let message: String
    let updatedAt: Date
    let outputWasTruncated: Bool
}

struct OpenASOMCPKeywordMarketDifficulty: Codable, Equatable, Sendable {
    let state: String
    let score: Int?
    let confidenceScore: Int?
    let confidence: String?
    let unavailableReason: String?
    let estimationSource: String
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let rankingSource: String
    let rankingFetchedAt: Date
    let computedAt: Date
    let isStale: Bool
    let outputWasTruncated: Bool
}

struct OpenASOMCPKeywordMarket: Codable, Equatable, Identifiable, Sendable {
    var id: String { storefront }

    let storefront: String
    let state: String
    let rankingEvidence: OpenASOMCPKeywordMarketRankingEvidence?
    let rankingFailure: OpenASOMCPKeywordMarketRankingFailure?
    let estimatedDifficulty: OpenASOMCPKeywordMarketDifficulty?
    let isStale: Bool
    let isPartial: Bool
    let outputWasTruncated: Bool
}

struct OpenASOMCPKeywordMarketRankSummary: Codable, Equatable, Sendable {
    let storefront: String
    let rank: Int
    let searchedAt: Date
    let source: String
    let state: String
    let isStale: Bool
}

struct OpenASOMCPKeywordMarketSummary: Codable, Equatable, Sendable {
    let requestedMarketCount: Int
    let trackedMarketCount: Int
    let availableRankingEvidenceCount: Int
    let rankedEvidenceMarketCount: Int
    let freshRankedMarketCount: Int
    let notRankedMarketCount: Int
    let neverRefreshedMarketCount: Int
    let failedWithCachedEvidenceMarketCount: Int
    let failedWithoutEvidenceMarketCount: Int
    let notTrackedMarketCount: Int
    let unavailableMarketCount: Int
    let staleMarketCount: Int
    let bestMarket: OpenASOMCPKeywordMarketRankSummary?
    let worstMarket: OpenASOMCPKeywordMarketRankSummary?
    let averageRank: Double?
    let rankSpread: Int?
}

struct OpenASOMCPKeywordMarketRankings: Codable, Equatable, Identifiable, Sendable {
    var id: String { [keywordDigest, platform].joined(separator: "::") }

    let keyword: String
    let normalizedKeyword: String
    let keywordDigest: String
    let platform: String
    let markets: [OpenASOMCPKeywordMarket]
    let summary: OpenASOMCPKeywordMarketSummary
    let isPartial: Bool
    let partialReasons: [String]
    let outputWasTruncated: Bool
}

struct OpenASOMCPKeywordMarketRankingsResult: Codable, Equatable, Sendable {
    let appStoreID: String
    let storefronts: [String]
    let platform: String
    let keyword: String?
    let items: [OpenASOMCPKeywordMarketRankings]
    let nextCursor: String?
    let requestedKeywordLimit: Int
    let effectiveKeywordLimit: Int
    let marketEvidenceLimit: Int
    let returnedMarketEvidenceCount: Int
    let isPartial: Bool
    let partialReasons: [String]
    let staleMarketCount: Int
    let outputWasTruncated: Bool
}

extension OpenASOMCPKeywordMarketRankingsResult {
    init(_ page: KeywordMarketInsightsPage) {
        let projectedItems = page.items.map(OpenASOMCPKeywordMarketRankings.init)
        let wasTruncated = projectedItems.contains(where: \.outputWasTruncated)
        appStoreID = String(page.scope.appStoreID)
        storefronts = page.scope.storefronts
        platform = page.scope.platform.rawValue
        keyword = page.scope.keyword
        items = projectedItems
        nextCursor = page.nextCursor
        requestedKeywordLimit = page.requestedKeywordLimit
        effectiveKeywordLimit = page.effectiveKeywordLimit
        marketEvidenceLimit = page.marketEvidenceLimit
        returnedMarketEvidenceCount = page.returnedMarketEvidenceCount
        isPartial = page.isPartial || wasTruncated
        partialReasons = OpenASOMCPKeywordMarketOutputLimits.partialReasons(
            page.partialReasons.map(\.rawValue),
            outputWasTruncated: wasTruncated
        )
        staleMarketCount = page.staleMarketCount
        outputWasTruncated = wasTruncated
    }
}

private extension OpenASOMCPKeywordMarketRankings {
    init(_ insight: KeywordMarketInsight) {
        var projection = OpenASOMCPKeywordMarketProjection()
        let projectedKeyword = projection.string(
            insight.keyword,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumKeywordUTF8Bytes
        )
        let projectedNormalizedKeyword = projection.string(
            insight.normalizedKeyword,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumKeywordUTF8Bytes
        )
        let projectedMarkets = insight.markets.map(OpenASOMCPKeywordMarket.init)
        let wasTruncated = projection.wasTruncated
            || projectedMarkets.contains(where: \.outputWasTruncated)
        keyword = projectedKeyword
        normalizedKeyword = projectedNormalizedKeyword
        keywordDigest = KeywordMarketInsightsStableIdentity.keywordDigest(
            insight.normalizedKeyword
        )
        platform = insight.platform.rawValue
        markets = projectedMarkets
        summary = OpenASOMCPKeywordMarketSummary(insight.summary)
        isPartial = insight.isPartial || wasTruncated
        partialReasons = OpenASOMCPKeywordMarketOutputLimits.partialReasons(
            insight.partialReasons.map(\.rawValue),
            outputWasTruncated: wasTruncated
        )
        outputWasTruncated = wasTruncated
    }
}

private extension OpenASOMCPKeywordMarket {
    init(_ market: KeywordMarketInsightMarket) {
        let projectedFailure = market.rankingFailure.map(
            OpenASOMCPKeywordMarketRankingFailure.init
        )
        let projectedDifficulty = market.estimatedDifficulty.map(
            OpenASOMCPKeywordMarketDifficulty.init
        )
        let wasTruncated = projectedFailure?.outputWasTruncated == true
            || projectedDifficulty?.outputWasTruncated == true
        storefront = market.storefront
        state = market.state.rawValue
        rankingEvidence = market.rankingEvidence.map(
            OpenASOMCPKeywordMarketRankingEvidence.init
        )
        rankingFailure = projectedFailure
        estimatedDifficulty = projectedDifficulty
        isStale = market.isStale
        isPartial = market.isPartial || wasTruncated
        outputWasTruncated = wasTruncated
    }
}

private extension OpenASOMCPKeywordMarketRankingEvidence {
    init(_ evidence: KeywordMarketInsightRankingEvidence) {
        rank = evidence.rank
        searchedAt = evidence.searchedAt
        source = evidence.source.rawValue
        resultCount = evidence.resultCount
    }
}

private extension OpenASOMCPKeywordMarketRankingFailure {
    init(_ failure: KeywordMarketInsightRankingFailure) {
        let projection = OpenASOMCPKeywordMarketOutputLimits.bounded(
            failure.message,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumFailureMessageUTF8Bytes
        )
        message = projection.value
        updatedAt = failure.updatedAt
        outputWasTruncated = projection.wasTruncated
    }
}

private extension OpenASOMCPKeywordMarketDifficulty {
    init(_ difficulty: KeywordMarketInsightDifficulty) {
        var projection = OpenASOMCPKeywordMarketProjection()
        state = projection.string(
            difficulty.state,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumProvenanceUTF8Bytes
        )
        score = difficulty.score
        confidenceScore = difficulty.confidenceScore
        confidence = projection.optionalString(
            difficulty.confidence,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumProvenanceUTF8Bytes
        )
        unavailableReason = projection.optionalString(
            difficulty.unavailableReason,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumReasonUTF8Bytes
        )
        estimationSource = projection.string(
            difficulty.estimationSource,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumProvenanceUTF8Bytes
        )
        algorithmIdentifier = projection.string(
            difficulty.algorithmIdentifier,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumProvenanceUTF8Bytes
        )
        algorithmVersion = difficulty.algorithmVersion
        rankingSource = projection.string(
            difficulty.rankingSource,
            maximumUTF8Bytes: OpenASOMCPKeywordMarketOutputLimits.maximumProvenanceUTF8Bytes
        )
        rankingFetchedAt = difficulty.rankingFetchedAt
        computedAt = difficulty.computedAt
        isStale = difficulty.isStale
        outputWasTruncated = projection.wasTruncated
    }
}

private extension OpenASOMCPKeywordMarketSummary {
    init(_ summary: KeywordMarketInsightSummary) {
        requestedMarketCount = summary.requestedMarketCount
        trackedMarketCount = summary.trackedMarketCount
        availableRankingEvidenceCount = summary.availableRankingEvidenceCount
        rankedEvidenceMarketCount = summary.rankedEvidenceMarketCount
        freshRankedMarketCount = summary.freshRankedMarketCount
        notRankedMarketCount = summary.notRankedMarketCount
        neverRefreshedMarketCount = summary.neverRefreshedMarketCount
        failedWithCachedEvidenceMarketCount = summary.failedWithCachedEvidenceMarketCount
        failedWithoutEvidenceMarketCount = summary.failedWithoutEvidenceMarketCount
        notTrackedMarketCount = summary.notTrackedMarketCount
        unavailableMarketCount = summary.unavailableMarketCount
        staleMarketCount = summary.staleMarketCount
        bestMarket = summary.bestMarket.map(OpenASOMCPKeywordMarketRankSummary.init)
        worstMarket = summary.worstMarket.map(OpenASOMCPKeywordMarketRankSummary.init)
        averageRank = summary.averageRank
        rankSpread = summary.rankSpread
    }
}

private extension OpenASOMCPKeywordMarketRankSummary {
    init(_ summary: KeywordMarketInsightRankSummary) {
        storefront = summary.storefront
        rank = summary.rank
        searchedAt = summary.searchedAt
        source = summary.source.rawValue
        state = summary.state.rawValue
        isStale = summary.isStale
    }
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
        case notes
        case batchSummary
    }

    let summary: OpenASOMCPMutationSummary
    let outcomes: [OpenASOMCPKeywordRefreshOutcome]
    let notes: [String]
    let batchSummary: OpenASOMCPKeywordRefreshBatchSummary?

    init(
        summary: OpenASOMCPMutationSummary,
        outcomes: [OpenASOMCPKeywordRefreshOutcome],
        notes: [String] = [],
        batchSummary: OpenASOMCPKeywordRefreshBatchSummary? = nil
    ) {
        self.summary = summary
        self.outcomes = outcomes
        self.notes = notes
        self.batchSummary = batchSummary
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(OpenASOMCPMutationSummary.self, forKey: .summary)
        outcomes = try container.decode([OpenASOMCPKeywordRefreshOutcome].self, forKey: .outcomes)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        batchSummary = try container.decodeIfPresent(
            OpenASOMCPKeywordRefreshBatchSummary.self,
            forKey: .batchSummary
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(outcomes, forKey: .outcomes)
        if !notes.isEmpty {
            try container.encode(notes, forKey: .notes)
        }
        try container.encodeIfPresent(batchSummary, forKey: .batchSummary)
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
