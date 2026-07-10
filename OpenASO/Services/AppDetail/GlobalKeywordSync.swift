import Foundation
import SwiftData

// Reconciles every tracked app's keyword tracks with the shared global
// keyword list. Global keywords are tracked across all bundled storefronts
// using each app's default platform. Tracks created by this sync carry a
// marker note so removals never touch manually added keywords.
enum GlobalKeywordSync {
    static let globalTrackNote = "Added from global keyword list."

    struct Outcome: Sendable {
        var appCount = 0
        var insertedTrackCount = 0
        var removedTrackCount = 0

        var summaryText: String {
            var parts: [String] = []
            if insertedTrackCount > 0 {
                parts.append("added \(insertedTrackCount.formatted()) keyword tracks")
            }
            if removedTrackCount > 0 {
                parts.append("removed \(removedTrackCount.formatted())")
            }
            guard !parts.isEmpty else {
                return "All \(appCount.formatted()) apps already in sync."
            }
            return "Synced \(appCount.formatted()) apps: \(parts.joined(separator: ", "))."
        }
    }

    // Reconcile all apps' tracks with the global list. Storefront codes are
    // normally every bundled storefront so rankings cover all markets.
    static func sync(
        templates: [GlobalTrackedKeywordTemplate],
        storefrontCodes: [String],
        in modelContext: ModelContext
    ) throws -> Outcome {
        let terms = templates.map(\.term).filter { !$0.isEmpty }
        let termKeys = Set(terms.map(\.normalizedKeywordKey))
        let normalizedStorefronts = Array(Set(
            storefrontCodes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )).sorted()

        var outcome = Outcome()
        // TrackedApp.name is computed, not a schema field — sort in memory.
        let apps = try modelContext.fetch(FetchDescriptor<TrackedApp>(
            sortBy: [SortDescriptor(\.appStoreID, order: .forward)]
        ))
        outcome.appCount = apps.count

        // Remove sync-created tracks whose term left the global list.
        let markerNote = globalTrackNote
        let markedDescriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.notes == markerNote
            }
        )
        for track in try modelContext.fetch(markedDescriptor)
        where !termKeys.contains(track.term.normalizedKeywordKey) {
            deleteSnapshots(for: track, in: modelContext)
            modelContext.delete(track)
            outcome.removedTrackCount += 1
        }

        guard !apps.isEmpty, !terms.isEmpty, !normalizedStorefronts.isEmpty else {
            if outcome.removedTrackCount > 0 {
                try modelContext.save()
            }
            return outcome
        }

        // Resolve every needed keyword query with one batch fetch; queries are
        // shared across apps.
        let platforms = Set(apps.map(\.defaultPlatform))
        var neededQueryKeySet: Set<String> = []
        for platform in platforms {
            for storefront in normalizedStorefronts {
                for term in terms {
                    neededQueryKeySet.insert(
                        KeywordQuery.makeQueryKey(term: term, storefront: storefront, platform: platform)
                    )
                }
            }
        }
        var queriesByKey: [String: KeywordQuery] = [:]
        let targetQueryKeys = Array(neededQueryKeySet)
        let queryDescriptor = FetchDescriptor<KeywordQuery>(
            predicate: #Predicate { query in
                targetQueryKeys.contains(query.queryKey)
            }
        )
        for query in try modelContext.fetch(queryDescriptor) {
            queriesByKey[query.queryKey] = query
        }

        for app in apps {
            let platform = app.defaultPlatform
            var existingKeys = Set<String>()
            for track in app.keywordTracks where !track.isDeleted {
                existingKeys.insert(
                    trackKey(term: track.term, storefront: track.storefront, platform: track.platform)
                )
            }

            for storefront in normalizedStorefronts {
                for term in terms {
                    let key = trackKey(term: term, storefront: storefront, platform: platform)
                    guard existingKeys.insert(key).inserted else { continue }

                    let queryKey = KeywordQuery.makeQueryKey(
                        term: term, storefront: storefront, platform: platform)
                    let query: KeywordQuery
                    if let existing = queriesByKey[queryKey] {
                        query = existing
                    } else {
                        query = KeywordQuery(term: term, storefront: storefront, platform: platform)
                        modelContext.insert(query)
                        queriesByKey[queryKey] = query
                    }

                    let track = TrackedAppKeyword(
                        term: term,
                        storefront: storefront,
                        platform: platform,
                        trackedApp: app,
                        query: query
                    )
                    track.notes = markerNote
                    app.keywordTracks.append(track)
                    modelContext.insert(track)
                    outcome.insertedTrackCount += 1
                }
            }
        }

        try modelContext.save()
        return outcome
    }

    // Sync the global list to all apps and kick a background ranking and
    // metrics refresh for the tracks that were just created.
    @MainActor
    static func syncAndRefresh(
        templates: [GlobalTrackedKeywordTemplate],
        services: AppServices,
        modelContext: ModelContext
    ) async throws -> Outcome {
        let storefrontCodes = try StorefrontCatalog.bundledStorefrontCodes()

        let outcome: Outcome
        if let backgroundModelStore = services.backgroundModelStore {
            outcome = try await backgroundModelStore.write { backgroundContext in
                try sync(
                    templates: templates,
                    storefrontCodes: storefrontCodes,
                    in: backgroundContext
                )
            }
            services.markBackgroundModelStoreChanged()
        } else {
            outcome = try sync(
                templates: templates,
                storefrontCodes: storefrontCodes,
                in: modelContext
            )
        }

        if outcome.insertedTrackCount > 0 {
            Task { @MainActor in
                await refreshUnfetchedSyncedTracks(services: services, in: modelContext)
            }
        }
        return outcome
    }

    // Fetch rankings and metrics for sync-created tracks that have never been
    // refreshed. Runs one coordinator pass so identical keyword+market queries
    // shared by multiple apps are fetched exactly once.
    @MainActor
    static func refreshUnfetchedSyncedTracks(
        services: AppServices,
        in modelContext: ModelContext
    ) async {
        let markerNote = globalTrackNote
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.notes == markerNote && track.lastRefreshAt == nil
            }
        )
        guard let tracks = try? modelContext.fetch(descriptor), !tracks.isEmpty else { return }

        let progressStore = services.refreshProgressStore
        progressStore.beginGlobalKeywordSync(trackTotal: tracks.count)

        _ = await services.refreshCoordinator.refresh(
            tracks: tracks,
            in: modelContext,
            analyticsTrigger: "global_keyword_sync",
            progress: { completed, total, failureCount in
                await progressStore.updateStep(
                    .keywords,
                    status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                    completed: completed,
                    total: total,
                    failureCount: failureCount
                )
            }
        )

        var metricsErrorMessage: String?
        if let backgroundModelStore = services.backgroundModelStore {
            let identityKeys = tracks.map(\.identityKey)
            let outcomes = try? await services.keywordMetricsService.refreshMetrics(
                for: identityKeys,
                popularityContextAppStoreID: services.settingsStore.popularityContextAppStoreID,
                webSession: services.appleAdsWebSessionStore.session,
                using: backgroundModelStore,
                progress: { completed, total, failureCount in
                    await progressStore.updateStep(
                        .metrics,
                        status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                        completed: completed,
                        total: total,
                        failureCount: failureCount
                    )
                }
            )
            metricsErrorMessage = outcomes?.first { $0.errorMessage != nil }?.errorMessage
        }

        services.markBackgroundModelStoreChanged()
        progressStore.finish(error: metricsErrorMessage.map(OpenASOError.providerUnavailable))
    }

    private static func trackKey(term: String, storefront: String, platform: AppPlatform) -> String {
        [
            term.normalizedKeywordKey,
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform.rawValue,
        ].joined(separator: "::")
    }

    private static func deleteSnapshots(for track: TrackedAppKeyword, in modelContext: ModelContext) {
        for snapshot in track.snapshots {
            for result in snapshot.topResults {
                modelContext.delete(result)
            }
            snapshot.topResults.removeAll()
            modelContext.delete(snapshot)
        }
        track.snapshots.removeAll()
    }
}
