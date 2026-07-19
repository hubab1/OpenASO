import Testing
@testable import OpenASO

struct KeywordMarketInsightsViewScopeTests {
    @Test
    func allFiltersResolveToConcreteDefaultPlatformAndItsTrackedMarkets() throws {
        let scope = try KeywordMarketInsightsScopeProjection.project(
            appStoreID: 42,
            candidateMarkets: [
                .init(storefront: "GB", platform: .iphone),
                .init(storefront: "us", platform: .iphone),
                .init(storefront: "gb", platform: .iphone),
                .init(storefront: "ca", platform: .ipad)
            ],
            selectedStorefrontFilter: .all,
            selectedPlatformFilter: .all,
            defaultPlatform: .iphone
        )

        #expect(scope.appStoreID == 42)
        #expect(scope.platform == .iphone)
        #expect(scope.storefronts == ["gb", "us"])
    }

    @Test
    func selectedFiltersRemainExplicitEvenWithoutExistingTrack() throws {
        let scope = try KeywordMarketInsightsScopeProjection.project(
            appStoreID: 99,
            candidateMarkets: [],
            selectedStorefrontFilter: .storefront(code: "CA", title: "🇨🇦 Canada"),
            selectedPlatformFilter: .platform(.ipad),
            defaultPlatform: .iphone
        )

        #expect(scope.platform == .ipad)
        #expect(scope.storefronts == ["ca"])
    }

    @Test
    func allCountriesWithNoTracksForConcretePlatformFailsBeforeLoading() {
        #expect(throws: (any Error).self) {
            _ = try KeywordMarketInsightsScopeProjection.project(
                appStoreID: 42,
                candidateMarkets: [
                    .init(storefront: "us", platform: .ipad)
                ],
                selectedStorefrontFilter: .all,
                selectedPlatformFilter: .platform(.iphone),
                defaultPlatform: .ipad
            )
        }
    }

    @Test
    func scopeIdentityCannotCollideAtStorefrontDelimiters() throws {
        let left = try KeywordMarketInsightsViewScope(
            appStoreID: 42,
            storefronts: ["a,b", "c"],
            platform: .iphone
        )
        let right = try KeywordMarketInsightsViewScope(
            appStoreID: 42,
            storefronts: ["a", "b,c"],
            platform: .iphone
        )

        #expect(left != right)
        #expect(left.id != right.id)
    }
}
