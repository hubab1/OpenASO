import Foundation
import SwiftData

extension OpenASOSchemaV1 {
@Model
final class TrackedKeywordDailyRanking {
    @Attribute(.unique) var snapshotKey: String
    var trackIdentityKey: String
    var rank: Int?
    var searchedAt: Date
    var sourceRaw: String
    var resultCount: Int
    var errorMessage: String?

    var keywordTrack: TrackedAppKeyword

    var topResults: [TrackedKeywordRankedResult]

    init(
        rank: Int?,
        searchedAt: Date,
        source: RankingSource,
        resultCount: Int,
        errorMessage: String? = nil,
        keywordTrack: TrackedAppKeyword
    ) {
        self.trackIdentityKey = keywordTrack.identityKey
        self.snapshotKey = Self.makeSnapshotKey(
            trackIdentityKey: keywordTrack.identityKey,
            searchedAt: searchedAt,
            source: source
        )
        self.rank = rank
        self.searchedAt = searchedAt
        self.sourceRaw = source.rawValue
        self.resultCount = resultCount
        self.errorMessage = errorMessage
        self.keywordTrack = keywordTrack
        self.topResults = []
    }

    static func makeSnapshotKey(trackIdentityKey: String, searchedAt: Date, source: RankingSource) -> String {
        [
            trackIdentityKey,
            String(KeywordRankingCrawl.utcDayBucket(for: searchedAt)),
            source.rawValue
        ].joined(separator: "::")
    }

    var source: RankingSource {
        get { RankingSource(rawValue: sourceRaw) ?? .iTunesFallback }
        set { sourceRaw = newValue.rawValue }
    }

    var sortedTopResults: [TrackedKeywordRankedResult] {
        topResults.sorted { $0.position < $1.position }
    }
}
}

typealias TrackedKeywordDailyRanking = OpenASOSchemaV1.TrackedKeywordDailyRanking
