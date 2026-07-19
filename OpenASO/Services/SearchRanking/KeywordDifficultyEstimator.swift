import Foundation

struct KeywordDifficultyRankedResult: Equatable, Sendable {
    let position: Int
    let appStoreID: Int64
    let title: String
    let subtitle: String?
    let ratingCount: Int?

    init(
        position: Int,
        appStoreID: Int64,
        title: String,
        subtitle: String? = nil,
        ratingCount: Int?
    ) {
        self.position = position
        self.appStoreID = appStoreID
        self.title = title
        self.subtitle = subtitle
        self.ratingCount = ratingCount
    }

    init(searchResult: SearchRankingItem) {
        self.init(
            position: searchResult.position,
            appStoreID: searchResult.appStoreID,
            title: searchResult.name,
            subtitle: searchResult.subtitle,
            ratingCount: searchResult.ratingCount
        )
    }
}

enum KeywordDifficultyEstimation: Equatable, Sendable {
    case estimated(EstimatedKeywordDifficulty)
    case unavailable(KeywordDifficultyUnavailable)
}

struct EstimatedKeywordDifficulty: Equatable, Sendable {
    enum Confidence: String, Equatable, Sendable {
        case low
        case medium
        case high
    }

    let score: Int
    let confidenceScore: Int
    let confidence: Confidence
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let evidence: KeywordDifficultyEvidence
    let notes: [String]
}

struct KeywordDifficultyUnavailable: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case emptyKeyword
        case insufficientResults
        case insufficientRatingEvidence
    }

    let reason: Reason
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let evidence: KeywordDifficultyEvidence
    let notes: [String]
}

struct KeywordDifficultyResultEvidence: Equatable, Sendable {
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
}

struct KeywordDifficultyEvidence: Equatable, Sendable {
    let consideredResultCount: Int
    let ratedResultCount: Int
    let weightedRatingCoveragePercentage: Int
    let maximumRatingCount: Int?
    let medianRatingCount: Int?
    let ratingAuthorityScore: Int?
    let metadataSaturationScore: Int?
    let resultEvidence: [KeywordDifficultyResultEvidence]

    var ratingCoveragePercentage: Int {
        guard consideredResultCount > 0 else { return 0 }
        return Int((Double(ratedResultCount) / Double(consideredResultCount) * 100).rounded())
    }

    var exactTitlePhraseMatchCount: Int {
        resultEvidence.count(where: \.exactTitlePhraseMatch)
    }

    var exactSubtitlePhraseMatchCount: Int {
        resultEvidence.count(where: \.exactSubtitlePhraseMatch)
    }
}

enum KeywordDifficultyEstimator {
    static let algorithmIdentifier = "top10-authority-saturation"
    static let algorithmVersion = 1
    static let maximumResultCount = 10
    static let minimumResultCount = 3
    static let minimumRatedResultCount = 3

    static func estimate(
        keyword: String,
        searchResults: [SearchRankingItem]
    ) -> KeywordDifficultyEstimation {
        estimate(
            keyword: keyword,
            rankedResults: searchResults.map(KeywordDifficultyRankedResult.init(searchResult:))
        )
    }

    static func estimate(
        keyword: String,
        rankedResults: [KeywordDifficultyRankedResult]
    ) -> KeywordDifficultyEstimation {
        let consideredResults = normalizedTopResults(rankedResults)
        let keywordTokens = tokens(keyword)
        let resultEvidence = makeResultEvidence(
            consideredResults,
            keywordTokens: keywordTokens
        )
        let evidence = makeEvidence(resultEvidence)

        guard !keywordTokens.isEmpty else {
            return unavailable(
                reason: .emptyKeyword,
                evidence: evidence,
                note: "Estimated competition is unavailable because the keyword is empty."
            )
        }
        guard consideredResults.count >= minimumResultCount else {
            return unavailable(
                reason: .insufficientResults,
                evidence: evidence,
                note: "Estimated competition is unavailable until at least \(minimumResultCount) unique top-ten ranking results are available."
            )
        }
        guard evidence.ratedResultCount >= minimumRatedResultCount else {
            return unavailable(
                reason: .insufficientRatingEvidence,
                evidence: evidence,
                note: "Estimated competition is unavailable until at least \(minimumRatedResultCount) top-ten results include rating counts."
            )
        }

        let ratingAuthority = Double(evidence.ratingAuthorityScore ?? 0)
        let metadataSaturation = Double(evidence.metadataSaturationScore ?? 0)
        let score = boundedScore(ratingAuthority * 0.70 + metadataSaturation * 0.30)
        let confidenceScore = confidenceScore(
            consideredResultCount: evidence.consideredResultCount,
            weightedRatingCoveragePercentage: evidence.weightedRatingCoveragePercentage
        )
        let confidence = confidence(for: confidenceScore)

        return .estimated(EstimatedKeywordDifficulty(
            score: score,
            confidenceScore: confidenceScore,
            confidence: confidence,
            algorithmIdentifier: algorithmIdentifier,
            algorithmVersion: algorithmVersion,
            evidence: evidence,
            notes: [
                "Heuristic estimated competition based on the current top App Store search results.",
                "Uses 70% rating-count authority and 30% title/subtitle keyword saturation.",
                "This is not Apple Ads difficulty, Search Popularity, or an Apple-provided metric.",
                "Evidence confidence \(confidence.rawValue) (\(confidenceScore)/100): \(evidence.ratedResultCount) of \(evidence.consideredResultCount) sampled results included rating counts."
            ]
        ))
    }

