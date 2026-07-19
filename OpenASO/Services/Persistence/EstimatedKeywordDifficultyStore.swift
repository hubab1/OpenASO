import Foundation
import SwiftData

enum EstimatedKeywordDifficultyFallbackCategory: String, Codable, CaseIterable, Sendable {
    case transport
    case httpStatus
    case response
    case provider
    case other
}

/// Redacted response classifications mirrored from the ranking provider.
/// Arbitrary response bodies and error strings are intentionally not accepted.
enum EstimatedKeywordDifficultyFallbackResponseFailure: String, Codable, CaseIterable, Sendable {
    case serializedServerDataMissing
    case decodingFailed
    case nonHTTPResponse
    case requestIntentMissing
    case requestIntentAmbiguous
    case pageShapeChanged
    case authoritativeShelfMissing
    case authoritativeShelfAmbiguous
    case malformedSearchResult
    case truncatedResults
}

struct EstimatedKeywordDifficultyFallbackProvenance: Equatable, Sendable {
    let provider: RankingSource
    let category: EstimatedKeywordDifficultyFallbackCategory
    let transportCode: Int?
    let httpStatus: Int?
    let responseFailure: EstimatedKeywordDifficultyFallbackResponseFailure?

    init(
        provider: RankingSource,
        category: EstimatedKeywordDifficultyFallbackCategory,
        transportCode: Int? = nil,
        httpStatus: Int? = nil,
        responseFailure: EstimatedKeywordDifficultyFallbackResponseFailure? = nil
    ) {
        self.provider = provider
        self.category = category
        self.transportCode = transportCode
        self.httpStatus = httpStatus
        self.responseFailure = responseFailure
    }
}

enum EstimatedKeywordDifficultyPersistenceResult: Equatable, Sendable {
    case estimated(
        score: Int,
        confidenceScore: Int,
        confidence: EstimatedKeywordDifficultyConfidence
    )
    case unavailable(reason: EstimatedKeywordDifficultyUnavailableReason)
}

struct EstimatedKeywordDifficultyResultEvidence: Equatable, Sendable {
    let position: Int
    let appStoreID: Int64
    let title: String
    let subtitle: String?
    let ratingCount: Int?
    let ratingAuthorityScore: Int?
    let titleTokenCoveragePercentage: Int?
    let combinedTokenCoveragePercentage: Int?
    let metadataMatchScore: Int?
    let exactTitlePhraseMatch: Bool
    let exactSubtitlePhraseMatch: Bool

    init(
        position: Int,
        appStoreID: Int64,
        title: String,
        subtitle: String? = nil,
        ratingCount: Int?,
        ratingAuthorityScore: Int?,
        titleTokenCoveragePercentage: Int?,
        combinedTokenCoveragePercentage: Int?,
        metadataMatchScore: Int?,
        exactTitlePhraseMatch: Bool,
        exactSubtitlePhraseMatch: Bool
    ) {
        self.position = position
        self.appStoreID = appStoreID
        self.title = title
        self.subtitle = subtitle
        self.ratingCount = ratingCount
        self.ratingAuthorityScore = ratingAuthorityScore
        self.titleTokenCoveragePercentage = titleTokenCoveragePercentage
        self.combinedTokenCoveragePercentage = combinedTokenCoveragePercentage
        self.metadataMatchScore = metadataMatchScore
        self.exactTitlePhraseMatch = exactTitlePhraseMatch
        self.exactSubtitlePhraseMatch = exactSubtitlePhraseMatch
    }
}

struct EstimatedKeywordDifficultyEvidence: Equatable, Sendable {
    let consideredResultCount: Int
    let ratedResultCount: Int
    let weightedRatingCoveragePercentage: Int
    let maximumRatingCount: Int?
    let medianRatingCount: Int?
    let ratingAuthorityScore: Int?
    let metadataSaturationScore: Int?
    let resultEvidence: [EstimatedKeywordDifficultyResultEvidence]

    init(
        consideredResultCount: Int,
        ratedResultCount: Int,
        weightedRatingCoveragePercentage: Int,
        maximumRatingCount: Int?,
        medianRatingCount: Int?,
        ratingAuthorityScore: Int?,
        metadataSaturationScore: Int?,
        resultEvidence: [EstimatedKeywordDifficultyResultEvidence]
    ) {
        self.consideredResultCount = consideredResultCount
        self.ratedResultCount = ratedResultCount
        self.weightedRatingCoveragePercentage = weightedRatingCoveragePercentage
        self.maximumRatingCount = maximumRatingCount
        self.medianRatingCount = medianRatingCount
        self.ratingAuthorityScore = ratingAuthorityScore
        self.metadataSaturationScore = metadataSaturationScore
        self.resultEvidence = resultEvidence
    }
}

