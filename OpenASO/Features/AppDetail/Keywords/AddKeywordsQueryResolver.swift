import Foundation
import SwiftData

enum AddKeywordsQueryResolver {
    struct Candidate: Sendable {
        let term: String
        let storefront: String
        let platform: AppPlatform

        var queryKey: String {
            KeywordQuery.makeQueryKey(
                term: term,
                storefront: storefront,
                platform: platform
            )
        }

        var duplicateKey: String {
            queryKey
        }

        func trackIdentityKey(appStoreID: Int64) -> String {
            TrackedAppKeyword.makeIdentityKey(
                appStoreID: appStoreID,
                term: term,
                storefront: storefront,
                platform: platform
            )
        }
    }

    static let defaultFetchBatchSize = 400

    static func duplicateKey(
        term: String,
        storefront: String,
        platform: AppPlatform
    ) -> String {
        KeywordQuery.makeQueryKey(
            term: term,
            storefront: storefront,
            platform: platform
        )
    }

    static func pendingCandidates(
        keywords: [String],
        storefrontCodes: Set<String>,
        platform: AppPlatform,
        existingDuplicateKeys: Set<String>
    ) -> [Candidate] {
        var seenKeys = existingDuplicateKeys
        var candidates: [Candidate] = []
        candidates.reserveCapacity(keywords.count * storefrontCodes.count)

        for storefrontCode in storefrontCodes.sorted() {
            for keyword in keywords {
                let candidate = Candidate(
                    term: keyword,
                    storefront: storefrontCode,
                    platform: platform
                )
                guard seenKeys.insert(candidate.duplicateKey).inserted else {
                    continue
                }
                candidates.append(candidate)
            }
        }

        return candidates
    }

    @MainActor
    static func existingTrackIdentityKeys(
        for candidates: [Candidate],
        appStoreID: Int64,
        in modelContext: ModelContext,
        fetchBatchSize: Int = defaultFetchBatchSize,
        fetchObserver: (_ identityKeyCount: Int) -> Void = { _ in }
    ) throws -> Set<String> {
        let identityKeys = Array(Set(candidates.map { candidate in
            candidate.trackIdentityKey(appStoreID: appStoreID)
        })).sorted()
        guard !identityKeys.isEmpty else { return [] }

        let batchSize = max(1, fetchBatchSize)
        var existingIdentityKeys: Set<String> = []
        existingIdentityKeys.reserveCapacity(identityKeys.count)

        for batchStart in stride(from: 0, to: identityKeys.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, identityKeys.count)
            let targetIdentityKeys = Array(identityKeys[batchStart..<batchEnd])
            fetchObserver(targetIdentityKeys.count)
            let descriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    targetIdentityKeys.contains(track.identityKey)
                }
            )
            existingIdentityKeys.formUnion(
                try modelContext.fetch(descriptor).map(\.identityKey)
            )
        }

        return existingIdentityKeys
    }

    @MainActor
    static func resolveQueries(
        for candidates: [Candidate],
        in modelContext: ModelContext,
        fetchBatchSize: Int = defaultFetchBatchSize,
        fetchObserver: (_ queryKeyCount: Int) -> Void = { _ in }
    ) throws -> [String: KeywordQuery] {
        let queryKeys = Array(Set(candidates.map(\.queryKey))).sorted()
        guard !queryKeys.isEmpty else { return [:] }

        let batchSize = max(1, fetchBatchSize)
        var queriesByKey: [String: KeywordQuery] = [:]
        queriesByKey.reserveCapacity(queryKeys.count)

        for batchStart in stride(from: 0, to: queryKeys.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, queryKeys.count)
            let targetQueryKeys = Array(queryKeys[batchStart..<batchEnd])
            fetchObserver(targetQueryKeys.count)
            let descriptor = FetchDescriptor<KeywordQuery>(
                predicate: #Predicate { query in
                    targetQueryKeys.contains(query.queryKey)
                }
            )
            for query in try modelContext.fetch(descriptor) {
                queriesByKey[query.queryKey] = query
            }
        }

        for candidate in candidates where queriesByKey[candidate.queryKey] == nil {
            let query = KeywordQuery(
                term: candidate.term,
                storefront: candidate.storefront,
                platform: candidate.platform
            )
            modelContext.insert(query)
            queriesByKey[candidate.queryKey] = query
        }

        return queriesByKey
    }
}
