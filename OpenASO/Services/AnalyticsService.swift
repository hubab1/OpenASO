import Foundation
import Observation

#if canImport(PostHog)
  import PostHog
#endif

enum MCPServerPort {
  static let defaultValue = 51626
  static let minimum = 1_024
  static let maximum = 65_535
}

@MainActor
@Observable
final class AppSettingsStore {
  private enum DefaultsKey {
    static let isAnalyticsEnabled = "analytics.isAnalyticsEnabled"
    static let popularityContextAppStoreID = "appleAds.popularityContextAppStoreID"
    static let popularityContextStorefrontCode = "appleAds.popularityContextStorefrontCode"
    static let isAutomaticRefreshEnabled = "dailyRefresh.isAutomaticRefreshEnabled"
    static let refreshTimeMinutes = "dailyRefresh.timeMinutes"
    static let lastRefreshTriggeredAt = "dailyRefresh.lastTriggeredAt"
    static let lastRatingsReviewsRefreshAt = "dailyRefresh.lastRatingsReviewsRefreshAt"
    static let mcpServerPort = "mcp.serverPort"
  }

  static let defaultIsAnalyticsEnabled = true
  static let defaultIsAutomaticRefreshEnabled = true
  static let defaultRefreshTimeMinutes = 7 * 60

  private let defaults: UserDefaults

  private(set) var isAnalyticsEnabled: Bool
  private(set) var popularityContextAppStoreID: Int64?
  private(set) var popularityContextStorefrontCode: String?
  private(set) var isAutomaticRefreshEnabled: Bool
  private(set) var refreshTimeMinutes: Int
  private(set) var lastRefreshTriggeredAt: Date?
  private(set) var lastRatingsReviewsRefreshAt: Date?
  private(set) var mcpServerPort: Int
  var requestedSettingsFocusSection: AppleAdsSettingsFocusSection?

  init(defaults: UserDefaults = .openASOShared) {
    self.defaults = defaults
    let storedValue = defaults.object(forKey: DefaultsKey.isAnalyticsEnabled) as? Bool
    let storedPopularityContextAppStoreID = defaults.string(
      forKey: DefaultsKey.popularityContextAppStoreID)
    let storedPopularityContextStorefrontCode = defaults.string(
      forKey: DefaultsKey.popularityContextStorefrontCode)
    let storedIsEnabled = defaults.object(forKey: DefaultsKey.isAutomaticRefreshEnabled) as? Bool
    let storedMinutes = defaults.object(forKey: DefaultsKey.refreshTimeMinutes) as? Int
    let storedMCPServerPort = defaults.object(forKey: DefaultsKey.mcpServerPort) as? Int
    self.isAnalyticsEnabled = storedValue ?? Self.defaultIsAnalyticsEnabled
    self.popularityContextAppStoreID = storedPopularityContextAppStoreID.flatMap(Int64.init)
    self.popularityContextStorefrontCode = Self.normalizedStorefrontCode(
      storedPopularityContextStorefrontCode)
    self.isAutomaticRefreshEnabled = storedIsEnabled ?? Self.defaultIsAutomaticRefreshEnabled
    self.refreshTimeMinutes = Self.normalized(
      minutes: storedMinutes ?? Self.defaultRefreshTimeMinutes)
    self.lastRefreshTriggeredAt =
      defaults.object(forKey: DefaultsKey.lastRefreshTriggeredAt) as? Date
    self.lastRatingsReviewsRefreshAt =
      defaults.object(forKey: DefaultsKey.lastRatingsReviewsRefreshAt) as? Date
    self.mcpServerPort = Self.normalizedMCPServerPort(storedMCPServerPort)
    self.requestedSettingsFocusSection = nil
  }

  func requestSettingsFocus(_ section: AppleAdsSettingsFocusSection) {
    requestedSettingsFocusSection = section
  }

  func clearSettingsFocusRequest() {
    requestedSettingsFocusSection = nil
  }

