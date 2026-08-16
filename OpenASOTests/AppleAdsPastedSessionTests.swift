import Foundation
import Testing
import WebKit
@testable import OpenASO

struct AppleAdsPastedSessionTests {
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func documentCookieOutputBecomesASession() throws {
        let session = try AppleAdsPastedSession.session(
            from: "XSRF-TOKEN-CM=token-value; searchads.soid=session-value; sa_user=42",
            updatedAt: updatedAt
        )

        #expect(session.xsrfToken == "token-value")
        #expect(session.cookieHeader == "XSRF-TOKEN-CM=token-value; searchads.soid=session-value; sa_user=42")
        #expect(session.isComplete)
        #expect(session.updatedAt == updatedAt)
    }

    @Test
    func requestHeaderPrefixAndWhitespaceAreTolerated() throws {
        let session = try AppleAdsPastedSession.session(
            from: "  Cookie: XSRF-TOKEN-CM=token-value ;\n searchads.soid=session-value \n",
            updatedAt: updatedAt
        )

        #expect(session.xsrfToken == "token-value")
        #expect(session.cookieHeader == "XSRF-TOKEN-CM=token-value; searchads.soid=session-value")
    }

    @Test
    func valuesContainingEqualsSignsSurvive() throws {
        let session = try AppleAdsPastedSession.session(
            from: "XSRF-TOKEN-CM=abc==; searchads.soid=zzz=",
            updatedAt: updatedAt
        )

        #expect(session.xsrfToken == "abc==")
        #expect(session.cookieHeader == "XSRF-TOKEN-CM=abc==; searchads.soid=zzz=")
    }

    @Test
    func laterDuplicatesReplaceEarlierOnesInPlace() {
        let pairs = AppleAdsPastedSession.cookiePairs(in: "a=1; b=2; a=3")

        #expect(pairs.map(\.name) == ["a", "b"])
        #expect(pairs.map(\.value) == ["3", "2"])
    }

