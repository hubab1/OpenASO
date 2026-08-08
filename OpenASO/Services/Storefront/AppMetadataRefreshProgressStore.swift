import Foundation
import Observation

@MainActor
@Observable
final class AppMetadataRefreshProgressStore {
    typealias RefreshOperation = @Sendable (
        AppMetadataRefreshRequest,
        AppMetadataRefreshService.ProgressHandler?
    ) async throws -> AppMetadataRefreshResult

    typealias RevisionHandler = @MainActor @Sendable (_ appStoreID: Int64, _ revision: UInt64) -> Void

    enum Status: Sendable, Equatable {
        case idle
        case preparing
        case refreshing
        case cancelling
        case succeeded
        case partial
        case failed
        case cancelled

        var isRunning: Bool {
            switch self {
            case .preparing, .refreshing, .cancelling:
                true
            case .idle, .succeeded, .partial, .failed, .cancelled:
                false
            }
        }

        var isTerminal: Bool {
            switch self {
            case .succeeded, .partial, .failed, .cancelled:
                true
            case .idle, .preparing, .refreshing, .cancelling:
                false
            }
        }
    }

    enum PresentationScope: Sendable, Equatable {
        case trackedApp
        case competitors(ownerAppStoreID: Int64)
    }

    struct ProviderRow: Sendable, Equatable, Identifiable {
        enum State: Sendable, Equatable {
            case queued
            case succeeded
            case failed(AppMetadataRefreshFailure)
            case notStarted
            case outcomeUnknownMayHaveCommitted
        }

        let provider: AppMetadataRefreshProvider
        var state: State

        var id: AppMetadataRefreshProvider { provider }
    }

    struct StorefrontRow: Sendable, Equatable, Identifiable {
        enum State: Sendable, Equatable {
            case queued
            case refreshing
            case completed(AppMetadataRefreshStorefrontStatus)
            case notStarted
            case interruptedOutcomeUnknown
        }

        let storefront: String
        var state: State
        var providers: [ProviderRow]

        var id: String { storefront }

        static func queued(storefront: String) -> StorefrontRow {
            StorefrontRow(
                storefront: storefront,
                state: .queued,
                providers: AppMetadataRefreshProvider.allProgressProviders.map {
                    ProviderRow(provider: $0, state: .queued)
                }
            )
        }

        static func completed(_ outcome: AppMetadataRefreshStorefrontOutcome) -> StorefrontRow {
            StorefrontRow(
                storefront: outcome.storefront,
                state: .completed(outcome.status),
                providers: [
                    ProviderRow(
                        provider: .iTunesLookup,
                        state: ProviderRow.State(outcome: outcome.iTunesLookup)
                    ),
                    ProviderRow(
                        provider: .appStoreWeb,
                        state: ProviderRow.State(outcome: outcome.appStoreWeb)
                    ),
                ]
            )
        }

        mutating func markNotStarted() {
            state = .notStarted
            providers = providers.map { ProviderRow(provider: $0.provider, state: .notStarted) }
        }

        mutating func markInterrupted() {
            state = .interruptedOutcomeUnknown
            providers = providers.map {
                ProviderRow(provider: $0.provider, state: .outcomeUnknownMayHaveCommitted)
            }
        }
    }

    struct Batch: Sendable, Equatable, Identifiable {
        let id: UUID
        let request: AppMetadataRefreshRequest
        let presentationScope: PresentationScope
        var storefronts: [StorefrontRow]
        var result: AppMetadataRefreshResult?
        var message: String?

        var completedStorefrontCount: Int {
            storefronts.count {
                if case .completed = $0.state { return true }
                return false
            }
        }
    }

    static let cancellationMessage = "Stopped; changes already completed may have been kept."
    static let interruptedStorefrontMessage =
        "Stopped while this storefront was refreshing. Some changes may already have been kept."

    private(set) var status: Status = .idle
    private(set) var batch: Batch?
    private(set) var revisionsByAppStoreID: [Int64: UInt64] = [:]

    @ObservationIgnored
    private let refreshOperation: RefreshOperation

