import Foundation

/// Builds an Apple Ads web session from a cookie header the user copied out of their own browser.
///
/// This is the escape hatch for people who would rather sign in to Apple Ads in the browser they
/// already use. macOS gives an app no way to read Safari or Chrome cookies, so the copy step has to
/// be manual.
enum AppleAdsPastedSession {
    static let copySnippet = "copy(document.cookie)"

    static let instructions = """
    Open app-ads.apple.com in your browser and sign in. Open the developer console on that page, \
    run copy(document.cookie), then paste the result here.
    """

    static func session(from pastedText: String, updatedAt: Date = .now) throws -> AppleAdsWebSession {
        let cookies = cookiePairs(in: pastedText)

        guard !cookies.isEmpty else {
            throw OpenASOError.providerUnavailable("No cookies found in the pasted text. \(instructions)")
        }

        guard let xsrfToken = cookies.first(where: { $0.name == AppleAdsSessionCookies.xsrfToken })?.value else {
            throw OpenASOError.providerUnavailable(
                "The pasted cookies are missing \(AppleAdsSessionCookies.xsrfToken). Copy them from an Apple Ads page you are signed in to."
            )
        }

        guard cookies.contains(where: { $0.name == AppleAdsSessionCookies.session }) else {
            throw OpenASOError.providerUnavailable(
                "The pasted cookies are missing \(AppleAdsSessionCookies.session). Copy them from an Apple Ads page you are signed in to."
            )
        }

        return AppleAdsWebSession(
            cookieHeader: cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            xsrfToken: xsrfToken,
            updatedAt: updatedAt
        )
    }

    /// Accepts a raw `document.cookie` string, a full `Cookie: …` request header, or either of those
    /// spread across several pasted lines. Later duplicates win, matching browser semantics.
    static func cookiePairs(in pastedText: String) -> [(name: String, value: String)] {
        var pairs: [(name: String, value: String)] = []
        var indexByName: [String: Int] = [:]

        for rawPair in pastedText.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            var candidate = rawPair.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.lowercased().hasPrefix("cookie:") {
                candidate = String(candidate.dropFirst("cookie:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let separator = candidate.firstIndex(of: "=") else { continue }

            let name = candidate[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = candidate[candidate.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }

            if let existing = indexByName[name] {
                pairs[existing] = (name, value)
            } else {
                indexByName[name] = pairs.count
                pairs.append((name, value))
            }
        }

        return pairs
    }
}