    @Test
    func missingXSRFTokenIsRejected() {
        #expect(throws: OpenASOError.self) {
            try AppleAdsPastedSession.session(from: "searchads.soid=session-value", updatedAt: updatedAt)
        }
    }

    @Test
    func missingSessionCookieIsRejected() {
        #expect(throws: OpenASOError.self) {
            try AppleAdsPastedSession.session(from: "XSRF-TOKEN-CM=token-value", updatedAt: updatedAt)
        }
    }

    @Test
    func textWithoutAnyCookiePairsIsRejected() {
        #expect(throws: OpenASOError.self) {
            try AppleAdsPastedSession.session(from: "no cookies here", updatedAt: updatedAt)
        }
    }

    @Test
    func webLoginCaptureRequiresAuthenticatedAppleAdsPage() {
        #expect(AppleAdsWebLoginController.isAuthenticatedAppleAdsPage(
            URL(string: "https://app-ads.apple.com/cm/app")
        ))
        #expect(!AppleAdsWebLoginController.isAuthenticatedAppleAdsPage(
            URL(string: "https://app-ads.apple.com/auth/signin")
        ))
        #expect(!AppleAdsWebLoginController.isAuthenticatedAppleAdsPage(
            URL(string: "https://account.apple.com/sign-in")
        ))
        #expect(!AppleAdsWebLoginController.isAuthenticatedAppleAdsPage(nil))
    }

    @MainActor
    @Test
    func webLoginUsesPersistentBrowserStorage() {
        #expect(AppleAdsWebLoginController.makeWebsiteDataStore().isPersistent)
    }

    @Test
    func webLoginCapturesUsableCookiesDuringAppleAdsAuthRedirect() throws {
        let sessionCookie = try #require(HTTPCookie(properties: [
            .domain: ".app-ads.apple.com",
            .path: "/",
            .name: AppleAdsSessionCookies.session,
            .value: "session",
            .secure: "TRUE"
        ]))
        let xsrfCookie = try #require(HTTPCookie(properties: [
            .domain: "app-ads.apple.com",
            .path: "/",
            .name: AppleAdsSessionCookies.xsrfToken,
            .value: "token",
            .secure: "TRUE"
        ]))

        #expect(AppleAdsWebLoginController.isCaptureReady(
            url: URL(string: "https://app-ads.apple.com/auth/callback"),
            cookies: [sessionCookie, xsrfCookie]
        ))
    }

    @MainActor
    @Test
    func webLoginPreparationPreservesTrustedBrowserCookiesAndRemovesStaleSession() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore
        let identityCookie = try #require(HTTPCookie(properties: [
            .domain: "idmsa.apple.com",
            .path: "/",
            .name: "trusted-browser",
            .value: "trusted",
            .secure: "TRUE"
        ]))
        let sessionCookie = try #require(HTTPCookie(properties: [
            .domain: ".app-ads.apple.com",
            .path: "/",
            .name: AppleAdsSessionCookies.session,
            .value: "stale-session",
            .secure: "TRUE"
        ]))
        let xsrfCookie = try #require(HTTPCookie(properties: [
            .domain: "app-ads.apple.com",
            .path: "/",
            .name: AppleAdsSessionCookies.xsrfToken,
            .value: "stale-token",
            .secure: "TRUE"
        ]))
        await cookieStore.setCookie(identityCookie)
        await cookieStore.setCookie(sessionCookie)
        await cookieStore.setCookie(xsrfCookie)

        let reusesExplicitAccount = await AppleAdsWebLoginController.prepareForSignIn(
            using: dataStore
        )
        let retainedCookies = await cookieStore.allCookies()

        #expect(reusesExplicitAccount)
        #expect(retainedCookies.contains { $0.name == identityCookie.name })
        #expect(!retainedCookies.contains { $0.name == sessionCookie.name })
        #expect(!retainedCookies.contains { $0.name == xsrfCookie.name })
    }

    @Test
    func webLoginCookieHeaderIsDeterministicAndAppleAdsScoped() throws {
        let sessionCookie = try #require(HTTPCookie(properties: [
            .domain: ".app-ads.apple.com",
            .path: "/",
            .name: AppleAdsSessionCookies.session,
            .value: "session",
            .secure: "TRUE"
        ]))
        let xsrfCookie = try #require(HTTPCookie(properties: [
            .domain: "app-ads.apple.com",
            .path: "/",
            .name: AppleAdsSessionCookies.xsrfToken,
            .value: "token",
            .secure: "TRUE"
        ]))
        let unrelatedCookie = try #require(HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: "unrelated",
            .value: "value"
        ]))

        #expect(AppleAdsWebLoginController.appliesToAppleAds(sessionCookie))
        #expect(AppleAdsWebLoginController.appliesToAppleAds(xsrfCookie))
        #expect(!AppleAdsWebLoginController.appliesToAppleAds(unrelatedCookie))
        #expect(
            AppleAdsWebLoginController.cookieHeader(from: [sessionCookie, xsrfCookie])
                == "XSRF-TOKEN-CM=token; searchads.soid=session"
        )
    }

    @Test
    func webLoginWindowFitsWithinVisibleScreen() {
        let compactScreen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let compactSize = AppleAdsWebLoginWindowLayout.contentSize(for: compactScreen)
        let largeSize = AppleAdsWebLoginWindowLayout.contentSize(
            for: CGRect(x: 0, y: 0, width: 2_000, height: 1_400)
        )

        #expect(compactSize.width == 752)
        #expect(compactSize.height == 552)
        #expect(largeSize.width == 1_060)
        #expect(largeSize.height == 820)
    }

    @Test
    func webLoginUsesSafariBrowserIdentityForAppleAccountCompatibility() {
        let macOS15UserAgent = AppleAdsWebLoginBrowser.safariUserAgent(
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 6,
                patchVersion: 0
            )
        )
        let macOS26UserAgent = AppleAdsWebLoginBrowser.safariUserAgent(
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 26,
                minorVersion: 5,
                patchVersion: 2
            )
        )

        #expect(macOS15UserAgent.contains("Version/18.6"))
        #expect(macOS26UserAgent.contains("Version/26.5"))
        #expect(macOS26UserAgent.hasSuffix("Safari/605.1.15"))
    }

    @Test
    func credentialAutomationIsAvailableOnlyForCompleteCredentials() {
        #expect(AppleAdsWebLoginAutomation.script(for: nil) == nil)
        #expect(AppleAdsWebLoginAutomation.script(for: AppleAdsWebLoginCredentials(
            username: "person@example.com",
            password: ""
        )) == nil)

        let script = AppleAdsWebLoginAutomation.script(for: AppleAdsWebLoginCredentials(
            username: "person@example.com",
            password: "quoted \" password"
        ))
        #expect(script?.contains("host.endsWith(\".apple.com\")") == true)
        #expect(script?.contains("input#password_text_field") == true)
    }

    @Test
    func webLoginRequiresExplicitAccountSelectionBeforeCapturingSession() {
        let policy = AppleAdsWebLoginAutomation.explicitAccountPolicyScript

        #expect(policy.contains("enableTiburonInd = false"))
        #expect(policy.contains("openASOExplicitAccount"))

        let credentialScript = AppleAdsWebLoginAutomation.script(for: AppleAdsWebLoginCredentials(
            username: "person@example.com",
            password: "password"
        ))
        #expect(credentialScript?.contains("__openasoMarkExplicitAccount") == true)
    }
}