/// Branch-independent transport for the V4 store. Item 20c adapts the estimator
/// and ranking-provider values into this payload without making persistence
/// depend on either implementation branch.
struct EstimatedKeywordDifficultyPersistencePayload: Equatable, Sendable {
    let queryKey: String
    let calculationID: UUID
    let keyword: String
    let storefront: String
    let platform: AppPlatform
    let result: EstimatedKeywordDifficultyPersistenceResult
    let estimationSource: EstimatedKeywordDifficultySource
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let requestedResultLimit: Int
    let providerResultCount: Int
    let evidence: EstimatedKeywordDifficultyEvidence
    let rankingSource: RankingSource
    let rankingFetchedAt: Date
    let computedAt: Date
    let fallback: EstimatedKeywordDifficultyFallbackProvenance?
    let notes: [String]

    init(
        queryKey: String,
        calculationID: UUID = UUID(),
        keyword: String,
        storefront: String,
        platform: AppPlatform,
        result: EstimatedKeywordDifficultyPersistenceResult,
        estimationSource: EstimatedKeywordDifficultySource = .topResultsHeuristic,
        algorithmIdentifier: String,
        algorithmVersion: Int,
        requestedResultLimit: Int,
        providerResultCount: Int,
        evidence: EstimatedKeywordDifficultyEvidence,
        rankingSource: RankingSource,
        rankingFetchedAt: Date,
        computedAt: Date,
        fallback: EstimatedKeywordDifficultyFallbackProvenance? = nil,
        notes: [String]
    ) {
        self.queryKey = queryKey
        self.calculationID = calculationID
        self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.platform = platform
        self.result = result
        self.estimationSource = estimationSource
        self.algorithmIdentifier = algorithmIdentifier
        self.algorithmVersion = algorithmVersion
        self.requestedResultLimit = requestedResultLimit
        self.providerResultCount = providerResultCount
        self.evidence = evidence
        self.rankingSource = rankingSource
        self.rankingFetchedAt = rankingFetchedAt
        self.computedAt = computedAt
        self.fallback = fallback
        self.notes = notes
    }
}

struct EstimatedKeywordDifficultySnapshot: Equatable, Sendable {
    let queryKey: String
    let calculationID: UUID
    let keyword: String
    let storefront: String
    let platformRaw: String
    let stateRaw: String
    let score: Int?
    let confidenceScore: Int?
    let confidenceRaw: String?
    let unavailableReasonRaw: String?
    let estimationSourceRaw: String
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let requestedResultLimit: Int
    let providerResultCount: Int
    let consideredResultCount: Int
    let ratedResultCount: Int
    let weightedRatingCoveragePercentage: Int
    let maximumRatingCount: Int?
    let medianRatingCount: Int?
    let ratingAuthorityScore: Int?
    let metadataSaturationScore: Int?
    let exactTitlePhraseMatchCount: Int
    let exactSubtitlePhraseMatchCount: Int
    let rankingSourceRaw: String
    let rankingFetchedAt: Date
    let computedAt: Date
    let fallbackProviderRaw: String?
    let fallbackCategoryRaw: String?
    let fallbackTransportCode: Int?
    let fallbackHTTPStatus: Int?
    let fallbackResponseFailureRaw: String?
    let notes: [String]
    let resultEvidence: [EstimatedKeywordDifficultyResultEvidence]

    var platform: AppPlatform? {
        AppPlatform(rawValue: platformRaw)
    }

    var state: EstimatedKeywordDifficultyState? {
        EstimatedKeywordDifficultyState(rawValue: stateRaw)
    }

    var confidence: EstimatedKeywordDifficultyConfidence? {
        confidenceRaw.flatMap(EstimatedKeywordDifficultyConfidence.init(rawValue:))
    }

    var unavailableReason: EstimatedKeywordDifficultyUnavailableReason? {
        unavailableReasonRaw.flatMap(EstimatedKeywordDifficultyUnavailableReason.init(rawValue:))
    }

    var estimationSource: EstimatedKeywordDifficultySource? {
        EstimatedKeywordDifficultySource(rawValue: estimationSourceRaw)
    }

    var rankingSource: RankingSource? {
        RankingSource(rawValue: rankingSourceRaw)
    }

    var fallbackCategory: EstimatedKeywordDifficultyFallbackCategory? {
        fallbackCategoryRaw.flatMap(EstimatedKeywordDifficultyFallbackCategory.init(rawValue:))
    }

    var fallbackResponseFailure: EstimatedKeywordDifficultyFallbackResponseFailure? {
        fallbackResponseFailureRaw.flatMap(
            EstimatedKeywordDifficultyFallbackResponseFailure.init(rawValue:)
        )
    }

