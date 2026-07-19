import Foundation
import Synchronization
import Testing
@testable import OpenASO

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HeadlessRefreshObservationTests {
    @Test
    func streamsReplayCurrentSnapshotAndBroadcastUpdatesToEverySubscriber() async {
        let recorder = HeadlessRefreshObservationRecorder(log: { _ in })
        let runID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let instant = Date(timeIntervalSince1970: 1_000)
        let initialSnapshot = HeadlessRefreshSnapshot(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .planning,
                plannedAppCount: nil,
                completedAppCount: 0
            ),
            recentRuns: []
        )
        await recorder.record(HeadlessRefreshObservation(
            event: .runStarted(
                runID: runID,
                scheduledFor: instant,
                startedAt: instant
            ),
            snapshot: initialSnapshot
        ))

        let firstStream = await recorder.updates()
        let secondStream = await recorder.updates()
        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()

        #expect(await recorder.subscriberCount() == 2)
        let firstReplay = await firstIterator.next()
        let secondReplay = await secondIterator.next()
        #expect(firstReplay == initialSnapshot)
        #expect(secondReplay == initialSnapshot)

        let refreshingSnapshot = HeadlessRefreshSnapshot(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .refreshing,
                plannedAppCount: 3,
                completedAppCount: 0,
                currentAppStoreID: 9_182_736_450
            ),
            recentRuns: []
        )
        await recorder.record(HeadlessRefreshObservation(
            event: .planLoaded(runID: runID, plannedAppCount: 3),
            snapshot: refreshingSnapshot
        ))

        let firstUpdate = await firstIterator.next()
        let secondUpdate = await secondIterator.next()
        #expect(firstUpdate == refreshingSnapshot)
        #expect(secondUpdate == refreshingSnapshot)
        #expect(await recorder.currentSnapshot() == refreshingSnapshot)
    }

    @Test
    func slowSubscriberReceivesTheLatestCoherentTerminalSnapshot() async {
        let recorder = HeadlessRefreshObservationRecorder(log: { _ in })
        let runID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let instant = Date(timeIntervalSince1970: 2_000)
        let planningSnapshot = HeadlessRefreshSnapshot(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .planning,
                plannedAppCount: nil,
                completedAppCount: 0
            ),
            recentRuns: []
        )
        await recorder.record(HeadlessRefreshObservation(
            event: .runStarted(
                runID: runID,
                scheduledFor: instant,
                startedAt: instant
            ),
            snapshot: planningSnapshot
        ))

        let stream = await recorder.updates()
        var iterator = stream.makeAsyncIterator()
        let replayedSnapshot = await iterator.next()
        #expect(replayedSnapshot == planningSnapshot)

        let plannedSnapshot = HeadlessRefreshSnapshot(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .refreshing,
                plannedAppCount: 2,
                completedAppCount: 0
            ),
            recentRuns: []
        )
        await recorder.record(HeadlessRefreshObservation(
            event: .planLoaded(runID: runID, plannedAppCount: 2),
            snapshot: plannedSnapshot
        ))

        let appStartedSnapshot = HeadlessRefreshSnapshot(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .refreshing,
                plannedAppCount: 2,
                completedAppCount: 0,
                currentAppStoreID: 9_182_736_450
            ),
            recentRuns: []
        )
        await recorder.record(HeadlessRefreshObservation(
            event: .appStarted(
                runID: runID,
                appStoreID: 9_182_736_450,
                position: 1,
                total: 2
            ),
            snapshot: appStartedSnapshot
        ))

        let appFinishedSnapshot = HeadlessRefreshSnapshot(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .refreshing,
                plannedAppCount: 2,
                completedAppCount: 1
            ),
            recentRuns: []
        )
        await recorder.record(HeadlessRefreshObservation(
            event: .appFinished(
                runID: runID,
                appStoreID: 9_182_736_450,
                position: 1,
                total: 2,
                disposition: .success
            ),
            snapshot: appFinishedSnapshot
        ))

        let summary = makeSummary(
            runID: runID,
            instant: instant,
            disposition: .partialFailure,
            plannedAppCount: 2,
            completedAppCount: 2,
            successfulAppCount: 1,
            partialFailureAppCount: 1,
            failedAppCount: 0,
            issue: HeadlessRefreshIssue(kind: .appRefreshFailed)
        )
        let terminalSnapshot = HeadlessRefreshSnapshot(
            activeRun: nil,
            recentRuns: [summary]
        )
        await recorder.record(HeadlessRefreshObservation(
            event: .runFinished(summary),
            snapshot: terminalSnapshot
        ))

        let latestBufferedSnapshot = await iterator.next()
        #expect(latestBufferedSnapshot == terminalSnapshot)
        #expect(await recorder.currentSnapshot() == terminalSnapshot)
    }

    @Test
    func aggregateLogMessagesAreExactBoundedAndRedacted() async {
        let logRecorder = HeadlessObservationLogRecorder()
        let recorder = HeadlessRefreshObservationRecorder(log: logRecorder.record)
        let runID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let activeRunID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        let instant = Date(timeIntervalSince1970: 4_000)
        let appStoreID: Int64 = 9_182_736_450
        let summary = makeSummary(
            runID: runID,
            instant: instant,
            duration: 2,
            disposition: .partialFailure,
            plannedAppCount: 7,
            completedAppCount: 5,
            successfulAppCount: 2,
            partialFailureAppCount: 1,
            failedAppCount: 2,
            ratingsReviewsAttempted: true,
            ratingsReviewsFullySucceeded: false,
            issue: HeadlessRefreshIssue(kind: .appRefreshFailed)
        )
        let expectedSummaryMessage = "Headless refresh completed runID=\(runID.uuidString) disposition=partialFailure durationMs=2000 planned=7 completed=5 success=2 partialFailure=1 failure=2 unfinished=2 ratingsReviewsAttempted=true ratingsReviewsFullySucceeded=false issue=appRefreshFailed"
        #expect(summary.redactedLogMessage == expectedSummaryMessage)

        let maximumDurationSummary = makeSummary(
            runID: runID,
            instant: instant,
            duration: .greatestFiniteMagnitude,
            disposition: .failure,
            plannedAppCount: 0,
            completedAppCount: 0,
            successfulAppCount: 0,
            partialFailureAppCount: 0,
            failedAppCount: 0,
            issue: nil
        )
        #expect(maximumDurationSummary.redactedLogMessage.contains("durationMs=\(Int.max)"))

        let negativeDurationSummary = makeSummary(
            runID: runID,
            instant: instant,
            duration: -1,
            disposition: .failure,
            plannedAppCount: 0,
            completedAppCount: 0,
            successfulAppCount: 0,
            partialFailureAppCount: 0,
            failedAppCount: 0,
            issue: nil
        )
        #expect(negativeDurationSummary.redactedLogMessage.contains("durationMs=0"))

        let started = HeadlessRefreshEvent.runStarted(
            runID: runID,
            scheduledFor: instant,
            startedAt: instant
        )
        let planLoaded = HeadlessRefreshEvent.planLoaded(
            runID: runID,
            plannedAppCount: 7
        )
        let appStarted = HeadlessRefreshEvent.appStarted(
            runID: runID,
            appStoreID: appStoreID,
            position: 1,
            total: 7
        )
        let appFinished = HeadlessRefreshEvent.appFinished(
            runID: runID,
            appStoreID: appStoreID,
            position: 1,
            total: 7,
            disposition: .failure
        )
        let finished = HeadlessRefreshEvent.runFinished(summary)
        let skipped = HeadlessRefreshEvent.runSkipped(
            requestRunID: runID,
            activeRunID: activeRunID,
            at: instant
        )
        let reused = HeadlessRefreshEvent.completedRunReused(
            requestRunID: runID,
            priorDisposition: .partialFailure,
            at: instant
        )
        let rejected = HeadlessRefreshEvent.runRejected(
            requestRunID: runID,
            at: instant
        )

        #expect(started.redactedLogMessage == "Headless refresh started runID=\(runID.uuidString)")
        #expect(planLoaded.redactedLogMessage == nil)
        #expect(appStarted.redactedLogMessage == nil)
        #expect(appFinished.redactedLogMessage == nil)
        #expect(finished.redactedLogMessage == expectedSummaryMessage)
        #expect(skipped.redactedLogMessage == "Headless refresh skipped requestRunID=\(runID.uuidString) activeRunID=\(activeRunID.uuidString)")
        #expect(reused.redactedLogMessage == "Headless refresh reused requestRunID=\(runID.uuidString) priorDisposition=partialFailure")
        #expect(rejected.redactedLogMessage == "Headless refresh rejected requestRunID=\(runID.uuidString)")

        let activeSnapshot = HeadlessRefreshSnapshot(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .refreshing,
                plannedAppCount: 7,
                completedAppCount: 0,
                currentAppStoreID: appStoreID
            ),
            recentRuns: []
        )
        let terminalSnapshot = HeadlessRefreshSnapshot(activeRun: nil, recentRuns: [summary])
        for observation in [
            HeadlessRefreshObservation(event: started, snapshot: activeSnapshot),
            HeadlessRefreshObservation(event: planLoaded, snapshot: activeSnapshot),
            HeadlessRefreshObservation(event: appStarted, snapshot: activeSnapshot),
            HeadlessRefreshObservation(event: appFinished, snapshot: activeSnapshot),
            HeadlessRefreshObservation(event: finished, snapshot: terminalSnapshot),
            HeadlessRefreshObservation(event: skipped, snapshot: terminalSnapshot),
            HeadlessRefreshObservation(event: reused, snapshot: terminalSnapshot),
            HeadlessRefreshObservation(event: rejected, snapshot: terminalSnapshot),
        ] {
            await recorder.record(observation)
        }

        let messages = logRecorder.values()
        #expect(messages == [
            started.redactedLogMessage,
            expectedSummaryMessage,
            skipped.redactedLogMessage,
            reused.redactedLogMessage,
            rejected.redactedLogMessage,
        ].compactMap { $0 })
        #expect(messages.allSatisfy { $0.utf8.count < 512 })
        #expect(messages.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })

        let renderedMessages = messages.joined(separator: " ").lowercased()
        for sentinel in [
            String(appStoreID),
            "secret-app-name-sentinel",
            "com.example.secret-bundle-sentinel",
            "secret-keyword-sentinel",
            "secret-storefront-sentinel",
            "secret-session-sentinel",
            "secret-private-key-sentinel",
            "secret-raw-error-sentinel",
        ] {
            #expect(!renderedMessages.contains(sentinel.lowercased()))
        }
    }

    private func assertActivePresentationsExposeExactProgressWithoutIdentifiers() throws {
        let runID = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        let instant = Date(timeIntervalSince1970: 5_000)
        let identifierSentinel: Int64 = 9_182_736_450
        let planning = try #require(DailyRefreshRunStatusPresentation(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .planning,
                plannedAppCount: nil,
                completedAppCount: 0,
                currentAppStoreID: identifierSentinel
            ),
            latestRun: nil
        ))

        #expect(planning.kind == .preparing)
        #expect(planning.title == "Preparing automatic refresh")
        #expect(planning.detail == "Building the refresh plan.")
        #expect(planning.progress == .indeterminate)
        #expect(planning.isActive)
        #expect(planning.systemImage == nil)
        #expect(planning.finishedAt == nil)
        #expect(planning.facts == nil)
        #expect(planning.issueMessage == nil)
        #expect(planning.accessibilityLabel == "Automatic refresh progress")
        #expect(planning.accessibilityValue == "Building the refresh plan.")

        let refreshing = try #require(DailyRefreshRunStatusPresentation(
            activeRun: makeActiveSnapshot(
                runID: runID,
                instant: instant,
                phase: .refreshing,
                plannedAppCount: 3,
                completedAppCount: 1,
                currentAppStoreID: identifierSentinel
            ),
            latestRun: nil
        ))

        #expect(refreshing.kind == .refreshing)
        #expect(refreshing.title == "Refreshing apps")
        #expect(refreshing.detail == "1 of 3 apps complete.")
        #expect(refreshing.progress == .determinate(completed: 1, total: 3))
        #expect(refreshing.isActive)
        #expect(refreshing.accessibilityLabel == "Automatic refresh progress")
        #expect(refreshing.accessibilityValue == "1 of 3 apps complete.")

        for presentation in [planning, refreshing] {
            let rendered = presentationText(presentation).lowercased()
            #expect(!rendered.contains(String(identifierSentinel)))
            #expect(!rendered.contains("secret-app-name-sentinel"))
            #expect(!rendered.contains("secret-keyword-sentinel"))
        }
    }

    @Test
    func terminalPresentationsMapEveryCompletedRunDispositionToExactSessionResult() throws {
        try assertActivePresentationsExposeExactProgressWithoutIdentifiers()

        struct Case {
            let disposition: HeadlessRefreshRunDisposition
            let expectedKind: DailyRefreshRunStatusPresentation.Kind
            let title: String
            let detail: String
            let systemImage: String
            let planned: Int
            let completed: Int
            let succeeded: Int
            let partial: Int
            let failed: Int
            let issueKind: HeadlessRefreshIssue.Kind?
            let expectedFacts: String
        }

        let cases = [
            Case(
                disposition: .noWork,
                expectedKind: .noWork,
                title: "No refresh work needed",
                detail: "No apps needed refreshing.",
                systemImage: "checkmark.circle",
                planned: 0,
                completed: 0,
                succeeded: 0,
                partial: 0,
                failed: 0,
                issueKind: nil,
                expectedFacts: "Completed 0 of 0 apps: 0 succeeded, 0 partial, 0 failed."
            ),
            Case(
                disposition: .success,
                expectedKind: .success,
                title: "Automatic refresh completed",
                detail: "All completed app refreshes succeeded.",
                systemImage: "checkmark.circle.fill",
                planned: 3,
                completed: 3,
                succeeded: 3,
                partial: 0,
                failed: 0,
                issueKind: nil,
                expectedFacts: "Completed 3 of 3 apps: 3 succeeded, 0 partial, 0 failed."
            ),
            Case(
                disposition: .partialFailure,
                expectedKind: .partialFailure,
                title: "Automatic refresh completed with issues",
                detail: "Some apps did not fully refresh.",
                systemImage: "exclamationmark.triangle.fill",
                planned: 3,
                completed: 3,
                succeeded: 1,
                partial: 1,
                failed: 1,
                issueKind: .appRefreshFailed,
                expectedFacts: "Completed 3 of 3 apps: 1 succeeded, 1 partial, 1 failed."
            ),
            Case(
                disposition: .failure,
                expectedKind: .failure,
                title: "Automatic refresh failed",
                detail: "The automatic refresh could not complete.",
                systemImage: "xmark.octagon.fill",
                planned: 3,
                completed: 3,
                succeeded: 0,
                partial: 0,
                failed: 3,
                issueKind: .appRefreshFailed,
                expectedFacts: "Completed 3 of 3 apps: 0 succeeded, 0 partial, 3 failed."
            ),
            Case(
                disposition: .cancelled,
                expectedKind: .cancelled,
                title: "Automatic refresh cancelled",
                detail: "The automatic refresh stopped before completing.",
                systemImage: "stop.circle.fill",
                planned: 3,
                completed: 1,
                succeeded: 1,
                partial: 0,
                failed: 0,
                issueKind: nil,
                expectedFacts: "Completed 1 of 3 apps: 1 succeeded, 0 partial, 0 failed."
            ),
        ]
        let identifierSentinel = "9182736450"
        let instant = Date(timeIntervalSince1970: 6_000)

        for (index, testCase) in cases.enumerated() {
            let runID = UUID(
                uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 10)
            )!
            let issue = testCase.issueKind.map { HeadlessRefreshIssue(kind: $0) }
            let summary = makeSummary(
                runID: runID,
                instant: instant,
                disposition: testCase.disposition,
                plannedAppCount: testCase.planned,
                completedAppCount: testCase.completed,
                successfulAppCount: testCase.succeeded,
                partialFailureAppCount: testCase.partial,
                failedAppCount: testCase.failed,
                issue: issue
            )
            let presentation = try #require(DailyRefreshRunStatusPresentation(
                activeRun: nil,
                latestRun: summary
            ))

            #expect(presentation.kind == testCase.expectedKind)
            #expect(presentation.title == testCase.title)
            #expect(presentation.detail == testCase.detail)
            #expect(presentation.systemImage == testCase.systemImage)
            #expect(presentation.progress == nil)
            #expect(presentation.finishedAt == summary.finishedAt)
            #expect(presentation.facts == testCase.expectedFacts)
            #expect(presentation.issueMessage == issue?.message)
            #expect(presentation.accessibilityLabel == "Latest automatic refresh result this session")
            #expect(presentation.accessibilityValue.contains(testCase.detail))
            #expect(presentation.accessibilityValue.contains(testCase.expectedFacts))
            #expect(!presentation.isActive)

            let rendered = presentationText(presentation).lowercased()
            #expect(!rendered.contains(identifierSentinel))
            #expect(!rendered.contains("secret-app-name-sentinel"))
            #expect(!rendered.contains("com.example.secret-bundle-sentinel"))
            #expect(!rendered.contains("secret-keyword-sentinel"))
            #expect(!rendered.contains("secret-session-sentinel"))
            #expect(!rendered.contains("secret-private-key-sentinel"))
            #expect(!rendered.contains("secret-raw-error-sentinel"))
        }
    }
}

