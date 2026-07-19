import Foundation

struct KeywordMarketInsightsViewScope: Equatable, Hashable, Identifiable, Sendable {
    let appStoreID: Int64
    let storefronts: [String]
    let platform: AppPlatform

    var id: String {
        let values = [String(appStoreID), platform.rawValue] + storefronts
        return "\(storefronts.count)|" + values.map { value in
            "\(value.utf8.count):\(value)"
        }.joined()
    }

    init(
        appStoreID: Int64,
        storefronts: [String],
        platform: AppPlatform
    ) throws {
        let validatedRequest = try KeywordMarketInsightsRequest(
            appStoreID: appStoreID,
            storefronts: storefronts,
            platform: platform
        )
        self.appStoreID = validatedRequest.appStoreID
        self.storefronts = validatedRequest.storefronts
        self.platform = validatedRequest.platform
    }

    func request(cursor: String?) throws -> KeywordMarketInsightsRequest {
        try KeywordMarketInsightsRequest(
            appStoreID: appStoreID,
            storefronts: storefronts,
            platform: platform,
            cursor: cursor
        )
    }
}

struct KeywordMarketInsightsSheetContext: Identifiable {
    let id = UUID()
    let appName: String
    let appStoreID: Int64
    let platform: AppPlatform
    let scope: KeywordMarketInsightsViewScope?
    let scopeIssue: String?
}

enum KeywordMarketInsightsScopeProjection {
    struct CandidateMarket: Equatable, Hashable, Sendable {
        let storefront: String
        let platform: AppPlatform
    }

    static func project(
        appStoreID: Int64,
        candidateMarkets: [CandidateMarket],
        selectedStorefrontFilter: StorefrontFilter,
        selectedPlatformFilter: PlatformFilter,
        defaultPlatform: AppPlatform
    ) throws -> KeywordMarketInsightsViewScope {
        let platform = concretePlatform(
            selectedPlatformFilter: selectedPlatformFilter,
            defaultPlatform: defaultPlatform
        )

        let storefronts = switch selectedStorefrontFilter {
        case .all:
            candidateMarkets.compactMap { candidate in
                candidate.platform == platform ? candidate.storefront : nil
            }
        case .storefront(let code, _):
            [code]
        }

        return try KeywordMarketInsightsViewScope(
            appStoreID: appStoreID,
            storefronts: storefronts,
            platform: platform
        )
    }


    static func concretePlatform(
        selectedPlatformFilter: PlatformFilter,
        defaultPlatform: AppPlatform
    ) -> AppPlatform {
        switch selectedPlatformFilter {
        case .all:
            defaultPlatform
        case .platform(let platform):
            platform
        }
    }
}
