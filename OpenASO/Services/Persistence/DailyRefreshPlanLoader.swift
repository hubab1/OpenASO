import Foundation
import SwiftData

struct DailyRefreshPlanConfiguration: Equatable, Sendable {
    let fallbackStorefrontCodes: [String]
    let refreshRatingsAndReviews: Bool
    let popularityContextAppStoreID: Int64?
    let appleAdsWebSession: AppleAdsWebSession?
    let appStoreConnectCredentials: AppStoreConnectCredentials
}

struct HeadlessRefreshAppPlan: Sendable {
    let appStoreID: Int64
    let sidebarSortOrder: Int
    let metadataRequest: AppMetadataRefreshRequest
    let appDetailRequest: AppDetailRefreshRequest

    init(
        appStoreID: Int64,
        sidebarSortOrder: Int = 0,
        metadataRequest: AppMetadataRefreshRequest,
        appDetailRequest: AppDetailRefreshRequest
    ) {
        precondition(metadataRequest.appStoreID == appStoreID)
        precondition(appDetailRequest.app.appStoreID == appStoreID)
        self.appStoreID = appStoreID
        self.sidebarSortOrder = sidebarSortOrder
        self.metadataRequest = metadataRequest
        self.appDetailRequest = appDetailRequest
    }
}

struct HeadlessRefreshPlan: Sendable {
    let apps: [HeadlessRefreshAppPlan]

    init(apps: [HeadlessRefreshAppPlan]) {
        var seenAppStoreIDs = Set<Int64>()
        self.apps = apps
            .sorted { first, second in
                let firstTracksKeywords = !first.appDetailRequest.trackIdentityKeys.isEmpty
                let secondTracksKeywords = !second.appDetailRequest.trackIdentityKeys.isEmpty
                if firstTracksKeywords != secondTracksKeywords {
                    return firstTracksKeywords
                }
                if first.sidebarSortOrder != second.sidebarSortOrder {
                    return first.sidebarSortOrder < second.sidebarSortOrder
                }
                return first.appStoreID < second.appStoreID
            }
            .filter { seenAppStoreIDs.insert($0.appStoreID).inserted }
    }
}

enum DailyRefreshPlanLoaderError: Error, Equatable, Sendable {
    case inconsistentTrackedApp
}

final class DailyRefreshPlanLoader: Sendable {
    private let backgroundModelStore: BackgroundModelStore

    init(backgroundModelStore: BackgroundModelStore) {
        self.backgroundModelStore = backgroundModelStore
    }

