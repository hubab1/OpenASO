import Foundation

enum BackgroundRefreshRuntime {
    static let argument = "--daily-refresh-once"
    static let dailyLockFileName = "daily-refresh.lock"

    @MainActor
    static func runOnce(
        defaults: UserDefaults = .openASOShared,
        namespace: AppNamespace = .current,
        now: Date = .now,
        calendar: Calendar = .current
    ) async -> Int32 {
        let lock = CrossProcessFileLock(
            namespace: namespace,
            fileName: dailyLockFileName
        )

        do {
            let attempt = try await lock.attempt {
                await runClaimedRefresh(
                    defaults: defaults,
                    namespace: namespace,
                    now: now,
                    calendar: calendar
                )
            }
            switch attempt {
            case .acquired(let exitCode):
                return exitCode
            case .unavailable:
                return 0
            }
        } catch {
            writeError("OpenASO background refresh lock failed: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    private static func runClaimedRefresh(
        defaults: UserDefaults,
        namespace: AppNamespace,
        now: Date,
        calendar: Calendar
    ) async -> Int32 {
        let settingsStore = AppSettingsStore(defaults: defaults)
        let evaluation = settingsStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )
        guard let claim = evaluation.claim else {
            return 0
        }

        do {
            let modelContainer = try ModelContainerFactory.makeModelContainer(
                isStoredInMemoryOnly: false,
                namespace: namespace
            )
            let services = AppServices.appLaunch(modelContainer: modelContainer)
            await services.prepareBackgroundModelStore()
            guard services.headlessRefreshService != nil else {
                throw OpenASOError.providerUnavailable(
                    "The automatic refresh service is unavailable."
                )
            }

            let summary = await services.runAutomaticHeadlessRefresh(
                HeadlessRefreshRunRequest(
                    scheduledFor: claim.scheduledFor,
                    refreshRatingsAndReviews: claim.refreshRatingsAndReviews
                )
            )
            settingsStore.recordBackgroundRefreshRun(
                BackgroundRefreshRunRecord(summary: summary)
            )
            switch summary.disposition {
            case .failure, .cancelled, .rejectedRequestConflict:
                return 1
            case .noWork, .success, .partialFailure, .skippedAlreadyRunning:
                return 0
            }
        } catch {
            let message = (error as? PersistentStoreError)?.diagnosticReport
                ?? OpenASOError.map(error).localizedDescription
            settingsStore.recordBackgroundRefreshRun(BackgroundRefreshRunRecord(
                scheduledFor: claim.scheduledFor,
                finishedAt: .now,
                disposition: .failure,
                issueMessage: message
            ))
            writeError("OpenASO background refresh failed: \(message)")
            return 1
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
