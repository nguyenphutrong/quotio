import AppKit
import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import QuotioPresentation

enum AppEnvironment {
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
enum CompositionRoot {
    static func makeProduction() -> AppRuntime {
        if !AppEnvironment.isRunningUnitTests {
            AppIdentity.migrateLegacyUserDefaults()
        }

        let viewModel = QuotaViewModel()
        let logRepository = QuotioInfrastructure.ManagementAPIClient(
            connectionProvider: { [proxyManager = viewModel.proxyManager] in
                await MainActor.run {
                    QuotioInfrastructure.ManagementAPIClient.Connection(
                        baseURL: proxyManager.managementURL,
                        authKey: proxyManager.managementKey
                    )
                }
            }
        )
        let logsScreenModel = LogsScreenModel(
            loadLogs: LoadProxyLogsUseCase(
                repository: logRepository,
                timeProvider: SystemDateProvider()
            ),
            clearLogs: ClearProxyLogsUseCase(repository: logRepository),
            sleeper: ContinuousSleeper()
        )
        let updaterService = UpdaterService.shared
        let settingsScreenModel = SettingsScreenModel(
            proxyRepository: UserDefaultsProxyPreferencesRepository(),
            tunnelRepository: UserDefaultsTunnelPreferencesRepository(),
            appShellRepository: UserDefaultsAppShellPreferencesRepository(),
            applyNetworkAccess: { [proxyManager = viewModel.proxyManager] enabled in
                proxyManager.allowNetworkAccess = enabled
            },
            applyAutomaticUpdateChecks: { [updaterService] enabled in
                updaterService.automaticallyChecksForUpdates = enabled
            },
            applyDockVisibility: { enabled in
                NSApp.setActivationPolicy(enabled ? .regular : .accessory)
            }
        )
        let services = LegacyAppRuntimeServices(
            viewModel: viewModel,
            logsScreenModel: logsScreenModel,
            settingsScreenModel: settingsScreenModel,
            modeManager: .shared,
            appearanceManager: .shared,
            statusBarManager: .shared,
            menuBarSettings: .shared,
            languageManager: .shared,
            refreshSettings: .shared,
            warmupSettings: .shared,
            ideScanSettings: .shared,
            launchAtLoginManager: .shared,
            notificationManager: .shared,
            telemetrySettings: .shared,
            telemetryService: .shared,
            updaterService: updaterService,
            updatePollingService: .shared,
            tunnelManager: .shared
        )
        return AppRuntime(services: services)
    }
}

@MainActor
private final class LegacyAppRuntimeServices: AppRuntimeServices {
    let viewModel: QuotaViewModel
    let logsScreenModel: LogsScreenModel
    let settingsScreenModel: SettingsScreenModel
    let modeManager: OperatingModeManager
    let appearanceManager: AppearanceManager
    let statusBarManager: StatusBarManager
    let menuBarSettings: MenuBarSettingsManager
    let languageManager: LanguageManager
    let refreshSettings: RefreshSettingsManager
    let warmupSettings: WarmupSettingsManager
    let ideScanSettings: IDEScanSettingsManager
    let launchAtLoginManager: LaunchAtLoginManager
    let updaterService: UpdaterService
    let notificationManager: NotificationManager
    let telemetrySettings: TelemetrySettings
    let updatePollingService: AtomFeedUpdateService

    private let telemetryService: TelemetryService
    private let tunnelManager: TunnelManager

    var hasCompletedOnboarding: Bool { modeManager.hasCompletedOnboarding }
    var showInDock: Bool { settingsScreenModel.appShellPreferences.showInDock }
    var canCheckForUpdates: Bool { updaterService.canCheckForUpdates }

    init(
        viewModel: QuotaViewModel,
        logsScreenModel: LogsScreenModel,
        settingsScreenModel: SettingsScreenModel,
        modeManager: OperatingModeManager,
        appearanceManager: AppearanceManager,
        statusBarManager: StatusBarManager,
        menuBarSettings: MenuBarSettingsManager,
        languageManager: LanguageManager,
        refreshSettings: RefreshSettingsManager,
        warmupSettings: WarmupSettingsManager,
        ideScanSettings: IDEScanSettingsManager,
        launchAtLoginManager: LaunchAtLoginManager,
        notificationManager: NotificationManager,
        telemetrySettings: TelemetrySettings,
        telemetryService: TelemetryService,
        updaterService: UpdaterService,
        updatePollingService: AtomFeedUpdateService,
        tunnelManager: TunnelManager
    ) {
        self.viewModel = viewModel
        self.logsScreenModel = logsScreenModel
        self.settingsScreenModel = settingsScreenModel
        self.modeManager = modeManager
        self.appearanceManager = appearanceManager
        self.statusBarManager = statusBarManager
        self.menuBarSettings = menuBarSettings
        self.languageManager = languageManager
        self.refreshSettings = refreshSettings
        self.warmupSettings = warmupSettings
        self.ideScanSettings = ideScanSettings
        self.launchAtLoginManager = launchAtLoginManager
        self.notificationManager = notificationManager
        self.telemetrySettings = telemetrySettings
        self.telemetryService = telemetryService
        self.updaterService = updaterService
        self.updatePollingService = updatePollingService
        self.tunnelManager = tunnelManager
    }

