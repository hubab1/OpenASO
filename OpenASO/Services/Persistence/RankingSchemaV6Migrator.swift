import Foundation
import SwiftData

enum RankingSchemaV6MigrationError: LocalizedError {
    case invalidLegacyData(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidLegacyData(let detail):
            "The ranking database contains legacy data that cannot be normalized: \(detail)"
        case .validationFailed(let detail):
            "The normalized ranking data did not pass validation: \(detail)"
        }
    }
}

/// Copies the frozen V1 ranking rows into the normalized V6 entities, validates
/// every persisted ranking payload, and only then removes redundant legacy rows.
/// Copy and link progress is committed in bounded batches, so an interrupted
/// launch resumes from the last completely saved batch. Each batch uses a fresh
/// context to keep the million-row migration's working set bounded.
enum RankingSchemaV6Migrator {
    private static let crawlBatchSize = 100
    private static let snapshotBatchSize = 50

    static func migrateIfNeeded(in container: ModelContainer) throws {
        try initializeMigrationIfNeeded(in: container)

        while try autoreleasepool(invoking: {
            switch try currentPhase(in: container) {
            case .copyingCrawls:
                try copyCanonicalBatch(in: container)
                return true
            case .linkingSnapshots:
                try linkTrackedSnapshotBatch(in: container)
                return true
            case .validating:
                try validateAllLegacyData(in: container)
                return true
            case .cleaningLegacyRows:
                try removeValidatedLegacyRows(in: container)
                return true
            case .completed:
                let context = migrationContext(for: container)
                let state = try migrationState(in: context)
                OpenASOLog.rankingMigration.notice(
                    "Normalized ranking migration completed: \(state.migratedCrawlCount) crawls, \(state.migratedFactCount) canonical facts, \(state.migratedTrackedLinkCount) tracked links, and \(state.recoveredCrawlCount) recovered crawls."
                )
                return false
            }
        }) {
            // The autorelease pool bounds Core Data's temporary objects per batch.
        }
    }

