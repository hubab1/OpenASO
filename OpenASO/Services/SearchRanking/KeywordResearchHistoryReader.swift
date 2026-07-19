import Foundation
import SwiftData

/// The stable position immediately after one bounded history page.
///
/// Same-day crawls are updated in place, including their exact observation
/// time. The persistence pipeline nevertheless keeps their UTC-day/source slot
/// fixed. Remembering consumed sources inside the boundary day therefore keeps
/// continuation stable across both newer inserts and same-day updates.
struct KeywordResearchRankingHistoryCursor: Equatable, Hashable, Sendable {
    let dayBucket: Int
    let consumedSourceIDs: Set<String>
}

/// One bounded page of app-independent search-result observations.
///
/// `nextCursor` is present only when the store returned a lookahead row. The
/// observations deliberately contain search-result positions, not a rank for
/// any particular app.
struct KeywordResearchRankingHistoryPage: Equatable, Sendable {
    let observations: [KeywordResearchRankingObservationSnapshot]
    let nextCursor: KeywordResearchRankingHistoryCursor?
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
        after cursor: KeywordResearchRankingHistoryCursor? = nil,
        limit: Int = 50
    ) async throws -> KeywordResearchRankingHistoryPage {
        try Self.validateLimit(limit)
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
            let rowsWithLookahead = try Self.rowsWithLookahead(
                queryKey: queryKey,
                after: cursor,
                limit: limit,
                in: modelContext
            )
            try Task.checkCancellation()
            let hasMore = rowsWithLookahead.count > limit
            let rows = Array(rowsWithLookahead.prefix(limit))
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
                nextCursor: hasMore
                    ? Self.cursor(after: cursor, returnedRows: rows)
                    : nil
            )
        }

        try Task.checkCancellation()
        return page
    }
}

private extension KeywordResearchHistoryReader {
    static func validateLimit(_ limit: Int) throws {
        guard (1...maximumPageLimit).contains(limit) else {
            throw KeywordResearchProjectStoreError.invalidLimit
        }
    }

    static func rowsWithLookahead(
        queryKey: String,
        after cursor: KeywordResearchRankingHistoryCursor?,
        limit: Int,
        in modelContext: ModelContext
    ) throws -> [KeywordRankingCrawl] {
        guard let cursor else {
            var descriptor = FetchDescriptor<KeywordRankingCrawl>(
                predicate: #Predicate { crawl in
                    crawl.queryKey == queryKey
                },
                sortBy: sortDescriptors
            )
            descriptor.fetchLimit = limit + 1
            return try modelContext.fetch(descriptor)
        }

        let boundaryStart = Date(
            timeIntervalSince1970: TimeInterval(cursor.dayBucket) * 86_400
        )
        let boundaryEnd = boundaryStart.addingTimeInterval(86_400)
        var boundaryDescriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { crawl in
                crawl.queryKey == queryKey
                    && crawl.observedAt >= boundaryStart
                    && crawl.observedAt < boundaryEnd
            },
            sortBy: sortDescriptors
        )
        // The write pipeline has at most one crawl per query/day/source slot.
        boundaryDescriptor.fetchLimit = RankingSource.allCases.count
        var rows = try modelContext.fetch(boundaryDescriptor).filter {
            !cursor.consumedSourceIDs.contains($0.sourceRaw)
        }

        let remainingLookahead = limit + 1 - rows.count
        guard remainingLookahead > 0 else {
            return Array(rows.prefix(limit + 1))
        }

        var olderDescriptor = FetchDescriptor<KeywordRankingCrawl>(
            predicate: #Predicate { crawl in
                crawl.queryKey == queryKey
                    && crawl.observedAt < boundaryStart
            },
            sortBy: sortDescriptors
        )
        olderDescriptor.fetchLimit = remainingLookahead
        rows.append(contentsOf: try modelContext.fetch(olderDescriptor))
        return rows
    }

    static var sortDescriptors: [SortDescriptor<KeywordRankingCrawl>] {
        [
            SortDescriptor(\KeywordRankingCrawl.observedAt, order: .reverse),
            SortDescriptor(
                \KeywordRankingCrawl.observationKey,
                comparator: .lexical,
                order: .forward
            ),
        ]
    }

    static func cursor(
        after previous: KeywordResearchRankingHistoryCursor?,
        returnedRows: [KeywordRankingCrawl]
    ) -> KeywordResearchRankingHistoryCursor? {
        guard let boundaryRow = returnedRows.last else { return nil }
        let dayBucket = KeywordRankingCrawl.utcDayBucket(
            for: boundaryRow.observedAt
        )
        var consumedSourceIDs = previous?.dayBucket == dayBucket
            ? previous?.consumedSourceIDs ?? []
            : []
        consumedSourceIDs.formUnion(
            returnedRows.lazy
                .filter {
                    KeywordRankingCrawl.utcDayBucket(for: $0.observedAt)
                        == dayBucket
                }
                .map(\.sourceRaw)
        )
        return KeywordResearchRankingHistoryCursor(
            dayBucket: dayBucket,
            consumedSourceIDs: consumedSourceIDs
        )
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
