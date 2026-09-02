import Foundation
import QuotioApplication
import QuotioDomain

public final class UserDefaultsOperatingModePreferencesRepository: OperatingModePreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> OperatingModePreferences {
        migrateLegacyModeIfNeeded()

        let stored = defaults.string(forKey: "operatingMode")
        let mode = stored.flatMap(OperatingMode.init(rawValue:)) ?? .monitor
        if let stored, stored != mode.rawValue {
            defaults.set(mode.rawValue, forKey: "operatingMode")
        }
        return OperatingModePreferences(
            mode: mode,
            hasCompletedOnboarding: defaults.bool(forKey: "hasCompletedOnboarding")
        )
    }

    public func save(_ preferences: OperatingModePreferences) {
        defaults.set(preferences.mode.rawValue, forKey: "operatingMode")
        defaults.set(preferences.hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
    }

    private func migrateLegacyModeIfNeeded() {
        guard defaults.string(forKey: "operatingMode") == nil,
              let appMode = defaults.string(forKey: "appMode") else { return }

        let mode = OperatingMode.fromLegacy(
            appModeRaw: appMode,
            connectionModeRaw: defaults.string(forKey: "connectionMode")
        )
        defaults.set(mode.rawValue, forKey: "operatingMode")
        defaults.set(true, forKey: "migratedToOperatingMode")
    }
}

public final class UserDefaultsMenuBarPreferencesRepository: MenuBarPreferencesRepository, @unchecked Sendable {
    public static let minimumItemCount = 1
    public static let maximumItemCount = 10
    public static let defaultItemCount = 3

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MenuBarPreferences {
        setDefault(true, forKey: "showMenuBarIcon")
        setDefault(true, forKey: "menuBarShowQuota")
        setDefault(Self.defaultItemCount, forKey: "menuBarMaxItems")
        setDefault(true, forKey: "menuBarStackClaudeQuotaWindows")

        let storedMaximum = defaults.integer(forKey: "menuBarMaxItems")
        let maximum = Self.clampItemCount(storedMaximum)
        if maximum != storedMaximum {
            defaults.set(maximum, forKey: "menuBarMaxItems")
        }

        let selectedItems = loadSelectedItems()
        return MenuBarPreferences(
            showMenuBarIcon: defaults.bool(forKey: "showMenuBarIcon"),
            showQuotaInMenuBar: defaults.bool(forKey: "menuBarShowQuota"),
            menuBarMaxItems: maximum,
            selectedItems: Array(selectedItems.prefix(maximum)),
            colorMode: MenuBarColorMode(rawValue: defaults.string(forKey: "menuBarColorMode") ?? "") ?? .colored,
            quotaDisplayMode: QuotaDisplayMode(rawValue: defaults.string(forKey: "quotaDisplayMode") ?? "") ?? .used,
            quotaDisplayStyle: QuotaDisplayStyle(rawValue: defaults.string(forKey: "quotaDisplayStyle") ?? "") ?? .card,
            stackPairedQuotaMetrics: defaults.bool(forKey: "menuBarStackClaudeQuotaWindows"),
            hideSensitiveInfo: defaults.bool(forKey: "hideSensitiveInfo"),
            totalUsageMode: TotalUsageMode(rawValue: defaults.string(forKey: "totalUsageMode") ?? "") ?? .sessionOnly,
            modelAggregationMode: ModelAggregationMode(rawValue: defaults.string(forKey: "modelAggregationMode") ?? "") ?? .lowest,
            hasUserModifiedMenuBar: defaults.bool(forKey: "hasUserModifiedMenuBar")
        )
    }

    public func save(_ preferences: MenuBarPreferences) {
        let maximum = Self.clampItemCount(preferences.menuBarMaxItems)
        defaults.set(preferences.showMenuBarIcon, forKey: "showMenuBarIcon")
        defaults.set(preferences.showQuotaInMenuBar, forKey: "menuBarShowQuota")
        defaults.set(maximum, forKey: "menuBarMaxItems")
        defaults.set(preferences.colorMode.rawValue, forKey: "menuBarColorMode")
        defaults.set(preferences.quotaDisplayMode.rawValue, forKey: "quotaDisplayMode")
        defaults.set(preferences.quotaDisplayStyle.rawValue, forKey: "quotaDisplayStyle")
        defaults.set(preferences.stackPairedQuotaMetrics, forKey: "menuBarStackClaudeQuotaWindows")
        defaults.set(preferences.hideSensitiveInfo, forKey: "hideSensitiveInfo")
        defaults.set(preferences.totalUsageMode.rawValue, forKey: "totalUsageMode")
        defaults.set(preferences.modelAggregationMode.rawValue, forKey: "modelAggregationMode")
        defaults.set(preferences.hasUserModifiedMenuBar, forKey: "hasUserModifiedMenuBar")
        if let data = try? JSONEncoder().encode(Array(preferences.selectedItems.prefix(maximum))) {
            defaults.set(data, forKey: "menuBarSelectedQuotaItems")
        }
    }

