import Foundation
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
    func inferredStateShowsReconnectRequirementDespiteRetainedSession() {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let state = AppleAdsConnectionState.inferred(
            hasSession: true,
            requiresReconnect: true,
            updatedAt: updatedAt
        )

        #expect(state == .expiredSession(AppleAdsConnectionState.reconnectRequiredMessage))
    }

    @Test
    func inferredStateWithoutSessionRemainsNotConnected() {
        let state = AppleAdsConnectionState.inferred(
            hasSession: false,
            requiresReconnect: true,
            updatedAt: nil
        )

        #expect(state == .notConnected)
    }

    @Test
    func typedExpiryRetainsManualPopularityContext() {
        #expect(
            !AppleAdsConnectionState.shouldClearManualPopularityContext(
                after: AppleAdsWebSessionExpiredError()
            )
        )
        #expect(
            AppleAdsConnectionState.shouldClearManualPopularityContext(
                after: OpenASOError.appNotFound
            )
        )
    }

    @Test
    func reconnectRequirementOverridesFreshAndStalePopularityIndicators() {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let reconnectState = KeywordPopularityIndicatorState.reconnectRequired(
            message: KeywordPopularityIndicatorState.reconnectRequiredDetail
        )

        #expect(
            KeywordPopularityIndicatorState.none
                .overridingForAppleAdsReconnectRequirement(true) == reconnectState
        )
        #expect(
            KeywordPopularityIndicatorState.stale(lastUpdatedAt: updatedAt)
                .overridingForAppleAdsReconnectRequirement(true) == reconnectState
        )
        #expect(
            KeywordPopularityIndicatorState.stale(lastUpdatedAt: updatedAt)
                .overridingForAppleAdsReconnectRequirement(false) == .stale(lastUpdatedAt: updatedAt)
        )
        #expect(
            KeywordPopularityIndicatorState.unavailable(message: "Popularity unavailable in this storefront.")
                .overridingForAppleAdsReconnectRequirement(true)
                == .unavailable(message: "Popularity unavailable in this storefront.")
        )
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
    func closingTheSignInWindowWithoutASessionStaysNotConnected() {
        let state = AppleAdsConnectionState.classified(
            error: AppleAdsWebLoginError.closedBeforeCapture,
            hasSession: false
        )

        #expect(state == .notConnected)
    }

    @Test
    func closingTheSignInWindowKeepsAnExistingSessionConnected() {
        let state = AppleAdsConnectionState.classified(
            error: AppleAdsWebLoginError.closedBeforeCapture,
            hasSession: true
        )

        #expect(state == .connected(updatedAt: nil))
    }

    @Test
    func signInTimeoutAsksForAnotherAttempt() {
        let state = AppleAdsConnectionState.classified(
            error: AppleAdsWebLoginError.timedOut,
            hasSession: false
        )

        #expect(state == .expiredSession(AppleAdsWebLoginError.timedOut.localizedDescription))
    }
}
