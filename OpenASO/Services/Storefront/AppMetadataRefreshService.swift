import Foundation
import SwiftData

protocol AppStoreWebMetadataProviding: Sendable {
    func fetch(appStoreID: Int64, storefrontCode: String) async throws -> AppStoreWebMetadata
}

extension AppStoreWebMetadataProvider: AppStoreWebMetadataProviding {}

protocol AppMetadataRefreshStoring: Sendable {
    func loadScope(appStoreID: Int64) async throws -> AppMetadataRefreshStoredScope

    func persist(
        resolvedApp: ResolvedApp,
        storefront: String,
        canonicalStorefront: String
    ) async throws -> AppMetadataRefreshPersistenceResult

    func persist(
        webMetadata: AppStoreWebMetadata,
        storefront: String,
        canonicalStorefront: String
    ) async throws -> AppMetadataRefreshPersistenceResult
}

protocol AppIconInvalidating: Sendable {
    func invalidate(appStoreID: Int64) async
}

extension AppIconStore: AppIconInvalidating {}

struct AppMetadataRefreshRequest: Sendable, Equatable {
    let appStoreID: Int64
    let requestedStorefronts: [String]
    let includesDefaultStorefront: Bool
    let includesTrackedStorefronts: Bool

    init(
        appStoreID: Int64,
        requestedStorefronts: [String] = [],
        includesDefaultStorefront: Bool = true,
        includesTrackedStorefronts: Bool = true
    ) {
        self.appStoreID = appStoreID
        self.requestedStorefronts = requestedStorefronts
        self.includesDefaultStorefront = includesDefaultStorefront
        self.includesTrackedStorefronts = includesTrackedStorefronts
    }
}

enum AppMetadataRefreshProvider: String, Sendable, Equatable {
    case iTunesLookup
    case appStoreWeb
}

struct AppMetadataRefreshFailure: LocalizedError, Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        case fetch
        case validation
        case persistence
    }

    let provider: AppMetadataRefreshProvider
    let stage: Stage
    let error: OpenASOError

    var errorDescription: String? {
        error.errorDescription
    }
}

enum AppMetadataRefreshProviderOutcome: Sendable, Equatable {
    case succeeded
    case failed(AppMetadataRefreshFailure)

    var didSucceed: Bool {
        if case .succeeded = self {
            return true
        }
        return false
    }
}

enum AppMetadataRefreshStorefrontStatus: String, Sendable, Equatable {
    case succeeded
    case partial
    case failed
}

struct AppMetadataRefreshStorefrontOutcome: Sendable, Equatable {
    let storefront: String
    let iTunesLookup: AppMetadataRefreshProviderOutcome
    let appStoreWeb: AppMetadataRefreshProviderOutcome

    var status: AppMetadataRefreshStorefrontStatus {
        switch (iTunesLookup.didSucceed, appStoreWeb.didSucceed) {
        case (true, true):
            return .succeeded
        case (true, false), (false, true):
            return .partial
        case (false, false):
            return .failed
        }
    }

    var persistedProviderCount: Int {
        [iTunesLookup, appStoreWeb].count(where: \.didSucceed)
    }
}

enum AppMetadataRefreshStatus: String, Sendable, Equatable {
    case succeeded
    case partial
    case failed
}

struct AppMetadataRefreshResult: Sendable, Equatable {
    let appStoreID: Int64
    let defaultStorefront: String
    let storefronts: [AppMetadataRefreshStorefrontOutcome]
    let iconInvalidated: Bool

    var status: AppMetadataRefreshStatus {
        let persistedProviderCount = storefronts.reduce(into: 0) { count, outcome in
            count += outcome.persistedProviderCount
        }
        guard persistedProviderCount > 0 else {
            return .failed
        }
        return storefronts.allSatisfy { $0.status == .succeeded } ? .succeeded : .partial
    }

    var succeededStorefrontCount: Int {
        storefronts.count { $0.status == .succeeded }
    }

    var partialStorefrontCount: Int {
        storefronts.count { $0.status == .partial }
    }

    var failedStorefrontCount: Int {
        storefronts.count { $0.status == .failed }
    }

    var persistedStorefrontCount: Int {
        storefronts.count { $0.persistedProviderCount > 0 }
    }
}

