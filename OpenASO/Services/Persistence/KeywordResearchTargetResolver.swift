import Foundation
import SwiftData

/// Immutable query scope for one exact project-keyword generation.
///
/// Persistent models stay inside their `ModelContext`; workflows may safely
/// carry this scalar value across provider suspension points and compare it
/// with a freshly resolved target before committing late results.
struct KeywordResearchTarget: Equatable, Sendable {
    let queryKey: String
    let term: String
    let storefront: String
    let platform: AppPlatform
}

/// Resolves generation-safe research membership and its shared query without
/// allowing SwiftData models to cross an isolation boundary.
struct KeywordResearchTargetResolver: Sendable {
    func requireTarget(
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGeneration: KeywordResearchKeywordGeneration,
        in modelContext: ModelContext
    ) throws -> KeywordResearchTarget {
        let projectID = projectGeneration.id
        var projectDescriptor = FetchDescriptor<KeywordResearchProject>(
            predicate: #Predicate { project in
                project.id == projectID
            }
        )
        projectDescriptor.fetchLimit = 1
        guard let project = try modelContext.fetch(projectDescriptor).first else {
            throw KeywordResearchProjectStoreError.projectNotFound(projectID)
        }
        guard project.incarnationID == projectGeneration.incarnationID else {
            throw KeywordResearchProjectStoreError.staleProjectRevision(projectID)
        }

        let keywordID = keywordGeneration.id
        var keywordDescriptor = FetchDescriptor<KeywordResearchKeyword>(
            predicate: #Predicate { keyword in
                keyword.id == keywordID
            }
        )
        keywordDescriptor.fetchLimit = 1
        guard let keyword = try modelContext.fetch(keywordDescriptor).first else {
            throw KeywordResearchProjectStoreError.keywordNotFound(keywordID)
        }
        guard keyword.incarnationID == keywordGeneration.incarnationID else {
            throw KeywordResearchProjectStoreError.staleKeywordRevision(keywordID)
        }
        guard keyword.projectID == project.id else {
            throw KeywordResearchProjectStoreError.keywordNotFound(keywordID)
        }

        return KeywordResearchTarget(
            queryKey: keyword.queryKey,
            term: keyword.term,
            storefront: keyword.storefront,
            platform: keyword.platform
        )
    }

    func requireQuery(
        for target: KeywordResearchTarget,
        in modelContext: ModelContext
    ) throws -> KeywordQuery {
        let queryKey = target.queryKey
        var descriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                query.queryKey == queryKey
            }
        )
        descriptor.fetchLimit = 1
        guard let query = try modelContext.fetch(descriptor).first,
              query.term == target.term,
              query.storefront == target.storefront,
              query.platform == target.platform
        else {
            throw OpenASOError.unexpectedResponse
        }
        return query
    }
}
