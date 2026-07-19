import Foundation
import SwiftData

/// One bounded page of app-independent search-result observations.
///
/// `nextOffset` is present only when the store returned a lookahead row. The
/// observations deliberately contain search-result positions, not a rank for
/// any particular app.
struct KeywordResearchRankingHistoryPage: Equatable, Sendable {
    let observations: [KeywordResearchRankingObservationSnapshot]
    let nextOffset: Int?
}

/// Reads shared ranking observations for one exact research membership.
///
/// Project and keyword generations are resolved inside the same background
/// store read as the crawl fetch. A removed or reincarnated membership is
/// therefore rejected before any shared query history is returned, while
/// observations remain reusable by every current membership for that query.
struct KeywordResearchHistoryReader: Sendable {
    static let maximumPageLimit = KeywordResearchProjectStore.maximumPageLimit

    private let modelStore: BackgroundModelStore
    private let targetResolver: KeywordResearchTargetResolver

    init(
        backgroundModelStore: BackgroundModelStore,
        targetResolver: KeywordResearchTargetResolver = KeywordResearchTargetResolver()
    ) {
        self.modelStore = backgroundModelStore
        self.targetResolver = targetResolver
    }

    func page(
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGeneration: KeywordResearchKeywordGeneration,
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> KeywordResearchRankingHistoryPage {
        try Self.validatePagination(offset: offset, limit: limit)
        try Task.checkCancellation()

        let targetResolver = targetResolver
        let page = try await modelStore.read { modelContext in
            try Task.checkCancellation()
            let target = try targetResolver.requireTarget(
                projectGeneration: projectGeneration,
                keywordGeneration: keywordGeneration,
                in: modelContext
            )

            let queryKey = target.queryKey
            var descriptor = FetchDescriptor<KeywordRankingCrawl>(
                predicate: #Predicate { crawl in
                    crawl.queryKey == queryKey
                },
                sortBy: [
                    SortDescriptor(\.observedAt, order: .reverse),
                    SortDescriptor(
                        \.observationKey,
                        comparator: .lexical,
                        order: .forward
                    ),
                ]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit + 1

            let rowsWithLookahead = try modelContext.fetch(descriptor)
            try Task.checkCancellation()
            let hasMore = rowsWithLookahead.count > limit
            let rows = rowsWithLookahead.prefix(limit)
            let observations = rows.map {
                Self.snapshot(
                    $0,
                    projectGeneration: projectGeneration,
                    keywordGeneration: keywordGeneration
                )
            }
            try Task.checkCancellation()

            return KeywordResearchRankingHistoryPage(
                observations: observations,
                nextOffset: hasMore ? offset + observations.count : nil
            )
        }

        try Task.checkCancellation()
        return page
    }
}

private extension KeywordResearchHistoryReader {
    static func validatePagination(offset: Int, limit: Int) throws {
        guard offset >= 0 else {
            throw KeywordResearchProjectStoreError.invalidOffset
        }
        guard (1...maximumPageLimit).contains(limit) else {
            throw KeywordResearchProjectStoreError.invalidLimit
        }
        guard offset <= Int.max - limit else {
            throw KeywordResearchProjectStoreError.invalidOffset
        }
    }

    static func snapshot(
        _ observation: KeywordRankingCrawl,
        projectGeneration: KeywordResearchProjectGeneration,
        keywordGeneration: KeywordResearchKeywordGeneration
    ) -> KeywordResearchRankingObservationSnapshot {
        let items = observation.items
            .map {
                KeywordResearchRankingItemSnapshot(
                    id: $0.itemKey,
                    position: $0.position,
                    appStoreID: $0.appStoreID,
                    bundleID: $0.bundleID,
                    name: $0.name,
                    subtitle: $0.subtitle,
                    sellerName: $0.sellerName
                )
            }
            .sorted {
                if $0.position != $1.position {
                    return $0.position < $1.position
                }
                if $0.appStoreID != $1.appStoreID {
                    return $0.appStoreID < $1.appStoreID
                }
                return $0.id < $1.id
            }

        return KeywordResearchRankingObservationSnapshot(
            id: observation.observationKey,
            projectGeneration: projectGeneration,
            keywordGeneration: keywordGeneration,
            queryKey: observation.queryKey,
            term: observation.keyword,
            storefront: observation.storefront,
            platform: observation.platform,
            observedAt: observation.observedAt,
            observedHour: observation.observedHour,
            source: observation.source,
            resultCount: observation.resultCount,
            submissionCount: observation.submissionCount,
            winningCount: observation.winningCount,
            confidence: observation.confidenceRaw,
            items: items
        )
    }
}
