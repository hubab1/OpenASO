import Foundation
import Testing
@testable import OpenASO

@MainActor
struct AnalyticsServiceTests {
    @Test
    func settingsStoreUsesConfiguredAnalyticsDefaultAndPersistsChanges() {
        let defaults = UserDefaults(suiteName: "analytics-settings-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)

        #expect(store.isAnalyticsEnabled == AppSettingsStore.defaultIsAnalyticsEnabled)

        store.setAnalyticsEnabled(true)
        #expect(AppSettingsStore(defaults: defaults).isAnalyticsEnabled)

        store.setAnalyticsEnabled(false)
        #expect(!store.isAnalyticsEnabled)
        #expect(!AppSettingsStore(defaults: defaults).isAnalyticsEnabled)
    }

    @Test
    func settingsStorePersistsAndNormalizesMCPServerPort() {
        let defaults = UserDefaults(suiteName: "mcp-port-settings-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)

        #expect(store.mcpServerPort == MCPServerPort.defaultValue)

        store.saveMCPServerPort(52_345)
        #expect(AppSettingsStore(defaults: defaults).mcpServerPort == 52_345)

        store.saveMCPServerPort(1)
        #expect(store.mcpServerPort == MCPServerPort.minimum)
        #expect(AppSettingsStore(defaults: defaults).mcpServerPort == MCPServerPort.minimum)

        store.saveMCPServerPort(70_000)
        #expect(store.mcpServerPort == MCPServerPort.maximum)
        #expect(AppSettingsStore(defaults: defaults).mcpServerPort == MCPServerPort.maximum)
    }

    @Test
    func disabledAnalyticsNoOpsAndUpdatesOptOut() {
        let defaults = UserDefaults(suiteName: "analytics-disabled-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        let client = RecordingAnalyticsClient()
        let service = AnalyticsService(settingsStore: store, client: client)

        service.setAnalyticsEnabled(false)
        service.capture(.keywordDeleted(deleteCount: 3))

        #expect(client.optOutStates == [!AppSettingsStore.defaultIsAnalyticsEnabled, true])
        #expect(client.events.map(\.name) == [])
    }

    @Test
    func enabledAnalyticsCapturesEventsDirectly() {
        let defaults = UserDefaults(suiteName: "analytics-enabled-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        store.setAnalyticsEnabled(true)
        let client = RecordingAnalyticsClient()
        let service = AnalyticsService(settingsStore: store, client: client)

        service.capture(.keywordDeleted(deleteCount: 3))
        service.capture(AnalyticsEvent(name: "keyword_deleted", properties: ["keyword": "private"]))

        #expect(client.events.count == 2)
        #expect(client.events.first?.name == "keyword_deleted")
        #expect(client.events.first?.properties["delete_count_bucket"] as? String == "2-5")
        #expect(client.events.last?.properties["keyword"] as? String == "private")
    }

    @Test
    func enablingAnalyticsCapturesPreferenceChange() {
        let defaults = UserDefaults(suiteName: "analytics-preference-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        let client = RecordingAnalyticsClient()
        let service = AnalyticsService(settingsStore: store, client: client)

        service.setAnalyticsEnabled(true)

        #expect(client.optOutStates == [!AppSettingsStore.defaultIsAnalyticsEnabled, false])
        #expect(client.events.first?.name == "analytics_preference_changed")
        #expect(client.events.first?.properties["enabled"] as? Bool == true)
    }
}

@MainActor
private final class RecordingAnalyticsClient: AnalyticsClient {
    private(set) var events: [(name: String, properties: [String: Any])] = []
    private(set) var optOutStates: [Bool] = []

    func capture(name: String, properties: [String: Any]) {
        events.append((name, properties))
    }

    func setOptOut(_ isOptedOut: Bool) {
        optOutStates.append(isOptedOut)
    }
}