    private static func normalizedTopResults(
        _ results: [KeywordDifficultyRankedResult]
    ) -> [KeywordDifficultyRankedResult] {
        // Provider positions are not a unique key. Keep different apps that share
        // a position ordered by app ID, then deduplicate only repeated app IDs.
        let sortedResults = results
            .filter { (1...maximumResultCount).contains($0.position) }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                if $0.appStoreID != $1.appStoreID { return $0.appStoreID < $1.appStoreID }
                let leftHasRatingEvidence = $0.ratingCount.map { $0 >= 0 } ?? false
                let rightHasRatingEvidence = $1.ratingCount.map { $0 >= 0 } ?? false
                if leftHasRatingEvidence != rightHasRatingEvidence {
                    return leftHasRatingEvidence
                }
                if leftHasRatingEvidence,
                   let leftRatingCount = $0.ratingCount,
                   let rightRatingCount = $1.ratingCount,
                   leftRatingCount != rightRatingCount
                {
                    return leftRatingCount < rightRatingCount
                }
                if $0.title != $1.title { return $0.title < $1.title }
                let leftSubtitle = $0.subtitle ?? ""
                let rightSubtitle = $1.subtitle ?? ""
                if leftSubtitle != rightSubtitle { return leftSubtitle < rightSubtitle }
                if ($0.ratingCount == nil) != ($1.ratingCount == nil) {
                    return $0.ratingCount == nil
                }
                if let leftRatingCount = $0.ratingCount,
                   let rightRatingCount = $1.ratingCount,
                   leftRatingCount != rightRatingCount
                {
                    return leftRatingCount < rightRatingCount
                }
                return false
            }