    private func setDefault(_ value: Any, forKey key: String) {
        if defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private func loadSelectedItems() -> [MenuBarQuotaItem] {
        guard let data = defaults.data(forKey: "menuBarSelectedQuotaItems"),
              let decoded = try? JSONDecoder().decode([MenuBarQuotaItem].self, from: data) else {
            return []
        }

        let current = decoded.filter { $0.provider != "gemini-cli" }
        if current != decoded, let migrated = try? JSONEncoder().encode(current) {
            defaults.set(migrated, forKey: "menuBarSelectedQuotaItems")
        }
        return current
    }

    private static func clampItemCount(_ value: Int) -> Int {
        min(max(value, minimumItemCount), maximumItemCount)
    }
}

public final class UserDefaultsRefreshPreferencesRepository: RefreshPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RefreshPreferences {
        RefreshPreferences(
            cadence: RefreshCadence(rawValue: defaults.string(forKey: "refreshCadence") ?? "") ?? .tenMinutes
        )
    }

    public func save(_ preferences: RefreshPreferences) {
        defaults.set(preferences.cadence.rawValue, forKey: "refreshCadence")
    }
}

public final class UserDefaultsWarmupPreferencesRepository: WarmupPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> WarmupPreferences {
        WarmupPreferences(
            enabledAccountIds: Set(defaults.stringArray(forKey: "warmupEnabledAccounts") ?? []),
            cadence: WarmupCadence(rawValue: defaults.string(forKey: "warmupCadence") ?? "") ?? .oneHour,
            scheduleMode: WarmupScheduleMode(rawValue: defaults.string(forKey: "warmupScheduleMode") ?? "") ?? .interval,
            dailyMinutes: loadDailyMinutes(),
            selectedModelsByAccount: decode([String: [String]].self, key: "warmupSelectedModels") ?? [:],
            cadenceByAccount: decode([String: String].self, key: "warmupCadenceByAccount") ?? [:],
            scheduleModeByAccount: decode([String: String].self, key: "warmupScheduleModeByAccount") ?? [:],
            dailyMinutesByAccount: decode([String: Int].self, key: "warmupDailyMinutesByAccount") ?? [:]
        )
    }

    public func save(_ preferences: WarmupPreferences) {
        defaults.set(preferences.enabledAccountIds.sorted(), forKey: "warmupEnabledAccounts")
        defaults.set(preferences.cadence.rawValue, forKey: "warmupCadence")
        defaults.set(preferences.scheduleMode.rawValue, forKey: "warmupScheduleMode")
        defaults.set(Self.clampMinutes(preferences.dailyMinutes), forKey: "warmupDailyMinutes")
        encode(preferences.selectedModelsByAccount, key: "warmupSelectedModels")
        encode(preferences.cadenceByAccount, key: "warmupCadenceByAccount")
        encode(preferences.scheduleModeByAccount, key: "warmupScheduleModeByAccount")
        encode(preferences.dailyMinutesByAccount, key: "warmupDailyMinutesByAccount")
    }

    private func loadDailyMinutes() -> Int {
        guard defaults.object(forKey: "warmupDailyMinutes") != nil else { return 540 }
        let stored = defaults.integer(forKey: "warmupDailyMinutes")
        let clamped = Self.clampMinutes(stored)
        if clamped != stored {
            defaults.set(clamped, forKey: "warmupDailyMinutes")
        }
        return clamped
    }

    private func decode<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func clampMinutes(_ value: Int) -> Int {
        min(max(value, 0), 1_439)
    }
}

public final class UserDefaultsAppearancePreferencesRepository: AppearancePreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppearancePreferences {
        AppearancePreferences(
            mode: AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        )
    }

    public func save(_ preferences: AppearancePreferences) {
        defaults.set(preferences.mode.rawValue, forKey: "appearanceMode")
    }
}

public final class UserDefaultsLanguagePreferencesRepository: LanguagePreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LanguagePreferences {
        let stored = defaults.string(forKey: "appLanguage") ?? AppLanguage.english.rawValue
        let migrated = stored == "zh" ? AppLanguage.chinese.rawValue : stored
        if migrated != stored {
            defaults.set(migrated, forKey: "appLanguage")
        }
        return LanguagePreferences(language: AppLanguage(rawValue: migrated) ?? .english)
    }

    public func save(_ preferences: LanguagePreferences) {
        defaults.set(preferences.language.rawValue, forKey: "appLanguage")
    }
}

public final class UserDefaultsUpdatePreferencesRepository: UpdatePreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> UpdatePreferences {
        UpdatePreferences(
            channel: UpdateChannel(rawValue: defaults.string(forKey: "updateChannel") ?? "") ?? .stable
        )
    }

    public func save(_ preferences: UpdatePreferences) {
        defaults.set(preferences.channel.rawValue, forKey: "updateChannel")
    }
}

