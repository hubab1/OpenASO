import Foundation

enum KeywordTargetingText {
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func filler(_ locale: String) -> Set<String> {
        locale.lowercased().hasPrefix("en") ? ["a", "an", "and", "for", "the", "to", "of", "with", "in"] : []
    }

    /// Conservative English plural matching is reported as a variant, never an
    /// exact phrase or proof that Apple indexes a query.
    static func variant(_ word: String, locale: String) -> String {
        guard locale.lowercased().hasPrefix("en"), word.count > 3,
              word.hasSuffix("s"), !["ss", "us", "is"].contains(where: word.hasSuffix),
              !["news", "series", "species"].contains(word) else { return word }
        return String(word.dropLast())
    }
}

struct KeywordAppContext: Sendable {
    let name: String
    let featureText: String
    var locale = "en-US"

    var brandTokens: [String] {
        var prefix = name
        for separator in [" - ", " – ", " — ", ": ", " | "] {
            if let range = prefix.range(of: separator) { prefix = String(prefix[..<range.lowerBound]) }
        }
        return KeywordTargetingText.tokens(prefix)
    }

    func relevance(_ keyword: String) -> KeywordRelevance {
        let words = KeywordTargetingText.tokens(keyword).filter {
            !KeywordTargetingText.filler(locale).contains($0)
        }
        let keywordTokens = KeywordTargetingText.tokens(keyword)
        let brand = !brandTokens.isEmpty && keywordTokens.windowsContain(brandTokens)
        let featureTokens = Set(KeywordTargetingText.tokens(name + " " + featureText).map {
            KeywordTargetingText.variant($0, locale: locale)
        })
        let matched = words.filter { featureTokens.contains(KeywordTargetingText.variant($0, locale: locale)) }
        return .init(
            score: brand ? 1 : (words.isEmpty ? 0 : Double(matched.count) / Double(words.count)),
            matchedTerms: Array(Set(matched)).sorted(),
            isOwnBrand: brand,
            basis: "app_metadata_token_overlap"
        )
    }
}

struct KeywordRelevance: Codable, Sendable {
    let score: Double
    let matchedTerms: [String]
    let isOwnBrand: Bool
    let basis: String
}

struct KeywordMetadataToken: Codable, Sendable {
    let term: String
    let fields: [String]
    let variantFields: [String]
    let isFiller: Bool
}

struct KeywordMetadataCoverage: Codable, Sendable {
    let status: String
    let literalPhraseFields: [String]
    let components: [KeywordMetadataToken]
    let missingTerms: [String]
}

struct MetadataFieldValidation: Codable, Sendable {
    let characterCounts: [String: Int]
    let limits: [String: Int]
    let errors: [String]
    let warnings: [String]
}

struct KeywordTargetingRanking: Codable, Sendable {
    let rank: Int?
    let source: String
    let observedAt: Date
    let sampledResults: Int
    var isNative: Bool { source == RankingSource.appStoreWeb.rawValue }
}

struct KeywordTargetingItem: Codable, Sendable {
    let keyword: String
    let popularity: OpenASOMCPKeywordPopularity
    let relevance: KeywordRelevance
    let coverage: KeywordMetadataCoverage
    let ranking: KeywordTargetingRanking?
    let opportunity: String
    let rationale: [String]
    var competition: KeywordTargetingCompetition? = nil
}

/// Ephemeral analysis of the same bounded native sample used for rank checks.
/// It is never written into Apple's popularity or legacy difficulty fields.
struct KeywordTargetingCompetition: Codable, Sendable {
    let score: Int?
    let confidence: String?
    let confidenceScore: Int?
    let unavailableReason: String?
    let source: String
    let observedAt: Date
    let algorithmIdentifier: String
    let algorithmVersion: Int
    let evidence: KeywordDifficultyEvidence?
    let notes: [String]

