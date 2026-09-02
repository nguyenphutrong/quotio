import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class SettingsScreenModel {
    public private(set) var proxyPreferences: ProxyPreferences
    public private(set) var tunnelPreferences: TunnelPreferences
    public private(set) var appShellPreferences: AppShellPreferences

    private let proxyRepository: any ProxyPreferencesRepository
    private let tunnelRepository: any TunnelPreferencesRepository
    private let appShellRepository: any AppShellPreferencesRepository
    private let applyNetworkAccess: (Bool) -> Void
    private let applyAutomaticUpdateChecks: (Bool) -> Void
    private let applyDockVisibility: (Bool) -> Void

    public init(
        proxyRepository: any ProxyPreferencesRepository,
        tunnelRepository: any TunnelPreferencesRepository,
        appShellRepository: any AppShellPreferencesRepository,
        applyNetworkAccess: @escaping (Bool) -> Void = { _ in },
        applyAutomaticUpdateChecks: @escaping (Bool) -> Void = { _ in },
        applyDockVisibility: @escaping (Bool) -> Void = { _ in }
    ) {
        self.proxyRepository = proxyRepository
        self.tunnelRepository = tunnelRepository
        self.appShellRepository = appShellRepository
        self.applyNetworkAccess = applyNetworkAccess
        self.applyAutomaticUpdateChecks = applyAutomaticUpdateChecks
        self.applyDockVisibility = applyDockVisibility
        self.proxyPreferences = proxyRepository.load()
        self.tunnelPreferences = tunnelRepository.load()
        self.appShellPreferences = appShellRepository.load()
    }

    public func setAutoStartProxy(_ enabled: Bool) {
        proxyPreferences.autoStartProxy = enabled
        proxyRepository.setAutoStartProxy(enabled)
    }

    public func setAutoStartTunnel(_ enabled: Bool) {
        tunnelPreferences.autoStartTunnel = enabled
        tunnelRepository.setAutoStartTunnel(enabled)
    }

    public func setAutoRestartTunnel(_ enabled: Bool) {
        tunnelPreferences.autoRestartTunnel = enabled
        tunnelRepository.setAutoRestartTunnel(enabled)
    }

    public func setAllowNetworkAccess(_ enabled: Bool) {
        applyNetworkAccess(enabled)
        proxyPreferences.allowNetworkAccess = enabled
        proxyRepository.setAllowNetworkAccess(enabled)
    }

    public func setAutomaticUpdateChecks(_ enabled: Bool) {
        applyAutomaticUpdateChecks(enabled)
        appShellPreferences.autoCheckUpdates = enabled
        appShellRepository.setAutomaticUpdateChecks(enabled)
    }

    public func setShowInDock(_ enabled: Bool) {
        applyDockVisibility(enabled)
        appShellPreferences.showInDock = enabled
        appShellRepository.setShowInDock(enabled)
    }

    public func setLoggingToFile(_ enabled: Bool) {
        proxyPreferences.loggingToFile = enabled
        proxyRepository.setLoggingToFile(enabled)
    }

    public func setHideGettingStarted(_ hidden: Bool) {
        appShellPreferences.hideGettingStarted = hidden
        appShellRepository.setHideGettingStarted(hidden)
    }

    public func setProxyURL(_ proxyURL: String?) {
        proxyPreferences.proxyURL = proxyURL
        proxyRepository.setProxyURL(proxyURL)
    }
}