enum AppMetadataRefreshProgress: Sendable, Equatable {
    case batchStarted(appStoreID: Int64, storefronts: [String])
    case storefrontStarted(storefront: String, position: Int, total: Int)
    case storefrontFinished(
        outcome: AppMetadataRefreshStorefrontOutcome,
        completed: Int,
        total: Int
    )
    case batchFinished(AppMetadataRefreshResult)
}

enum AppMetadataRefreshServiceError: LocalizedError, Sendable, Equatable {
    case invalidAppStoreID
    case emptyStorefrontScope

    var errorDescription: String? {
        switch self {
        case .invalidAppStoreID:
            return "The App Store ID is invalid."
        case .emptyStorefrontScope:
            return "Choose at least one storefront to refresh."
        }
    }
}

struct AppMetadataRefreshStoredScope: Sendable, Equatable {
    let defaultStorefront: String?
    let trackedStorefronts: [String]
}

struct AppMetadataRefreshPersistenceResult: Sendable, Equatable {
    let canonicalIconURLBefore: String?
    let canonicalIconURLAfter: String?

    var canonicalIconChanged: Bool {
        canonicalIconURLBefore != canonicalIconURLAfter
    }
}

final class AppMetadataRefreshService: Sendable {
    typealias ProgressHandler = @Sendable (AppMetadataRefreshProgress) async -> Void

    private let appResolver: any AppResolver
    private let webMetadataProvider: any AppStoreWebMetadataProviding
    private let store: any AppMetadataRefreshStoring
    private let iconInvalidator: any AppIconInvalidating

    init(
        appResolver: any AppResolver,
        webMetadataProvider: any AppStoreWebMetadataProviding,
        store: any AppMetadataRefreshStoring,
        iconInvalidator: any AppIconInvalidating
    ) {
        self.appResolver = appResolver
        self.webMetadataProvider = webMetadataProvider
        self.store = store
        self.iconInvalidator = iconInvalidator
    }

    func refresh(
        _ request: AppMetadataRefreshRequest,
        progress: ProgressHandler? = nil
    ) async throws -> AppMetadataRefreshResult {
        guard request.appStoreID > 0 else {
            throw AppMetadataRefreshServiceError.invalidAppStoreID
        }

        let storedScope = try await store.loadScope(appStoreID: request.appStoreID)
        try Task.checkCancellation()
        let scope = try Self.resolveScope(request: request, storedScope: storedScope)
        await progress?(.batchStarted(appStoreID: request.appStoreID, storefronts: scope.storefronts))

        var storefrontOutcomes: [AppMetadataRefreshStorefrontOutcome] = []
        var iconInvalidated = false
        for (offset, storefront) in scope.storefronts.enumerated() {
            try Task.checkCancellation()
            await progress?(.storefrontStarted(
                storefront: storefront,
                position: offset + 1,
                total: scope.storefronts.count
            ))
            try Task.checkCancellation()

            let iTunesAttempt = try await refreshFromITunes(
                appStoreID: request.appStoreID,
                storefront: storefront,
                canonicalStorefront: scope.defaultStorefront
            )
            iconInvalidated = iTunesAttempt.iconInvalidated || iconInvalidated

            try Task.checkCancellation()
            let webAttempt = try await refreshFromWeb(
                appStoreID: request.appStoreID,
                storefront: storefront,
                canonicalStorefront: scope.defaultStorefront
            )
            try Task.checkCancellation()
            let outcome = AppMetadataRefreshStorefrontOutcome(
                storefront: storefront,
                iTunesLookup: iTunesAttempt.outcome,
                appStoreWeb: webAttempt.outcome
            )
            storefrontOutcomes.append(outcome)
            await progress?(.storefrontFinished(
                outcome: outcome,
                completed: offset + 1,
                total: scope.storefronts.count
            ))
            try Task.checkCancellation()
        }

        let result = AppMetadataRefreshResult(
            appStoreID: request.appStoreID,
            defaultStorefront: scope.defaultStorefront,
            storefronts: storefrontOutcomes,
            iconInvalidated: iconInvalidated
        )
        await progress?(.batchFinished(result))
        return result
    }