        var seenAppStoreIDs = Set<Int64>()
        return Array(sortedResults.filter {
            seenAppStoreIDs.insert($0.appStoreID).inserted
        }.prefix(maximumResultCount))
    }

    private static func makeResultEvidence(
        _ results: [KeywordDifficultyRankedResult],
        keywordTokens: [String]
    ) -> [KeywordDifficultyResultEvidence] {
        let uniqueKeywordTokens = Set(keywordTokens)
        return results.map { result in
            let validRatingCount = result.ratingCount.flatMap { $0 >= 0 ? $0 : nil }
            let titleTokens = tokens(result.title)
            let subtitleTokens = tokens(result.subtitle ?? "")
            let titleTokenSet = Set(titleTokens)
            let combinedTokenSet = titleTokenSet.union(subtitleTokens)
            let exactTitlePhraseMatch = containsPhrase(keywordTokens, in: titleTokens)
            let exactSubtitlePhraseMatch = containsPhrase(keywordTokens, in: subtitleTokens)

            let titleCoverage = tokenCoverage(
                keywordTokens: uniqueKeywordTokens,
                candidateTokens: titleTokenSet
            )
            let combinedCoverage = tokenCoverage(
                keywordTokens: uniqueKeywordTokens,
                candidateTokens: combinedTokenSet
            )
            let metadataMatchScore: Double?
            if keywordTokens.isEmpty {
                metadataMatchScore = nil
            } else {
                metadataMatchScore = max(
                    titleCoverage * 100,
                    combinedCoverage * 75
                )
            }

            return KeywordDifficultyResultEvidence(
                position: result.position,
                appStoreID: result.appStoreID,
                title: result.title,
                subtitle: result.subtitle,
                ratingCount: validRatingCount,
                ratingAuthorityScore: validRatingCount.map(ratingAuthorityScore),
                titleTokenCoveragePercentage: keywordTokens.isEmpty ? nil : boundedScore(titleCoverage * 100),
                combinedTokenCoveragePercentage: keywordTokens.isEmpty ? nil : boundedScore(combinedCoverage * 100),
                metadataMatchScore: metadataMatchScore.map(boundedScore),
                exactTitlePhraseMatch: exactTitlePhraseMatch,
                exactSubtitlePhraseMatch: exactSubtitlePhraseMatch
            )
        }
    }

    private static func makeEvidence(
        _ resultEvidence: [KeywordDifficultyResultEvidence]
    ) -> KeywordDifficultyEvidence {
        let ratedEvidence = resultEvidence.filter { $0.ratingCount != nil }
        let ratingCounts = ratedEvidence.compactMap(\.ratingCount).sorted()
        let totalWeight = resultEvidence.reduce(0.0) { partialResult, evidence in
            partialResult + positionWeight(evidence.position)
        }
        let ratedWeight = ratedEvidence.reduce(0.0) { partialResult, evidence in
            partialResult + positionWeight(evidence.position)
        }
        let weightedRatingCoverage = totalWeight > 0 ? ratedWeight / totalWeight * 100 : 0

        return KeywordDifficultyEvidence(
            consideredResultCount: resultEvidence.count,
            ratedResultCount: ratedEvidence.count,
            weightedRatingCoveragePercentage: boundedScore(weightedRatingCoverage),
            maximumRatingCount: ratingCounts.last,
            medianRatingCount: medianRatingCount(ratingCounts),
            ratingAuthorityScore: weightedAverage(
                ratedEvidence,
                value: { $0.ratingAuthorityScore }
            ),
            metadataSaturationScore: weightedAverage(
                resultEvidence,
                value: { $0.metadataMatchScore }
            ),
            resultEvidence: resultEvidence
        )
    }

    private static func weightedAverage(
        _ evidence: [KeywordDifficultyResultEvidence],
        value: (KeywordDifficultyResultEvidence) -> Int?
    ) -> Int? {
        let availableEvidence = evidence.compactMap { item -> (KeywordDifficultyResultEvidence, Int)? in
            value(item).map { (item, $0) }
        }
        guard !availableEvidence.isEmpty else { return nil }

        let totalWeight = availableEvidence.reduce(0.0) { partialResult, pair in
            partialResult + positionWeight(pair.0.position)
        }
        guard totalWeight > 0 else { return nil }
        let weightedValue = availableEvidence.reduce(0.0) { partialResult, pair in
            partialResult + Double(pair.1) * positionWeight(pair.0.position)
        }
        return boundedScore(weightedValue / totalWeight)
    }

    private static func ratingAuthorityScore(_ ratingCount: Int) -> Int {
        boundedScore(min(1, log10(Double(ratingCount) + 1) / 6) * 100)
    }

    private static func medianRatingCount(_ sortedRatingCounts: [Int]) -> Int? {
        guard !sortedRatingCounts.isEmpty else { return nil }
        let middleIndex = sortedRatingCounts.count / 2
        guard sortedRatingCounts.count.isMultiple(of: 2) else {
            return sortedRatingCounts[middleIndex]
        }

        let lower = sortedRatingCounts[middleIndex - 1]
        let upper = sortedRatingCounts[middleIndex]
        return lower + (upper - lower) / 2
    }

    private static func tokenCoverage(
        keywordTokens: Set<String>,
        candidateTokens: Set<String>
    ) -> Double {
        guard !keywordTokens.isEmpty else { return 0 }
        return Double(keywordTokens.intersection(candidateTokens).count) / Double(keywordTokens.count)
    }

    private static func containsPhrase(_ phrase: [String], in candidate: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= candidate.count else { return false }
        if phrase.count == 1 {
            return candidate.contains(phrase[0])
        }

        for startIndex in 0...(candidate.count - phrase.count) {
            if candidate[startIndex..<(startIndex + phrase.count)].elementsEqual(phrase) {
                return true
            }
        }
        return false
    }

    private static func tokens(_ value: String) -> [String] {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func positionWeight(_ position: Int) -> Double {
        Double(maximumResultCount - position + 1)
    }

    private static func confidenceScore(
        consideredResultCount: Int,
        weightedRatingCoveragePercentage: Int
    ) -> Int {
        let sampleCoverage = Double(consideredResultCount) / Double(maximumResultCount)
        let ratingCoverage = Double(weightedRatingCoveragePercentage) / 100
        return boundedScore(sqrt(sampleCoverage * ratingCoverage) * 100)
    }

    private static func confidence(
        for score: Int
    ) -> EstimatedKeywordDifficulty.Confidence {
        switch score {
        case 85...:
            return .high
        case 65...:
            return .medium
        default:
            return .low
        }
    }

    private static func unavailable(
        reason: KeywordDifficultyUnavailable.Reason,
        evidence: KeywordDifficultyEvidence,
        note: String
    ) -> KeywordDifficultyEstimation {
        .unavailable(KeywordDifficultyUnavailable(
            reason: reason,
            algorithmIdentifier: algorithmIdentifier,
            algorithmVersion: algorithmVersion,
            evidence: evidence,
            notes: [
                "This would be a heuristic estimate, not Apple Ads difficulty or an Apple-provided metric.",
                note
            ]
        ))
    }

    private static func boundedScore(_ value: Double) -> Int {
        Int(min(100, max(0, value)).rounded())
    }
}