    /// Freshness follows the ranking evidence, not the later calculation time.
    func isStale(asOf date: Date, maximumAge: TimeInterval) -> Bool {
        guard maximumAge > 0 else { return true }
        return date.timeIntervalSince(rankingFetchedAt) >= maximumAge
    }
}

enum EstimatedKeywordDifficultyUpsertOutcome: Equatable, Sendable {
    case inserted
    case updated
    case unchanged
    case ignoredOlder
}

enum EstimatedKeywordDifficultyStoreError: Error, Equatable {
    case invalidQueryScope
    case invalidRequestedResultLimit
    case invalidProviderResultCount
    case invalidTimestampOrder
    case invalidAlgorithm
    case invalidNotes
    case invalidResultState
    case invalidEvidence(String)
    case invalidFallback
    case revisionConflict
}

enum EstimatedKeywordDifficultyStore {
    static let maximumEvidenceResultCount = 10
    static let maximumRequestedResultCount = 200
    private static let maximumTextLength = 1_000
    private static let maximumNoteCount = 10

    static func persist(
        _ payload: EstimatedKeywordDifficultyPersistencePayload,
        using store: BackgroundModelStore
    ) async throws -> EstimatedKeywordDifficultyUpsertOutcome {
        try await store.write { modelContext in
            try upsert(payload, in: modelContext)
        }
    }

    static func upsert(
        _ payload: EstimatedKeywordDifficultyPersistencePayload,
        in modelContext: ModelContext
    ) throws -> EstimatedKeywordDifficultyUpsertOutcome {
        try validate(payload)

        let queryKey = payload.queryKey
        let metricDescriptor = FetchDescriptor<EstimatedKeywordDifficultyMetric>(
            predicate: #Predicate { metric in
                metric.queryKey == queryKey
            }
        )
        let existingMetrics = try modelContext.fetch(metricDescriptor)
        let incomingMetricKey = EstimatedKeywordDifficultyMetric.makeMetricKey(
            queryKey: payload.queryKey,
            calculationID: payload.calculationID
        )
        if let sameCalculation = existingMetrics.first(where: {
            $0.metricKey == incomingMetricKey
        }) {
            guard compareRevision(payload, to: sameCalculation) == .orderedSame,
                  try snapshot(for: sameCalculation, in: modelContext) == snapshot(from: payload)
            else {
                throw EstimatedKeywordDifficultyStoreError.revisionConflict
            }
        }
        let existingMetric = latestMetric(in: existingMetrics)

        if let existingMetric {
            switch compareRevision(payload, to: existingMetric) {
            case .orderedAscending:
                try compactVisibleRevisions(
                    keeping: existingMetric,
                    among: existingMetrics,
                    in: modelContext
                )
                return .ignoredOlder
            case .orderedSame:
                let existing = try snapshot(for: existingMetric, in: modelContext)
                guard existing == snapshot(from: payload) else {
                    throw EstimatedKeywordDifficultyStoreError.revisionConflict
                }
                try replaceEvidence(for: payload, in: modelContext)
                for metric in existingMetrics where metric.metricKey != existingMetric.metricKey {
                    modelContext.delete(metric)
                }
                return .unchanged
            case .orderedDescending:
                break
            }
        }