private final class HeadlessObservationLogRecorder: Sendable {
    private let messages = Mutex<[String]>([])

    func record(_ message: String) {
        messages.withLock { $0.append(message) }
    }

    func values() -> [String] {
        messages.withLock { $0 }
    }
}

private func makeActiveSnapshot(
    runID: UUID,
    instant: Date,
    phase: HeadlessRefreshRunPhase,
    plannedAppCount: Int?,
    completedAppCount: Int,
    currentAppStoreID: Int64? = nil
) -> HeadlessRefreshActiveSnapshot {
    HeadlessRefreshActiveSnapshot(
        runID: runID,
        scheduledFor: instant,
        startedAt: instant,
        phase: phase,
        plannedAppCount: plannedAppCount,
        completedAppCount: completedAppCount,
        currentAppStoreID: currentAppStoreID
    )
}

private func makeSummary(
    runID: UUID,
    instant: Date,
    duration: TimeInterval = 1,
    disposition: HeadlessRefreshRunDisposition,
    plannedAppCount: Int,
    completedAppCount: Int,
    successfulAppCount: Int,
    partialFailureAppCount: Int,
    failedAppCount: Int,
    ratingsReviewsAttempted: Bool = false,
    ratingsReviewsFullySucceeded: Bool = false,
    issue: HeadlessRefreshIssue?
) -> HeadlessRefreshRunSummary {
    HeadlessRefreshRunSummary(
        runID: runID,
        activeRunID: nil,
        scheduledFor: instant,
        startedAt: instant,
        finishedAt: instant.addingTimeInterval(duration),
        disposition: disposition,
        plannedAppCount: plannedAppCount,
        completedAppCount: completedAppCount,
        successfulAppCount: successfulAppCount,
        partialFailureAppCount: partialFailureAppCount,
        failedAppCount: failedAppCount,
        ratingsReviewsAttempted: ratingsReviewsAttempted,
        ratingsReviewsFullySucceeded: ratingsReviewsFullySucceeded,
        issue: issue
    )
}

private func presentationText(
    _ presentation: DailyRefreshRunStatusPresentation
) -> String {
    [
        presentation.title,
        presentation.detail,
        presentation.systemImage,
        presentation.facts,
        presentation.issueMessage,
        presentation.accessibilityLabel,
        presentation.accessibilityValue,
    ]
    .compactMap { $0 }
    .joined(separator: " ")
}
