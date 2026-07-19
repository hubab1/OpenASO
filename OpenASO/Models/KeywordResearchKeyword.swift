import Foundation
import SwiftData

/// Project-local membership in an app-independent keyword query.
///
/// This model stores canonical query scope as scalars rather than adding a
/// relationship to the frozen V1 `KeywordQuery` model. Later workflows resolve
/// or create that shared query explicitly by `queryKey`.
@Model
final class KeywordResearchKeyword {
    #Index<KeywordResearchKeyword>(
        [\.projectID],
        [\.projectID, \.createdAt],
        [\.queryKey],
        [\.membershipKey]
    )

    @Attribute(.unique) private(set) var id: UUID
    @Attribute(.unique) private(set) var incarnationID: UUID
    @Attribute(.unique) private(set) var membershipKey: String
    private(set) var projectID: UUID
    private(set) var queryKey: String
    private(set) var term: String
    private(set) var storefront: String
    private(set) var platformRaw: String
    var notes: String
    private(set) var createdAt: Date
    var updatedAt: Date

    private(set) var project: KeywordResearchProject

    init(
        id: UUID = UUID(),
        term: String,
        storefront: String,
        platform: AppPlatform,
        project: KeywordResearchProject,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStorefront = KeywordResearchProject.normalizedStorefront(storefront)
        let queryKey = KeywordQuery.makeQueryKey(
            term: normalizedTerm,
            storefront: normalizedStorefront,
            platform: platform
        )

        self.id = id
        self.incarnationID = UUID()
        self.membershipKey = Self.makeMembershipKey(
            projectID: project.id,
            queryKey: queryKey
        )
        self.projectID = project.id
        self.queryKey = queryKey
        self.term = normalizedTerm
        self.storefront = normalizedStorefront
        self.platformRaw = platform.rawValue
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = max(updatedAt ?? createdAt, createdAt)
        self.project = project
    }

    static func makeMembershipKey(projectID: UUID, queryKey: String) -> String {
        [
            projectID.uuidString.lowercased(),
            queryKey
        ].joined(separator: "::")
    }

    var platform: AppPlatform {
        AppPlatform(rawValue: platformRaw) ?? .iphone
    }

    var generation: KeywordResearchKeywordGeneration {
        KeywordResearchKeywordGeneration(
            id: id,
            incarnationID: incarnationID
        )
    }
}

struct KeywordResearchKeywordGeneration: Equatable, Hashable, Sendable {
    let id: UUID
    let incarnationID: UUID
}