    private func refreshFromITunes(
        appStoreID: Int64,
        storefront: String,
        canonicalStorefront: String
    ) async throws -> ProviderAttempt {
        let resolvedApp: ResolvedApp
        do {
            resolvedApp = try await appResolver.resolve(
                appStoreID: appStoreID,
                storefrontCode: storefront
            )
        } catch {
            try Self.rethrowCancellationIfNeeded(error)
            return ProviderAttempt(outcome: .failed(Self.failure(
                provider: .iTunesLookup,
                stage: .fetch,
                error: error
            )))
        }

        try Task.checkCancellation()
        guard resolvedApp.appStoreID == appStoreID else {
            return ProviderAttempt(outcome: .failed(AppMetadataRefreshFailure(
                provider: .iTunesLookup,
                stage: .validation,
                error: .unexpectedResponse
            )))
        }

        do {
            let persistenceResult = try await store.persist(
                resolvedApp: resolvedApp,
                storefront: storefront,
                canonicalStorefront: canonicalStorefront
            )
            let shouldInvalidateIcon = persistenceResult.canonicalIconChanged
            if shouldInvalidateIcon {
                // The provider payload is already committed. Finish required cache cleanup even
                // when cancellation arrives immediately after the save.
                await iconInvalidator.invalidate(appStoreID: appStoreID)
            }
            return ProviderAttempt(
                outcome: .succeeded,
                iconInvalidated: shouldInvalidateIcon
            )
        } catch {
            try Self.rethrowCancellationIfNeeded(error)
            return ProviderAttempt(outcome: .failed(Self.failure(
                provider: .iTunesLookup,
                stage: .persistence,
                error: error
            )))
        }
    }

    private func refreshFromWeb(
        appStoreID: Int64,
        storefront: String,
        canonicalStorefront: String
    ) async throws -> ProviderAttempt {
        let webMetadata: AppStoreWebMetadata
        do {
            webMetadata = try await webMetadataProvider.fetch(
                appStoreID: appStoreID,
                storefrontCode: storefront
            )
        } catch {
            try Self.rethrowCancellationIfNeeded(error)
            return ProviderAttempt(outcome: .failed(Self.failure(
                provider: .appStoreWeb,
                stage: .fetch,
                error: error
            )))
        }

        try Task.checkCancellation()
        guard webMetadata.appStoreID == appStoreID,
              Self.normalizeStorefront(webMetadata.storefront) == storefront
        else {
            return ProviderAttempt(outcome: .failed(AppMetadataRefreshFailure(
                provider: .appStoreWeb,
                stage: .validation,
                error: .unexpectedResponse
            )))
        }

        do {
            _ = try await store.persist(
                webMetadata: webMetadata,
                storefront: storefront,
                canonicalStorefront: canonicalStorefront
            )
            return ProviderAttempt(outcome: .succeeded)
        } catch {
            try Self.rethrowCancellationIfNeeded(error)
            return ProviderAttempt(outcome: .failed(Self.failure(
                provider: .appStoreWeb,
                stage: .persistence,
                error: error
            )))
        }
    }

    private static func resolveScope(
        request: AppMetadataRefreshRequest,
        storedScope: AppMetadataRefreshStoredScope
    ) throws -> ResolvedScope {
        let requestedStorefronts = orderedUnique(request.requestedStorefronts)
        let storedDefault = normalizeStorefront(storedScope.defaultStorefront)
        let defaultStorefront = storedDefault
            ?? requestedStorefronts.first
            ?? "us"

        var storefronts: [String] = []
        if request.includesDefaultStorefront {
            storefronts.append(defaultStorefront)
        }
        storefronts.append(contentsOf: requestedStorefronts)
        if request.includesTrackedStorefronts {
            storefronts.append(contentsOf: orderedUnique(storedScope.trackedStorefronts).sorted())
        }
        storefronts = orderedUnique(storefronts)
        guard !storefronts.isEmpty else {
            throw AppMetadataRefreshServiceError.emptyStorefrontScope
        }
        return ResolvedScope(
            defaultStorefront: defaultStorefront,
            storefronts: storefronts
        )
    }