    @ObservationIgnored
    private var revisionHandler: RevisionHandler

    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var activeGeneration: UUID?

    @ObservationIgnored
    private var revisionedStorefronts: Set<String> = []

    init(
        refreshOperation: @escaping RefreshOperation,
        revisionHandler: @escaping RevisionHandler = { _, _ in }
    ) {
        self.refreshOperation = refreshOperation
        self.revisionHandler = revisionHandler
    }

    convenience init(
        service: AppMetadataRefreshService,
        revisionHandler: @escaping RevisionHandler = { _, _ in }
    ) {
        self.init(
            refreshOperation: { request, progress in
                try await service.refresh(request, progress: progress)
            },
            revisionHandler: revisionHandler
        )
    }

    deinit {
        refreshTask?.cancel()
    }

    var isRunning: Bool { status.isRunning }

    func revision(for appStoreID: Int64) -> UInt64 {
        revisionsByAppStoreID[appStoreID, default: 0]
    }

    func revisionSignature(for appStoreIDs: [Int64]) -> String {
        Set(appStoreIDs)
            .sorted()
            .compactMap { appStoreID in
                let revision = revision(for: appStoreID)
                // Discovering a row at its initial revision must not restart its loader task.
                guard revision > 0 else { return nil }
                return "\(appStoreID):\(revision)"
            }
            .joined(separator: "|")
    }

    func setRevisionHandler(_ revisionHandler: @escaping RevisionHandler) {
        self.revisionHandler = revisionHandler
    }

    @discardableResult
    func start(
        _ request: AppMetadataRefreshRequest,
        presentationScope: PresentationScope = .trackedApp
    ) -> Bool {
        guard !status.isRunning else { return false }
        if status.isTerminal {
            clearTerminalBatch()
        }
        guard status == .idle, batch == nil else { return false }

        let generation = UUID()
        activeGeneration = generation
        revisionedStorefronts = []
        status = .preparing
        batch = Batch(
            id: generation,
            request: request,
            presentationScope: presentationScope,
            storefronts: [],
            result: nil,
            message: nil
        )

        let operation = refreshOperation
        refreshTask = Task { [weak self, operation] in
            let progress: AppMetadataRefreshService.ProgressHandler = { [weak self] event in
                await self?.receive(event, generation: generation)
            }

            do {
                let result = try await operation(request, progress)
                guard let self else { return }
                if Task.isCancelled {
                    self.finishCancellation(generation: generation)
                } else {
                    self.finish(result, generation: generation)
                }
            } catch {
                guard let self else { return }
                if error is CancellationError || Task.isCancelled {
                    self.finishCancellation(generation: generation)
                } else {
                    self.finishFailure(error, generation: generation)
                }
            }
        }
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        guard status == .preparing || status == .refreshing,
              let batch
        else {
            return false
        }

        status = .cancelling
        markUnfinishedRowsForCancellation()
        bumpRevision(for: batch.request.appStoreID)
        refreshTask?.cancel()
        return true
    }

    @discardableResult
    func retry() -> Bool {
        guard status.isTerminal, let batch else { return false }
        clearTerminalBatch()
        return start(
            batch.request,
            presentationScope: batch.presentationScope
        )
    }

    @discardableResult
    func dismiss() -> Bool {
        guard status.isTerminal else { return false }
        clearTerminalBatch()
        return true
    }

    func waitForCurrentBatch() async {
        let task = refreshTask
        await task?.value
    }

