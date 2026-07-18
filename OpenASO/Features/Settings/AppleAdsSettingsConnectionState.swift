import SwiftUI

enum AppleAdsSettingsFocusSection {
    case dailyRefresh
    case webSession
    case appStoreConnect
    case analytics

    var analyticsValue: String {
        switch self {
        case .dailyRefresh:
            return "daily_refresh"
        case .webSession:
            return "apple_ads"
        case .appStoreConnect:
            return "app_store_connect"
        case .analytics:
            return "analytics"
        }
    }
}

enum AppleAdsConnectionState: Equatable {
    case notConnected
    case installingHelper
    case openingBrowser
    case detectingLinkedApp
    case validatingSession
    case connected(updatedAt: Date?)
    case expiredSession(String)
    case noLinkedApps
    case apiIssue(String)
    case dependencyIssue(String)

    static let noLinkedAppsMessage = "No linked Apple Ads apps were found for this account. Add a campaign-linked app in Apple Ads, then refresh."

    var title: String {
        switch self {
        case .notConnected:
            return "Not connected"
        case .installingHelper:
            return "Installing browser helper"
        case .openingBrowser:
            return "Connecting"
        case .detectingLinkedApp:
            return "Detecting linked app"
        case .validatingSession:
            return "Validating session"
        case .connected:
            return "Connected"
        case .expiredSession:
            return "Session expired"
        case .noLinkedApps:
            return "No linked apps"
        case .apiIssue:
            return "Apple Ads API issue"
        case .dependencyIssue:
            return "Setup required"
        }
    }

    var message: String {
        switch self {
        case .notConnected:
            return "Connect Apple Ads to fetch keyword popularity."
        case .installingHelper:
            return "Preparing the browser helper."
        case .openingBrowser:
            return "Opening Apple Ads. Complete sign-in or 2FA if Apple asks."
        case .detectingLinkedApp:
            return "Finding an app linked to this Apple Ads account."
        case .validatingSession:
            return "Checking that keyword popularity can be fetched."
        case .connected(let updatedAt):
            if let updatedAt {
                return "Last connected \(updatedAt.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Apple Ads is ready for keyword popularity."
        case .expiredSession(let message):
            return message
        case .noLinkedApps:
            return Self.noLinkedAppsMessage
        case .apiIssue(let message), .dependencyIssue(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .connected:
            return "checkmark.circle.fill"
        case .expiredSession, .apiIssue:
            return "xmark.circle.fill"
        case .noLinkedApps, .dependencyIssue:
            return "exclamationmark.triangle.fill"
        case .installingHelper, .openingBrowser, .detectingLinkedApp, .validatingSession:
            return "arrow.triangle.2.circlepath"
        case .notConnected:
            return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            return .green
        case .expiredSession, .apiIssue:
            return .red
        case .noLinkedApps, .dependencyIssue:
            return .orange
        case .installingHelper, .openingBrowser, .detectingLinkedApp, .validatingSession:
            return .accentColor
        case .notConnected:
            return .secondary
        }
    }

    var isBusy: Bool {
        switch self {
        case .installingHelper, .openingBrowser, .detectingLinkedApp, .validatingSession:
            return true
        case .notConnected, .connected, .expiredSession, .noLinkedApps, .apiIssue, .dependencyIssue:
            return false
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .connected, .expiredSession, .noLinkedApps, .apiIssue:
            return "Refresh Session"
        case .installingHelper:
            return "Installing..."
        case .openingBrowser:
            return "Opening Browser..."
        case .detectingLinkedApp:
            return "Detecting App..."
        case .validatingSession:
            return "Validating..."
        case .notConnected, .dependencyIssue:
            return "Connect Apple Ads"
        }
    }

    var isPrimaryActionDisabled: Bool {
        isBusy
    }

    static func classified(error: Error, hasSession: Bool) -> AppleAdsConnectionState {
        if error is AppleAdsWebSessionExpiredError {
            return .expiredSession("Apple Ads asked for sign-in again. Refresh the session to continue.")
        }

        let message = OpenASOError.map(error).localizedDescription
        let lowercasedMessage = message.lowercased()

        if lowercasedMessage.contains("web session expired")
            || lowercasedMessage.contains("sign in")
            || lowercasedMessage.contains("<html") {
            return .expiredSession("Apple Ads asked for sign-in again. Refresh the session to continue.")
        }

        if lowercasedMessage.contains("at least one app")
            || lowercasedMessage.contains("campaign linked")
            || lowercasedMessage.contains("campaign-linked") {
            return .noLinkedApps
        }

        if lowercasedMessage.contains("node.js is required")
            || lowercasedMessage.contains("npm is required")
            || lowercasedMessage.contains("browser helper")
            || lowercasedMessage.contains("playwright")
            || lowercasedMessage.contains("env: npm")
            || lowercasedMessage.contains("npm: no such file") {
            return .dependencyIssue(message)
        }

        if hasSession {
            return .apiIssue(message)
        }

        return .expiredSession(message)
    }
}

enum AppStoreConnectConnectionState: Equatable {
    case notConnected
    case validating
    case connected(updatedAt: Date?)
    case apiIssue(String)

    var title: String {
        switch self {
        case .notConnected:
            return "Not connected"
        case .validating:
            return "Validating"
        case .connected:
            return "Connected"
        case .apiIssue:
            return "Connection issue"
        }
    }

    var message: String {
        switch self {
        case .notConnected:
            return "Connect App Store Connect to view developer responses and reply to reviews for apps you own."
        case .validating:
            return "Checking App Store Connect API access."
        case .connected(let updatedAt):
            if let updatedAt {
                return "Last validated \(updatedAt.formatted(date: .abbreviated, time: .shortened))."
            }
            return "App Store Connect is ready for review replies."
        case .apiIssue(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .connected:
            return "checkmark.circle.fill"
        case .validating:
            return "arrow.triangle.2.circlepath"
        case .apiIssue:
            return "xmark.circle.fill"
        case .notConnected:
            return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            return .green
        case .validating:
            return .accentColor
        case .apiIssue:
            return .red
        case .notConnected:
            return .secondary
        }
    }

    var isBusy: Bool {
        if case .validating = self {
            return true
        }
        return false
    }
}
