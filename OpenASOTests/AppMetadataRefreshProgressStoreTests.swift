import Foundation
import Testing
@testable import OpenASO

@MainActor
struct AppMetadataRefreshProgressStoreTests {
    private let appStoreID: Int64 = 91_014

    @Test
    func successKeepsStorefrontAndProviderOrderAndAdvancesRevision() async throws {
        let controller = ControlledMetadataRefreshOperation()
        let revisions = MetadataRevisionRecorder()
        let store = makeStore(controller: controller, revisions: revisions)
        let request = AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: ["jp"]
        )

        #expect(store.start(request))
        await controller.waitForInvocation(at: 0)
        await controller.send(.batchStarted(
            appStoreID: appStoreID,
            storefronts: ["us", "jp"]
        ), to: 0)
        await controller.send(.storefrontStarted(
            storefront: "us",
            position: 1,
            total: 2
        ), to: 0)

        let us = makeOutcome(storefront: "us")
        await controller.send(.storefrontFinished(
            outcome: us,
            completed: 1,
            total: 2
        ), to: 0)
        await controller.send(.storefrontStarted(
            storefront: "jp",
            position: 2,
            total: 2
        ), to: 0)

        let jp = makeOutcome(storefront: "jp")
        await controller.send(.storefrontFinished(
            outcome: jp,
            completed: 2,
            total: 2
        ), to: 0)
        let result = makeResult(appStoreID: appStoreID, storefronts: [us, jp])
        await controller.succeed(result, invocation: 0)
        await store.waitForCurrentBatch()

