import Foundation
import Synchronization
import Testing
@testable import OpenASO

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DailyRefreshSchedulerTests {
    @Test
    func disabledPolicyHasNoDueSlotOrWakeDate() {
        let calendar = utcCalendar()
        let now = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 12,
            calendar: calendar
        )

        let decision = DailyRefreshDuePolicy.evaluate(
            configuration: DailyRefreshScheduleConfiguration(
                isAutomaticRefreshEnabled: false,
                refreshTimeMinutes: 7 * 60
            ),
            lastClaimedAt: nil,
            now: now,
            calendar: calendar
        )

        #expect(decision == DailyRefreshScheduleDecision(
            dueSlot: nil,
            nextCheckAt: nil
        ))
    }

    @Test
    func policyUsesOnlyTheCurrentDaySlotAndClaimsAtTheExactScheduledTime() {
        let calendar = utcCalendar()
        let configuration = DailyRefreshScheduleConfiguration(
            isAutomaticRefreshEnabled: true,
            refreshTimeMinutes: 7 * 60
        )
        let before = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 6,
            minute: 59,
            calendar: calendar
        )
        let scheduled = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 7,
            calendar: calendar
        )
        let tomorrow = date(
            year: 2026,
            month: 1,
            day: 3,
            hour: 7,
            calendar: calendar
        )

        let beforeDecision = DailyRefreshDuePolicy.evaluate(
            configuration: configuration,
            lastClaimedAt: nil,
            now: before,
            calendar: calendar
        )
        let exactDecision = DailyRefreshDuePolicy.evaluate(
            configuration: configuration,
            lastClaimedAt: nil,
            now: scheduled,
            calendar: calendar
        )

        #expect(beforeDecision.dueSlot == nil)
        #expect(beforeDecision.nextCheckAt == scheduled)
        #expect(exactDecision.dueSlot?.scheduledFor == scheduled)
        #expect(exactDecision.nextCheckAt == tomorrow)
    }

    @Test
    func policyCoalescesMissedDaysAndSuppressesSameDayOrFutureClaims() {
        let calendar = utcCalendar()
        let configuration = DailyRefreshScheduleConfiguration(
            isAutomaticRefreshEnabled: true,
            refreshTimeMinutes: 7 * 60
        )
        let now = date(
            year: 2026,
            month: 1,
            day: 5,
            hour: 12,
            calendar: calendar
        )
        let scheduledToday = date(
            year: 2026,
            month: 1,
            day: 5,
            hour: 7,
            calendar: calendar
        )
        let scheduledTomorrow = date(
            year: 2026,
            month: 1,
            day: 6,
            hour: 7,
            calendar: calendar
        )
        let oldClaim = date(
            year: 2026,
            month: 1,
            day: 1,
            hour: 7,
            calendar: calendar
        )
        let sameDayClaim = date(
            year: 2026,
            month: 1,
            day: 5,
            hour: 8,
            calendar: calendar
        )
        let futureClaim = date(
            year: 2026,
            month: 1,
            day: 8,
            hour: 8,
            calendar: calendar
        )

        let missedDaysDecision = DailyRefreshDuePolicy.evaluate(
            configuration: configuration,
            lastClaimedAt: oldClaim,
            now: now,
            calendar: calendar
        )
        let sameDayDecision = DailyRefreshDuePolicy.evaluate(
            configuration: configuration,
            lastClaimedAt: sameDayClaim,
            now: now,
            calendar: calendar
        )
        let futureDecision = DailyRefreshDuePolicy.evaluate(
            configuration: configuration,
            lastClaimedAt: futureClaim,
            now: now,
            calendar: calendar
        )

        #expect(missedDaysDecision.dueSlot?.scheduledFor == scheduledToday)
        #expect(missedDaysDecision.nextCheckAt == scheduledTomorrow)
        #expect(sameDayDecision.dueSlot == nil)
        #expect(sameDayDecision.nextCheckAt == scheduledTomorrow)
        #expect(futureDecision.dueSlot == nil)
        #expect(futureDecision.nextCheckAt == scheduledTomorrow)
    }

    @Test
    func changingTheScheduleCannotCreateASecondSlotOnTheClaimedDay() {
        let calendar = utcCalendar()
        let now = date(
            year: 2026,
            month: 1,
            day: 5,
            hour: 20,
            calendar: calendar
        )
        let claim = date(
            year: 2026,
            month: 1,
            day: 5,
            hour: 7,
            calendar: calendar
        )

        for minutes in [6 * 60, 19 * 60] {
            let decision = DailyRefreshDuePolicy.evaluate(
                configuration: DailyRefreshScheduleConfiguration(
                    isAutomaticRefreshEnabled: true,
                    refreshTimeMinutes: minutes
                ),
                lastClaimedAt: claim,
                now: now,
                calendar: calendar
            )

            #expect(decision.dueSlot == nil)
        }
    }

    @Test
    func policyUsesCalendarDSTRulesForMissingAndRepeatedWallTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let configuration = DailyRefreshScheduleConfiguration(
            isAutomaticRefreshEnabled: true,
            refreshTimeMinutes: (2 * 60) + 30
        )
        let springNow = date(
            year: 2026,
            month: 3,
            day: 8,
            hour: 4,
            calendar: calendar
        )

        let springDecision = DailyRefreshDuePolicy.evaluate(
            configuration: configuration,
            lastClaimedAt: nil,
            now: springNow,
            calendar: calendar
        )
        let springSlot = try #require(springDecision.dueSlot?.scheduledFor)
        let springComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: springSlot
        )

        #expect(springComponents.year == 2026)
        #expect(springComponents.month == 3)
        #expect(springComponents.day == 8)
        #expect(springComponents.hour == 3)
        #expect(springComponents.minute == 0)

        let repeatedConfiguration = DailyRefreshScheduleConfiguration(
            isAutomaticRefreshEnabled: true,
            refreshTimeMinutes: (1 * 60) + 30
        )
        let fallNow = date(
            year: 2026,
            month: 11,
            day: 1,
            hour: 3,
            calendar: calendar
        )
        let fallDecision = DailyRefreshDuePolicy.evaluate(
            configuration: repeatedConfiguration,
            lastClaimedAt: nil,
            now: fallNow,
            calendar: calendar
        )
        let fallSlot = try #require(fallDecision.dueSlot?.scheduledFor)

        #expect(calendar.component(.hour, from: fallSlot) == 1)
        #expect(calendar.component(.minute, from: fallSlot) == 30)
        #expect(calendar.timeZone.secondsFromGMT(for: fallSlot) == -4 * 60 * 60)
    }

    @Test
    func automaticClaimIsPersistedBeforeReturnAndCannotBeClaimedTwice() throws {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let now = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 7,
            minute: 1,
            calendar: calendar
        )

        let first = settingsStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )
        let second = settingsStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )
        let reloaded = AppSettingsStore(defaults: defaults)
        let third = reloaded.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )

        #expect(first.claim?.claimedAt == now)
        #expect(first.claim?.scheduledFor == date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 5,
            calendar: calendar
        ))
        #expect(first.claim?.refreshRatingsAndReviews == true)
        #expect(second.claim == nil)
        #expect(third.claim == nil)
        #expect(reloaded.hasClaimedAutomaticRefresh(on: now, calendar: calendar))
        #expect(reloaded.hasTriggeredRefresh(on: now, calendar: calendar))
    }

    @Test
    func twoSettingsStoresSharingDefaultsCannotBothClaimTheSameSlot() {
        let defaults = makeDefaults()
        let firstStore = AppSettingsStore(defaults: defaults)
        let secondStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let now = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 7,
            minute: 1,
            calendar: calendar
        )

        let first = firstStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )
        let second = secondStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )

        #expect(first.claim != nil)
        #expect(second.claim == nil)
        #expect(secondStore.lastAutomaticRefreshClaimedAt == now)
    }

    @Test
    func manualRefreshDoesNotClaimOrSuppressTheAutomaticSlot() {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let calendar = utcCalendar()
        let manualRefresh = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 8,
            calendar: calendar
        )

        settingsStore.markRefreshTriggered(on: manualRefresh)
        let reloaded = AppSettingsStore(defaults: defaults)
        let evaluation = reloaded.evaluateAndClaimAutomaticRefresh(
            at: manualRefresh,
            calendar: calendar
        )

        #expect(reloaded.hasTriggeredRefresh(on: manualRefresh, calendar: calendar))
        #expect(evaluation.claim != nil)
        #expect(reloaded.hasClaimedAutomaticRefresh(on: manualRefresh, calendar: calendar))
    }

    @Test
    func legacyTriggeredDateMigratesOnceIntoTheAutomaticClaim() {
        let defaults = makeDefaults()
        let calendar = utcCalendar()
        let legacyClaim = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 7,
            calendar: calendar
        )
        defaults.set(legacyClaim, forKey: "dailyRefresh.lastTriggeredAt")

        let migrated = AppSettingsStore(defaults: defaults)
        let evaluation = migrated.evaluateAndClaimAutomaticRefresh(
            at: legacyClaim.addingTimeInterval(60 * 60),
            calendar: calendar
        )

        #expect(migrated.lastAutomaticRefreshClaimedAt == legacyClaim)
        #expect(evaluation.claim == nil)
    }

    @Test
    func completedMigrationNeverImportsALaterManualRefresh() {
        let defaults = makeDefaults()
        let calendar = utcCalendar()
        let initialStore = AppSettingsStore(defaults: defaults)
        let manualRefresh = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 8,
            calendar: calendar
        )
        initialStore.markRefreshTriggered(on: manualRefresh)

        let reloaded = AppSettingsStore(defaults: defaults)
        let evaluation = reloaded.evaluateAndClaimAutomaticRefresh(
            at: manualRefresh,
            calendar: calendar
        )

        #expect(evaluation.claim != nil)
        #expect(reloaded.lastAutomaticRefreshClaimedAt == manualRefresh)
    }

    @Test
    func invalidPersistedAutomaticClaimDoesNotBlockTheCurrentSlot() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "dailyRefresh.automaticClaimMigrationCompleted")
        defaults.set("not-a-date", forKey: "dailyRefresh.lastAutomaticClaimedAt")
        let calendar = utcCalendar()
        let now = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 8,
            calendar: calendar
        )
        let settingsStore = AppSettingsStore(defaults: defaults)

        let evaluation = settingsStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )

        #expect(evaluation.claim?.claimedAt == now)
        #expect(defaults.object(forKey: "dailyRefresh.lastAutomaticClaimedAt") as? Date == now)
    }

    @Test
    func claimSnapshotsWhetherRatingsAndReviewsAlreadySucceededToday() {
        let settingsStore = AppSettingsStore(defaults: makeDefaults())
        let calendar = utcCalendar()
        let ratingsRefresh = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 6,
            calendar: calendar
        )
        let now = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 7,
            minute: 1,
            calendar: calendar
        )
        settingsStore.markRatingsReviewsRefreshed(on: ratingsRefresh)

        let evaluation = settingsStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )

        #expect(evaluation.claim?.refreshRatingsAndReviews == false)
    }

    @Test
    func olderAutomaticCompletionCannotOverwriteANewerRatingsRefresh() {
        let defaults = makeDefaults()
        let settingsStore = AppSettingsStore(defaults: defaults)
        let newerRefresh = Date(timeIntervalSince1970: 2_000)
        let olderCompletion = Date(timeIntervalSince1970: 1_000)

        settingsStore.markRatingsReviewsRefreshed(on: newerRefresh)
        settingsStore.markRatingsReviewsRefreshed(on: olderCompletion)

        let reloaded = AppSettingsStore(defaults: defaults)
        #expect(settingsStore.lastRatingsReviewsRefreshAt == newerRefresh)
        #expect(reloaded.lastRatingsReviewsRefreshAt == newerRefresh)
    }

    @Test
    func lifecycleRunsOnlyAfterTheClaimIsDurableAndDoesNotRetryThatDay() async {
        let settingsStore = AppSettingsStore(defaults: makeDefaults())
        let calendar = utcCalendar()
        let now = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 7,
            minute: 1,
            calendar: calendar
        )
        let recorder = DailyRefreshLifecycleRecorder()

        func makeScheduler() -> DailyRefreshScheduler {
            DailyRefreshScheduler(
                evaluateAndClaim: { date, calendar in
                    await settingsStore.evaluateAndClaimAutomaticRefresh(
                        at: date,
                        calendar: calendar
                    )
                },
                runHeadlessRefresh: { request in
                    let claimWasPersisted = await settingsStore
                        .hasClaimedAutomaticRefresh(on: now, calendar: calendar)
                    await recorder.recordRun(
                        request,
                        claimWasPersisted: claimWasPersisted
                    )
                    return makeSummary(
                        for: request,
                        at: now,
                        disposition: .failure
                    )
                },
                now: { now },
                calendar: { calendar },
                sleepUntil: { date in
                    await recorder.recordSleep(date)
                    throw DailyRefreshTestStop.expected
                }
            )
        }

        await makeScheduler().run()
        await makeScheduler().run()

        let runs = await recorder.runs()
        #expect(runs.count == 1)
        #expect(runs.first?.claimWasPersisted == true)
        #expect(runs.first?.request.scheduledFor == date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 5,
            calendar: calendar
        ))
        #expect(await recorder.sleepDates().count == 2)
    }

    @Test
    func disabledLifecycleDoesNotRunOrSleep() async {
        let recorder = DailyRefreshLifecycleRecorder()
        let scheduler = DailyRefreshScheduler(
            evaluateAndClaim: { _, _ in
                DailyRefreshClaimEvaluation(claim: nil, nextCheckAt: nil)
            },
            runHeadlessRefresh: { request in
                await recorder.recordRun(request, claimWasPersisted: false)
                return makeSummary(for: request, at: .now, disposition: .success)
            },
            sleepUntil: { date in
                await recorder.recordSleep(date)
            }
        )

        await scheduler.run()

        #expect(await recorder.runs().isEmpty)
        #expect(await recorder.sleepDates().isEmpty)
    }

    @Test
    func lifecycleCancellationInterruptsTheInjectedSleepWithoutAnotherCycle() async throws {
        let calendar = utcCalendar()
        let now = date(
            year: 2026,
            month: 1,
            day: 2,
            hour: 6,
            calendar: calendar
        )
        let sleepStarted = DailyRefreshOneShotSignal()
        let sleepGate = DailyRefreshOneShotSignal()
        let recorder = DailyRefreshLifecycleRecorder()
        let scheduler = DailyRefreshScheduler(
            evaluateAndClaim: { _, _ in
                await recorder.recordEvaluation()
                return DailyRefreshClaimEvaluation(
                    claim: nil,
                    nextCheckAt: now.addingTimeInterval(60 * 60)
                )
            },
            runHeadlessRefresh: { request in
                await recorder.recordRun(request, claimWasPersisted: false)
                return makeSummary(for: request, at: now, disposition: .success)
            },
            now: { now },
            calendar: { calendar },
            sleepUntil: { _ in
                sleepStarted.signal()
                try await sleepGate.wait()
            }
        )

        let task = Task { await scheduler.run() }
        try await sleepStarted.wait()
        task.cancel()
        await task.value

        #expect(await recorder.evaluationCount() == 1)
        #expect(await recorder.runs().isEmpty)
    }
}