public final class UserDefaultsTelemetryPreferencesRepository: TelemetryPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> TelemetryPreferences {
        TelemetryPreferences(
            shareAnonymousUsage: defaults.bool(forKey: "shareAnonymousUsage"),
            anonymousInstallID: defaults.string(forKey: "anonymousInstallID"),
            hasSentFirstOptInLaunch: defaults.bool(forKey: "telemetry.hasSentFirstOptInLaunch")
        )
    }

    public func save(_ preferences: TelemetryPreferences) {
        defaults.set(preferences.shareAnonymousUsage, forKey: "shareAnonymousUsage")
        if let anonymousInstallID = preferences.anonymousInstallID {
            defaults.set(anonymousInstallID, forKey: "anonymousInstallID")
        } else {
            defaults.removeObject(forKey: "anonymousInstallID")
        }
        defaults.set(preferences.hasSentFirstOptInLaunch, forKey: "telemetry.hasSentFirstOptInLaunch")
    }
}

public final class UserDefaultsNotificationPreferencesRepository: NotificationPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> NotificationPreferences {
        if defaults.object(forKey: "notificationsEnabled") == nil {
            defaults.set(true, forKey: "notificationsEnabled")
        }
        let threshold = defaults.double(forKey: "quotaAlertThreshold")
        return NotificationPreferences(
            notificationsEnabled: defaults.bool(forKey: "notificationsEnabled"),
            quotaAlertThreshold: threshold > 0 ? threshold : 20,
            notifyOnQuotaLow: defaults.object(forKey: "notifyOnQuotaLow") as? Bool ?? true,
            notifyOnCooling: defaults.object(forKey: "notifyOnCooling") as? Bool ?? true,
            notifyOnProxyCrash: defaults.object(forKey: "notifyOnProxyCrash") as? Bool ?? true,
            notifyOnUpgradeAvailable: defaults.object(forKey: "notifyOnUpgradeAvailable") as? Bool ?? true
        )
    }

    public func save(_ preferences: NotificationPreferences) {
        defaults.set(preferences.notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(preferences.quotaAlertThreshold, forKey: "quotaAlertThreshold")
        defaults.set(preferences.notifyOnQuotaLow, forKey: "notifyOnQuotaLow")
        defaults.set(preferences.notifyOnCooling, forKey: "notifyOnCooling")
        defaults.set(preferences.notifyOnProxyCrash, forKey: "notifyOnProxyCrash")
        defaults.set(preferences.notifyOnUpgradeAvailable, forKey: "notifyOnUpgradeAvailable")
    }
}

public final class UserDefaultsProxyPreferencesRepository: ProxyPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "loggingToFile": true,
        ])
    }

    public func load() -> ProxyPreferences {
        ProxyPreferences(
            autoStartProxy: defaults.bool(forKey: "autoStartProxy"),
            allowNetworkAccess: defaults.bool(forKey: "allowNetworkAccess"),
            loggingToFile: defaults.bool(forKey: "loggingToFile"),
            proxyURL: defaults.object(forKey: "proxyURL") == nil ? nil : defaults.string(forKey: "proxyURL")
        )
    }

    public func setAutoStartProxy(_ enabled: Bool) {
        defaults.set(enabled, forKey: "autoStartProxy")
    }

    public func setAllowNetworkAccess(_ enabled: Bool) {
        defaults.set(enabled, forKey: "allowNetworkAccess")
    }

    public func setLoggingToFile(_ enabled: Bool) {
        defaults.set(enabled, forKey: "loggingToFile")
    }

    public func setProxyURL(_ proxyURL: String?) {
        if let proxyURL {
            defaults.set(proxyURL, forKey: "proxyURL")
        } else {
            defaults.removeObject(forKey: "proxyURL")
        }
    }
}

public final class UserDefaultsTunnelPreferencesRepository: TunnelPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> TunnelPreferences {
        TunnelPreferences(
            autoStartTunnel: defaults.bool(forKey: "autoStartTunnel"),
            autoRestartTunnel: defaults.bool(forKey: "autoRestartTunnel")
        )
    }

    public func setAutoStartTunnel(_ enabled: Bool) {
        defaults.set(enabled, forKey: "autoStartTunnel")
    }

    public func setAutoRestartTunnel(_ enabled: Bool) {
        defaults.set(enabled, forKey: "autoRestartTunnel")
    }
}

public final class UserDefaultsAppShellPreferencesRepository: AppShellPreferencesRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "autoCheckUpdates": true,
            "showInDock": true,
        ])
    }

    public func load() -> AppShellPreferences {
        AppShellPreferences(
            autoCheckUpdates: defaults.bool(forKey: "autoCheckUpdates"),
            showInDock: defaults.bool(forKey: "showInDock"),
            hideGettingStarted: defaults.bool(forKey: "hideGettingStarted")
        )
    }

    public func setAutomaticUpdateChecks(_ enabled: Bool) {
        defaults.set(enabled, forKey: "autoCheckUpdates")
    }

    public func setShowInDock(_ enabled: Bool) {
        defaults.set(enabled, forKey: "showInDock")
    }

    public func setHideGettingStarted(_ hidden: Bool) {
        defaults.set(hidden, forKey: "hideGettingStarted")
    }
}
