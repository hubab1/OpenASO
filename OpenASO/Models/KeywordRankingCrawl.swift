import Foundation
import SwiftData

extension OpenASOSchemaV1 {
@Model
final class KeywordRankingCrawl {
    #Index<KeywordRankingCrawl>(
        [\.queryKey],
        [\.queryKey, \.observedAt],
        [\.observedAt]
    )

    @Attribute(.unique) var observationKey: String
    var queryKey: String
    var keyword: String
    var storefront: String
    var platformRaw: String
    var observedAt: Date
    var observedHour: Int
    var sourceRaw: String
    var resultCount: Int
    var submissionCount: Int
    var winningCount: Int
    var confidenceRaw: String?

    var items: [KeywordAppRanking]
    var query: KeywordQuery

    init(
        keyword: String,
        storefront: String,
        platform: AppPlatform,
        observedAt: Date,
        source: RankingSource,
        resultCount: Int,
        query: KeywordQuery,
        observedHour: Int? = nil,
        submissionCount: Int = 1,
        winningCount: Int = 1,
        confidence: String? = nil
    ) {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStorefront = storefront.lowercased()

        let queryKey = TrackedAppKeyword.makeQueryKey(
            term: normalizedKeyword,
            storefront: normalizedStorefront,
            platform: platform
        )
        self.queryKey = queryKey
        self.observationKey = Self.makeObservationKey(
            queryKey: queryKey,
            observedAt: observedAt,
            source: source
        )
        self.keyword = normalizedKeyword
        self.storefront = normalizedStorefront
        self.platformRaw = platform.rawValue
        self.observedAt = observedAt
        self.observedHour = observedHour ?? Self.utcHourBucket(for: observedAt)
        self.sourceRaw = source.rawValue
        self.resultCount = resultCount
        self.submissionCount = submissionCount
        self.winningCount = winningCount
        self.confidenceRaw = confidence
        self.items = []
        self.query = query
    }

    static func makeObservationKey(queryKey: String, observedAt: Date, source: RankingSource) -> String {
        let timestampBucket = utcDayBucket(for: observedAt)
        return [queryKey, String(timestampBucket), source.rawValue].joined(separator: "::")
    }

    static func utcHourBucket(for date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 3_600))
    }

    static func utcDayBucket(for date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 86_400))
    }

    var platform: AppPlatform {
        get { AppPlatform(rawValue: platformRaw) ?? .iphone }
        set { platformRaw = newValue.rawValue }
    }

    var source: RankingSource {
        get { RankingSource(rawValue: sourceRaw) ?? .iTunesFallback }
        set { sourceRaw = newValue.rawValue }
    }

    var sortedItems: [KeywordAppRanking] {
        items.sorted { $0.position < $1.position }
    }
}
}

typealias KeywordRankingCrawl = OpenASOSchemaV1.KeywordRankingCrawl