  func setAnalyticsEnabled(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: DefaultsKey.isAnalyticsEnabled)
    isAnalyticsEnabled = isEnabled
  }

  func savePopularityContextAppStoreID(_ appStoreID: Int64) {
    defaults.set(String(appStoreID), forKey: DefaultsKey.popularityContextAppStoreID)
    popularityContextAppStoreID = appStoreID
  }

  func savePopularityContext(appStoreID: Int64, storefrontCode: String?) {
    savePopularityContextAppStoreID(appStoreID)
    if let storefrontCode = Self.normalizedStorefrontCode(storefrontCode) {
      defaults.set(storefrontCode, forKey: DefaultsKey.popularityContextStorefrontCode)
      popularityContextStorefrontCode = storefrontCode
    } else {
      defaults.removeObject(forKey: DefaultsKey.popularityContextStorefrontCode)
      popularityContextStorefrontCode = nil
    }
  }

  func clearPopularityContextAppStoreID() {
    defaults.removeObject(forKey: DefaultsKey.popularityContextAppStoreID)
    defaults.removeObject(forKey: DefaultsKey.popularityContextStorefrontCode)
    popularityContextAppStoreID = nil
    popularityContextStorefrontCode = nil
  }

  var scheduleConfiguration: DailyRefreshScheduleConfiguration {
    DailyRefreshScheduleConfiguration(
      isAutomaticRefreshEnabled: isAutomaticRefreshEnabled,
      refreshTimeMinutes: refreshTimeMinutes
    )
  }

  var refreshHour: Int {
    refreshTimeMinutes / 60
  }

  var refreshMinute: Int {
    refreshTimeMinutes % 60
  }

  func setAutomaticRefreshEnabled(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: DefaultsKey.isAutomaticRefreshEnabled)
    isAutomaticRefreshEnabled = isEnabled
  }

  func saveRefreshTime(hour: Int, minute: Int) {
    let minutes = Self.normalized(minutes: hour * 60 + minute)
    defaults.set(minutes, forKey: DefaultsKey.refreshTimeMinutes)
    refreshTimeMinutes = minutes
  }

  func saveRefreshTime(from date: Date, calendar: Calendar = .current) {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    saveRefreshTime(hour: components.hour ?? 7, minute: components.minute ?? 0)
  }

  func refreshTimeDate(relativeTo referenceDate: Date = .now, calendar: Calendar = .current) -> Date
  {
    scheduledRefreshDate(on: referenceDate, calendar: calendar)
  }

  func shouldTriggerRefresh(at date: Date, calendar: Calendar = .current) -> Bool {
    guard isAutomaticRefreshEnabled else {
      return false
    }

    guard !hasTriggeredRefresh(on: date, calendar: calendar) else {
      return false
    }

    return date >= scheduledRefreshDate(on: date, calendar: calendar)
  }

  func hasTriggeredRefresh(on date: Date, calendar: Calendar = .current) -> Bool {
    guard let lastRefreshTriggeredAt else {
      return false
    }

    return calendar.isDate(lastRefreshTriggeredAt, inSameDayAs: date)
  }

  func markRefreshTriggered(on date: Date = .now) {
    defaults.set(date, forKey: DefaultsKey.lastRefreshTriggeredAt)
    lastRefreshTriggeredAt = date
  }

  func hasRefreshedRatingsReviews(on date: Date, calendar: Calendar = .current) -> Bool {
    guard let lastRatingsReviewsRefreshAt else {
      return false
    }

    return calendar.isDate(lastRatingsReviewsRefreshAt, inSameDayAs: date)
  }

  func markRatingsReviewsRefreshed(on date: Date = .now) {
    defaults.set(date, forKey: DefaultsKey.lastRatingsReviewsRefreshAt)
    lastRatingsReviewsRefreshAt = date
  }

  func saveMCPServerPort(_ port: Int) {
    let normalizedPort = Self.normalizedMCPServerPort(port)
    defaults.set(normalizedPort, forKey: DefaultsKey.mcpServerPort)
    mcpServerPort = normalizedPort
  }

  func nextRefreshCheckDate(after date: Date, calendar: Calendar = .current) -> Date {
    guard isAutomaticRefreshEnabled else {
      return calendar.date(byAdding: .day, value: 1, to: date)
        ?? date.addingTimeInterval(60 * 60 * 24)
    }

    let todayScheduledDate = scheduledRefreshDate(on: date, calendar: calendar)
    if date < todayScheduledDate, !hasTriggeredRefresh(on: date, calendar: calendar) {
      return todayScheduledDate
    }

    let tomorrow =
      calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(60 * 60 * 24)
    return scheduledRefreshDate(on: tomorrow, calendar: calendar)
  }

  private func scheduledRefreshDate(on date: Date, calendar: Calendar) -> Date {
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = refreshHour
    components.minute = refreshMinute
    components.second = 0
    return calendar.date(from: components) ?? date
  }

  private static func normalized(minutes: Int) -> Int {
    min(max(minutes, 0), (24 * 60) - 1)
  }

  private static func normalizedMCPServerPort(_ port: Int?) -> Int {
    guard let port else {
      return MCPServerPort.defaultValue
    }

    return min(max(port, MCPServerPort.minimum), MCPServerPort.maximum)
  }

  private static func normalizedStorefrontCode(_ storefrontCode: String?) -> String? {
    guard let storefrontCode = storefrontCode?.trimmingCharacters(in: .whitespacesAndNewlines),
      !storefrontCode.isEmpty
    else {
      return nil
    }

    return storefrontCode.uppercased()
  }
}

