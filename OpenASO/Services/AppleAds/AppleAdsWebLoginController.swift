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

@MainActor
protocol AppleAdsWebLoginCapturing: AnyObject {
    func captureSession(
        credentials: AppleAdsWebLoginCredentials?,
        timeout: Duration
    ) async throws -> AppleAdsWebLoginCapture
}

enum AppleAdsWebLoginError: LocalizedError, Equatable {
    case closedBeforeCapture
    case explicitAccountRequired
    case timedOut

    var errorDescription: String? {
        switch self {
        case .closedBeforeCapture:
            return "The Apple Ads sign-in window closed before OpenASO captured the session."
        case .explicitAccountRequired:
            return "OpenASO will not use the Mac's default Apple Account. Try again, choose Use a Different Apple Account if Apple asks, then enter the Apple ID you want OpenASO to use."
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
final class AppleAdsWebLoginController: NSObject, AppleAdsWebLoginCapturing {
    static let signInURL = URL(string: "https://app-ads.apple.com/")!

    private static let logger = Logger(subsystem: OpenASOLog.subsystem, category: "apple-ads-login")
    private static let pollInterval = Duration.milliseconds(500)
    private static let accountNameTimeout = Duration.seconds(5)
    private static let explicitAccountMessageHandler = "openASOExplicitAccount"

    private var window: NSWindow?
    private var webView: WKWebView?
    private var didCloseWindow = false
    private var didUseExplicitAccount = false

    /// Presents the sign-in window and resolves once Apple Ads has handed out a usable session.
    ///
    /// Every step is bounded: the sign-in wait ends at `timeout`, the window closing ends the wait
    /// immediately, and the optional account-name lookup has its own deadline. The caller never
    /// waits on an unbounded operation.
    func captureSession(
        credentials: AppleAdsWebLoginCredentials? = nil,
        timeout: Duration = .seconds(300)
    ) async throws -> AppleAdsWebLoginCapture {
        let websiteDataStore = Self.makeWebsiteDataStore()
        let reusesExplicitAccount = await Self.prepareForSignIn(using: websiteDataStore)
        let webView = presentWindow(
            credentials: credentials,
            websiteDataStore: websiteDataStore,
            reusesExplicitAccount: reusesExplicitAccount
        )
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
                guard didUseExplicitAccount else {
                    throw AppleAdsWebLoginError.explicitAccountRequired
                }
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

        guard Self.isCaptureReady(url: webView.url, cookies: appleAdsCookies),
              let xsrfCookie = appleAdsCookies.first(where: { $0.name == AppleAdsSessionCookies.xsrfToken }),
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

    nonisolated static func appliesToAppleAds(_ cookie: HTTPCookie) -> Bool {
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

    nonisolated static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .sorted {
                if $0.name == $1.name {
                    return $0.path < $1.path
                }
                return $0.name < $1.name
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    nonisolated static func isCaptureReady(url: URL?, cookies: [HTTPCookie]) -> Bool {
        url != nil
            && cookies.contains { $0.name == AppleAdsSessionCookies.xsrfToken }
            && cookies.contains { $0.name == AppleAdsSessionCookies.session }
    }

    static func prepareForSignIn(using dataStore: WKWebsiteDataStore) async -> Bool {
        let cookieStore = dataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        let reusesExplicitAccount = cookies.contains(where: Self.isAppleIdentityCookie)

        for cookie in cookies where Self.isCapturedAppleAdsSessionCookie(cookie) {
            await cookieStore.deleteCookie(cookie)
        }

        return reusesExplicitAccount
    }

    nonisolated static func isAppleIdentityCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain != AppleAdsSessionCookies.host
            && (domain == "apple.com" || domain.hasSuffix(".apple.com"))
    }

    nonisolated static func isCapturedAppleAdsSessionCookie(_ cookie: HTTPCookie) -> Bool {
        appliesToAppleAds(cookie)
            && [AppleAdsSessionCookies.xsrfToken, AppleAdsSessionCookies.session].contains(cookie.name)
    }

    nonisolated static func isAuthenticatedAppleAdsPage(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == AppleAdsSessionCookies.host else {
            return false
        }

        let location = [url.path, url.query]
            .compactMap(\.self)
            .joined(separator: "?")
            .lowercased()
        return !["/auth/", "/authenticate", "/login", "/sign-in", "/signin"].contains {
            location.contains($0)
        }
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

    private func presentWindow(
        credentials: AppleAdsWebLoginCredentials?,
        websiteDataStore: WKWebsiteDataStore,
        reusesExplicitAccount: Bool
    ) -> WKWebView {
        if let webView, window != nil {
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.userContentController.add(
            self,
            name: Self.explicitAccountMessageHandler
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: AppleAdsWebLoginAutomation.explicitAccountPolicyScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        if let script = AppleAdsWebLoginAutomation.script(for: credentials) {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: script,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false
                )
            )
        }

        let contentSize = AppleAdsWebLoginWindowLayout.contentSize(
            for: NSScreen.main?.visibleFrame
        )
        let frame = NSRect(origin: .zero, size: contentSize)
        let webView = WKWebView(frame: frame, configuration: configuration)
        // Apple's alternate-account sign-in occasionally leaves its account widget blank when
        // it identifies the client as an embedded WebKit view. Use Safari's public browser
        // identity while retaining the isolated WKWebsiteDataStore and cookie capture.
        webView.customUserAgent = AppleAdsWebLoginBrowser.safariUserAgent()
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: frame,
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
        // The persistent WebKit store is private to OpenASO. Apple identity cookies in it can only
        // come from an account the user previously selected in this sign-in window.
        didUseExplicitAccount = reusesExplicitAccount
        return webView
    }

    static func makeWebsiteDataStore() -> WKWebsiteDataStore {
        .default()
    }

    private func dismissWindow() {
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.explicitAccountMessageHandler
        )
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }
}

enum AppleAdsWebLoginBrowser {
    static func safariUserAgent(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        // Safari 18 ships with macOS 15. Apple aligned Safari's major version with macOS when
        // macOS moved to version 26, so preserve the correct identity across our deployment range.
        let safariMajorVersion = operatingSystemVersion.majorVersion >= 26
            ? operatingSystemVersion.majorVersion
            : operatingSystemVersion.majorVersion + 3
        let version = "\(safariMajorVersion).\(operatingSystemVersion.minorVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version) Safari/605.1.15"
    }
}

enum AppleAdsWebLoginWindowLayout {
    private static let idealSize = NSSize(width: 1_060, height: 820)
    private static let screenMargin: CGFloat = 48

    static func contentSize(for visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else { return idealSize }
        return NSSize(
            width: min(idealSize.width, max(1, visibleFrame.width - screenMargin)),
            height: min(idealSize.height, max(1, visibleFrame.height - screenMargin))
        )
    }
}

/// Generates a document-local helper that fills the optional saved login on Apple-owned sign-in
/// pages. The script is installed only in the OpenASO WebKit view used for this capture attempt.
enum AppleAdsWebLoginAutomation {
    /// Prevents Apple-owned sign-in pages from silently requesting the Mac's platform credential.
    /// The Apple ID field also marks that a specific account was explicitly selected without
    /// exposing its value to native code.
    static let explicitAccountPolicyScript = """
    (() => {
      const host = window.location.hostname.toLowerCase();
      const isAppleOwned = host === "apple.com" || host.endsWith(".apple.com");
      if (!isAppleOwned || host === "app-ads.apple.com" || window.__openasoExplicitAccountPolicy) return;
      window.__openasoExplicitAccountPolicy = true;

      const disableAutomaticPlatformAccount = () => {
        const bootArguments = document.querySelector("#embed_login_boot_args");
        if (!bootArguments || bootArguments.dataset.openasoPatched === "true") return;
        try {
          const configuration = JSON.parse(bootArguments.textContent || "{}");
          if (!configuration.direct) return;
          configuration.direct.enableTiburonInd = false;
          bootArguments.textContent = JSON.stringify(configuration);
          bootArguments.dataset.openasoPatched = "true";
        } catch (_) {}
      };
      const bootObserver = new MutationObserver(disableAutomaticPlatformAccount);
      bootObserver.observe(document, { childList: true, subtree: true });
      document.addEventListener("DOMContentLoaded", () => {
        disableAutomaticPlatformAccount();
        bootObserver.disconnect();
      }, { once: true });

      const markExplicitAccount = () => {
        if (window.__openasoExplicitAccountSelected) return;
        window.__openasoExplicitAccountSelected = true;
        window.webkit?.messageHandlers?.openASOExplicitAccount?.postMessage("selected");
      };
      window.__openasoMarkExplicitAccount = markExplicitAccount;

      document.addEventListener("input", (event) => {
        const element = event.target;
        if (!(element instanceof HTMLInputElement)) return;
        const identity = [
          element.id,
          element.name,
          element.type,
          element.autocomplete,
          element.placeholder
        ].join(" ").toLowerCase();
        if (/account|email|apple.?id|username|phone/.test(identity)) {
          markExplicitAccount();
        }
      }, true);

    })();
    """

    static func script(for credentials: AppleAdsWebLoginCredentials?) -> String? {
        guard let credentials = credentials?.trimmed, credentials.isComplete,
              let data = try? JSONEncoder().encode(credentials),
              let encodedCredentials = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return """
        (() => {
          const host = window.location.hostname.toLowerCase();
          const isAppleOwned = host === "apple.com" || host.endsWith(".apple.com");
          if (!isAppleOwned || host === "app-ads.apple.com" || window.__openasoLoginActive) return;
          window.__openasoLoginActive = true;

          const credentials = \(encodedCredentials);
          const visible = (element) => {
            if (!element || element.disabled) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none"
              && rect.width > 0 && rect.height > 0;
          };
          const firstVisible = (selectors) => {
            for (const selector of selectors) {
              const element = document.querySelector(selector);
              if (visible(element)) return element;
            }
            return null;
          };
          const fill = (element, value) => {
            if (!element) return false;
            const setter = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype,
              "value"
            )?.set;
            if (setter) setter.call(element, value); else element.value = value;
            element.dispatchEvent(new Event("input", { bubbles: true }));
            element.dispatchEvent(new Event("change", { bubbles: true }));
            return true;
          };
          const clickButton = (labels, selectors = []) => {
            const selected = firstVisible(selectors);
            if (selected) { selected.click(); return true; }
            const buttons = Array.from(document.querySelectorAll("button, [role='button']"));
            const button = buttons.find((candidate) =>
              visible(candidate) && labels.includes((candidate.innerText || candidate.textContent || "").trim())
            );
            if (!button) return false;
            button.click();
            return true;
          };

          let usernameSubmitted = false;
          let passwordSubmitted = false;
          const tick = () => {
            if (passwordSubmitted) return;

            const username = firstVisible([
              "input#account_name_text_field",
              "input[name='accountName']",
              "input[type='email']",
              "input[autocomplete*='username']",
              "input[placeholder*='Apple']"
            ]);
            if (!usernameSubmitted && username && fill(username, credentials.username)) {
              window.__openasoMarkExplicitAccount?.();
              usernameSubmitted = clickButton(
                ["Continue", "Next"],
                ["button#sign-in", "button[type='submit']"]
              );
              return;
            }

            const password = firstVisible([
              "input#password_text_field",
              "input[name='password']",
              "input[type='password']",
              "input[autocomplete='current-password']"
            ]);
            if (password && fill(password, credentials.password)) {
              passwordSubmitted = clickButton(
                ["Sign In", "Log In", "Log in", "Login", "Continue"],
                ["button#sign-in", "button[type='submit']"]
              );
            }
          };

          tick();
          const timer = window.setInterval(tick, 250);
          window.setTimeout(() => window.clearInterval(timer), 120000);
        })();
        """
    }
}

extension AppleAdsWebLoginController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        didCloseWindow = true
    }
}

extension AppleAdsWebLoginController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.explicitAccountMessageHandler else { return }
        didUseExplicitAccount = true
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
