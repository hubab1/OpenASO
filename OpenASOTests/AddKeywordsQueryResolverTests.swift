import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct AddKeywordsQueryResolverTests {
    @Test
    func pendingCandidatesPreserveOrderAndSkipNormalizedDuplicates() {
        let candidates = AddKeywordsQueryResolver.pendingCandidates(
            keywords: [" Focus ", "Growth"],
            storefrontCodes: ["GB", "us"],
            platform: .iphone,
            existingDuplicateKeys: [
                AddKeywordsQueryResolver.duplicateKey(
                    term: "focus",
                    storefront: "gb",
                    platform: .iphone
                )
            ]
        )

        #expect(candidates.map(\.queryKey) == [
            KeywordQuery.makeQueryKey(term: "Growth", storefront: "GB", platform: .iphone),
            KeywordQuery.makeQueryKey(term: " Focus ", storefront: "us", platform: .iphone),
            KeywordQuery.makeQueryKey(term: "Growth", storefront: "us", platform: .iphone)
        ])
    }

    @Test
    func resolvesLargeFixtureWithOneBulkFetchAndCreatesEachMissingQueryOnce() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let existingQuery = KeywordQuery(term: "keyword-0", storefront: "US", platform: .iphone)
        modelContext.insert(existingQuery)
        try modelContext.save()
        let candidates = (0..<240).map { index in
            AddKeywordsQueryResolver.Candidate(
                term: "keyword-\(index)",
                storefront: "us",
                platform: .iphone
            )
        }
        var fetchSizes: [Int] = []

        let queriesByKey = try AddKeywordsQueryResolver.resolveQueries(
            for: candidates + [candidates[1]],
            in: modelContext,
            fetchObserver: { fetchSizes.append($0) }
        )
        try modelContext.save()
        let storedQueries = try modelContext.fetch(FetchDescriptor<KeywordQuery>())

        #expect(fetchSizes == [240])
        #expect(queriesByKey.count == 240)
        #expect(queriesByKey[existingQuery.queryKey] === existingQuery)
        #expect(storedQueries.count == 240)
        #expect(Set(storedQueries.map(\.queryKey)).count == 240)
    }

    @Test
    func boundsBulkFetchSizeWithoutChangingResolvedQueries() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let candidates = (0..<8).map { index in
            AddKeywordsQueryResolver.Candidate(
                term: "bounded-\(index)",
                storefront: "us",
                platform: .ipad
            )
        }
        var fetchSizes: [Int] = []

        let queriesByKey = try AddKeywordsQueryResolver.resolveQueries(
            for: candidates,
            in: modelContext,
            fetchBatchSize: 3,
            fetchObserver: { fetchSizes.append($0) }
        )

        #expect(fetchSizes == [3, 3, 2])
        #expect(Set(queriesByKey.keys) == Set(candidates.map(\.queryKey)))
    }

    @Test
    func submitTimeFetchDetectsTrackSavedAfterSnapshotWasTaken() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let setupContext = ModelContext(container)
        let trackedApp = TrackedApp(
            appStoreID: 123456789,
            bundleID: "com.example.external-save",
            name: "External Save",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        setupContext.insert(trackedApp)
        try setupContext.save()

        let submitContext = ModelContext(container)
        let staleSnapshotKeys = Set(
            try submitContext.fetch(FetchDescriptor<TrackedAppKeyword>()).map(\.identityKey)
        )
        #expect(staleSnapshotKeys.isEmpty)

        let writerContext = ModelContext(container)
        let writerApp = try #require(
            try writerContext.fetch(FetchDescriptor<TrackedApp>()).first
        )
        let query = KeywordQuery(term: "growth", storefront: "gb", platform: .iphone)
        let externallySavedTrack = TrackedAppKeyword(
            term: "growth",
            storefront: "gb",
            platform: .iphone,
            trackedApp: writerApp,
            query: query
        )
        writerContext.insert(query)
        writerContext.insert(externallySavedTrack)
        writerApp.keywordTracks.append(externallySavedTrack)
        try writerContext.save()

        let candidate = AddKeywordsQueryResolver.Candidate(
            term: " Growth ",
            storefront: "GB",
            platform: .iphone
        )
        var fetchSizes: [Int] = []
        let persistedIdentityKeys = try AddKeywordsQueryResolver.existingTrackIdentityKeys(
            for: [candidate, candidate],
            appStoreID: trackedApp.appStoreID,
            in: submitContext,
            fetchBatchSize: 1,
            fetchObserver: { fetchSizes.append($0) }
        )

        #expect(fetchSizes == [1])
        #expect(persistedIdentityKeys == [
            candidate.trackIdentityKey(appStoreID: trackedApp.appStoreID)
        ])
        #expect(staleSnapshotKeys.isDisjoint(with: persistedIdentityKeys))
    }

    @Test
    func emptySelectionPerformsNoFetchOrInsertion() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        var fetchCount = 0

        let queriesByKey = try AddKeywordsQueryResolver.resolveQueries(
            for: [],
            in: modelContext,
            fetchObserver: { _ in fetchCount += 1 }
        )

        #expect(queriesByKey.isEmpty)
        #expect(fetchCount == 0)
        #expect(try modelContext.fetchCount(FetchDescriptor<KeywordQuery>()) == 0)
    }

    @Test
    func emptyTrackSelectionPerformsNoFetch() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        var fetchCount = 0

        let identityKeys = try AddKeywordsQueryResolver.existingTrackIdentityKeys(
            for: [],
            appStoreID: 123456789,
            in: modelContext,
            fetchObserver: { _ in fetchCount += 1 }
        )

        #expect(identityKeys.isEmpty)
        #expect(fetchCount == 0)
    }
}
