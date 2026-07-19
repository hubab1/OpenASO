import Foundation

struct KeywordResearchProjectPresentationPage: Equatable, Sendable {
    let projects: [KeywordResearchProjectSnapshot]
    let nextOffset: Int?
}

struct KeywordResearchKeywordPresentationPage: Equatable, Sendable {
    let keywords: [KeywordResearchKeywordSnapshot]
    let nextOffset: Int?
}

enum KeywordResearchPageLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case loadingNextPage
    case failed(KeywordResearchErrorPresentation)

    var isLoading: Bool {
        switch self {
        case .loading, .loadingNextPage:
            return true
        case .idle, .loaded, .failed:
            return false
        }
    }
}

enum KeywordResearchMutationAction: Equatable, Hashable, Sendable {
    case createProject(UUID)
    case updateProject(UUID)
    case deleteProject(UUID)
    case addKeyword(UUID)
    case removeKeyword(UUID)

    var isDestructive: Bool {
        switch self {
        case .deleteProject, .removeKeyword:
            return true
        case .createProject, .updateProject, .addKeyword:
            return false
        }
    }
}

enum KeywordResearchMutationState: Equatable, Sendable {
    case idle
    case running(KeywordResearchMutationAction)
    case succeeded(KeywordResearchMutationAction)
    case failed(KeywordResearchMutationAction, KeywordResearchErrorPresentation)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum KeywordResearchRefreshState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case refreshing(previous: Value?)
    case current(Value)
    case failed(previous: Value?, KeywordResearchErrorPresentation)

    var value: Value? {
        switch self {
        case .idle:
            return nil
        case .refreshing(let previous), .failed(let previous, _):
            return previous
        case .current(let value):
            return value
        }
    }

    var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }
}

struct KeywordResearchProjectDraft: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var bundleID: String
    var defaultStorefront: String
    var defaultPlatform: AppPlatform
    var notes: String

    init(
        id: UUID = UUID(),
        name: String = "",
        bundleID: String = "",
        defaultStorefront: String = "us",
        defaultPlatform: AppPlatform = .iphone,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.defaultStorefront = defaultStorefront
        self.defaultPlatform = defaultPlatform
        self.notes = notes
    }

    init(project: KeywordResearchProjectSnapshot) {
        self.init(
            id: project.id,
            name: project.name,
            bundleID: project.bundleID ?? "",
            defaultStorefront: project.defaultStorefront,
            defaultPlatform: project.defaultPlatform,
            notes: project.notes
        )
    }
}

struct KeywordResearchKeywordDraft: Equatable, Identifiable, Sendable {
    let id: UUID
    var term: String
    var storefront: String
    var platform: AppPlatform
    var notes: String

    init(
        id: UUID = UUID(),
        term: String = "",
        storefront: String = "us",
        platform: AppPlatform = .iphone,
        notes: String = ""
    ) {
        self.id = id
        self.term = term
        self.storefront = storefront
        self.platform = platform
        self.notes = notes
    }
}

enum KeywordResearchErrorKind: String, Equatable, Hashable, Sendable {
    case validation
    case limitReached
    case notFound
    case conflict
    case networkUnavailable
    case rateLimited
    case authenticationRequired
    case configurationChanged
    case providerUnavailable
    case unexpected
}

/// A fixed, user-facing error that deliberately omits provider payloads,
/// identifiers, credentials, and arbitrary `localizedDescription` strings.
struct KeywordResearchErrorPresentation: Equatable, Identifiable, Sendable {
    let kind: KeywordResearchErrorKind
    let title: String
    let message: String
    let recoverySuggestion: String?

    var id: String { kind.rawValue }