    func load(
        configuration: DailyRefreshPlanConfiguration
    ) async throws -> HeadlessRefreshPlan {
        try Task.checkCancellation()
        return try await backgroundModelStore.read { modelContext in
            try Task.checkCancellation()
            let descriptor = FetchDescriptor<TrackedApp>(sortBy: [
                SortDescriptor(\.appStoreID, order: .forward),
            ])
            let apps = try modelContext.fetch(descriptor)
            let fallbackStorefrontCodes = configuration.fallbackStorefrontCodes
            return try HeadlessRefreshPlan(apps: apps.map { app in
                guard app.storeApp.appStoreID == app.appStoreID else {
                    throw DailyRefreshPlanLoaderError.inconsistentTrackedApp
                }
                guard app.keywordTracks.allSatisfy({ track in
                    guard let platform = AppPlatform(rawValue: track.platformRaw) else {
                        return false
                    }
                    let expectedQueryKey = KeywordQuery.makeQueryKey(
                        term: track.term,
                        storefront: track.storefront,
                        platform: platform
                    )
                    let expectedIdentityKey = TrackedAppKeyword.makeIdentityKey(
                        appStoreID: app.appStoreID,
                        term: track.term,
                        storefront: track.storefront,
                        platform: platform
                    )
                    return track.appStoreID == app.appStoreID
                        && track.trackedApp.persistentModelID == app.persistentModelID
                        && track.identityKey == expectedIdentityKey
                        && track.query.queryKey == expectedQueryKey
                        && track.query.platformRaw == platform.rawValue
                        && KeywordQuery.makeQueryKey(
                            term: track.query.term,
                            storefront: track.query.storefront,
                            platform: platform
                        ) == expectedQueryKey
                }) else {
                    throw DailyRefreshPlanLoaderError.inconsistentTrackedApp
                }
                let trackIdentityKeys = Array(Set(app.keywordTracks.map(\.identityKey))).sorted()
                let storefrontCodes = DailyRefreshStorefrontScope.codes(
                    trackedStorefronts: app.keywordTracks.map(\.storefront),
                    defaultStorefront: app.storeApp.defaultStorefront,
                    fallback: fallbackStorefrontCodes
                )
                let metadataStorefrontCodes = DailyRefreshStorefrontScope.metadataCodes(
                    trackedStorefronts: app.keywordTracks.map(\.storefront),
                    defaultStorefront: app.storeApp.defaultStorefront,
                    fallback: fallbackStorefrontCodes
                )
                let metadataRequest = AppMetadataRefreshRequest(
                    appStoreID: app.appStoreID,
                    requestedStorefronts: metadataStorefrontCodes,
                    includesDefaultStorefront: false,
                    includesTrackedStorefronts: false
                )
                let detailRequest = AppDetailRefreshRequest(
                    app: AppDetailRefreshAppSnapshot(
                        appStoreID: app.appStoreID,
                        bundleID: app.bundleID,
                        name: app.name,
                        subtitle: app.subtitle,
                        sellerName: app.sellerName,
                        defaultPlatform: app.defaultPlatform
                    ),
                    workspace: .keywords,
                    storefrontSelection: .all(codes: storefrontCodes),
                    trackIdentityKeys: trackIdentityKeys,
                    trigger: "daily_refresh",
                    refreshRatings: configuration.refreshRatingsAndReviews,
                    refreshReviews: configuration.refreshRatingsAndReviews,
                    recordsRatingsReviewsRefresh: false,
                    popularityContextAppStoreID: configuration.popularityContextAppStoreID,
                    appleAdsWebSession: configuration.appleAdsWebSession,
                    appStoreConnectCredentials: configuration.appStoreConnectCredentials
                )
                return HeadlessRefreshAppPlan(
                    appStoreID: app.appStoreID,
                    sidebarSortOrder: app.sidebarSortOrder,
                    metadataRequest: metadataRequest,
                    appDetailRequest: detailRequest
                )
            })
        }
    }
}

enum DailyRefreshStorefrontScope {
    static func codes(
        trackedStorefronts: [String],
        defaultStorefront: String?,
        fallback: [String]
    ) -> [String] {
        let tracked = normalized(trackedStorefronts).sorted()
        guard tracked.isEmpty else { return tracked }

        if let defaultStorefront = normalized(defaultStorefront) {
            return [defaultStorefront]
        }

        let fallback = normalized(fallback).sorted()
        if fallback.contains("us") {
            return ["us"]
        }
        return fallback.first.map { [$0] } ?? []
    }

    static func metadataCodes(
        trackedStorefronts: [String],
        defaultStorefront: String?,
        fallback: [String]
    ) -> [String] {
        let tracked = normalized(trackedStorefronts).sorted()
        let canonical = normalized(defaultStorefront)
            ?? codes(
                trackedStorefronts: tracked,
                defaultStorefront: nil,
                fallback: fallback
            ).first
        var storefronts = canonical.map { [$0] } ?? []
        storefronts.append(contentsOf: tracked)
        var seen = Set<String>()
        return storefronts.filter { seen.insert($0).inserted }
    }

    private static func normalized(_ storefronts: [String]) -> [String] {
        Array(Set(storefronts.compactMap(normalized)))
    }

    private static func normalized(_ storefront: String?) -> String? {
        let value = storefront?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
