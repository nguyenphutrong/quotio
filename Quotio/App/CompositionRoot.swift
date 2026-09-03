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

        let customProviderRepository = UserDefaultsCustomProviderRepository()
        let customProviderTransport = URLSessionCustomProviderTransport()
        let customProviderService = QuotioApplication.CustomProviderService(
            repository: customProviderRepository,
            discovery: customProviderTransport,
            connectionTester: customProviderTransport,
            configurationSynchronizer: FileCustomProviderConfigurationSynchronizer()
        )
        let paths = FileProxyConfigurationRepository.defaultPaths()
        let configurationRepository = FileProxyConfigurationRepository(paths: paths)
        let proxyScreenModel = ProxyScreenModel(
            controller: ProxyLifecycleController(
                paths: paths,
                processController: ProxyProcessController(),
                versionRepository: FileProxyVersionRepository(),
                releaseRepository: GitHubProxyReleaseRepository(),
                updateFeed: LegacyProxyUpdateFeed(service: .shared),
                configurationRepository: configurationRepository,
                binaryDownloader: URLSessionProxyBinaryDownloader(),
                checksumVerifier: SHA256ProxyChecksumVerifier(),
                managementChecker: LocalProxyManagementClient(),
                metadataRepository: UserDefaultsProxyRuntimeMetadataRepository(),
                preferencesRepository: UserDefaultsProxyPreferencesRepository(),
                keyVault: LegacyProxyManagementKeyVault(),
                configurationSupplement: CustomProviderConfigurationSupplement(
                    service: customProviderService
                ),
                notificationDelivery: LegacyProxyNotificationDelivery(service: .shared),
                sleeper: ContinuousSleeper(),
                dateProvider: SystemDateProvider(),
                installedVersionLimit: AppConstants.maxInstalledVersions
            ),
            initialState: ProxySnapshot(
                status: ProxyStatus(
                    port: UserDefaultsProxyRuntimeMetadataRepository().loadPort()
                ),
                paths: paths
            )
        )

        let authFileRepository = FileAuthFileRepository()
        let directAuthService = DirectAuthFileService(repository: authFileRepository)
        let metadataRepository = MonitorAccountMigrationBridge.metadataRepository
        let credentialVault = MonitorAccountMigrationBridge.credentialVault
        let accountDiscovery = MonitorAccountDiscovery(
            vault: credentialVault,
            directAuthService: directAuthService,
            metadata: MonitorMetadataStore(repository: metadataRepository),
            externalCredentials: ExternalKeychainCredentialReader()
        )
        let accountService = AccountService(
            discovery: accountDiscovery,
            metadataRepository: metadataRepository,
            credentialVault: credentialVault,
            reservedLabels: [
                AccountProviderID(rawValue: AIProvider.amp.rawValue): [AmpQuotaFetcher.localAccountKey],
            ]
        )
        let accountsScreenModel = AccountsScreenModel(
            accountService: accountService,
            authFileRepository: authFileRepository
        )

        let urlOpener = WorkspaceURLOpener()
        let monitorAuthorizer = MonitorOAuthAuthorizer(
            vault: credentialVault,
            urlOpener: urlOpener,
            callbackTransport: LoopbackOAuthCallbackTransport(),
            httpTransport: URLSessionOAuthHTTPTransport()
        ) { accessToken, expiresAt, clientID, clientSecret, region in
            await KiroQuotaFetcher().authenticatedAccountIdentity(
                accessToken: accessToken,
                expiresAt: expiresAt,
                clientID: clientID,
                clientSecret: clientSecret,
                region: region
            )
        }
        let localProxyAuthorizer = LocalProxyOAuthAuthorizer(
            proxy: proxyScreenModel,
            authService: LegacyProxyAuthService(proxy: proxyScreenModel),
            authFiles: authFileRepository,
            urlOpener: urlOpener
        ) {
            await KiroQuotaFetcher().refreshAllTokensIfNeeded()
        }
        let modeManager = OperatingModeManager.shared
        let authorizer = OperatingModeOAuthAuthorizer(
            monitor: monitorAuthorizer,
            localProxy: localProxyAuthorizer
        ) {
            await MainActor.run { modeManager.isMonitorMode }
        }
        let oauthScreenModel = OAuthScreenModel(
            controller: OAuthFlowController(authorizer: authorizer)
        )

        let factoryDroidCredentials = LocalFactoryDroidCredentialStore()
        let registry = QuotaProviderRegistry([
            QuotioInfrastructure.ClaudeQuotaFetcher(
                credentials: CompositeClaudeQuotaCredentialLoader(
                    vault: credentialVault,
                    metadata: metadataRepository
                )
            ),
            QuotioInfrastructure.CodexQuotaFetcher(
                credentials: CompositeCodexQuotaCredentialLoader(
                    vault: credentialVault,
                    metadata: metadataRepository
                )
            ),
            QuotioInfrastructure.AntigravityQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository,
                nativeCredentials: NativeAntigravityCredentialReader()
            ),
            QuotioInfrastructure.CopilotQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository
            ),
            QuotioInfrastructure.KiroQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository
            ),
            QuotioInfrastructure.CursorQuotaFetcher(),
            QuotioInfrastructure.TraeQuotaFetcher(),
            QuotioInfrastructure.FactoryDroidQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository,
                localCredentials: factoryDroidCredentials,
                credentialWriter: factoryDroidCredentials
            ),
            QuotioInfrastructure.GLMQuotaFetcher(repository: customProviderRepository),
            QuotioInfrastructure.ClinePassQuotaFetcher(repository: customProviderRepository),
            QuotioInfrastructure.WarpQuotaFetcher(repository: UserDefaultsWarpTokenRepository()),
            QuotioInfrastructure.OpenRouterQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository
            ),
            QuotioInfrastructure.AmpQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository
            ),
            QuotioInfrastructure.DevinQuotaFetcher(),
            QuotioInfrastructure.GrokQuotaFetcher(),
        ])
        let quotaScreenModel = QuotaScreenModel(
            coordinator: QuotaRefreshCoordinator(
                registry: registry,
                snapshots: PersistentQuotaSnapshotStore(),
                clock: SystemDateProvider()
            )
        )
        let dashboardScreenModel = DashboardScreenModel(
            quota: quotaScreenModel,
            accounts: accountsScreenModel
        )
        let providersScreenModel = ProvidersScreenModel(
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            quota: quotaScreenModel,
            customProviderService: customProviderService
        )
        providersScreenModel.reloadCustomProviders()

        let antigravityAccountScreenModel = AntigravityAccountScreenModel(
            switcher: .shared
        )
        let refreshSettings = RefreshSettingsManager.shared
        let menuBarSettings = MenuBarSettingsManager.shared
        let notificationManager = NotificationManager.shared
        let quotaController = QuotaFeatureController(
            quota: quotaScreenModel,
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            antigravityAccounts: antigravityAccountScreenModel,
            modeManager: modeManager,
            refreshSettings: refreshSettings,
            menuBarSettings: menuBarSettings,
            notificationManager: notificationManager,
            authFiles: { [] }
        )
        antigravityAccountScreenModel.setDidSwitchHandler { [weak quotaController] in
            await quotaController?.refresh(provider: .antigravity)
        }
        let agentSetup = AgentSetupViewModel()
        let tunnelManager = TunnelManager.shared
        let proxyManagement = ProxyManagementScreenModel(
            proxy: proxyScreenModel,
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            tunnelManager: tunnelManager,
            agentSetup: agentSetup,
            notificationManager: notificationManager,
            refreshSettings: refreshSettings
        )
        quotaController.setAuthFilesProvider { [weak proxyManagement] in
            proxyManagement?.authFiles ?? []
        }
        proxyManagement.setQuotaRefresh { [weak quotaController] force in
            await quotaController?.refreshAll(force: force)
        }
        agentSetup.setup(
            proxyManager: proxyScreenModel,
            apiKeys: { [weak proxyManagement] in proxyManagement?.apiKeys ?? [] },
            quotas: { [weak quotaScreenModel] in quotaScreenModel?.providerQuotas ?? [:] }
        )
        oauthScreenModel.setSuccessHandler { [weak proxyManagement, weak quotaController] in
            if !modeManager.isMonitorMode {
                await proxyManagement?.refreshData(refreshQuota: false)
            }
            await quotaController?.refreshAll(force: true)
        }

        let warmupExecutor = LegacyWarmupExecutor { [weak proxyManagement] in
            proxyManagement?.apiClient
        }
        let warmupScreenModel = WarmupScreenModel(
            scheduler: WarmupSchedulerService(
                executor: warmupExecutor,
                availability: warmupExecutor,
                clock: SystemDateProvider(),
                sleeper: ContinuousSleeper()
            ),
            settings: .shared,
            authFiles: { [weak proxyManagement] in proxyManagement?.authFiles ?? [] }
        )
        let ideImportScreenModel = IDEImportScreenModel(
            quotaController: quotaController,
            settings: .shared
        )

        let logRepository = QuotioInfrastructure.ManagementAPIClient(
            connectionProvider: { [proxyScreenModel] in
                await MainActor.run {
                    QuotioInfrastructure.ManagementAPIClient.Connection(
                        baseURL: proxyScreenModel.managementURL,
                        authKey: proxyScreenModel.managementKey
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
            applyNetworkAccess: { [proxyScreenModel] enabled in
                proxyScreenModel.setNetworkAccess(enabled)
            },
            applyAutomaticUpdateChecks: { [updaterService] enabled in
                updaterService.automaticallyChecksForUpdates = enabled
            },
            applyDockVisibility: { enabled in
                NSApp.setActivationPolicy(enabled ? .regular : .accessory)
            }
        )
        tunnelManager.configureProxyRemoteAccess { [proxyScreenModel] enabled in
            await proxyScreenModel.updateConfigAllowRemote(enabled)
        }
        let services = LegacyAppRuntimeServices(
            proxyManagement: proxyManagement,
            quotaController: quotaController,
            quotaScreenModel: quotaScreenModel,
            accountsScreenModel: accountsScreenModel,
            dashboardScreenModel: dashboardScreenModel,
            providersScreenModel: providersScreenModel,
            navigationScreenModel: NavigationScreenModel(),
            warmupScreenModel: warmupScreenModel,
            ideImportScreenModel: ideImportScreenModel,
            antigravityAccountScreenModel: antigravityAccountScreenModel,
            logsScreenModel: logsScreenModel,
            settingsScreenModel: settingsScreenModel,
            modeManager: modeManager,
            appearanceManager: .shared,
            statusBarManager: .shared,
            menuBarSettings: menuBarSettings,
            languageManager: .shared,
            refreshSettings: refreshSettings,
            warmupSettings: .shared,
            ideScanSettings: .shared,
            launchAtLoginManager: .shared,
            notificationManager: notificationManager,
            telemetrySettings: .shared,
            telemetryService: .shared,
            updaterService: updaterService,
            updatePollingService: .shared,
            tunnelManager: tunnelManager
        )
        return AppRuntime(services: services)
    }
}

private struct LegacyProxyManagementKeyVault: ProxyManagementKeyVault {
    func loadManagementKey() async -> String? {
        await MainActor.run { KeychainHelper.getLocalManagementKey() }
    }

    func saveManagementKey(_ key: String) async -> Bool {
        await MainActor.run { KeychainHelper.saveLocalManagementKey(key) }
    }
}

private final class LegacyProxyUpdateFeed: ProxyUpdateFeedChecking, @unchecked Sendable {
    private let service: AtomFeedUpdateService

    init(service: AtomFeedUpdateService) {
        self.service = service
    }

    func latestVersion(comparedTo currentVersion: String?) async -> String? {
        let result = await service.checkForCLIProxyUpdate(currentVersion: currentVersion)
        return result.isNewRelease ? result.latestVersion : nil
    }
}

private struct CustomProviderConfigurationSupplement: ProxyConfigurationSupplementing {
    private let service: QuotioApplication.CustomProviderService

    init(service: QuotioApplication.CustomProviderService) {
        self.service = service
    }

    func synchronize(configurationPath: String) async {
        try? service.synchronizeConfiguration(at: configurationPath)
    }
}

private final class LegacyProxyNotificationDelivery:
    ProxyNotificationDelivering,
    @unchecked Sendable
{
    private let service: NotificationManager

    init(service: NotificationManager) {
        self.service = service
    }

    func deliver(_ notification: ProxyNotification) async {
        await MainActor.run {
            switch notification {
            case .crashed(let exitCode):
                service.notifyProxyCrashed(exitCode: exitCode)
            case .upgradeSucceeded(let version):
                service.notifyUpgradeSuccess(version: version)
            case .upgradeFailed(let version, let reason):
                service.notifyUpgradeFailed(version: version, reason: reason)
            case .rolledBack(let version):
                service.notifyRollback(toVersion: version)
            case .suppressUpgrade(let version):
                service.suppressUpgradeNotification(version: version)
            }
        }
    }
}

@MainActor
private final class LegacyAppRuntimeServices: AppRuntimeServices {
    let proxyManagement: ProxyManagementScreenModel
    let quotaController: QuotaFeatureController
    let quotaScreenModel: QuotaScreenModel
    let accountsScreenModel: AccountsScreenModel
    let dashboardScreenModel: DashboardScreenModel
    let providersScreenModel: ProvidersScreenModel
    let navigationScreenModel: NavigationScreenModel
    let warmupScreenModel: WarmupScreenModel
    let ideImportScreenModel: IDEImportScreenModel
    let antigravityAccountScreenModel: AntigravityAccountScreenModel
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
        proxyManagement: ProxyManagementScreenModel,
        quotaController: QuotaFeatureController,
        quotaScreenModel: QuotaScreenModel,
        accountsScreenModel: AccountsScreenModel,
        dashboardScreenModel: DashboardScreenModel,
        providersScreenModel: ProvidersScreenModel,
        navigationScreenModel: NavigationScreenModel,
        warmupScreenModel: WarmupScreenModel,
        ideImportScreenModel: IDEImportScreenModel,
        antigravityAccountScreenModel: AntigravityAccountScreenModel,
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
        self.proxyManagement = proxyManagement
        self.quotaController = quotaController
        self.quotaScreenModel = quotaScreenModel
        self.accountsScreenModel = accountsScreenModel
        self.dashboardScreenModel = dashboardScreenModel
        self.providersScreenModel = providersScreenModel
        self.navigationScreenModel = navigationScreenModel
        self.warmupScreenModel = warmupScreenModel
        self.ideImportScreenModel = ideImportScreenModel
        self.antigravityAccountScreenModel = antigravityAccountScreenModel
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
        await proxyManagement.loadDirectAuthFiles()
    }

    func connectStatusBar() {
        statusBarManager.setDependencies(
            proxyManagement: proxyManagement,
            quota: quotaScreenModel,
            accounts: accountsScreenModel,
            quotaController: quotaController,
            antigravityAccounts: antigravityAccountScreenModel
        )
    }

    func setQuotaDataChangeHandler(_ handler: (@MainActor () -> Void)?) {
        quotaController.setDidChangeHandler(handler)
    }

    func updateStatusBar() {
        statusBarManager.updateStatusBar(
            items: quotaItems,
            colorMode: menuBarSettings.colorMode,
            quotaDisplayMode: menuBarSettings.quotaDisplayMode,
            isRunning: !quotaScreenModel.providerQuotas.isEmpty,
            showMenuBarIcon: menuBarSettings.showMenuBarIcon,
            showQuota: menuBarSettings.showQuotaInMenuBar
        )
    }

    func rebuildStatusBar() {
        statusBarManager.rebuildMenuInPlace()
    }

    func initializeFeatures() async {
        if modeManager.isLocalProxyMode {
            await proxyManagement.initialize()
        } else {
            await proxyManagement.loadDirectAuthFiles()
        }
        await quotaController.initialize()
        await warmupScreenModel.configure()
    }

    func checkForUpdatesInBackground() {
        updaterService.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        updaterService.checkForUpdates()
    }

    func startUpdatePolling() {
        updatePollingService.startPolling { [proxy = proxyManagement.proxy] in
            proxy.currentVersion ?? proxy.installedProxyVersion
        }
    }

    func stopUpdatePolling() {
        updatePollingService.stopPolling()
    }

    func shutdownOAuth() async {
        await warmupScreenModel.shutdown()
        await quotaController.shutdown()
    }

    func stopTunnel() async {
        await tunnelManager.stopTunnel()
    }

    func terminateProxyOnShutdown() async {
        await proxyManagement.shutdown()
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

            if let accountQuotas = quotaScreenModel.providerQuotas[provider],
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