    private func receive(_ progress: AppMetadataRefreshProgress, generation: UUID) {
        guard activeGeneration == generation,
              status != .cancelling,
              var batch
        else {
            return
        }

        switch progress {
        case .batchStarted(let appStoreID, let storefronts):
            guard appStoreID == batch.request.appStoreID else { return }
            batch.storefronts = storefronts.map(StorefrontRow.queued(storefront:))
            self.batch = batch
            status = .refreshing

        case .storefrontStarted(let storefront, _, _):
            guard let index = batch.storefronts.firstIndex(where: { $0.storefront == storefront }) else {
                return
            }
            batch.storefronts[index].state = .refreshing
            self.batch = batch
            status = .refreshing

        case .storefrontFinished(let outcome, _, _):
            guard let index = batch.storefronts.firstIndex(where: {
                $0.storefront == outcome.storefront
            }) else {
                return
            }
            batch.storefronts[index] = .completed(outcome)
            self.batch = batch
            recordPersistenceIfNeeded(outcome, appStoreID: batch.request.appStoreID)

        case .batchFinished(let result):
            finish(result, generation: generation)
        }
    }

    private func finish(_ result: AppMetadataRefreshResult, generation: UUID) {
        guard activeGeneration == generation,
              status != .cancelling,
              var batch,
              result.appStoreID == batch.request.appStoreID
        else {
            return
        }

        for outcome in result.storefronts {
            recordPersistenceIfNeeded(outcome, appStoreID: result.appStoreID)
        }
        batch.storefronts = result.storefronts.map(StorefrontRow.completed)
        batch.result = result
        batch.message = nil
        self.batch = batch

        status = switch result.status {
        case .succeeded: .succeeded
        case .partial: .partial
        case .failed: .failed
        }
        endGeneration(generation)
    }

    private func finishFailure(_ error: Error, generation: UUID) {
        guard activeGeneration == generation, var batch else { return }

        let hadActiveStorefront = batch.storefronts.contains(where: {
            $0.state == .refreshing
        })
        let hadUnfinishedStorefront = batch.storefronts.contains(where: {
            $0.state == .refreshing || $0.state == .queued
        })
        if hadUnfinishedStorefront {
            markUnfinishedRowsForCancellation()
            batch = self.batch ?? batch
        }
        if hadActiveStorefront {
            bumpRevision(for: batch.request.appStoreID)
        }
        batch.message = Self.failureMessage(for: error)
        self.batch = batch
        status = .failed
        endGeneration(generation)
    }

    private func finishCancellation(generation: UUID) {
        guard activeGeneration == generation, var batch else { return }
        markUnfinishedRowsForCancellation()
        batch = self.batch ?? batch
        batch.message = Self.cancellationMessage
        self.batch = batch
        status = .cancelled
        endGeneration(generation)
    }

    private func markUnfinishedRowsForCancellation() {
        guard var batch else { return }
        for index in batch.storefronts.indices {
            switch batch.storefronts[index].state {
            case .refreshing:
                batch.storefronts[index].markInterrupted()
            case .queued:
                batch.storefronts[index].markNotStarted()
            case .completed, .notStarted, .interruptedOutcomeUnknown:
                break
            }
        }
        self.batch = batch
    }

    private func recordPersistenceIfNeeded(
        _ outcome: AppMetadataRefreshStorefrontOutcome,
        appStoreID: Int64
    ) {
        guard outcome.persistedProviderCount > 0,
              revisionedStorefronts.insert(outcome.storefront).inserted
        else {
            return
        }
        bumpRevision(for: appStoreID)
    }

    private func bumpRevision(for appStoreID: Int64) {
        let current = revisionsByAppStoreID[appStoreID, default: 0]
        let next = current == .max ? current : current + 1
        revisionsByAppStoreID[appStoreID] = next
        revisionHandler(appStoreID, next)
    }

    private func endGeneration(_ generation: UUID) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        refreshTask = nil
    }

    private func clearTerminalBatch() {
        activeGeneration = nil
        refreshTask = nil
        revisionedStorefronts = []
        batch = nil
        status = .idle
    }

    private static func failureMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}

private extension AppMetadataRefreshProvider {
    static let allProgressProviders: [AppMetadataRefreshProvider] = [
        .iTunesLookup,
        .appStoreWeb,
    ]
}

private extension AppMetadataRefreshProgressStore.ProviderRow.State {
    init(outcome: AppMetadataRefreshProviderOutcome) {
        switch outcome {
        case .succeeded:
            self = .succeeded
        case .failed(let failure):
            self = .failed(failure)
        }
    }
}
