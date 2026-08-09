import Foundation
import Testing
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
}