    static func analyze(_ row: OpenASOMCPKeywordRankingEvidence) -> Self {
        guard row.source == RankingSource.appStoreWeb.rawValue else {
            return .init(score: nil, confidence: nil, confidenceScore: nil,
                         unavailableReason: "native_ranking_required", source: row.source,
                         observedAt: row.observedAt, algorithmIdentifier: KeywordDifficultyEstimator.algorithmIdentifier,
                         algorithmVersion: KeywordDifficultyEstimator.algorithmVersion, evidence: nil,
                         notes: ["Fallback results cannot establish native App Store competition."])
        }
        let results = row.topApps.compactMap { app -> KeywordDifficultyRankedResult? in
            guard let id = Int64(app.appStoreID) else { return nil }
            return .init(position: app.position, appStoreID: id, title: app.name,
                         subtitle: app.subtitle, ratingCount: app.ratingCount)
        }
        switch KeywordDifficultyEstimator.estimate(keyword: row.keyword, rankedResults: results) {
        case .estimated(let value):
            return .init(score: value.score, confidence: value.confidence.rawValue,
                         confidenceScore: value.confidenceScore, unavailableReason: nil,
                         source: row.source, observedAt: row.observedAt,
                         algorithmIdentifier: value.algorithmIdentifier, algorithmVersion: value.algorithmVersion,
                         evidence: value.evidence, notes: value.notes)
        case .unavailable(let value):
            return .init(score: nil, confidence: nil, confidenceScore: nil,
                         unavailableReason: value.reason.rawValue, source: row.source,
                         observedAt: row.observedAt, algorithmIdentifier: value.algorithmIdentifier,
                         algorithmVersion: value.algorithmVersion, evidence: value.evidence, notes: value.notes)
        }
    }
}

struct KeywordTargetingAudit: Codable, Sendable {
    let metadata: AppStoreMetadataSnapshot
    let metadataHash: String
    let storefront: String
    let searchPlatform: String
    let generatedAt: Date
    let items: [KeywordTargetingItem]
    let validation: MetadataFieldValidation
    let providerErrors: [OpenASOMCPKeywordSuggestionProviderError]
    let notes: [String]
}

struct MetadataDraftComparison: Codable, Sendable {
    let baselineHash: String
    let baselineMetadata: AppStoreMetadataSnapshot
    let proposedFields: AppStoreMetadataFields
    let validation: MetadataFieldValidation
    let gainedCoverage: [String]
    let lostCoverage: [String]
    let items: [MetadataDraftCoverageChange]
    let visibilityChanges: [MetadataDraftVisibilityChange]
    let notes: [String]
}

struct MetadataDraftVisibilityChange: Codable, Sendable {
    let keyword: String
    let beforeFields: [String]
    let afterFields: [String]
}

struct MetadataDraftCoverageChange: Codable, Sendable {
    let keyword: String
    let popularityScore: Int?
    let before: KeywordMetadataCoverage
    let after: KeywordMetadataCoverage
}

enum KeywordTargetingAnalysis {
    static func coverage(_ keyword: String, fields: AppStoreMetadataFields, locale: String) -> KeywordMetadataCoverage {
        let allFields = [
            "title": fields.title,
            "subtitle": fields.subtitle,
            "keywords": fields.keywords ?? "",
        ]
        let byField = allFields.mapValues(KeywordTargetingText.tokens)
        let words = KeywordTargetingText.tokens(keyword)
        let components = words.map { word in
            KeywordMetadataToken(
                term: word,
                fields: byField.keys.filter { byField[$0, default: []].contains(word) }.sorted(),
                variantFields: byField.keys.filter { key in
                    byField[key, default: []].contains {
                        $0 != word && KeywordTargetingText.variant($0, locale: locale)
                            == KeywordTargetingText.variant(word, locale: locale)
                    }
                }.sorted(),
                isFiller: KeywordTargetingText.filler(locale).contains(word)
            )
        }
        let required = components.filter { !$0.isFiller }
        let missing = required.filter { $0.fields.isEmpty && $0.variantFields.isEmpty }.map(\.term)
        let literal = byField.keys.filter { byField[$0, default: []].windowsContain(words) }.sorted()
        let status: String
        if !literal.isEmpty { status = "literal_phrase" }
        else if fields.keywords == nil && !missing.isEmpty { status = "private_field_unknown" }
        else if required.isEmpty { status = "uncovered" }
        else if missing.isEmpty {
            status = required.contains { $0.fields.isEmpty } ? "variant_combination" : "component_combination"
        } else if missing.count == required.count { status = "uncovered" }
        else { status = "partial" }
        return .init(status: status, literalPhraseFields: literal, components: components, missingTerms: missing)
    }