    var accessibilityLabel: String {
        [title, message, recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    static func presenting(_ error: Error) -> Self {
        if let error = error as? KeywordResearchProjectStoreError {
            return presenting(error)
        }
        if let error = error as? KeywordResearchMetricsWorkflowError {
            switch error {
            case .tooManyKeywords:
                return limit(
                    message: "Too many keywords were selected for one popularity refresh."
                )
            }
        }
        if let error = error as? OpenASOError {
            return presenting(error)
        }
        return unexpected
    }

    static func presenting(_ issue: KeywordResearchMetricsIssue) -> Self {
        switch issue.code {
        case .missingContextApp:
            return authentication(
                message: "Choose an Apple Ads context app before refreshing popularity."
            )
        case .missingSession:
            return authentication(
                message: "Connect an Apple Ads web session before refreshing popularity."
            )
        case .reconnectRequired, .sessionExpired:
            return authentication(
                message: "Reconnect the Apple Ads web session before refreshing popularity."
            )
        case .configurationChanged:
            return Self(
                kind: .configurationChanged,
                title: "Settings changed",
                message: "The popularity refresh was not applied because its settings changed.",
                recoverySuggestion: "Start the refresh again with the current settings."
            )
        case .unsupportedStorefront:
            return validation(
                message: "Apple Ads does not support popularity for this storefront."
            )
        case .rateLimited:
            return rateLimited
        case .providerFailure:
            return providerUnavailable
        }
    }
}

extension KeywordResearchProjectSnapshot {
    var keywordResearchAccessibilityLabel: String {
        var parts = [
            "Research project \(name)",
            "default storefront \(defaultStorefront.uppercased())",
            defaultPlatform.displayName,
        ]
        if let bundleID {
            parts.append("bundle identifier \(bundleID)")
        }
        return parts.joined(separator: ", ")
    }
}

extension KeywordResearchKeywordSnapshot {
    var keywordResearchAccessibilityLabel: String {
        "Keyword \(term), storefront \(storefront.uppercased()), \(platform.displayName)"
    }
}

extension KeywordResearchRankingObservationSnapshot {
    /// This describes app-independent result evidence and intentionally makes
    /// no claim that the research project itself has an App Store rank.
    var keywordResearchAccessibilityLabel: String {
        "Shared search evidence for \(term), storefront \(storefront.uppercased()), "
            + "\(platform.displayName), \(resultCount) results observed"
    }
}

extension KeywordResearchMetricsOutcome {
    var keywordResearchAccessibilityLabel: String {
        let value = popularityScore.map(String.init) ?? "unavailable"
        return "Shared popularity for \(term), score \(value), storefront "
            + "\(storefront.uppercased()), \(platform.displayName)"
    }
}

private extension KeywordResearchErrorPresentation {
    static func presenting(_ error: KeywordResearchProjectStoreError) -> Self {
        switch error {
        case .invalidName:
            return validation(message: "Enter a valid project name.")
        case .invalidBundleID:
            return validation(message: "Enter a valid bundle identifier or leave it blank.")
        case .invalidStorefront:
            return validation(message: "Choose a valid two-letter storefront.")
        case .invalidTerm:
            return validation(message: "Enter a valid keyword.")
        case .invalidNotes:
            return validation(message: "The notes are too long.")
        case .invalidOffset, .invalidLimit:
            return Self(
                kind: .unexpected,
                title: "Page unavailable",
                message: "This page of research data could not be loaded.",
                recoverySuggestion: "Reload the research workspace."
            )
        case .projectLimitReached:
            return limit(message: "The research project limit has been reached.")
        case .keywordLimitReached:
            return limit(message: "The keyword limit for this project has been reached.")
        case .projectNotFound:
            return notFound(message: "This research project no longer exists.")
        case .keywordNotFound:
            return notFound(message: "This research keyword no longer exists.")
        case .keywordIdentifierConflict:
            return conflict(
                message: "This keyword draft identifier is already used by different research data."
            )
        case .staleProjectRevision:
            return conflict(
                message: "This project changed after it was opened. Your change was not applied."
            )
        case .staleKeywordRevision:
            return conflict(
                message: "This keyword changed after it was opened. Your change was not applied."
            )
        }
    }

    static func presenting(_ error: OpenASOError) -> Self {
        switch error {
        case .emptyQuery:
            return validation(message: "Enter a keyword before refreshing.")
        case .invalidAppStoreID:
            return validation(message: "The selected App Store context is invalid.")
        case .appNotFound:
            return notFound(message: "The selected App Store app could not be found.")
        case .networkUnavailable:
            return Self(
                kind: .networkUnavailable,
                title: "You’re offline",
                message: "Research data could not be refreshed because the network is unavailable.",
                recoverySuggestion: "Check the connection and try again."
            )
        case .rateLimited:
            return rateLimited
        case .decodingFailed, .unexpectedResponse, .primaryProviderUnavailable,
             .providerUnavailable:
            return providerUnavailable
        }
    }

    static func validation(message: String) -> Self {
        Self(
            kind: .validation,
            title: "Check the details",
            message: message,
            recoverySuggestion: nil
        )
    }

    static func limit(message: String) -> Self {
        Self(
            kind: .limitReached,
            title: "Limit reached",
            message: message,
            recoverySuggestion: "Remove an existing item before trying again."
        )
    }

    static func notFound(message: String) -> Self {
        Self(
            kind: .notFound,
            title: "No longer available",
            message: message,
            recoverySuggestion: "Reload the research workspace."
        )
    }

    static func conflict(message: String) -> Self {
        Self(
            kind: .conflict,
            title: "Review the latest changes",
            message: message,
            recoverySuggestion: "Reload before making another change."
        )
    }

    static func authentication(message: String) -> Self {
        Self(
            kind: .authenticationRequired,
            title: "Apple Ads connection required",
            message: message,
            recoverySuggestion: "Open Settings to update the connection."
        )
    }

    static let rateLimited = Self(
        kind: .rateLimited,
        title: "Try again shortly",
        message: "The provider is temporarily rate-limiting research requests.",
        recoverySuggestion: "Wait a moment before refreshing again."
    )

    static let providerUnavailable = Self(
        kind: .providerUnavailable,
        title: "Research data unavailable",
        message: "The provider did not return usable research data.",
        recoverySuggestion: "Try again later."
    )

    static let unexpected = Self(
        kind: .unexpected,
        title: "Research data unavailable",
        message: "The research operation could not be completed.",
        recoverySuggestion: "Try again."
    )
}
