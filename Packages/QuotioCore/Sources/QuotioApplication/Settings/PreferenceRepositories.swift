import QuotioDomain

public protocol OperatingModePreferencesRepository: Sendable {
    func load() -> OperatingModePreferences
    func save(_ preferences: OperatingModePreferences)
}

public protocol MenuBarPreferencesRepository: Sendable {
    func load() -> MenuBarPreferences
    func save(_ preferences: MenuBarPreferences)
}

public protocol RefreshPreferencesRepository: Sendable {
    func load() -> RefreshPreferences
    func save(_ preferences: RefreshPreferences)
}

public protocol WarmupPreferencesRepository: Sendable {
    func load() -> WarmupPreferences
    func save(_ preferences: WarmupPreferences)
}

public protocol AppearancePreferencesRepository: Sendable {
    func load() -> AppearancePreferences
    func save(_ preferences: AppearancePreferences)
}

public protocol LanguagePreferencesRepository: Sendable {
    func load() -> LanguagePreferences
    func save(_ preferences: LanguagePreferences)
}

public protocol UpdatePreferencesRepository: Sendable {
    func load() -> UpdatePreferences
    func save(_ preferences: UpdatePreferences)
}

public protocol TelemetryPreferencesRepository: Sendable {
    func load() -> TelemetryPreferences
    func save(_ preferences: TelemetryPreferences)
}

public protocol NotificationPreferencesRepository: Sendable {
    func load() -> NotificationPreferences
    func save(_ preferences: NotificationPreferences)
}

public protocol ProxyPreferencesRepository: Sendable {
    func load() -> ProxyPreferences
    func setAutoStartProxy(_ enabled: Bool)
    func setAllowNetworkAccess(_ enabled: Bool)
    func setLoggingToFile(_ enabled: Bool)
    func setProxyURL(_ proxyURL: String?)
}

public protocol TunnelPreferencesRepository: Sendable {
    func load() -> TunnelPreferences
    func setAutoStartTunnel(_ enabled: Bool)
    func setAutoRestartTunnel(_ enabled: Bool)
}

public protocol AppShellPreferencesRepository: Sendable {
    func load() -> AppShellPreferences
    func setAutomaticUpdateChecks(_ enabled: Bool)
    func setShowInDock(_ enabled: Bool)
    func setHideGettingStarted(_ hidden: Bool)
}