    private static func migrationContext(for container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static func initializeMigrationIfNeeded(in container: ModelContainer) throws {
        let context = migrationContext(for: container)
        let state = try migrationState(in: context)
        guard state.phase != .completed else { return }

        OpenASOLog.rankingMigration.notice(
            "Starting normalized ranking migration at phase \(state.phaseRaw, privacy: .public)."
        )
        if state.legacyCrawlCount == 0,
           state.legacyFactCount == 0,
           state.legacyTrackedFactCount == 0,
           state.lastObservationKey == nil,
           state.lastSnapshotKey == nil {
            state.legacyCrawlCount = try context.fetchCount(
                FetchDescriptor<LegacyKeywordRankingCrawl>()
            )
            state.legacyFactCount = try context.fetchCount(
                FetchDescriptor<LegacyKeywordAppRanking>()
            )
            state.legacyTrackedFactCount = try context.fetchCount(
                FetchDescriptor<TrackedKeywordRankedResult>()
            )
            try context.save()
        }
    }

    private static func currentPhase(in container: ModelContainer) throws -> RankingMigrationPhase {
        let context = migrationContext(for: container)
        return try migrationState(in: context).phase
    }

    private static func migrationState(in context: ModelContext) throws -> RankingMigrationState {
        let key = RankingMigrationState.singletonKey
        var descriptor = FetchDescriptor<RankingMigrationState>(
            predicate: #Predicate { state in
                state.migrationKey == key
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let state = RankingMigrationState()
        context.insert(state)
        try context.save()
        return state
    }

    // MARK: - Canonical crawl copy

    private static func copyCanonicalBatch(in container: ModelContainer) throws {
        let context = migrationContext(for: container)
        let state = try migrationState(in: context)
        let legacyCrawls = try fetchLegacyCrawlBatch(
            offset: state.migratedCrawlCount,
            in: context
        )
        guard !legacyCrawls.isEmpty else {
            guard state.migratedCrawlCount == state.legacyCrawlCount else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "copied \(state.migratedCrawlCount) of \(state.legacyCrawlCount) canonical crawls"
                )
            }
            guard state.migratedFactCount == state.legacyFactCount else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "copied \(state.migratedFactCount) of \(state.legacyFactCount) canonical facts; orphaned facts remain"
                )
            }
            state.phase = .linkingSnapshots
            try context.save()
            return
        }

        let crawlKeys = legacyCrawls.map(\.observationKey)
        let legacyFacts = try context.fetch(
            FetchDescriptor<LegacyKeywordAppRanking>(
                predicate: #Predicate { fact in
                    crawlKeys.contains(fact.crawlKey)
                },
                sortBy: [
                    SortDescriptor(\.crawlKey),
                    SortDescriptor(\.position),
                    SortDescriptor(\.appStoreID)
                ]
            )
        )
        let factsByCrawlKey = Dictionary(grouping: legacyFacts, by: \.crawlKey)
        let payloads = legacyFacts.map(Self.revisionPayload)
        let revisionKeyByItemKey = Dictionary(
            uniqueKeysWithValues: zip(legacyFacts, payloads).map {
                ($0.itemKey, $1.revisionKey)
            }
        )
        let revisionsByKey = try RankingAppRevisionStore.revisions(
            for: payloads,
            in: context
        )

        for legacyCrawl in legacyCrawls {
            let normalizedCrawl = makeCrawl(from: legacyCrawl)
            context.insert(normalizedCrawl)
            let crawlFacts = factsByCrawlKey[legacyCrawl.observationKey, default: []]
            try insertFacts(
                crawlFacts,
                into: normalizedCrawl,
                revisionKeyByItemKey: revisionKeyByItemKey,
                revisionsByKey: revisionsByKey,
                in: context
            )
            state.migratedCrawlCount += 1
            state.migratedFactCount += crawlFacts.count
            state.lastObservationKey = legacyCrawl.observationKey
        }
        try context.save()
    }

    private static func fetchLegacyCrawlBatch(
        offset: Int,
        in context: ModelContext
    ) throws -> [LegacyKeywordRankingCrawl] {
        var descriptor = FetchDescriptor<LegacyKeywordRankingCrawl>(
            sortBy: [SortDescriptor(\.observationKey)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = crawlBatchSize
        return try context.fetch(descriptor)
    }

    private static func makeCrawl(
        from legacy: LegacyKeywordRankingCrawl
    ) -> RankingCrawlRecord {
        let crawl = RankingCrawlRecord(
            keyword: legacy.keyword,
            storefront: legacy.storefront,
            platform: legacy.platform,
            observedAt: legacy.observedAt,
            source: legacy.source,
            resultCount: legacy.resultCount,
            observedHour: legacy.observedHour,
            submissionCount: legacy.submissionCount,
            winningCount: legacy.winningCount,
            confidence: legacy.confidenceRaw
        )
        crawl.observationKey = legacy.observationKey
        crawl.queryKey = legacy.queryKey
        crawl.keyword = legacy.keyword
        crawl.storefront = legacy.storefront
        crawl.platformRaw = legacy.platformRaw
        crawl.observedAt = legacy.observedAt
        crawl.observedHour = legacy.observedHour
        crawl.sourceRaw = legacy.sourceRaw
        crawl.resultCount = legacy.resultCount
        crawl.submissionCount = legacy.submissionCount
        crawl.winningCount = legacy.winningCount
        crawl.confidenceRaw = legacy.confidenceRaw
        return crawl
    }

    private static func insertFacts(
        _ legacyFacts: [LegacyKeywordAppRanking],
        into crawl: RankingCrawlRecord,
        revisionKeyByItemKey: [String: String],
        revisionsByKey: [String: RankingAppRevision],
        in context: ModelContext
    ) throws {
        var seenAppStoreIDs = Set<Int64>()
        for legacyFact in legacyFacts {
            guard seenAppStoreIDs.insert(legacyFact.appStoreID).inserted else {
                throw RankingSchemaV6MigrationError.invalidLegacyData(
                    "crawl \(legacyFact.crawlKey) contains duplicate app \(legacyFact.appStoreID)"
                )
            }
            guard let revisionKey = revisionKeyByItemKey[legacyFact.itemKey],
                  let revision = revisionsByKey[revisionKey] else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "missing app revision for legacy fact \(legacyFact.itemKey)"
                )
            }
            let fact = RankingFact(
                position: legacyFact.position,
                appStoreID: legacyFact.appStoreID,
                revision: revision,
                observation: crawl
            )
            context.insert(fact)
        }
    }

    // MARK: - Tracked snapshot links

    private static func linkTrackedSnapshotBatch(in container: ModelContainer) throws {
        let context = migrationContext(for: container)
        let state = try migrationState(in: context)
        let snapshots = try fetchSnapshotBatch(
            offset: state.processedSnapshotCount,
            in: context
        )
        guard !snapshots.isEmpty else {
            let legacySnapshotCount = try context.fetchCount(
                FetchDescriptor<TrackedKeywordDailyRanking>()
            )
            guard state.processedSnapshotCount == legacySnapshotCount else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "processed \(state.processedSnapshotCount) of \(legacySnapshotCount) tracked snapshots"
                )
            }
            state.phase = .validating
            try context.save()
            return
        }

        let snapshotKeys = snapshots.map(\.snapshotKey)
        let legacyResults = try context.fetch(
            FetchDescriptor<TrackedKeywordRankedResult>(
                predicate: #Predicate { result in
                    snapshotKeys.contains(result.snapshotKey)
                },
                sortBy: [
                    SortDescriptor(\.snapshotKey),
                    SortDescriptor(\.position),
                    SortDescriptor(\.appStoreID)
                ]
            )
        )
        let resultsBySnapshotKey = Dictionary(grouping: legacyResults, by: \.snapshotKey)

        var queryKeyBySnapshotKey: [String: String] = [:]
        var canonicalKeyBySnapshotKey: [String: String] = [:]
        for snapshot in snapshots {
            guard let queryKey = TrackedAppKeyword.queryKey(
                fromIdentityKey: snapshot.trackIdentityKey
            ) else {
                if resultsBySnapshotKey[snapshot.snapshotKey, default: []].isEmpty {
                    continue
                }
                throw RankingSchemaV6MigrationError.invalidLegacyData(
                    "snapshot \(snapshot.snapshotKey) has ranked results but no valid query key"
                )
            }
            queryKeyBySnapshotKey[snapshot.snapshotKey] = queryKey
            canonicalKeyBySnapshotKey[snapshot.snapshotKey] = RankingCrawlRecord.makeObservationKey(
                queryKey: queryKey,
                observedAt: snapshot.searchedAt,
                source: snapshot.source
            )
        }

        let canonicalKeys = Array(Set(canonicalKeyBySnapshotKey.values))
        let canonicalCrawls = canonicalKeys.isEmpty ? [] : try context.fetch(
            FetchDescriptor<RankingCrawlRecord>(
                predicate: #Predicate { crawl in
                    canonicalKeys.contains(crawl.observationKey)
                }
            )
        )
        let crawlsByKey = Dictionary(
            canonicalCrawls.map { ($0.observationKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let canonicalFacts = try fetchNormalizedFacts(crawlKeys: canonicalKeys, in: context)
        let factsByCrawlKey = Dictionary(grouping: canonicalFacts) {
            $0.observation.observationKey
        }

        let existingLinks = try context.fetch(
            FetchDescriptor<TrackedRankingCrawlLink>(
                predicate: #Predicate { link in
                    snapshotKeys.contains(link.snapshotKey)
                }
            )
        )
        var linksBySnapshotKey = Dictionary(
            existingLinks.map { ($0.snapshotKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        for snapshot in snapshots {
            let results = resultsBySnapshotKey[snapshot.snapshotKey, default: []]
            var selectedCrawl: RankingCrawlRecord?
            if let canonicalKey = canonicalKeyBySnapshotKey[snapshot.snapshotKey],
               let canonical = crawlsByKey[canonicalKey],
               facts(
                    factsByCrawlKey[canonicalKey, default: []],
                    exactlyMatch: results
               ) {
                selectedCrawl = canonical
            } else if !results.isEmpty {
                guard let queryKey = queryKeyBySnapshotKey[snapshot.snapshotKey] else {
                    throw RankingSchemaV6MigrationError.invalidLegacyData(
                        "snapshot \(snapshot.snapshotKey) has no valid query key"
                    )
                }
                selectedCrawl = try makeRecoveryCrawl(
                    for: snapshot,
                    queryKey: queryKey,
                    results: results,
                    state: state,
                    in: context
                )
            }

            if let selectedCrawl {
                if let link = linksBySnapshotKey[snapshot.snapshotKey] {
                    link.crawl = selectedCrawl
                } else {
                    let link = TrackedRankingCrawlLink(
                        snapshotKey: snapshot.snapshotKey,
                        crawl: selectedCrawl
                    )
                    context.insert(link)
                    linksBySnapshotKey[snapshot.snapshotKey] = link
                }
                state.migratedTrackedLinkCount += 1
            }
            state.lastSnapshotKey = snapshot.snapshotKey
            state.processedSnapshotCount += 1
        }
        try context.save()
    }

    private static func fetchSnapshotBatch(
        offset: Int,
        in context: ModelContext
    ) throws -> [TrackedKeywordDailyRanking] {
        var descriptor = FetchDescriptor<TrackedKeywordDailyRanking>(
            sortBy: [SortDescriptor(\.snapshotKey)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = snapshotBatchSize
        return try context.fetch(descriptor)
    }

    private static func makeRecoveryCrawl(
        for snapshot: TrackedKeywordDailyRanking,
        queryKey: String,
        results: [TrackedKeywordRankedResult],
        state: RankingMigrationState,
        in context: ModelContext
    ) throws -> RankingCrawlRecord {
        guard let components = KeywordQuery.components(from: queryKey) else {
            throw RankingSchemaV6MigrationError.invalidLegacyData(
                "query key \(queryKey) cannot be decoded"
            )
        }
        let recoveryKey = RankingCrawlRecord.makeTrackedRecoveryObservationKey(
            snapshotKey: snapshot.snapshotKey
        )
        let recovered = RankingCrawlRecord(
            keyword: components.term,
            storefront: components.storefront,
            platform: components.platform,
            observedAt: snapshot.searchedAt,
            source: snapshot.source,
            resultCount: snapshot.resultCount
        )
        recovered.observationKey = recoveryKey
        context.insert(recovered)

        let payloads = results.map(Self.revisionPayload)
        let revisionsByKey = try RankingAppRevisionStore.revisions(
            for: payloads,
            in: context
        )
        var seenAppStoreIDs = Set<Int64>()
        for (result, payload) in zip(results, payloads) {
            guard seenAppStoreIDs.insert(result.appStoreID).inserted else {
                throw RankingSchemaV6MigrationError.invalidLegacyData(
                    "snapshot \(snapshot.snapshotKey) contains duplicate apps"
                )
            }
            guard let revision = revisionsByKey[payload.revisionKey] else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "missing recovered app revision for snapshot \(snapshot.snapshotKey)"
                )
            }
            let fact = RankingFact(
                position: result.position,
                appStoreID: result.appStoreID,
                revision: revision,
                observation: recovered
            )
            context.insert(fact)
        }
        state.recoveredCrawlCount += 1
        return recovered
    }

    // MARK: - Validation

    private static func validateAllLegacyData(in container: ModelContainer) throws {
        var validatedCrawls = 0
        var validatedFacts = 0
        while let batch = try validateCanonicalBatch(
            offset: validatedCrawls,
            in: container
        ) {
            validatedCrawls += batch.crawlCount
            validatedFacts += batch.factCount
        }

        let stateContext = migrationContext(for: container)
        let state = try migrationState(in: stateContext)
        guard validatedCrawls == state.legacyCrawlCount,
              validatedFacts == state.legacyFactCount else {
            throw RankingSchemaV6MigrationError.validationFailed(
                "validated \(validatedCrawls)/\(state.legacyCrawlCount) crawls and \(validatedFacts)/\(state.legacyFactCount) facts"
            )
        }

        var validatedSnapshots = 0
        var validatedTrackedFacts = 0
        while let batch = try validateTrackedBatch(
            offset: validatedSnapshots,
            in: container
        ) {
            validatedSnapshots += batch.snapshotCount
            validatedTrackedFacts += batch.factCount
        }
        guard validatedTrackedFacts == state.legacyTrackedFactCount else {
            throw RankingSchemaV6MigrationError.validationFailed(
                "validated \(validatedTrackedFacts)/\(state.legacyTrackedFactCount) tracked facts"
            )
        }

        state.phase = .cleaningLegacyRows
        try stateContext.save()
    }

    private static func validateCanonicalBatch(
        offset: Int,
        in container: ModelContainer
    ) throws -> (crawlCount: Int, factCount: Int)? {
        let context = migrationContext(for: container)
        let legacyCrawls = try fetchLegacyCrawlBatch(offset: offset, in: context)
        guard !legacyCrawls.isEmpty else { return nil }

        let crawlKeys = legacyCrawls.map(\.observationKey)
        let legacyFacts = try context.fetch(
            FetchDescriptor<LegacyKeywordAppRanking>(
                predicate: #Predicate { fact in
                    crawlKeys.contains(fact.crawlKey)
                }
            )
        )
        let normalizedCrawls = try context.fetch(
            FetchDescriptor<RankingCrawlRecord>(
                predicate: #Predicate { crawl in
                    crawlKeys.contains(crawl.observationKey)
                }
            )
        )
        let normalizedFacts = try fetchNormalizedFacts(crawlKeys: crawlKeys, in: context)
        let normalizedCrawlsByKey = Dictionary(
            normalizedCrawls.map { ($0.observationKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let legacyFactsByCrawlKey = Dictionary(grouping: legacyFacts, by: \.crawlKey)
        let normalizedFactsByCrawlKey = Dictionary(grouping: normalizedFacts) {
            $0.observation.observationKey
        }

        for legacy in legacyCrawls {
            guard let normalized = normalizedCrawlsByKey[legacy.observationKey] else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "canonical crawl \(legacy.observationKey) is missing"
                )
            }
            try validateCrawlFields(legacy: legacy, normalized: normalized)
            try validateFacts(
                legacyItems: legacyFactsByCrawlKey[legacy.observationKey, default: []],
                normalizedItems: normalizedFactsByCrawlKey[legacy.observationKey, default: []],
                crawlKey: legacy.observationKey
            )
        }
        return (legacyCrawls.count, legacyFacts.count)
    }

    private static func validateTrackedBatch(
        offset: Int,
        in container: ModelContainer
    ) throws -> (snapshotCount: Int, factCount: Int)? {
        let context = migrationContext(for: container)
        let snapshots = try fetchSnapshotBatch(offset: offset, in: context)
        guard !snapshots.isEmpty else { return nil }

        let snapshotKeys = snapshots.map(\.snapshotKey)
        let results = try context.fetch(
            FetchDescriptor<TrackedKeywordRankedResult>(
                predicate: #Predicate { result in
                    snapshotKeys.contains(result.snapshotKey)
                }
            )
        )
        let resultsBySnapshotKey = Dictionary(grouping: results, by: \.snapshotKey)
        let links = try context.fetch(
            FetchDescriptor<TrackedRankingCrawlLink>(
                predicate: #Predicate { link in
                    snapshotKeys.contains(link.snapshotKey)
                }
            )
        )
        let linksBySnapshotKey = Dictionary(
            links.map { ($0.snapshotKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let crawlKeys = Array(Set(links.map { $0.crawl.observationKey }))
        let normalizedFacts = try fetchNormalizedFacts(crawlKeys: crawlKeys, in: context)
        let factsByCrawlKey = Dictionary(grouping: normalizedFacts) {
            $0.observation.observationKey
        }

        for (snapshotKey, snapshotResults) in resultsBySnapshotKey {
            guard let link = linksBySnapshotKey[snapshotKey],
                  facts(
                    factsByCrawlKey[link.crawl.observationKey, default: []],
                    exactlyMatch: snapshotResults
                  ) else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "tracked snapshot \(snapshotKey) was not preserved exactly"
                )
            }
        }
        return (snapshots.count, results.count)
    }

    private static func validateCrawlFields(
        legacy: LegacyKeywordRankingCrawl,
        normalized: RankingCrawlRecord
    ) throws {
        guard normalized.observationKey == legacy.observationKey,
              normalized.queryKey == legacy.queryKey,
              normalized.keyword == legacy.keyword,
              normalized.storefront == legacy.storefront,
              normalized.platformRaw == legacy.platformRaw,
              normalized.observedAt == legacy.observedAt,
              normalized.observedHour == legacy.observedHour,
              normalized.sourceRaw == legacy.sourceRaw,
              normalized.resultCount == legacy.resultCount,
              normalized.submissionCount == legacy.submissionCount,
              normalized.winningCount == legacy.winningCount,
              normalized.confidenceRaw == legacy.confidenceRaw else {
            throw RankingSchemaV6MigrationError.validationFailed(
                "canonical crawl \(legacy.observationKey) changed"
            )
        }
    }

    private static func validateFacts(
        legacyItems: [LegacyKeywordAppRanking],
        normalizedItems: [RankingFact],
        crawlKey: String
    ) throws {
        let normalizedByAppStoreID = Dictionary(
            normalizedItems.map { ($0.appStoreID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        guard normalizedByAppStoreID.count == legacyItems.count else {
            throw RankingSchemaV6MigrationError.validationFailed(
                "canonical crawl \(crawlKey) changed item count"
            )
        }
        for legacy in legacyItems {
            let expectedRevisionKey = revisionPayload(for: legacy).revisionKey
            guard let normalized = normalizedByAppStoreID[legacy.appStoreID],
                  normalized.position == legacy.position,
                  normalized.revision.revisionKey == expectedRevisionKey else {
                throw RankingSchemaV6MigrationError.validationFailed(
                    "canonical fact \(legacy.itemKey) changed"
                )
            }
        }
    }

    private static func facts(
        _ facts: [RankingFact],
        exactlyMatch results: [TrackedKeywordRankedResult]
    ) -> Bool {
        guard facts.count == results.count else { return false }
        let factsByAppStoreID = Dictionary(
            facts.map { ($0.appStoreID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        guard factsByAppStoreID.count == results.count else { return false }
        return results.allSatisfy { result in
            guard let fact = factsByAppStoreID[result.appStoreID] else { return false }
            return fact.position == result.position
                && fact.revision.revisionKey == revisionPayload(for: result).revisionKey
        }
    }

    private static func fetchNormalizedFacts(
        crawlKeys: [String],
        in context: ModelContext
    ) throws -> [RankingFact] {
        guard !crawlKeys.isEmpty else { return [] }
        return try context.fetch(
            FetchDescriptor<RankingFact>(
                predicate: #Predicate { fact in
                    crawlKeys.contains(fact.observation.observationKey)
                }
            )
        )
    }

    private static func revisionPayload(
        for fact: LegacyKeywordAppRanking
    ) -> RankingAppRevisionPayload {
        RankingAppRevisionPayload(
            appStoreID: fact.appStoreID,
            bundleID: fact.bundleID,
            name: fact.name,
            subtitle: fact.subtitle,
            sellerName: fact.sellerName
        )
    }

    private static func revisionPayload(
        for result: TrackedKeywordRankedResult
    ) -> RankingAppRevisionPayload {
        RankingAppRevisionPayload(
            appStoreID: result.appStoreID,
            bundleID: result.bundleID,
            name: result.name,
            subtitle: result.subtitle,
            sellerName: result.sellerName
        )
    }

    // MARK: - Cleanup

    private static func removeValidatedLegacyRows(in container: ModelContainer) throws {
        let context = migrationContext(for: container)
        let state = try migrationState(in: context)
        try context.delete(model: TrackedKeywordRankedResult.self)
        try context.delete(model: LegacyKeywordAppRanking.self)
        try context.delete(model: LegacyKeywordRankingCrawl.self)
        try context.save()

        guard try context.fetchCount(FetchDescriptor<TrackedKeywordRankedResult>()) == 0,
              try context.fetchCount(FetchDescriptor<LegacyKeywordAppRanking>()) == 0,
              try context.fetchCount(FetchDescriptor<LegacyKeywordRankingCrawl>()) == 0 else {
            throw RankingSchemaV6MigrationError.validationFailed(
                "redundant legacy ranking rows were not removed"
            )
        }
        state.phase = .completed
        state.completedAt = .now
        try context.save()
    }
}