@MainActor
protocol AnalyticsClient: AnyObject {
  func capture(name: String, properties: [String: Any])
  func setOptOut(_ isOptedOut: Bool)
}

@MainActor
final class AnalyticsService: Sendable {
  nonisolated static let schemaVersion = 1

  let settingsStore: AppSettingsStore
  private let client: any AnalyticsClient

  init(
    settingsStore: AppSettingsStore,
    client: (any AnalyticsClient)? = nil
  ) {
    self.settingsStore = settingsStore
    self.client = client ?? PostHogAnalyticsClient(settingsStore: settingsStore)
    self.client.setOptOut(!settingsStore.isAnalyticsEnabled)
  }

  func capture(_ event: AnalyticsEvent) {
    guard settingsStore.isAnalyticsEnabled else { return }
    client.capture(name: event.name, properties: event.properties)
  }

  func setAnalyticsEnabled(_ isEnabled: Bool) {
    settingsStore.setAnalyticsEnabled(isEnabled)
    client.setOptOut(!isEnabled)
    capture(.analyticsPreferenceChanged(enabled: isEnabled))
  }
}

struct AnalyticsEvent {
  let name: String
  let properties: [String: Any]
}

enum AnalyticsCountBucket: String {
  case zero = "0"
  case one = "1"
  case twoToFive = "2-5"
  case sixToTwenty = "6-20"
  case twentyOneToOneHundred = "21-100"
  case oneHundredOnePlus = "101+"

  init(_ count: Int) {
    switch count {
    case ...0:
      self = .zero
    case 1:
      self = .one
    case 2...5:
      self = .twoToFive
    case 6...20:
      self = .sixToTwenty
    case 21...100:
      self = .twentyOneToOneHundred
    default:
      self = .oneHundredOnePlus
    }
  }
}

extension AnalyticsEvent {
  static func appLaunched() -> AnalyticsEvent {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info["CFBundleVersion"] as? String ?? "unknown"
    let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return AnalyticsEvent(
      name: "app_launched",
      properties: [
        "app_version": version,
        "build_number": build,
        "os_major": osMajor,
        "analytics_schema_version": AnalyticsService.schemaVersion,
      ]
    )
  }

  static func analyticsPreferenceChanged(enabled: Bool) -> AnalyticsEvent {
    AnalyticsEvent(name: "analytics_preference_changed", properties: ["enabled": enabled])
  }