    static func covered(_ coverage: KeywordMetadataCoverage) -> Bool {
        ["literal_phrase", "component_combination", "variant_combination"].contains(coverage.status)
    }

    static func validate(_ fields: AppStoreMetadataFields, locale: String) -> MetadataFieldValidation {
        let counts = ["title": fields.title.count, "subtitle": fields.subtitle.count, "keywords": fields.keywords?.count ?? 0]
        let limits = ["title": 30, "subtitle": 30, "keywords": 100]
        var errors = counts.keys.sorted().compactMap { key in
            counts[key, default: 0] > limits[key, default: 0] ? "\(key) exceeds \(limits[key, default: 0]) characters." : nil
        }
        if fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Title must not be empty.")
        }
        var warnings: [String] = []
        let titleTerms = Set(KeywordTargetingText.tokens(fields.title).map {
            KeywordTargetingText.variant($0, locale: locale)
        })
        for word in KeywordTargetingText.tokens(fields.subtitle)
            where !KeywordTargetingText.filler(locale).contains(word)
                && titleTerms.contains(KeywordTargetingText.variant(word, locale: locale)) {
            warnings.append("Subtitle repeats a title word or plural variant: \(word).")
        }
        guard let keywords = fields.keywords else {
            return .init(characterCounts: counts, limits: limits, errors: errors,
                         warnings: warnings + ["Private keywords are unavailable; coverage is incomplete."])
        }
        let visible = Set(KeywordTargetingText.tokens(fields.title + " " + fields.subtitle).map {
            KeywordTargetingText.variant($0, locale: locale)
        })
        var seen = Set<String>()
        for word in KeywordTargetingText.tokens(keywords) {
            let normalized = KeywordTargetingText.variant(word, locale: locale)
            if visible.contains(normalized) || !seen.insert(normalized).inserted {
                warnings.append("Keyword field repeats \(word) or a plural variant already present.")
            }
            if KeywordTargetingText.filler(locale).contains(word) {
                warnings.append("Keyword field spends space on filler: \(word).")
            }
            if ["app", "apps", "free"].contains(word) {
                warnings.append("Review generic or pricing term in keyword field: \(word).")
            }
        }
        if keywords.contains(", ") { warnings.append("Remove spaces after commas to recover keyword-field capacity.") }
        warnings.append("Check competitor names, feature claims, and semantic relevance before publishing.")
        return .init(characterCounts: counts, limits: limits, errors: errors, warnings: Array(Set(warnings)).sorted())
    }

    static func item(
        popularity: OpenASOMCPKeywordPopularity,
        metadata: AppStoreMetadataSnapshot,
        context: KeywordAppContext,
        ranking: KeywordTargetingRanking?
    ) -> KeywordTargetingItem {
        let relevance = context.relevance(popularity.keyword)
        let coverage = coverage(popularity.keyword, fields: metadata.fields, locale: metadata.locale)
        let aboveFloor = (popularity.popularityScore ?? 0) > 5
        let opportunity: String
        if relevance.isOwnBrand { opportunity = "own_brand" }
        else if relevance.score < 0.35 { opportunity = "relevance_review" }
        else if popularity.popularityScore == nil { opportunity = "demand_unknown" }
        else if !aboveFloor { opportunity = "weak_demand" }
        else if coverage.status == "private_field_unknown" { opportunity = "private_metadata_unknown" }
        else if !covered(coverage) { opportunity = "metadata_gap" }
        else if let ranking, ranking.isNative, let rank = ranking.rank {
            opportunity = rank <= 3 ? "maintain" : "ranking_opportunity"
        } else { opportunity = "ranking_needs_verification" }
        var rationale = [
            "App relevance uses metadata overlap; semantic fit and achievable rank still require review.",
            "Metadata presence describes lexical coverage, not confirmed indexing.",
        ]
        if !coverage.missingTerms.isEmpty { rationale.append("Missing components: \(coverage.missingTerms.joined(separator: ", ")).") }
        if let ranking, !ranking.isNative {
            rationale.append("Ranking evidence is \(ranking.source); native organic rank remains unverified.")
        }
        if let ranking, ranking.rank == nil {
            rationale.append("Target was absent from a \(ranking.sampledResults)-result sample; this does not prove non-indexing.")
        }
        return .init(keyword: popularity.keyword, popularity: popularity, relevance: relevance, coverage: coverage,
                     ranking: ranking, opportunity: opportunity, rationale: rationale)
    }

    static func compare(_ audit: KeywordTargetingAudit, proposed: AppStoreMetadataFields) -> MetadataDraftComparison {
        let changes = audit.items.map {
            MetadataDraftCoverageChange(
                keyword: $0.keyword, popularityScore: $0.popularity.popularityScore, before: $0.coverage,
                after: coverage($0.keyword, fields: proposed, locale: audit.metadata.locale)
            )
        }
        let visibility = changes.compactMap { change -> MetadataDraftVisibilityChange? in
            let before = change.before.literalPhraseFields.filter { $0 != "keywords" }
            let after = change.after.literalPhraseFields.filter { $0 != "keywords" }
            guard before != after else { return nil }
            return .init(keyword: change.keyword, beforeFields: before, afterFields: after)
        }
        let baseValidation = validate(proposed, locale: audit.metadata.locale)
        var warnings = baseValidation.warnings
        let context = KeywordAppContext(name: audit.metadata.fields.title, featureText: "", locale: audit.metadata.locale)
        if !context.brandTokens.isEmpty && !context.relevance(proposed.title).isOwnBrand {
            warnings.append("The proposed title removes the existing brand; review this positioning change.")
        }
        let lostWinners = audit.items.filter { item in
            item.ranking?.isNative == true && (item.ranking?.rank ?? Int.max) <= 10
                && changes.contains {
                    $0.keyword == item.keyword && $0.after.status != "private_field_unknown" && !covered($0.after)
                }
        }
        for item in lostWinners {
            warnings.append("The draft loses component coverage for an observed native top-ten term: \(item.keyword).")
        }
        let validation = MetadataFieldValidation(characterCounts: baseValidation.characterCounts, limits: baseValidation.limits,
                                                 errors: baseValidation.errors, warnings: warnings)
        return .init(
            baselineHash: audit.metadataHash,
            baselineMetadata: audit.metadata,
            proposedFields: proposed,
            validation: validation,
            gainedCoverage: changes.filter {
                $0.before.status != "private_field_unknown" && !covered($0.before) && covered($0.after)
            }.map(\.keyword),
            lostCoverage: changes.filter {
                $0.after.status != "private_field_unknown" && covered($0.before) && !covered($0.after)
            }.map(\.keyword),
            items: changes,
            visibilityChanges: visibility,
            notes: [
                "Coverage gains are lexical hypotheses, not predicted rank or download lift.",
                "Review lost coverage and changes in visible positioning before choosing a draft.",
                "Unavailable private keyword data is not treated as an empty field or a verified coverage gain/loss.",
                "This comparison does not publish metadata. Re-read the baseline and compare its hash before any later apply step.",
            ]
        )
    }
}

private extension Array where Element == String {
    func windowsContain(_ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= count else { return false }
        return (0...(count - phrase.count)).contains { start in
            Array(self[start..<(start + phrase.count)]) == phrase
        }
    }
}