        #expect(store.status == .succeeded)
        #expect(store.batch?.storefronts.map(\.storefront) == ["us", "jp"])
        #expect(store.batch?.storefronts.map(\.providers).map { rows in
            rows.map(\.provider)
        } == [
            [.iTunesLookup, .appStoreWeb],
            [.iTunesLookup, .appStoreWeb],
        ])
        #expect(store.batch?.storefronts.allSatisfy {
            $0.state == .completed(.succeeded)
        } == true)
        #expect(store.revision(for: appStoreID) == 2)
        #expect(revisions.events == [
            MetadataRevisionEvent(appStoreID: appStoreID, revision: 1),
            MetadataRevisionEvent(appStoreID: appStoreID, revision: 2),
        ])
        #expect(store.batch?.result == result)
    }

    @Test
    func partialResultKeepsProviderFailureAndAdvancesRevisionOnce() async {
        let controller = ControlledMetadataRefreshOperation()
        let revisions = MetadataRevisionRecorder()
        let store = makeStore(controller: controller, revisions: revisions)
        let request = AppMetadataRefreshRequest(appStoreID: appStoreID)
        let failure = makeFailure(provider: .appStoreWeb)
        let outcome = makeOutcome(
            storefront: "us",
            iTunesLookup: .succeeded,
            appStoreWeb: .failed(failure)
        )

        #expect(store.start(request))
        await controller.waitForInvocation(at: 0)
        await controller.send(.batchStarted(
            appStoreID: appStoreID,
            storefronts: ["us"]
        ), to: 0)
        await controller.send(.storefrontFinished(
            outcome: outcome,
            completed: 1,
            total: 1
        ), to: 0)
        await controller.succeed(
            makeResult(appStoreID: appStoreID, storefronts: [outcome]),
            invocation: 0
        )
        await store.waitForCurrentBatch()

        #expect(store.status == .partial)
        #expect(store.batch?.storefronts.first?.state == .completed(.partial))
        #expect(store.batch?.storefronts.first?.providers == [
            .init(provider: .iTunesLookup, state: .succeeded),
            .init(provider: .appStoreWeb, state: .failed(failure)),
        ])
        #expect(store.revision(for: appStoreID) == 1)
        #expect(revisions.events.count == 1)
    }

    @Test
    func totalProviderFailureDoesNotAdvanceRevision() async {
        let controller = ControlledMetadataRefreshOperation()
        let revisions = MetadataRevisionRecorder()
        let store = makeStore(controller: controller, revisions: revisions)
        let iTunesFailure = makeFailure(provider: .iTunesLookup)
        let webFailure = makeFailure(provider: .appStoreWeb)
        let outcome = makeOutcome(
            storefront: "us",
            iTunesLookup: .failed(iTunesFailure),
            appStoreWeb: .failed(webFailure)
        )

        #expect(store.start(AppMetadataRefreshRequest(appStoreID: appStoreID)))
        await controller.waitForInvocation(at: 0)
        await controller.send(.batchStarted(
            appStoreID: appStoreID,
            storefronts: ["us"]
        ), to: 0)
        await controller.send(.storefrontFinished(
            outcome: outcome,
            completed: 1,
            total: 1
        ), to: 0)
        await controller.succeed(
            makeResult(appStoreID: appStoreID, storefronts: [outcome]),
            invocation: 0
        )
        await store.waitForCurrentBatch()

        #expect(store.status == .failed)
        #expect(store.batch?.storefronts.first?.state == .completed(.failed))
        #expect(store.revision(for: appStoreID) == 0)
        #expect(revisions.events.isEmpty)
    }

    @Test
    func setupFailurePersistsUntilDismissedOrReplaced() async {
        let controller = ControlledMetadataRefreshOperation()
        let store = makeStore(controller: controller)
        let request = AppMetadataRefreshRequest(appStoreID: appStoreID)

        #expect(store.start(request))
        await controller.waitForInvocation(at: 0)
        await controller.fail(MetadataProgressStoreTestError.setup, invocation: 0)
        await store.waitForCurrentBatch()

        #expect(store.status == .failed)
        #expect(store.batch?.message == "The refresh could not be prepared.")
        #expect(store.batch?.storefronts.isEmpty == true)
        #expect(store.batch?.request == request)

        let replacement = AppMetadataRefreshRequest(appStoreID: appStoreID + 1)
        #expect(store.start(replacement))
        await controller.waitForInvocation(at: 1)
        #expect(store.status == .preparing)
        #expect(store.batch?.request == replacement)
        await controller.fail(MetadataProgressStoreTestError.setup, invocation: 1)
        await store.waitForCurrentBatch()

        #expect(store.dismiss())
        #expect(store.status == .idle)
        #expect(store.batch == nil)
    }

    @Test
    func failureAfterPartialProgressMarksQueuedStorefrontsNotStarted() async {
        let controller = ControlledMetadataRefreshOperation()
        let revisions = MetadataRevisionRecorder()
        let store = makeStore(controller: controller, revisions: revisions)
        let completedOutcome = makeOutcome(storefront: "us")

        #expect(store.start(AppMetadataRefreshRequest(appStoreID: appStoreID)))
        await controller.waitForInvocation(at: 0)
        await controller.send(.batchStarted(
            appStoreID: appStoreID,
            storefronts: ["us", "jp"]
        ), to: 0)
        await controller.send(.storefrontFinished(
            outcome: completedOutcome,
            completed: 1,
            total: 2
        ), to: 0)
        await controller.fail(MetadataProgressStoreTestError.setup, invocation: 0)
        await store.waitForCurrentBatch()

        #expect(store.status == .failed)
        #expect(store.batch?.storefronts[0].state == .completed(.succeeded))
        #expect(store.batch?.storefronts[1].state == .notStarted)
        #expect(store.batch?.storefronts[1].providers.allSatisfy {
            $0.state == .notStarted
        } == true)
        #expect(store.revision(for: appStoreID) == 1)
        #expect(revisions.events.map(\.revision) == [1])
    }

    @Test
    func duplicateStartIsRejectedWhileOneGlobalBatchRuns() async {
        let controller = ControlledMetadataRefreshOperation()
        let store = makeStore(controller: controller)
        let firstRequest = AppMetadataRefreshRequest(appStoreID: appStoreID)
        let secondRequest = AppMetadataRefreshRequest(appStoreID: appStoreID + 1)

        #expect(store.start(firstRequest))
        await controller.waitForInvocation(at: 0)
        #expect(!store.start(secondRequest))
        #expect(await controller.invocationCount == 1)
        #expect(store.batch?.request == firstRequest)

        await controller.fail(MetadataProgressStoreTestError.setup, invocation: 0)
        await store.waitForCurrentBatch()
    }

    @Test
    func cancellationWhilePreparingForcesRevisionAndKeepsTerminalState() async {
        let controller = ControlledMetadataRefreshOperation()
        let revisions = MetadataRevisionRecorder()
        let store = makeStore(controller: controller, revisions: revisions)

        #expect(store.start(AppMetadataRefreshRequest(appStoreID: appStoreID)))
        await controller.waitForInvocation(at: 0)
        #expect(store.status == .preparing)
        #expect(store.cancel())
        #expect(store.status == .cancelling)
        #expect(store.revision(for: appStoreID) == 1)
        #expect(!store.cancel())

        await controller.cancel(invocation: 0)
        await store.waitForCurrentBatch()

        #expect(store.status == .cancelled)
        #expect(store.batch?.message == AppMetadataRefreshProgressStore.cancellationMessage)
        #expect(store.batch?.storefronts.isEmpty == true)
        #expect(revisions.events == [
            MetadataRevisionEvent(appStoreID: appStoreID, revision: 1),
        ])
    }

    @Test
    func cancellationDuringActiveStorefrontPreservesCompletedAndMarksUnknownAndNotStarted() async {
        let controller = ControlledMetadataRefreshOperation()
        let revisions = MetadataRevisionRecorder()
        let store = makeStore(controller: controller, revisions: revisions)
        let us = makeOutcome(storefront: "us")

        #expect(store.start(AppMetadataRefreshRequest(appStoreID: appStoreID)))
        await controller.waitForInvocation(at: 0)
        await controller.send(.batchStarted(
            appStoreID: appStoreID,
            storefronts: ["us", "jp", "de"]
        ), to: 0)
        await controller.send(.storefrontFinished(
            outcome: us,
            completed: 1,
            total: 3
        ), to: 0)
        await controller.send(.storefrontStarted(
            storefront: "jp",
            position: 2,
            total: 3
        ), to: 0)

        #expect(store.cancel())
        #expect(store.status == .cancelling)
        #expect(store.batch?.storefronts[0].state == .completed(.succeeded))
        #expect(store.batch?.storefronts[1].state == .interruptedOutcomeUnknown)
        #expect(store.batch?.storefronts[1].providers.allSatisfy {
            $0.state == .outcomeUnknownMayHaveCommitted
        } == true)
        #expect(store.batch?.storefronts[2].state == .notStarted)
        #expect(store.batch?.storefronts[2].providers.allSatisfy {
            $0.state == .notStarted
        } == true)
        #expect(AppMetadataRefreshProgressStore.interruptedStorefrontMessage.contains(
            "may already have been kept"
        ))
        #expect(store.revision(for: appStoreID) == 2)

        let lateJP = makeOutcome(storefront: "jp")
        await controller.send(.storefrontFinished(
            outcome: lateJP,
            completed: 2,
            total: 3
        ), to: 0)
        #expect(store.batch?.storefronts[1].state == .interruptedOutcomeUnknown)

        await controller.cancel(invocation: 0)
        await store.waitForCurrentBatch()

        #expect(store.status == .cancelled)
        #expect(store.batch?.storefronts[0].state == .completed(.succeeded))
        #expect(store.batch?.storefronts[1].state == .interruptedOutcomeUnknown)
        #expect(store.batch?.storefronts[2].state == .notStarted)
        #expect(revisions.events.map(\.revision) == [1, 2])
    }

    @Test
    func cancellationAfterCompletionIsRejectedWithoutAnotherRevision() async {
        let controller = ControlledMetadataRefreshOperation()
        let revisions = MetadataRevisionRecorder()
        let store = makeStore(controller: controller, revisions: revisions)
        let outcome = makeOutcome(storefront: "us")

        #expect(store.start(AppMetadataRefreshRequest(appStoreID: appStoreID)))
        await controller.waitForInvocation(at: 0)
        await controller.succeed(
            makeResult(appStoreID: appStoreID, storefronts: [outcome]),
            invocation: 0
        )
        await store.waitForCurrentBatch()

        #expect(store.status == .succeeded)
        #expect(store.revision(for: appStoreID) == 1)
        #expect(!store.cancel())
        #expect(store.revision(for: appStoreID) == 1)
        #expect(revisions.events.count == 1)
    }

    @Test
    func retryUsesNewGenerationAndIgnoresLateEventsFromPreviousOperation() async {
        let controller = ControlledMetadataRefreshOperation()
        let store = makeStore(controller: controller)
        let request = AppMetadataRefreshRequest(appStoreID: appStoreID)
        let firstOutcome = makeOutcome(storefront: "us")

        #expect(store.start(request))
        await controller.waitForInvocation(at: 0)
        await controller.succeed(
            makeResult(appStoreID: appStoreID, storefronts: [firstOutcome]),
            invocation: 0
        )
        await store.waitForCurrentBatch()
        let firstGeneration = store.batch?.id

        #expect(store.retry())
        await controller.waitForInvocation(at: 1)
        #expect(store.status == .preparing)
        #expect(store.batch?.id != firstGeneration)

        await controller.send(.batchStarted(
            appStoreID: appStoreID,
            storefronts: ["late"]
        ), to: 0)
        #expect(store.status == .preparing)
        #expect(store.batch?.storefronts.isEmpty == true)

        await controller.send(.batchStarted(
            appStoreID: appStoreID,
            storefronts: ["jp"]
        ), to: 1)
        #expect(store.status == .refreshing)
        #expect(store.batch?.storefronts.map(\.storefront) == ["jp"])

        let retryOutcome = makeOutcome(storefront: "jp")
        await controller.succeed(
            makeResult(appStoreID: appStoreID, storefronts: [retryOutcome]),
            invocation: 1
        )
        await store.waitForCurrentBatch()
        #expect(store.status == .succeeded)
        #expect(store.batch?.storefronts.map(\.storefront) == ["jp"])
    }

    @Test
    func dismissClearsTerminalBatchButKeepsMonotonicRevision() async {
        let controller = ControlledMetadataRefreshOperation()
        let store = makeStore(controller: controller)
        let outcome = makeOutcome(storefront: "us")
        let request = AppMetadataRefreshRequest(appStoreID: appStoreID)

        #expect(store.start(request))
        await controller.waitForInvocation(at: 0)
        await controller.succeed(
            makeResult(appStoreID: appStoreID, storefronts: [outcome]),
            invocation: 0
        )
        await store.waitForCurrentBatch()
        #expect(store.revision(for: appStoreID) == 1)

        #expect(store.dismiss())
        #expect(store.status == .idle)
        #expect(store.batch == nil)
        #expect(store.revision(for: appStoreID) == 1)
        #expect(!store.dismiss())

        #expect(store.start(request))
        await controller.waitForInvocation(at: 1)
        await controller.succeed(
            makeResult(appStoreID: appStoreID, storefronts: [outcome]),
            invocation: 1
        )
        await store.waitForCurrentBatch()
        #expect(store.revision(for: appStoreID) == 2)
    }

    @Test
    func revisionSignatureIsStableDeduplicatedAndChangesPerApp() async {
        let controller = ControlledMetadataRefreshOperation()
        let store = makeStore(controller: controller)
        let secondAppStoreID = appStoreID + 1

        #expect(store.revisionSignature(for: [secondAppStoreID, appStoreID, appStoreID]) == "")

        let outcome = makeOutcome(storefront: "us")
        #expect(store.start(AppMetadataRefreshRequest(appStoreID: secondAppStoreID)))
        await controller.waitForInvocation(at: 0)
        await controller.succeed(
            makeResult(appStoreID: secondAppStoreID, storefronts: [outcome]),
            invocation: 0
        )
        await store.waitForCurrentBatch()

        #expect(store.revisionSignature(for: [secondAppStoreID, appStoreID])
            == "\(secondAppStoreID):1")
    }

    private func makeStore(
        controller: ControlledMetadataRefreshOperation,
        revisions: MetadataRevisionRecorder = MetadataRevisionRecorder()
    ) -> AppMetadataRefreshProgressStore {
        AppMetadataRefreshProgressStore(
            refreshOperation: { request, progress in
                try await controller.run(request: request, progress: progress)
            },
            revisionHandler: { appStoreID, revision in
                revisions.record(appStoreID: appStoreID, revision: revision)
            }
        )
    }
}

