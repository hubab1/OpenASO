import Foundation
import Security
import Testing
@testable import OpenASO

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BackgroundRefreshInfrastructureTests {
    @Test
    func enablingRegistersTheAgentAndPersistsItsVersion() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.notRegistered
        var registrationCount = 0
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { serviceStatus },
                register: {
                    registrationCount += 1
                    serviceStatus = .enabled
                },
                unregister: {
                    serviceStatus = .notRegistered
                },
                openSystemSettings: {}
            ),
            defaults: defaults,
            registrationVersion: "1-10"
        )

        await controller.reconcile(isEnabled: true)

        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.lastErrorMessage == nil)
        #expect(registrationCount == 1)

        await controller.reconcile(isEnabled: true)
        #expect(registrationCount == 1)
    }

    @Test
    func anAppUpdateReplacesTheRegisteredAgent() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.notRegistered
        var registrationCount = 0
        var unregistrationCount = 0
        let client = BackgroundRefreshAgentServiceClient(
            status: { serviceStatus },
            register: {
                registrationCount += 1
                serviceStatus = .enabled
            },
            unregister: {
                unregistrationCount += 1
                serviceStatus = .notRegistered
            },
            openSystemSettings: {}
        )

        let firstController = BackgroundRefreshAgentController(
            client: client,
            defaults: defaults,
            registrationVersion: "1-10"
        )
        await firstController.reconcile(isEnabled: true)

        let updatedController = BackgroundRefreshAgentController(
            client: client,
            defaults: defaults,
            registrationVersion: "1-11"
        )
        await updatedController.reconcile(isEnabled: true)

        #expect(updatedController.status == .enabled)
        #expect(registrationCount == 2)
        #expect(unregistrationCount == 1)
    }

    @Test
    func approvalStateIsExposedWithoutRepeatedRegistrationAttempts() async {
        let defaults = makeBackgroundRefreshDefaults()
        var registrationCount = 0
        var openedSettings = false
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { .requiresApproval },
                register: { registrationCount += 1 },
                unregister: {},
                openSystemSettings: { openedSettings = true }
            ),
            defaults: defaults,
            registrationVersion: "1-10"
        )

        await controller.reconcile(isEnabled: true)
        controller.openSystemSettings()

        #expect(controller.status == .requiresApproval)
        #expect(!controller.isEnabled)
        #expect(registrationCount == 0)
        #expect(openedSettings)
    }

    @Test
    func disablingUnregistersAnEnabledAgent() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.enabled
        var unregistrationCount = 0
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { serviceStatus },
                register: {},
                unregister: {
                    unregistrationCount += 1
                    serviceStatus = .notRegistered
                },
                openSystemSettings: {}
            ),
            defaults: defaults,
            registrationVersion: "1-10"
        )

        await controller.reconcile(isEnabled: false)

        #expect(controller.status == .notRegistered)
        #expect(unregistrationCount == 1)
    }

    @Test
    func automaticRefreshDefaultsToFiveAMAndPreservesSavedTimes() {
        let defaults = makeBackgroundRefreshDefaults()
        let newSettings = AppSettingsStore(defaults: defaults)

        #expect(newSettings.refreshHour == 5)
        #expect(newSettings.refreshMinute == 0)

        newSettings.saveRefreshTime(hour: 8, minute: 45)
        let reloadedSettings = AppSettingsStore(defaults: defaults)
        #expect(reloadedSettings.refreshHour == 8)
        #expect(reloadedSettings.refreshMinute == 45)
    }

    @Test
    func backgroundRunResultCanBeReadByANewSettingsStore() {
        let defaults = makeBackgroundRefreshDefaults()
        let scheduledFor = Date(timeIntervalSince1970: 1_800_000_000)
        let finishedAt = scheduledFor.addingTimeInterval(42)
        let record = BackgroundRefreshRunRecord(
            scheduledFor: scheduledFor,
            finishedAt: finishedAt,
            disposition: .failure,
            issueMessage: "Offline"
        )

        AppSettingsStore(defaults: defaults).recordBackgroundRefreshRun(record)
        let reloadedSettings = AppSettingsStore(defaults: defaults)

        #expect(reloadedSettings.lastBackgroundRefreshRun == record)
    }

    @Test
    func oneShotRuntimeClaimsRunsAndCoalescesTheDay() async throws {
        let defaults = makeBackgroundRefreshDefaults()
        let uniqueIdentifier = "background.refresh.runtime.tests.\(UUID().uuidString)"
        let namespace = AppNamespace(bundleIdentifier: uniqueIdentifier)
        let applicationSupportURL = try namespace.applicationSupportDirectoryURL()
        let containerURL = applicationSupportURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 8,
            hour: 6
        )))

        let firstExitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: now,
            calendar: calendar
        )
        let settingsAfterFirstRun = AppSettingsStore(defaults: defaults)
        let secondExitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: now.addingTimeInterval(60),
            calendar: calendar
        )

        #expect(firstExitCode == 0)
        #expect(secondExitCode == 0)
        #expect(settingsAfterFirstRun.hasClaimedAutomaticRefresh(on: now, calendar: calendar))
        #expect(settingsAfterFirstRun.lastBackgroundRefreshRun?.disposition
            == HeadlessRefreshRunDisposition.noWork.rawValue)
    }

    @Test
    func keychainReadsTheDataProtectionKeychainBeforeLegacyStorage() {
        var queries: [[String: Any]] = []
        let keychain = SystemKeychainService(copyMatching: { query, _ in
            queries.append(query as NSDictionary as! [String: Any])
            return errSecItemNotFound
        })

        #expect(keychain.readData(service: "service", account: "account") == .notFound)
        #expect(queries.count == 2)
        #expect(queries.first?[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(queries.last?[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test
    func crossProcessLockRejectsAConcurrentAttempt() async throws {
        let uniqueIdentifier = "background.refresh.lock.tests.\(UUID().uuidString)"
        let namespace = AppNamespace(bundleIdentifier: uniqueIdentifier)
        let applicationSupportURL = try namespace.applicationSupportDirectoryURL()
        let containerURL = applicationSupportURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }

        let lock = CrossProcessFileLock(namespace: namespace, fileName: "daily.lock")
        let gate = BackgroundRefreshLockGate()
        let firstAttempt = Task {
            try await lock.attempt {
                await gate.hold()
                return "first"
            }
        }

        await gate.waitUntilHeld()
        let concurrentAttempt = try await lock.attempt { "second" }
        switch concurrentAttempt {
        case .acquired:
            Issue.record("A second attempt acquired a lock that was already held")
        case .unavailable:
            break
        }

        await gate.release()
        let firstResult = try await firstAttempt.value
        switch firstResult {
        case .acquired(let value):
            #expect(value == "first")
        case .unavailable:
            Issue.record("The first attempt did not acquire the lock")
        }

        let laterAttempt = try await lock.attempt { "later" }
        switch laterAttempt {
        case .acquired(let value):
            #expect(value == "later")
        case .unavailable:
            Issue.record("The lock was not released after the first operation")
        }
    }
}

private actor BackgroundRefreshLockGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        let waiters = heldWaiters
        heldWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { continuation in
            heldWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func makeBackgroundRefreshDefaults() -> UserDefaults {
    let suiteName = "background.refresh.infrastructure.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