    private static func orderedUnique(_ storefronts: [String]) -> [String] {
        var seen = Set<String>()
        return storefronts.compactMap { storefront in
            guard let normalized = normalizeStorefront(storefront),
                  seen.insert(normalized).inserted
            else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizeStorefront(_ storefront: String?) -> String? {
        let normalized = storefront?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func failure(
        provider: AppMetadataRefreshProvider,
        stage: AppMetadataRefreshFailure.Stage,
        error: Error
    ) -> AppMetadataRefreshFailure {
        AppMetadataRefreshFailure(
            provider: provider,
            stage: stage,
            error: OpenASOError.map(error)
        )
    }

    private static func rethrowCancellationIfNeeded(_ error: Error) throws {
        if error is CancellationError
            || Task.isCancelled {
            throw CancellationError()
        }
    }
}

private extension AppMetadataRefreshService {
    struct ResolvedScope: Sendable {
        let defaultStorefront: String
        let storefronts: [String]
    }

    struct ProviderAttempt: Sendable {
        let outcome: AppMetadataRefreshProviderOutcome
        let iconInvalidated: Bool

        init(
            outcome: AppMetadataRefreshProviderOutcome,
            iconInvalidated: Bool = false
        ) {
            self.outcome = outcome
            self.iconInvalidated = iconInvalidated
        }
    }
}

final class SwiftDataAppMetadataRefreshStore: AppMetadataRefreshStoring, Sendable {
    private let backgroundModelStore: BackgroundModelStore
    private let appCatalogService: AppCatalogService

    init(
        backgroundModelStore: BackgroundModelStore,
        appCatalogService: AppCatalogService
    ) {
        self.backgroundModelStore = backgroundModelStore
        self.appCatalogService = appCatalogService
    }

    func loadScope(appStoreID: Int64) async throws -> AppMetadataRefreshStoredScope {
        try await backgroundModelStore.read { modelContext in
            let targetAppStoreID = appStoreID
            var appDescriptor = FetchDescriptor<StoreApp>(
                predicate: #Predicate { storeApp in
                    storeApp.appStoreID == targetAppStoreID
                }
            )
            appDescriptor.fetchLimit = 1
            let defaultStorefront = try modelContext.fetch(appDescriptor).first?.defaultStorefront

            let trackDescriptor = FetchDescriptor<TrackedAppKeyword>(
                predicate: #Predicate { track in
                    track.appStoreID == targetAppStoreID
                }
            )
            let trackedStorefronts = try modelContext.fetch(trackDescriptor).map(\.storefront)
            return AppMetadataRefreshStoredScope(
                defaultStorefront: defaultStorefront,
                trackedStorefronts: trackedStorefronts
            )
        }
    }

    func persist(
        resolvedApp: ResolvedApp,
        storefront: String,
        canonicalStorefront: String
    ) async throws -> AppMetadataRefreshPersistenceResult {
        try await backgroundModelStore.write { modelContext in
            let iconURLBefore = try Self.iconURL(
                appStoreID: resolvedApp.appStoreID,
                in: modelContext
            )
            let storeApp = try appCatalogService.upsertStoreApp(
                from: resolvedApp,
                storefrontCode: storefront,
                canonicalStorefrontCode: canonicalStorefront,
                in: modelContext
            )
            return AppMetadataRefreshPersistenceResult(
                canonicalIconURLBefore: iconURLBefore,
                canonicalIconURLAfter: storeApp.iconURLString
            )
        }
    }

    func persist(
        webMetadata: AppStoreWebMetadata,
        storefront: String,
        canonicalStorefront: String
    ) async throws -> AppMetadataRefreshPersistenceResult {
        try await backgroundModelStore.write { modelContext in
            let iconURLBefore = try Self.iconURL(
                appStoreID: webMetadata.appStoreID,
                in: modelContext
            )
            let storeApp = try appCatalogService.upsertStoreApp(
                from: webMetadata,
                storefrontCode: storefront,
                canonicalStorefrontCode: canonicalStorefront,
                in: modelContext
            )
            return AppMetadataRefreshPersistenceResult(
                canonicalIconURLBefore: iconURLBefore,
                canonicalIconURLAfter: storeApp.iconURLString
            )
        }
    }

    private static func iconURL(
        appStoreID: Int64,
        in modelContext: ModelContext
    ) throws -> String? {
        let targetAppStoreID = appStoreID
        var descriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { storeApp in
                storeApp.appStoreID == targetAppStoreID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.iconURLString
    }
}