private actor ControlledMetadataRefreshOperation {
    private struct Invocation {
        let request: AppMetadataRefreshRequest
        let progress: AppMetadataRefreshService.ProgressHandler?
        var continuation: CheckedContinuation<AppMetadataRefreshResult, any Error>?
    }

    private struct InvocationWaiter {
        let index: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var invocations: [Invocation] = []
    private var invocationWaiters: [InvocationWaiter] = []

    var invocationCount: Int { invocations.count }

    func run(
        request: AppMetadataRefreshRequest,
        progress: AppMetadataRefreshService.ProgressHandler?
    ) async throws -> AppMetadataRefreshResult {
        try await withCheckedThrowingContinuation { continuation in
            invocations.append(Invocation(
                request: request,
                progress: progress,
                continuation: continuation
            ))
            resumeSatisfiedWaiters()
        }
    }

    func waitForInvocation(at index: Int) async {
        guard invocations.indices.contains(index) == false else { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(InvocationWaiter(
                index: index,
                continuation: continuation
            ))
        }
    }

    func send(_ progress: AppMetadataRefreshProgress, to invocation: Int) async {
        guard invocations.indices.contains(invocation) else { return }
        let progressHandler = invocations[invocation].progress
        await progressHandler?(progress)
    }

    func succeed(_ result: AppMetadataRefreshResult, invocation: Int) {
        guard invocations.indices.contains(invocation),
              let continuation = invocations[invocation].continuation
        else {
            return
        }
        invocations[invocation].continuation = nil
        continuation.resume(returning: result)
    }

    func fail(_ error: any Error, invocation: Int) {
        guard invocations.indices.contains(invocation),
              let continuation = invocations[invocation].continuation
        else {
            return
        }
        invocations[invocation].continuation = nil
        continuation.resume(throwing: error)
    }

    func cancel(invocation: Int) {
        fail(CancellationError(), invocation: invocation)
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [InvocationWaiter] = []
        for waiter in invocationWaiters {
            if invocations.indices.contains(waiter.index) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        invocationWaiters = remaining
    }
}

@MainActor
private final class MetadataRevisionRecorder {
    private(set) var events: [MetadataRevisionEvent] = []

    func record(appStoreID: Int64, revision: UInt64) {
        events.append(MetadataRevisionEvent(appStoreID: appStoreID, revision: revision))
    }
}

private struct MetadataRevisionEvent: Equatable {
    let appStoreID: Int64
    let revision: UInt64
}

private enum MetadataProgressStoreTestError: LocalizedError {
    case setup

    var errorDescription: String? {
        "The refresh could not be prepared."
    }
}

private func makeOutcome(
    storefront: String,
    iTunesLookup: AppMetadataRefreshProviderOutcome = .succeeded,
    appStoreWeb: AppMetadataRefreshProviderOutcome = .succeeded
) -> AppMetadataRefreshStorefrontOutcome {
    AppMetadataRefreshStorefrontOutcome(
        storefront: storefront,
        iTunesLookup: iTunesLookup,
        appStoreWeb: appStoreWeb
    )
}

private func makeResult(
    appStoreID: Int64,
    storefronts: [AppMetadataRefreshStorefrontOutcome]
) -> AppMetadataRefreshResult {
    AppMetadataRefreshResult(
        appStoreID: appStoreID,
        defaultStorefront: storefronts.first?.storefront ?? "us",
        storefronts: storefronts,
        iconInvalidated: false
    )
}

private func makeFailure(
    provider: AppMetadataRefreshProvider
) -> AppMetadataRefreshFailure {
    AppMetadataRefreshFailure(
        provider: provider,
        stage: .fetch,
        error: .networkUnavailable
    )
}
