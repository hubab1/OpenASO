import Foundation
import Observation
import ServiceManagement

enum BackgroundRefreshAgentStatus: String, Hashable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

@MainActor
struct BackgroundRefreshAgentServiceClient {
    let status: () -> BackgroundRefreshAgentStatus
    let register: () throws -> Void
    let unregister: () async throws -> Void
    let openSystemSettings: () -> Void

    static func live(plistName: String) -> Self {
        let service = SMAppService.agent(plistName: plistName)
        return Self(
            status: {
                switch service.status {
                case .enabled:
                    .enabled
                case .requiresApproval:
                    .requiresApproval
                case .notFound:
                    .notFound
                case .notRegistered:
                    .notRegistered
                @unknown default:
                    .notFound
                }
            },
            register: {
                try service.register()
            },
            unregister: {
                try await withCheckedThrowingContinuation { continuation in
                    service.unregister { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            },
            openSystemSettings: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }
}

struct InAppDailyRefreshConfiguration: Hashable, Sendable {
    let schedule: DailyRefreshScheduleConfiguration
    let agentStatus: BackgroundRefreshAgentStatus
}

@MainActor
@Observable
final class BackgroundRefreshAgentController {
    private enum DefaultsKey {
        static let registeredVersion = "dailyRefresh.agentRegisteredVersion"
    }

    private let client: BackgroundRefreshAgentServiceClient
    private let defaults: UserDefaults
    private let registrationVersion: String

    private(set) var status: BackgroundRefreshAgentStatus
    private(set) var isReconciling = false
    private(set) var lastErrorMessage: String?

    var isEnabled: Bool {
        status == .enabled
    }

    convenience init(
        defaults: UserDefaults = .openASOShared,
        bundle: Bundle = .main
    ) {
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.thirdtech.openaso"
        let plistName = "\(bundleIdentifier).refresh-agent.plist"
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "0"
        self.init(
            client: .live(plistName: plistName),
            defaults: defaults,
            registrationVersion: "\(shortVersion)-\(buildVersion)"
        )
    }

    init(
        client: BackgroundRefreshAgentServiceClient,
        defaults: UserDefaults,
        registrationVersion: String
    ) {
        self.client = client
        self.defaults = defaults
        self.registrationVersion = registrationVersion
        status = client.status()
    }

    func refreshStatus() {
        status = client.status()
    }

    func reconcile(isEnabled: Bool) async {
        guard !isReconciling else { return }
        isReconciling = true
        lastErrorMessage = nil
        defer {
            refreshStatus()
            isReconciling = false
        }

        do {
            refreshStatus()
            if !isEnabled {
                if status == .enabled || status == .requiresApproval {
                    try await client.unregister()
                }
                defaults.removeObject(forKey: DefaultsKey.registeredVersion)
                return
            }

            let savedVersion = defaults.string(forKey: DefaultsKey.registeredVersion)
            if status == .enabled, savedVersion == registrationVersion {
                return
            }

            if status == .enabled {
                try await client.unregister()
            }

            refreshStatus()
            if status == .notRegistered || status == .notFound {
                try client.register()
                defaults.set(registrationVersion, forKey: DefaultsKey.registeredVersion)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func openSystemSettings() {
        client.openSystemSettings()
    }
}
