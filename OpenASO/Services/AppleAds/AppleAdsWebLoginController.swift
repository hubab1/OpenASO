import AppKit
import Foundation
import OSLog
import WebKit

/// Names of the cookies Apple Ads hands out once a browser session is signed in and usable.
enum AppleAdsSessionCookies {
    static let host = "app-ads.apple.com"
    static let xsrfToken = "XSRF-TOKEN-CM"
    static let session = "searchads.soid"
}

struct AppleAdsWebLoginCapture: Equatable, Sendable {
    var cookieHeader: String
    var xsrfToken: String
    var accountName: String?
}

enum AppleAdsWebLoginError: LocalizedError, Equatable {
    case closedBeforeCapture
    case timedOut

    var errorDescription: String? {
        switch self {
        case .closedBeforeCapture:
            return "The Apple Ads sign-in window closed before OpenASO captured the session."
        case .timedOut:
            return "Timed out waiting for Apple Ads sign-in. Sign in and finish 2FA in the window, then try again."
        }
    }
}

/// Signs in to Apple Ads in an in-app WebKit window and captures the resulting web session.
///
/// WebKit is the same engine Safari uses, so Apple ID sign-in, 2FA, and passkeys behave the way
/// they do in a normal browser. The session cookies land in the web view's cookie store, which is
/// the only browser cookie jar a macOS app can legitimately read.
@MainActor
final class AppleAdsWebLoginController: NSObject {
    static let signInURL = URL(string: "https://app-ads.apple.com/")!

    private static let logger = Logger(subsystem: OpenASOLog.subsystem, category: "apple-ads-login")
    private static let pollInterval = Duration.milliseconds(500)
    private static let accountNameTimeout = Duration.seconds(5)

    private var window: NSWindow?
    private var webView: WKWebView?
    private var didCloseWindow = false

    /// Presents the sign-in window and resolves once Apple Ads has handed out a usable session.
    ///
    /// Every step is bounded: the sign-in wait ends at `timeout`, the window closing ends the wait
    /// immediately, and the optional account-name lookup has its own deadline. The caller never
    /// waits on an unbounded operation.
    func captureSession(timeout: Duration = .seconds(300)) async throws -> AppleAdsWebLoginCapture {
        let webView = presentWindow()
        defer { dismissWindow() }

        webView.load(URLRequest(url: Self.signInURL))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            try Task.checkCancellation()

            if didCloseWindow {
                throw AppleAdsWebLoginError.closedBeforeCapture
            }

            if let capture = await capturedSession(from: webView) {
                Self.logger.info("Captured Apple Ads web session from the in-app sign-in window.")
                return capture
            }

            try await Task.sleep(for: Self.pollInterval)
        }

        throw AppleAdsWebLoginError.timedOut
    }

    private func capturedSession(from webView: WKWebView) async -> AppleAdsWebLoginCapture? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let appleAdsCookies = cookies.filter(Self.appliesToAppleAds)

        guard let xsrfCookie = appleAdsCookies.first(where: { $0.name == AppleAdsSessionCookies.xsrfToken }),
              appleAdsCookies.contains(where: { $0.name == AppleAdsSessionCookies.session })
        else {
            return nil
        }

        return AppleAdsWebLoginCapture(
            cookieHeader: Self.cookieHeader(from: appleAdsCookies),
            xsrfToken: xsrfCookie.value,
            accountName: await accountName(from: webView)
        )
    }

    static func appliesToAppleAds(_ cookie: HTTPCookie) -> Bool {
        let host = AppleAdsSessionCookies.host
        let domain = cookie.domain.lowercased()
        let matchesDomain: Bool
        if domain.hasPrefix(".") {
            matchesDomain = host == String(domain.dropFirst()) || host.hasSuffix(domain)
        } else {
            matchesDomain = domain == host
        }

        guard matchesDomain else { return false }

        let path = cookie.path.isEmpty ? "/" : cookie.path
        return path == "/" || "/".hasPrefix(path)
    }

    static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Reads the account label from the signed-in page. Best effort: a missing name only costs the
    /// last-resort seller lookup, so a slow or wedged renderer must not stall the connect flow.
    private func accountName(from webView: WKWebView) async -> String? {
        let script = """
        (function () {
          var text = (document.body && document.body.innerText) || "";
          var ignored = ["Recommendations", "Terms of Service", "Privacy Policy"];
          var lines = text.split(/\\n+/);
          for (var index = 0; index < lines.length; index += 1) {
            var line = lines[index].trim();
            if (!line) continue;
            if (ignored.indexOf(line) !== -1) continue;
            if (/^copyright\\b/i.test(line)) continue;
            return line;
          }
          return "";
        })();
        """

        let name = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resolver = SingleResume(continuation: continuation)
            webView.evaluateJavaScript(script) { value, _ in
                resolver.resume(with: value as? String)
            }
            Task { @MainActor in
                try? await Task.sleep(for: Self.accountNameTimeout)
                resolver.resume(with: nil)
            }
        }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func presentWindow() -> WKWebView {
        if let webView, window != nil {
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_060, height: 820), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Apple Ads Sign In"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.webView = webView
        self.window = window
        didCloseWindow = false
        return webView
    }

    private func dismissWindow() {
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }
}

extension AppleAdsWebLoginController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        didCloseWindow = true
    }
}

/// Resumes a continuation exactly once, whichever of the racing callbacks arrives first.
@MainActor
private final class SingleResume {
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: String?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