  static func trackedAppAdded(platform: AppPlatform, source: String) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "tracked_app_added", properties: ["platform": platform.rawValue, "source": source])
  }

  static func trackedAppRemoved(keywordCount: Int) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "tracked_app_removed",
      properties: ["keyword_count_bucket": AnalyticsCountBucket(keywordCount).rawValue])
  }

  static func workspaceViewed(_ workspace: AppDetailWorkspaceView) -> AnalyticsEvent {
    AnalyticsEvent(name: "workspace_viewed", properties: ["workspace": workspace.rawValue])
  }

  static func keywordAdded(keywordCount: Int, storefrontCount: Int) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "keyword_added",
      properties: [
        "keyword_count_bucket": AnalyticsCountBucket(keywordCount).rawValue,
        "storefront_count_bucket": AnalyticsCountBucket(storefrontCount).rawValue,
      ]
    )
  }

  static func keywordDeleted(deleteCount: Int) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "keyword_deleted",
      properties: ["delete_count_bucket": AnalyticsCountBucket(deleteCount).rawValue])
  }

  static func keywordRefreshStarted(trigger: String, trackCount: Int) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "keyword_refresh_started",
      properties: [
        "trigger": trigger, "track_count_bucket": AnalyticsCountBucket(trackCount).rawValue,
      ]
    )
  }

  static func keywordRefreshCompleted(trigger: String, trackCount: Int, failureCount: Int)
    -> AnalyticsEvent
  {
    AnalyticsEvent(
      name: "keyword_refresh_completed",
      properties: [
        "trigger": trigger,
        "track_count_bucket": AnalyticsCountBucket(trackCount).rawValue,
        "failure_count_bucket": AnalyticsCountBucket(failureCount).rawValue,
      ]
    )
  }

  static func ratingsRefreshStarted(trigger: String, storefrontScope: String) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "ratings_refresh_started",
      properties: ["trigger": trigger, "storefront_scope": storefrontScope])
  }

  static func ratingsRefreshCompleted(trigger: String, storefrontScope: String, failureCount: Int)
    -> AnalyticsEvent
  {
    AnalyticsEvent(
      name: "ratings_refresh_completed",
      properties: [
        "trigger": trigger,
        "storefront_scope": storefrontScope,
        "failure_count_bucket": AnalyticsCountBucket(failureCount).rawValue,
      ]
    )
  }

  static func reviewTranslated(sourceLanguageKnown: Bool, result: String) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "review_translated",
      properties: ["source_language_known": sourceLanguageKnown, "result": result]
    )
  }

  static func reviewReplySent(result: String) -> AnalyticsEvent {
    AnalyticsEvent(name: "review_reply_sent", properties: ["result": result])
  }

  static func csvExported(type: String) -> AnalyticsEvent {
    AnalyticsEvent(name: "csv_exported", properties: ["export_type": type])
  }

  static func csvImported(rowCount: Int, result: String) -> AnalyticsEvent {
    AnalyticsEvent(
      name: "csv_imported",
      properties: ["row_count_bucket": AnalyticsCountBucket(rowCount).rawValue, "result": result]
    )
  }

  static func settingsOpened(focusSection: String) -> AnalyticsEvent {
    AnalyticsEvent(name: "settings_opened", properties: ["focus_section": focusSection])
  }
}

@MainActor
final class NoOpAnalyticsClient: AnalyticsClient {
  init() {}
  init(settingsStore: AppSettingsStore) {}

  func capture(name: String, properties: [String: Any]) {}
  func setOptOut(_ isOptedOut: Bool) {}
}

#if canImport(PostHog)
  @MainActor
  final class PostHogAnalyticsClient: AnalyticsClient {
    private var isConfigured = false

    init(settingsStore: AppSettingsStore) {
      guard let token = Self.configurationValue(for: "POSTHOG_PROJECT_TOKEN"), !token.isEmpty else {
        return
      }

      let host = Self.configurationValue(for: "POSTHOG_HOST") ?? PostHogConfig.defaultHost
      let config = PostHogConfig(projectToken: token, host: host)
      config.captureApplicationLifecycleEvents = false
      config.captureScreenViews = false
      config.enableSwizzling = false
      config.sendFeatureFlagEvent = false
      config.preloadFeatureFlags = false
      config.setDefaultPersonProperties = false
      config.personProfiles = .identifiedOnly
      config.optOut = !settingsStore.isAnalyticsEnabled
      config.errorTrackingConfig.autoCapture = false
      #if os(iOS) || targetEnvironment(macCatalyst)
        config.captureElementInteractions = false
        config.rageClickConfig.enabled = false
      #endif
      #if os(iOS)
        config.sessionReplay = false
        if #available(iOS 15.0, *) {
          config.surveys = false
        }
      #endif
      PostHogSDK.shared.setup(config)
      isConfigured = true
    }

    func capture(name: String, properties: [String: Any]) {
      guard isConfigured else { return }
      PostHogSDK.shared.capture(name, properties: properties)
    }

    func setOptOut(_ isOptedOut: Bool) {
      guard isConfigured else { return }
      if isOptedOut {
        PostHogSDK.shared.optOut()
      } else {
        PostHogSDK.shared.optIn()
      }
    }

    private static func configurationValue(for key: String) -> String? {
      if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }

      let environmentValue = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      return environmentValue?.isEmpty == false ? environmentValue : nil
    }
  }
#else
  typealias PostHogAnalyticsClient = NoOpAnalyticsClient
#endif