        let metric = makeMetric(from: payload)
        modelContext.insert(metric)
        for existing in existingMetrics {
            modelContext.delete(existing)
        }
        try replaceEvidence(for: payload, in: modelContext)
        return existingMetric == nil ? .inserted : .updated
    }

    static func snapshot(
        queryKey: String,
        in modelContext: ModelContext
    ) throws -> EstimatedKeywordDifficultySnapshot? {
        let targetQueryKey = queryKey
        let descriptor = FetchDescriptor<EstimatedKeywordDifficultyMetric>(
            predicate: #Predicate { metric in
                metric.queryKey == targetQueryKey
            }
        )
        guard let metric = latestMetric(in: try modelContext.fetch(descriptor)) else { return nil }
        return try snapshot(for: metric, in: modelContext)
    }

    static func snapshots(
        queryKeys: [String],
        in modelContext: ModelContext
    ) throws -> [String: EstimatedKeywordDifficultySnapshot] {
        let targetQueryKeys = Array(Set(queryKeys))
        guard !targetQueryKeys.isEmpty else { return [:] }

        let descriptor = FetchDescriptor<EstimatedKeywordDifficultyMetric>(
            predicate: #Predicate { metric in
                targetQueryKeys.contains(metric.queryKey)
            }
        )
        let groupedMetrics = Dictionary(
            grouping: try modelContext.fetch(descriptor),
            by: \.queryKey
        )
        var result: [String: EstimatedKeywordDifficultySnapshot] = [:]
        for (queryKey, metrics) in groupedMetrics {
            guard let metric = latestMetric(in: metrics) else { continue }
            result[queryKey] = try snapshot(for: metric, in: modelContext)
        }
        return result
    }

    static func delete(
        queryKeys: [String],
        in modelContext: ModelContext
    ) throws {
        let targetQueryKeys = Array(Set(queryKeys))
        guard !targetQueryKeys.isEmpty else { return }

        let metricDescriptor = FetchDescriptor<EstimatedKeywordDifficultyMetric>(
            predicate: #Predicate { metric in
                targetQueryKeys.contains(metric.queryKey)
            }
        )
        let evidenceDescriptor = FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>(
            predicate: #Predicate { evidence in
                targetQueryKeys.contains(evidence.queryKey)
            }
        )
        for metric in try modelContext.fetch(metricDescriptor) {
            modelContext.delete(metric)
        }
        for evidence in try modelContext.fetch(evidenceDescriptor) {
            modelContext.delete(evidence)
        }
    }

    private static func validate(
        _ payload: EstimatedKeywordDifficultyPersistencePayload
    ) throws {
        let expectedQueryKey = KeywordQuery.makeQueryKey(
            term: payload.keyword,
            storefront: payload.storefront,
            platform: payload.platform
        )
        guard payload.queryKey == expectedQueryKey,
              payload.keyword.count <= maximumTextLength,
              payload.storefront.utf8.count == 2,
              payload.storefront.utf8.allSatisfy({ (97 ... 122).contains($0) })
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidQueryScope
        }
        guard (1 ... maximumRequestedResultCount).contains(
            payload.requestedResultLimit
        ) else {
            throw EstimatedKeywordDifficultyStoreError.invalidRequestedResultLimit
        }
        guard payload.providerResultCount >= payload.evidence.consideredResultCount,
              payload.providerResultCount <= payload.requestedResultLimit
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidProviderResultCount
        }
        guard payload.computedAt >= payload.rankingFetchedAt else {
            throw EstimatedKeywordDifficultyStoreError.invalidTimestampOrder
        }
        let normalizedAlgorithm = payload.algorithmIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedAlgorithm.isEmpty,
              normalizedAlgorithm == payload.algorithmIdentifier,
              normalizedAlgorithm.count <= 128,
              payload.algorithmVersion > 0
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidAlgorithm
        }
        guard payload.notes.count <= maximumNoteCount,
              payload.notes.allSatisfy({ note in
                  let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !normalized.isEmpty
                      && normalized == note
                      && normalized.count <= maximumTextLength
              })
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidNotes
        }
        try validate(
            result: payload.result,
            evidence: payload.evidence,
            keyword: payload.keyword
        )
        try validate(evidence: payload.evidence, keyword: payload.keyword)
        try validate(fallback: payload.fallback, rankingSource: payload.rankingSource)
    }

    private static func validate(
        result: EstimatedKeywordDifficultyPersistenceResult,
        evidence: EstimatedKeywordDifficultyEvidence,
        keyword: String
    ) throws {
        switch result {
        case .estimated(let score, let confidenceScore, let confidence):
            let confidenceMatches: Bool
            switch confidence {
            case .low:
                confidenceMatches = confidenceScore < 65
            case .medium:
                confidenceMatches = (65 ..< 85).contains(confidenceScore)
            case .high:
                confidenceMatches = confidenceScore >= 85
            }
            guard isPercentage(score),
                  isPercentage(confidenceScore),
                  confidenceMatches,
                  !keyword.isEmpty,
                  evidence.consideredResultCount >= 3,
                  evidence.ratedResultCount >= 3,
                  evidence.ratingAuthorityScore != nil,
                  evidence.metadataSaturationScore != nil
            else {
                throw EstimatedKeywordDifficultyStoreError.invalidResultState
            }
        case .unavailable(let reason):
            let reasonMatches: Bool
            switch reason {
            case .emptyKeyword:
                reasonMatches = keyword.isEmpty
            case .insufficientResults:
                reasonMatches = !keyword.isEmpty && evidence.consideredResultCount < 3
            case .insufficientRatingEvidence:
                reasonMatches = !keyword.isEmpty
                    && evidence.consideredResultCount >= 3
                    && evidence.ratedResultCount < 3
            }
            guard reasonMatches else {
                throw EstimatedKeywordDifficultyStoreError.invalidResultState
            }
        }
    }

    private static func validate(
        evidence: EstimatedKeywordDifficultyEvidence,
        keyword: String
    ) throws {
        guard evidence.resultEvidence.count <= maximumEvidenceResultCount,
              evidence.consideredResultCount == evidence.resultEvidence.count
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidEvidence("result count")
        }
        let ratedResults = evidence.resultEvidence.compactMap(\.ratingCount)
        guard evidence.ratedResultCount == ratedResults.count,
              evidence.ratedResultCount <= evidence.consideredResultCount,
              ratedResults.allSatisfy({ $0 >= 0 })
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidEvidence("rated result count")
        }
        guard isPercentage(evidence.weightedRatingCoveragePercentage),
              isOptionalPercentage(evidence.ratingAuthorityScore),
              isOptionalPercentage(evidence.metadataSaturationScore)
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidEvidence("summary score")
        }
        if ratedResults.isEmpty {
            guard evidence.maximumRatingCount == nil,
                  evidence.medianRatingCount == nil,
                  evidence.ratingAuthorityScore == nil
            else {
                throw EstimatedKeywordDifficultyStoreError.invalidEvidence("rating summary")
            }
        } else {
            let sortedRatings = ratedResults.sorted()
            guard evidence.maximumRatingCount == sortedRatings.last,
                  evidence.medianRatingCount == median(sortedRatings),
                  evidence.ratingAuthorityScore != nil
            else {
                throw EstimatedKeywordDifficultyStoreError.invalidEvidence("rating summary")
            }
        }

        let expectedCoverageRange: ClosedRange<Int>
        if evidence.resultEvidence.isEmpty || ratedResults.isEmpty {
            expectedCoverageRange = 0 ... 0
        } else if ratedResults.count == evidence.resultEvidence.count {
            expectedCoverageRange = 100 ... 100
        } else {
            expectedCoverageRange = 1 ... 99
        }
        guard expectedCoverageRange.contains(evidence.weightedRatingCoveragePercentage),
              (keyword.isEmpty || evidence.resultEvidence.isEmpty)
                ? evidence.metadataSaturationScore == nil
                : evidence.metadataSaturationScore != nil
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidEvidence("summary coherence")
        }

        let appStoreIDs = evidence.resultEvidence.map(\.appStoreID)
        guard Set(appStoreIDs).count == appStoreIDs.count else {
            throw EstimatedKeywordDifficultyStoreError.invalidEvidence("duplicate result")
        }
        for result in evidence.resultEvidence {
            let hasRating = result.ratingCount != nil
            let hasKeywordCoverage = result.titleTokenCoveragePercentage != nil
                && result.combinedTokenCoveragePercentage != nil
                && result.metadataMatchScore != nil
            let hasNoKeywordCoverage = result.titleTokenCoveragePercentage == nil
                && result.combinedTokenCoveragePercentage == nil
                && result.metadataMatchScore == nil
            guard (1 ... maximumEvidenceResultCount).contains(result.position),
                  result.appStoreID > 0,
                  result.title.count <= maximumTextLength,
                  (result.subtitle?.count ?? 0) <= maximumTextLength,
                  isOptionalPercentage(result.ratingAuthorityScore),
                  isOptionalPercentage(result.titleTokenCoveragePercentage),
                  isOptionalPercentage(result.combinedTokenCoveragePercentage),
                  isOptionalPercentage(result.metadataMatchScore),
                  hasRating == (result.ratingAuthorityScore != nil),
                  keyword.isEmpty ? hasNoKeywordCoverage : hasKeywordCoverage,
                  !keyword.isEmpty
                    || (!result.exactTitlePhraseMatch && !result.exactSubtitlePhraseMatch)
            else {
                throw EstimatedKeywordDifficultyStoreError.invalidEvidence("result value")
            }
        }
    }

    private static func validate(
        fallback: EstimatedKeywordDifficultyFallbackProvenance?,
        rankingSource: RankingSource
    ) throws {
        guard let fallback else {
            guard rankingSource != .iTunesFallback else {
                throw EstimatedKeywordDifficultyStoreError.invalidFallback
            }
            return
        }
        guard rankingSource == .iTunesFallback,
              fallback.provider == .appStoreWeb
        else {
            throw EstimatedKeywordDifficultyStoreError.invalidFallback
        }

        let valid: Bool
        switch fallback.category {
        case .transport:
            valid = fallback.httpStatus == nil && fallback.responseFailure == nil
        case .httpStatus:
            valid = fallback.transportCode == nil
                && fallback.responseFailure == nil
                && fallback.httpStatus.map({ (100 ... 599).contains($0) }) == true
        case .response:
            valid = fallback.transportCode == nil
                && fallback.httpStatus == nil
                && fallback.responseFailure != nil
        case .provider, .other:
            valid = fallback.transportCode == nil
                && fallback.httpStatus == nil
                && fallback.responseFailure == nil
        }
        guard valid else {
            throw EstimatedKeywordDifficultyStoreError.invalidFallback
        }
    }

    private static func isPercentage(_ value: Int) -> Bool {
        (0 ... 100).contains(value)
    }

    private static func isOptionalPercentage(_ value: Int?) -> Bool {
        value.map(isPercentage) ?? true
    }

    private static func median(_ sortedValues: [Int]) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let middleIndex = sortedValues.count / 2
        guard sortedValues.count.isMultiple(of: 2) else {
            return sortedValues[middleIndex]
        }
        let lower = sortedValues[middleIndex - 1]
        let upper = sortedValues[middleIndex]
        return lower + (upper - lower) / 2
    }

    private static func compareRevision(
        _ payload: EstimatedKeywordDifficultyPersistencePayload,
        to metric: EstimatedKeywordDifficultyMetric
    ) -> ComparisonResult {
        if payload.rankingFetchedAt != metric.rankingFetchedAt {
            return payload.rankingFetchedAt < metric.rankingFetchedAt
                ? .orderedAscending
                : .orderedDescending
        }
        if payload.computedAt != metric.computedAt {
            return payload.computedAt < metric.computedAt
                ? .orderedAscending
                : .orderedDescending
        }
        return payload.calculationID.uuidString.lowercased().compare(
            metric.calculationID.uuidString.lowercased()
        )
    }

    private static func latestMetric(
        in metrics: [EstimatedKeywordDifficultyMetric]
    ) -> EstimatedKeywordDifficultyMetric? {
        metrics.max { left, right in
            compareRevision(left, to: right) == .orderedAscending
        }
    }

    private static func compareRevision(
        _ left: EstimatedKeywordDifficultyMetric,
        to right: EstimatedKeywordDifficultyMetric
    ) -> ComparisonResult {
        if left.rankingFetchedAt != right.rankingFetchedAt {
            return left.rankingFetchedAt < right.rankingFetchedAt
                ? .orderedAscending
                : .orderedDescending
        }
        if left.computedAt != right.computedAt {
            return left.computedAt < right.computedAt
                ? .orderedAscending
                : .orderedDescending
        }
        return left.calculationID.uuidString.lowercased().compare(
            right.calculationID.uuidString.lowercased()
        )
    }

    private static func compactVisibleRevisions(
        keeping metric: EstimatedKeywordDifficultyMetric,
        among metrics: [EstimatedKeywordDifficultyMetric],
        in modelContext: ModelContext
    ) throws {
        for candidate in metrics where candidate.metricKey != metric.metricKey {
            modelContext.delete(candidate)
        }

        let queryKey = metric.queryKey
        let calculationID = metric.calculationID
        let descriptor = FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>(
            predicate: #Predicate { evidence in
                evidence.queryKey == queryKey && evidence.calculationID != calculationID
            }
        )
        for evidence in try modelContext.fetch(descriptor) {
            modelContext.delete(evidence)
        }
    }

    private static func makeMetric(
        from payload: EstimatedKeywordDifficultyPersistencePayload
    ) -> EstimatedKeywordDifficultyMetric {
        let result = resultFields(payload.result)
        let fallback = fallbackFields(payload.fallback)
        return EstimatedKeywordDifficultyMetric(
            queryKey: payload.queryKey,
            calculationID: payload.calculationID,
            keyword: payload.keyword,
            storefront: payload.storefront,
            platformRaw: payload.platform.rawValue,
            stateRaw: result.stateRaw,
            score: result.score,
            confidenceScore: result.confidenceScore,
            confidenceRaw: result.confidenceRaw,
            unavailableReasonRaw: result.unavailableReasonRaw,
            estimationSourceRaw: payload.estimationSource.rawValue,
            algorithmIdentifier: payload.algorithmIdentifier,
            algorithmVersion: payload.algorithmVersion,
            requestedResultLimit: payload.requestedResultLimit,
            providerResultCount: payload.providerResultCount,
            consideredResultCount: payload.evidence.consideredResultCount,
            ratedResultCount: payload.evidence.ratedResultCount,
            weightedRatingCoveragePercentage: payload.evidence.weightedRatingCoveragePercentage,
            maximumRatingCount: payload.evidence.maximumRatingCount,
            medianRatingCount: payload.evidence.medianRatingCount,
            ratingAuthorityScore: payload.evidence.ratingAuthorityScore,
            metadataSaturationScore: payload.evidence.metadataSaturationScore,
            exactTitlePhraseMatchCount: payload.evidence.resultEvidence.count(
                where: \.exactTitlePhraseMatch
            ),
            exactSubtitlePhraseMatchCount: payload.evidence.resultEvidence.count(
                where: \.exactSubtitlePhraseMatch
            ),
            rankingSourceRaw: payload.rankingSource.rawValue,
            rankingFetchedAt: payload.rankingFetchedAt,
            computedAt: payload.computedAt,
            fallbackProviderRaw: fallback.providerRaw,
            fallbackCategoryRaw: fallback.categoryRaw,
            fallbackTransportCode: fallback.transportCode,
            fallbackHTTPStatus: fallback.httpStatus,
            fallbackResponseFailureRaw: fallback.responseFailureRaw,
            notes: payload.notes
        )
    }

    private static func replaceEvidence(
        for payload: EstimatedKeywordDifficultyPersistencePayload,
        in modelContext: ModelContext
    ) throws {
        let queryKey = payload.queryKey
        let descriptor = FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>(
            predicate: #Predicate { evidence in
                evidence.queryKey == queryKey
            }
        )
        let existing = try modelContext.fetch(descriptor)
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.evidenceKey, $0) })
        var retainedKeys = Set<String>()

        for result in payload.evidence.resultEvidence {
            let evidenceKey = EstimatedKeywordDifficultyResultEvidenceRecord.makeEvidenceKey(
                queryKey: payload.queryKey,
                calculationID: payload.calculationID,
                position: result.position,
                appStoreID: result.appStoreID
            )
            retainedKeys.insert(evidenceKey)
            if let record = existingByKey[evidenceKey] {
                apply(result, payload: payload, to: record)
            } else {
                modelContext.insert(makeEvidenceRecord(result, payload: payload))
            }
        }
        for record in existing where !retainedKeys.contains(record.evidenceKey) {
            modelContext.delete(record)
        }
    }

    private static func makeEvidenceRecord(
        _ evidence: EstimatedKeywordDifficultyResultEvidence,
        payload: EstimatedKeywordDifficultyPersistencePayload
    ) -> EstimatedKeywordDifficultyResultEvidenceRecord {
        EstimatedKeywordDifficultyResultEvidenceRecord(
            queryKey: payload.queryKey,
            calculationID: payload.calculationID,
            position: evidence.position,
            appStoreID: evidence.appStoreID,
            title: evidence.title,
            subtitle: evidence.subtitle,
            ratingCount: evidence.ratingCount,
            ratingAuthorityScore: evidence.ratingAuthorityScore,
            titleTokenCoveragePercentage: evidence.titleTokenCoveragePercentage,
            combinedTokenCoveragePercentage: evidence.combinedTokenCoveragePercentage,
            metadataMatchScore: evidence.metadataMatchScore,
            exactTitlePhraseMatch: evidence.exactTitlePhraseMatch,
            exactSubtitlePhraseMatch: evidence.exactSubtitlePhraseMatch
        )
    }

    private static func apply(
        _ evidence: EstimatedKeywordDifficultyResultEvidence,
        payload: EstimatedKeywordDifficultyPersistencePayload,
        to record: EstimatedKeywordDifficultyResultEvidenceRecord
    ) {
        record.queryKey = payload.queryKey
        record.calculationID = payload.calculationID
        record.position = evidence.position
        record.appStoreID = evidence.appStoreID
        record.title = evidence.title
        record.subtitle = evidence.subtitle
        record.ratingCount = evidence.ratingCount
        record.ratingAuthorityScore = evidence.ratingAuthorityScore
        record.titleTokenCoveragePercentage = evidence.titleTokenCoveragePercentage
        record.combinedTokenCoveragePercentage = evidence.combinedTokenCoveragePercentage
        record.metadataMatchScore = evidence.metadataMatchScore
        record.exactTitlePhraseMatch = evidence.exactTitlePhraseMatch
        record.exactSubtitlePhraseMatch = evidence.exactSubtitlePhraseMatch
    }

    private static func snapshot(
        for metric: EstimatedKeywordDifficultyMetric,
        in modelContext: ModelContext
    ) throws -> EstimatedKeywordDifficultySnapshot {
        let queryKey = metric.queryKey
        let calculationID = metric.calculationID
        var descriptor = FetchDescriptor<EstimatedKeywordDifficultyResultEvidenceRecord>(
            predicate: #Predicate { evidence in
                evidence.queryKey == queryKey && evidence.calculationID == calculationID
            },
            sortBy: [
                SortDescriptor(\.position),
                SortDescriptor(\.appStoreID)
            ]
        )
        descriptor.fetchLimit = maximumEvidenceResultCount
        let resultEvidence = try modelContext.fetch(descriptor).map(evidence(from:))
        return snapshot(from: metric, resultEvidence: resultEvidence)
    }

    private static func snapshot(
        from metric: EstimatedKeywordDifficultyMetric,
        resultEvidence: [EstimatedKeywordDifficultyResultEvidence]
    ) -> EstimatedKeywordDifficultySnapshot {
        EstimatedKeywordDifficultySnapshot(
            queryKey: metric.queryKey,
            calculationID: metric.calculationID,
            keyword: metric.keyword,
            storefront: metric.storefront,
            platformRaw: metric.platformRaw,
            stateRaw: metric.stateRaw,
            score: metric.score,
            confidenceScore: metric.confidenceScore,
            confidenceRaw: metric.confidenceRaw,
            unavailableReasonRaw: metric.unavailableReasonRaw,
            estimationSourceRaw: metric.estimationSourceRaw,
            algorithmIdentifier: metric.algorithmIdentifier,
            algorithmVersion: metric.algorithmVersion,
            requestedResultLimit: metric.requestedResultLimit,
            providerResultCount: metric.providerResultCount,
            consideredResultCount: metric.consideredResultCount,
            ratedResultCount: metric.ratedResultCount,
            weightedRatingCoveragePercentage: metric.weightedRatingCoveragePercentage,
            maximumRatingCount: metric.maximumRatingCount,
            medianRatingCount: metric.medianRatingCount,
            ratingAuthorityScore: metric.ratingAuthorityScore,
            metadataSaturationScore: metric.metadataSaturationScore,
            exactTitlePhraseMatchCount: metric.exactTitlePhraseMatchCount,
            exactSubtitlePhraseMatchCount: metric.exactSubtitlePhraseMatchCount,
            rankingSourceRaw: metric.rankingSourceRaw,
            rankingFetchedAt: metric.rankingFetchedAt,
            computedAt: metric.computedAt,
            fallbackProviderRaw: metric.fallbackProviderRaw,
            fallbackCategoryRaw: metric.fallbackCategoryRaw,
            fallbackTransportCode: metric.fallbackTransportCode,
            fallbackHTTPStatus: metric.fallbackHTTPStatus,
            fallbackResponseFailureRaw: metric.fallbackResponseFailureRaw,
            notes: metric.notes,
            resultEvidence: resultEvidence
        )
    }

    private static func snapshot(
        from payload: EstimatedKeywordDifficultyPersistencePayload
    ) -> EstimatedKeywordDifficultySnapshot {
        let metric = makeMetric(from: payload)
        let evidence = payload.evidence.resultEvidence.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.appStoreID < $1.appStoreID
        }
        return snapshot(from: metric, resultEvidence: evidence)
    }

    private static func evidence(
        from record: EstimatedKeywordDifficultyResultEvidenceRecord
    ) -> EstimatedKeywordDifficultyResultEvidence {
        EstimatedKeywordDifficultyResultEvidence(
            position: record.position,
            appStoreID: record.appStoreID,
            title: record.title,
            subtitle: record.subtitle,
            ratingCount: record.ratingCount,
            ratingAuthorityScore: record.ratingAuthorityScore,
            titleTokenCoveragePercentage: record.titleTokenCoveragePercentage,
            combinedTokenCoveragePercentage: record.combinedTokenCoveragePercentage,
            metadataMatchScore: record.metadataMatchScore,
            exactTitlePhraseMatch: record.exactTitlePhraseMatch,
            exactSubtitlePhraseMatch: record.exactSubtitlePhraseMatch
        )
    }

    private static func resultFields(
        _ result: EstimatedKeywordDifficultyPersistenceResult
    ) -> (
        stateRaw: String,
        score: Int?,
        confidenceScore: Int?,
        confidenceRaw: String?,
        unavailableReasonRaw: String?
    ) {
        switch result {
        case .estimated(let score, let confidenceScore, let confidence):
            return (
                EstimatedKeywordDifficultyState.estimated.rawValue,
                score,
                confidenceScore,
                confidence.rawValue,
                nil
            )
        case .unavailable(let reason):
            return (
                EstimatedKeywordDifficultyState.unavailable.rawValue,
                nil,
                nil,
                nil,
                reason.rawValue
            )
        }
    }

    private static func fallbackFields(
        _ fallback: EstimatedKeywordDifficultyFallbackProvenance?
    ) -> (
        providerRaw: String?,
        categoryRaw: String?,
        transportCode: Int?,
        httpStatus: Int?,
        responseFailureRaw: String?
    ) {
        (
            fallback?.provider.rawValue,
            fallback?.category.rawValue,
            fallback?.transportCode,
            fallback?.httpStatus,
            fallback?.responseFailure?.rawValue
        )
    }
}
