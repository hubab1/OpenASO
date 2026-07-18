import Testing
@testable import OpenASO

struct AppleAdsConnectionStateTests {
    @Test
    func typedExpiredSessionErrorsMapToExpiredState() {
        let state = AppleAdsConnectionState.classified(
            error: AppleAdsWebSessionExpiredError(),
            hasSession: true
        )

        #expect(state == .expiredSession("Apple Ads asked for sign-in again. Refresh the session to continue."))
    }

    @Test
    func expiredSessionErrorsMapToExpiredState() {
        let state = AppleAdsConnectionState.classified(
            error: OpenASOError.providerUnavailable("Apple Ads web session expired. Refresh it in Settings."),
            hasSession: true
        )

        #expect(state == .expiredSession("Apple Ads asked for sign-in again. Refresh the session to continue."))
    }

    @Test
    func noLinkedAppsErrorsMapToDedicatedState() {
        let state = AppleAdsConnectionState.classified(
            error: OpenASOError.providerUnavailable("Apple Ads needs at least one app with an Apple Ads campaign linked to this account to fetch popularity and difficulty data."),
            hasSession: true
        )

        #expect(state == .noLinkedApps)
        #expect(state.message == AppleAdsConnectionState.noLinkedAppsMessage)
    }

    @Test
    func validSessionApiFailuresMapToApiIssue() {
        let state = AppleAdsConnectionState.classified(
            error: OpenASOError.providerUnavailable("HTTP 500"),
            hasSession: true
        )

        #expect(state == .apiIssue("HTTP 500"))
    }

    @Test
    func genericForbiddenErrorsRemainAPIIssues() {
        let state = AppleAdsConnectionState.classified(
            error: OpenASOError.providerUnavailable("HTTP 403"),
            hasSession: true
        )

        #expect(state == .apiIssue("HTTP 403"))
    }

    @Test
    func dependencyFailuresMapToDependencyIssue() {
        let state = AppleAdsConnectionState.classified(
            error: OpenASOError.providerUnavailable("Node.js is required to connect Apple Ads."),
            hasSession: false
        )

        #expect(state == .dependencyIssue("Node.js is required to connect Apple Ads."))
    }

    @Test
    func npmLaunchFailuresMapToDependencyIssue() {
        let state = AppleAdsConnectionState.classified(
            error: OpenASOError.providerUnavailable("env: npm: No such file or directory"),
            hasSession: false
        )

        #expect(state == .dependencyIssue("env: npm: No such file or directory"))
    }
}