private enum DailyRefreshTestStop: Error {
    case expected
}

private actor DailyRefreshLifecycleRecorder {
    struct Run: Sendable {
        let request: HeadlessRefreshRunRequest
        let claimWasPersisted: Bool
    }

    private var recordedRuns: [Run] = []
    private var recordedSleepDates: [Date] = []
    private var recordedEvaluationCount = 0

    func recordRun(
        _ request: HeadlessRefreshRunRequest,
        claimWasPersisted: Bool
    ) {
        recordedRuns.append(Run(
            request: request,
            claimWasPersisted: claimWasPersisted
        ))
    }

    func recordSleep(_ date: Date) {
        recordedSleepDates.append(date)
    }

    func recordEvaluation() {
        recordedEvaluationCount += 1
    }

    func runs() -> [Run] {
        recordedRuns
    }

    func sleepDates() -> [Date] {
        recordedSleepDates
    }

    func evaluationCount() -> Int {
        recordedEvaluationCount
    }
}

private final class DailyRefreshOneShotSignal: Sendable {
    private enum Resolution: Sendable {
        case signalled
        case cancelled
    }

    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var resolution: Resolution?
    }

    private let state = Mutex(State())

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, any Error>
            ) in
                let resolution = state.withLock { state -> Resolution? in
                    if let resolution = state.resolution {
                        return resolution
                    }
                    precondition(state.continuation == nil)
                    state.continuation = continuation
                    return nil
                }
                if let resolution {
                    Self.resume(continuation, with: resolution)
                }
            }
        } onCancel: {
            resolve(.cancelled)
        }
    }

    func signal() {
        resolve(.signalled)
    }

    private func resolve(_ resolution: Resolution) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard case nil = state.resolution else { return nil }
            state.resolution = resolution
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        if let continuation {
            Self.resume(continuation, with: resolution)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<Void, any Error>,
        with resolution: Resolution
    ) {
        switch resolution {
        case .signalled:
            continuation.resume()
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        }
    }
}

private func makeSummary(
    for request: HeadlessRefreshRunRequest,
    at date: Date,
    disposition: HeadlessRefreshRunDisposition
) -> HeadlessRefreshRunSummary {
    HeadlessRefreshRunSummary(
        runID: request.id,
        activeRunID: nil,
        scheduledFor: request.scheduledFor,
        startedAt: date,
        finishedAt: date,
        disposition: disposition,
        plannedAppCount: 0,
        completedAppCount: 0,
        successfulAppCount: 0,
        partialFailureAppCount: 0,
        failedAppCount: 0,
        ratingsReviewsAttempted: false,
        ratingsReviewsFullySucceeded: false,
        issue: nil
    )
}

private func makeDefaults() -> UserDefaults {
    let suiteName = "daily.refresh.scheduler.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int = 0,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
    ))!
}
