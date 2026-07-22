import Foundation

struct DailyRefreshScheduleConfiguration: Hashable, Sendable {
    let isAutomaticRefreshEnabled: Bool
    let refreshTimeMinutes: Int
}

struct DailyRefreshScheduleSlot: Hashable, Sendable {
    let scheduledFor: Date
}

struct DailyRefreshScheduleDecision: Hashable, Sendable {
    let dueSlot: DailyRefreshScheduleSlot?
    let nextCheckAt: Date?
}

enum DailyRefreshDuePolicy {
    static func evaluate(
        configuration: DailyRefreshScheduleConfiguration,
        lastClaimedAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> DailyRefreshScheduleDecision {
        guard configuration.isAutomaticRefreshEnabled else {
            return DailyRefreshScheduleDecision(dueSlot: nil, nextCheckAt: nil)
        }

        guard let scheduledForToday = scheduledDate(
            on: now,
            minutesFromMidnight: configuration.refreshTimeMinutes,
            calendar: calendar
        ) else {
            return DailyRefreshScheduleDecision(dueSlot: nil, nextCheckAt: nil)
        }
        let scheduledForTomorrow = scheduledDate(
            on: nextDay(after: now, calendar: calendar),
            minutesFromMidnight: configuration.refreshTimeMinutes,
            calendar: calendar
        )

        if now < scheduledForToday {
            return DailyRefreshScheduleDecision(
                dueSlot: nil,
                nextCheckAt: scheduledForToday
            )
        }

        if let lastClaimedAt,
           calendar.compare(lastClaimedAt, to: now, toGranularity: .day) != .orderedAscending {
            return DailyRefreshScheduleDecision(
                dueSlot: nil,
                nextCheckAt: scheduledForTomorrow
            )
        }

        return DailyRefreshScheduleDecision(
            dueSlot: DailyRefreshScheduleSlot(scheduledFor: scheduledForToday),
            nextCheckAt: scheduledForTomorrow
        )
    }

    private static func scheduledDate(
        on date: Date,
        minutesFromMidnight: Int,
        calendar: Calendar
    ) -> Date? {
        let normalizedMinutes = min(max(minutesFromMidnight, 0), (24 * 60) - 1)
        let startOfDay = calendar.startOfDay(for: date)
        let searchStart = calendar.date(byAdding: .second, value: -1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(-1)
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay
        let components = DateComponents(
            hour: normalizedMinutes / 60,
            minute: normalizedMinutes % 60,
            second: 0
        )
        let match = calendar.nextDate(
            after: searchStart,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
        guard let match, match >= startOfDay, match < nextDayStart else {
            return nil
        }
        return match
    }

    private static func nextDay(after date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay
    }
}

struct DailyRefreshScheduleClaim: Hashable, Sendable {
    let claimedAt: Date
    let scheduledFor: Date
    let refreshRatingsAndReviews: Bool
}

struct DailyRefreshClaimEvaluation: Hashable, Sendable {
    let claim: DailyRefreshScheduleClaim?
    let nextCheckAt: Date?
}

struct DailyRefreshScheduler: Sendable {
    private static let maximumSleepInterval: TimeInterval = 60 * 60

    typealias ClaimEvaluator = @Sendable (
        _ now: Date,
        _ calendar: Calendar
    ) async -> DailyRefreshClaimEvaluation
    typealias RefreshRunner = @Sendable (
        _ request: HeadlessRefreshRunRequest
    ) async -> HeadlessRefreshRunSummary
    typealias DateProvider = @Sendable () -> Date
    typealias CalendarProvider = @Sendable () -> Calendar
    typealias Sleeper = @Sendable (_ date: Date) async throws -> Void

    private let evaluateAndClaim: ClaimEvaluator
    private let runHeadlessRefresh: RefreshRunner
    private let now: DateProvider
    private let calendar: CalendarProvider
    private let sleepUntil: Sleeper

    init(
        evaluateAndClaim: @escaping ClaimEvaluator,
        runHeadlessRefresh: @escaping RefreshRunner,
        now: @escaping DateProvider = { .now },
        calendar: @escaping CalendarProvider = { .current },
        sleepUntil: @escaping Sleeper = Self.liveSleep
    ) {
        self.evaluateAndClaim = evaluateAndClaim
        self.runHeadlessRefresh = runHeadlessRefresh
        self.now = now
        self.calendar = calendar
        self.sleepUntil = sleepUntil
    }

    func run() async {
        while !Task.isCancelled {
            let evaluation = await evaluateAndClaim(now(), calendar())
            guard !Task.isCancelled else { return }

            if let claim = evaluation.claim {
                _ = await runHeadlessRefresh(HeadlessRefreshRunRequest(
                    scheduledFor: claim.scheduledFor,
                    refreshRatingsAndReviews: claim.refreshRatingsAndReviews
                ))
                guard !Task.isCancelled else { return }
            }

            guard let nextCheckAt = evaluation.nextCheckAt else { return }
            let wakeAt = min(
                nextCheckAt,
                now().addingTimeInterval(Self.maximumSleepInterval)
            )
            do {
                try await sleepUntil(wakeAt)
            } catch {
                return
            }
        }
    }

    private static func liveSleep(until date: Date) async throws {
        let seconds = max(0, date.timeIntervalSinceNow)
        let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
