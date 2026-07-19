import Foundation
import SwiftData

/// One exact public ranking input selected by the estimated-difficulty algorithm,
/// together with the values the algorithm derived from that input.
@Model
final class EstimatedKeywordDifficultyResultEvidenceRecord {
    #Index<EstimatedKeywordDifficultyResultEvidenceRecord>(
        [\.queryKey],
        [\.queryKey, \.calculationID],
        [\.calculationID, \.position]
    )

    @Attribute(.unique) var evidenceKey: String
    var queryKey: String
    var calculationID: UUID
    var position: Int
    var appStoreID: Int64
    var title: String
    var subtitle: String?
    var ratingCount: Int?
    var ratingAuthorityScore: Int?
    var titleTokenCoveragePercentage: Int?
    var combinedTokenCoveragePercentage: Int?
    var metadataMatchScore: Int?
    var exactTitlePhraseMatch: Bool
    var exactSubtitlePhraseMatch: Bool

    init(
        queryKey: String,
        calculationID: UUID,
        position: Int,
        appStoreID: Int64,
        title: String,
        subtitle: String?,
        ratingCount: Int?,
        ratingAuthorityScore: Int?,
        titleTokenCoveragePercentage: Int?,
        combinedTokenCoveragePercentage: Int?,
        metadataMatchScore: Int?,
        exactTitlePhraseMatch: Bool,
        exactSubtitlePhraseMatch: Bool
    ) {
        self.evidenceKey = Self.makeEvidenceKey(
            queryKey: queryKey,
            calculationID: calculationID,
            position: position,
            appStoreID: appStoreID
        )
        self.queryKey = queryKey
        self.calculationID = calculationID
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

    static func makeEvidenceKey(
        queryKey: String,
        calculationID: UUID,
        position: Int,
        appStoreID: Int64
    ) -> String {
        [
            queryKey,
            calculationID.uuidString.lowercased(),
            String(position),
            String(appStoreID)
        ].joined(separator: "::")
    }
}
