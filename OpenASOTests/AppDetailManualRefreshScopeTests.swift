import Testing
@testable import OpenASO

@Suite
struct AppDetailManualRefreshScopeTests {
    @Test
    func focusedAllCountriesUsesTrackedStorefronts() {
        let selection = AppDetailManualRefreshScopeResolver.selection(
            scope: .focused,
            selectedStorefrontFilter: .all,
            trackedStorefronts: [" GB ", "us", "gb", ""],
            defaultStorefront: "ca",
            bundledStorefronts: ["us", "ca", "gb"]
        )

        #expect(selection.codes == ["gb", "us"])
    }

    @Test
    func focusedAllCountriesFallsBackToDefaultStorefront() {
        let selection = AppDetailManualRefreshScopeResolver.selection(
            scope: .focused,
            selectedStorefrontFilter: .all,
            trackedStorefronts: [],
            defaultStorefront: " CA ",
            bundledStorefronts: ["us", "ca", "gb"]
        )

        #expect(selection.codes == ["ca"])
    }

    @Test
    func focusedAllCountriesFallsBackToUnitedStates() {
        let selection = AppDetailManualRefreshScopeResolver.selection(
            scope: .focused,
            selectedStorefrontFilter: .all,
            trackedStorefronts: [],
            defaultStorefront: nil,
            bundledStorefronts: ["gb", " US ", "ca"]
        )

        #expect(selection.codes == ["us"])
    }

    @Test
    func focusedSpecificCountryUsesOnlySelectedStorefront() {
        let selection = AppDetailManualRefreshScopeResolver.selection(
            scope: .focused,
            selectedStorefrontFilter: .storefront(code: " GB ", title: "🇬🇧 United Kingdom"),
            trackedStorefronts: ["us", "ca"],
            defaultStorefront: "us",
            bundledStorefronts: ["us", "ca", "gb"]
        )

        #expect(selection.codes == ["gb"])
    }

    @Test
    func allStorefrontsUsesEveryBundledStorefront() {
        let selection = AppDetailManualRefreshScopeResolver.selection(
            scope: .allStorefronts,
            selectedStorefrontFilter: .storefront(code: "gb", title: "United Kingdom"),
            trackedStorefronts: ["gb"],
            defaultStorefront: "gb",
            bundledStorefronts: [" GB ", "us", "ca", "us", ""]
        )

        #expect(selection.codes == ["ca", "gb", "us"])
    }

    @Test
    func selectedCountryIncludesOnlyMatchingKeywordTracks() {
        let identityKeys = AppDetailManualRefreshScopeResolver.identityKeys(
            for: [
                AppDetailManualRefreshTrack(identityKey: "us-phone", storefront: " US "),
                AppDetailManualRefreshTrack(identityKey: "gb-phone", storefront: "gb"),
                AppDetailManualRefreshTrack(identityKey: "us-tablet", storefront: "us"),
            ],
            storefrontSelection: .storefront(code: "us")
        )

        #expect(identityKeys == ["us-phone", "us-tablet"])
    }

    @Test
    func allCountriesIncludesTracksFromEverySelectedStorefront() {
        let identityKeys = AppDetailManualRefreshScopeResolver.identityKeys(
            for: [
                AppDetailManualRefreshTrack(identityKey: "ca", storefront: "ca"),
                AppDetailManualRefreshTrack(identityKey: "gb", storefront: "gb"),
                AppDetailManualRefreshTrack(identityKey: "us", storefront: "us"),
            ],
            storefrontSelection: .all(codes: ["gb", " US "])
        )

        #expect(identityKeys == ["gb", "us"])
    }
}