    func prepareForLaunch() {
        telemetryService.configureIfAllowed()
    }

    func applyAppearance() {
        appearanceManager.applyAppearance()
    }

    func loadDirectAuthFiles() async {
        await viewModel.loadDirectAuthFiles()
    }

    func connectStatusBar() {
        statusBarManager.setViewModel(viewModel)
    }

    func setQuotaDataChangeHandler(_ handler: (@MainActor () -> Void)?) {
        viewModel.quotaDataDidChangeHandler = handler
    }

    func updateStatusBar() {
        statusBarManager.updateStatusBar(
            items: quotaItems,
            colorMode: menuBarSettings.colorMode,
            quotaDisplayMode: menuBarSettings.quotaDisplayMode,
            isRunning: !viewModel.providerQuotas.isEmpty,
            showMenuBarIcon: menuBarSettings.showMenuBarIcon,
            showQuota: menuBarSettings.showQuotaInMenuBar
        )
    }

    func rebuildStatusBar() {
        statusBarManager.rebuildMenuInPlace()
    }

    func initializeFeatures() async {
        await viewModel.initialize()
    }

    func checkForUpdatesInBackground() {
        updaterService.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        updaterService.checkForUpdates()
    }

    func startUpdatePolling() {
        updatePollingService.startPolling { [viewModel] in
            viewModel.proxyManager.currentVersion ?? viewModel.proxyManager.installedProxyVersion
        }
    }

    func stopUpdatePolling() {
        updatePollingService.stopPolling()
    }

    func stopTunnel() async {
        await tunnelManager.stopTunnel()
    }

    nonisolated func terminateProxyOnShutdown() {
        CLIProxyManager.terminateProxyOnShutdown()
    }

    nonisolated func cleanupTunnelOrphans() {
        TunnelManager.cleanupOrphans()
    }

    private var quotaItems: [MenuBarQuotaDisplayItem] {
        guard menuBarSettings.showQuotaInMenuBar else { return [] }

        return menuBarSettings.selectedItems.compactMap { selectedItem in
            guard let provider = selectedItem.aiProvider else { return nil }

            var displayPercent: Double = -1
            var isForbidden = false
            var quotaPair: MenuBarQuotaPair?

            if let accountQuotas = viewModel.providerQuotas[provider],
               let quotaData = resolveQuotaData(
                   for: selectedItem,
                   provider: provider,
                   accountQuotas: accountQuotas
               ) {
                isForbidden = quotaData.isForbidden
                if !quotaData.models.isEmpty {
                    let models = quotaData.models.map { (name: $0.name, percentage: $0.percentage) }
                    displayPercent = menuBarSettings.totalUsagePercent(models: models)
                    if menuBarSettings.stackPairedQuotaMetrics {
                        quotaPair = MenuBarQuotaPair.resolve(for: provider, from: quotaData.models)
                    }
                }
            }

            return MenuBarQuotaDisplayItem(
                id: selectedItem.id,
                providerSymbol: provider.menuBarSymbol,
                accountShort: selectedItem.accountKey,
                percentage: displayPercent,
                provider: provider,
                isForbidden: isForbidden,
                quotaPair: quotaPair
            )
        }
    }

    private func resolveQuotaData(
        for selectedItem: MenuBarQuotaItem,
        provider: AIProvider,
        accountQuotas: [String: ProviderQuotaData]
    ) -> ProviderQuotaData? {
        if let quotaData = accountQuotas[selectedItem.accountKey] {
            return quotaData
        }

        let cleanKey = selectedItem.accountKey.hasSuffix(".json")
            ? String(selectedItem.accountKey.dropLast(".json".count))
            : selectedItem.accountKey
        if let quotaData = accountQuotas[cleanKey] {
            return quotaData
        }

        if provider == .codex {
            return accountQuotas[selectedItem.accountKey.codexFilenameKey]
        }
        if provider == .copilot, let filenameKey = selectedItem.accountKey.copilotFilenameKey {
            return accountQuotas[filenameKey]
        }
        return nil
    }
}
