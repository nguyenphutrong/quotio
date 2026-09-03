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
        let urlOpener = WorkspaceURLOpener()
        let applicationPlatform = AppKitApplicationPlatformAdapter()
        let pasteboard = PasteboardAdapter()
        let languageManager = LanguageManager.shared
        let notificationController = NotificationController(
            repository: UserDefaultsNotificationPreferencesRepository(),
            delivery: UserNotificationCenterAdapter { [languageManager] key in
                languageManager.localized(key)
            }
        )
        let paths = FileProxyConfigurationRepository.defaultPaths()
        let configurationRepository = FileProxyConfigurationRepository(paths: paths)
        let proxyController = ProxyLifecycleController(
            paths: paths,
            processController: ProxyProcessController(),
            versionRepository: FileProxyVersionRepository(),
            releaseRepository: GitHubProxyReleaseRepository(),
            updateFeed: GitHubAtomProxyUpdateFeed(),
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
            notificationDelivery: ProxyNotificationRelay(notifications: notificationController),
            sleeper: ContinuousSleeper(),
            dateProvider: SystemDateProvider(),
            installedVersionLimit: AppConstants.maxInstalledVersions
        )
        let proxyScreenModel = ProxyScreenModel(
            controller: proxyController,
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
            authService: LegacyProxyAuthService(
                proxy: proxyScreenModel,
                copyToPasteboard: pasteboard.copy
            ),
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
        let quotaController = QuotaFeatureController(
            quota: quotaScreenModel,
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            antigravityAccounts: antigravityAccountScreenModel,
            modeManager: modeManager,
            refreshSettings: refreshSettings,
            menuBarSettings: menuBarSettings,
            notifications: notificationController,
            authFiles: { [] }
        )
        antigravityAccountScreenModel.setDidSwitchHandler { [weak quotaController] in
            await quotaController?.refresh(provider: .antigravity)
        }
        let tunnelPreferences = UserDefaultsTunnelPreferencesRepository()
        let tunnelController = TunnelLifecycleController(
            tunnel: CloudflaredService(),
            remoteAccess: ProxyTunnelRemoteAccessAdapter(proxy: proxyScreenModel),
            preferences: tunnelPreferences,
            sleeper: ContinuousSleeper(),
            clock: SystemDateProvider()
        )
        let tunnel = TunnelScreenModel(
            controller: tunnelController,
            failureMessage: { failure in
                switch failure {
                case .notInstalled:
                    "tunnel.error.notInstalled".localized()
                case .alreadyRunning:
                    "Tunnel is already running"
                case .startFailed(let reason):
                    "Failed to start tunnel: \(reason)"
                case .unexpectedExit:
                    "tunnel.error.unexpectedExit".localized()
                case .startTimeout:
                    "tunnel.error.startTimeout".localized()
                }
            }
        )
        let agentFileStore = AgentFileStore()
        let agentDetector = AgentDetectionAdapter()
        let agentInstallationProbe = AgentBinaryInstallationProbe()
        let agentConfigurationService = QuotioApplication.AgentConfigurationService(
            adapters: [
                ClaudeCodeAgentConfigurationAdapter(fileStore: agentFileStore),
                CodexAgentConfigurationAdapter(
                    fileStore: agentFileStore,
                    localize: { $0.localizedStatic() }
                ),
                AmpAgentConfigurationAdapter(
                    fileStore: agentFileStore,
                    localize: { $0.localizedStatic() }
                ),
                OpenCodeAgentConfigurationAdapter(
                    fileStore: agentFileStore,
                    localize: { $0.localizedStatic() }
                ),
                FactoryDroidAgentConfigurationAdapter(fileStore: agentFileStore),
            ],
            detector: agentDetector,
            shellProfiles: ShellProfileAdapter(fileStore: agentFileStore),
            modelCatalog: AgentModelCatalogHTTPAdapter {
                await CopilotQuotaFetcher().fetchUserAvailableModelIds()
            }
        )
        weak var proxyManagementReference: ProxyManagementScreenModel?
        let agentSetup = AgentSetupScreenModel(
            service: agentConfigurationService,
            endpointContext: { [weak proxyScreenModel, weak tunnel] in
                guard let proxyScreenModel else { return nil }
                return AgentEndpointContext(
                    baseURL: tunnel?.tunnelState.publicURL ?? proxyScreenModel.baseURL,
                    apiKey: proxyManagementReference?.apiKeys.first ?? proxyScreenModel.managementKey
                )
            }
        )
        let proxyManagement = ProxyManagementScreenModel(
            proxy: proxyScreenModel,
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            tunnel: tunnel,
            agentSetup: agentSetup,
            notifications: notificationController,
            refreshSettings: refreshSettings,
            tunnelPreferences: tunnelPreferences
        )
        proxyManagementReference = proxyManagement
        quotaController.setAuthFilesProvider { [weak proxyManagement] in
            proxyManagement?.authFiles ?? []
        }
        proxyManagement.setQuotaRefresh { [weak quotaController] force in
            await quotaController?.refreshAll(force: force)
        }
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
        let updatePreferences = UserDefaultsUpdatePreferencesRepository()
        let applicationUpdateController = ApplicationUpdateController(
            checker: SparkleApplicationUpdateAdapter(),
            preferencesRepository: updatePreferences,
            icon: AppKitUpdaterIconAdapter()
        )
        let applicationUpdateModel = ApplicationUpdateScreenModel(
            controller: applicationUpdateController
        )
        let notificationSettingsModel = NotificationSettingsScreenModel(
            controller: notificationController
        )
        let telemetryController = TelemetryController(
            repository: UserDefaultsTelemetryPreferencesRepository(),
            tracker: PostHogTelemetryAdapter(),
            contextProvider: BundleTelemetryRuntimeContextProvider(),
            updatePreferencesRepository: updatePreferences
        )
        let telemetryConsentModel = TelemetryConsentScreenModel(controller: telemetryController)
        let launchAtLoginController = LaunchAtLoginController(
            registration: ServiceManagementLaunchAtLoginAdapter(),
            urlOpener: urlOpener
        )
        let launchAtLoginModel = LaunchAtLoginScreenModel(
            controller: launchAtLoginController,
            failureMessage: { failure in
                switch failure {
                case .registrationFailed(let reason):
                    "launchAtLogin.error.registrationFailed".localized() + ": \(reason)"
                case .unregistrationFailed(let reason):
                    "launchAtLogin.error.unregistrationFailed".localized() + ": \(reason)"
                }
            }
        )
        let platformActions = PlatformActionScreenModel(urlOpener: urlOpener)
        let appearanceManager = AppearanceManager(
            repository: UserDefaultsAppearancePreferencesRepository(),
            platform: applicationPlatform
        )
        let proxyUpdatePolling = ProxyUpdatePollingController(
            proxy: proxyController,
            notifications: notificationController,
            notificationRecord: UserDefaultsProxyUpdateNotificationRecord(),
            sleeper: ContinuousSleeper()
        )
        let settingsScreenModel = SettingsScreenModel(
            proxyRepository: UserDefaultsProxyPreferencesRepository(),
            tunnelRepository: tunnelPreferences,
            appShellRepository: UserDefaultsAppShellPreferencesRepository(),
            applyNetworkAccess: { [proxyScreenModel] enabled in
                proxyScreenModel.setNetworkAccess(enabled)
            },
            applyAutomaticUpdateChecks: { [applicationUpdateController] enabled in
                applicationUpdateController.automaticallyChecksForUpdates = enabled
            },
            applyDockVisibility: { [applicationPlatform] enabled in
                applicationPlatform.setDockVisibility(enabled)
            }
        )
        let providerImageCache = ProviderImageCacheAdapter()
        let providerImageModel = ProviderImageScreenModel(
            loadImage: { [providerImageCache] name, size in
                providerImageCache.image(named: name, size: size)
            }
        )
        let statusBarManager = StatusBarManager()
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
            pasteboard: pasteboard,
            providerImageModel: providerImageModel,
            platformActions: platformActions,
            settingsScreenModel: settingsScreenModel,
            modeManager: modeManager,
            appearanceManager: appearanceManager,
            statusBarManager: statusBarManager,
            menuBarSettings: menuBarSettings,
            languageManager: languageManager,
            refreshSettings: refreshSettings,
            warmupSettings: .shared,
            ideScanSettings: .shared,
            launchAtLoginModel: launchAtLoginModel,
            notificationSettingsModel: notificationSettingsModel,
            telemetryConsentModel: telemetryConsentModel,
            applicationUpdateModel: applicationUpdateModel,
            notificationController: notificationController,
            telemetryController: telemetryController,
            applicationUpdateController: applicationUpdateController,
            applicationPlatform: applicationPlatform,
            proxyUpdatePolling: proxyUpdatePolling,
            tunnel: tunnel,
            isCLIInstalled: agentInstallationProbe.isInstalled
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

private struct CustomProviderConfigurationSupplement: ProxyConfigurationSupplementing {
    private let service: QuotioApplication.CustomProviderService

    init(service: QuotioApplication.CustomProviderService) {
        self.service = service
    }

    func synchronize(configurationPath: String) async {
        try? service.synchronizeConfiguration(at: configurationPath)
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
    let pasteboard: PasteboardAdapter
    let providerImageModel: ProviderImageScreenModel
    let platformActions: PlatformActionScreenModel
    let settingsScreenModel: SettingsScreenModel
    let modeManager: OperatingModeManager
    let appearanceManager: AppearanceManager
    let statusBarManager: StatusBarManager
    let menuBarSettings: MenuBarSettingsManager
    let languageManager: LanguageManager
    let refreshSettings: RefreshSettingsManager
    let warmupSettings: WarmupSettingsManager
    let ideScanSettings: IDEScanSettingsManager
    let launchAtLoginModel: LaunchAtLoginScreenModel
    let notificationSettingsModel: NotificationSettingsScreenModel
    let telemetryConsentModel: TelemetryConsentScreenModel
    let applicationUpdateModel: ApplicationUpdateScreenModel

    private let notificationController: NotificationController
    private let telemetryController: TelemetryController
    private let applicationUpdateController: ApplicationUpdateController
    private let applicationPlatform: AppKitApplicationPlatformAdapter
    private let proxyUpdatePolling: ProxyUpdatePollingController
    private let tunnel: TunnelScreenModel
    private let isCLIInstalled: (CLIAgent) -> Bool

    var hasCompletedOnboarding: Bool { modeManager.hasCompletedOnboarding }
    var showInDock: Bool { settingsScreenModel.appShellPreferences.showInDock }
    var canCheckForUpdates: Bool { applicationUpdateModel.snapshot.canCheck }

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
        pasteboard: PasteboardAdapter,
        providerImageModel: ProviderImageScreenModel,
        platformActions: PlatformActionScreenModel,
        settingsScreenModel: SettingsScreenModel,
        modeManager: OperatingModeManager,
        appearanceManager: AppearanceManager,
        statusBarManager: StatusBarManager,
        menuBarSettings: MenuBarSettingsManager,
        languageManager: LanguageManager,
        refreshSettings: RefreshSettingsManager,
        warmupSettings: WarmupSettingsManager,
        ideScanSettings: IDEScanSettingsManager,
        launchAtLoginModel: LaunchAtLoginScreenModel,
        notificationSettingsModel: NotificationSettingsScreenModel,
        telemetryConsentModel: TelemetryConsentScreenModel,
        applicationUpdateModel: ApplicationUpdateScreenModel,
        notificationController: NotificationController,
        telemetryController: TelemetryController,
        applicationUpdateController: ApplicationUpdateController,
        applicationPlatform: AppKitApplicationPlatformAdapter,
        proxyUpdatePolling: ProxyUpdatePollingController,
        tunnel: TunnelScreenModel,
        isCLIInstalled: @escaping (CLIAgent) -> Bool
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
        self.pasteboard = pasteboard
        self.providerImageModel = providerImageModel
        self.platformActions = platformActions
        self.settingsScreenModel = settingsScreenModel
        self.modeManager = modeManager
        self.appearanceManager = appearanceManager
        self.statusBarManager = statusBarManager
        self.menuBarSettings = menuBarSettings
        self.languageManager = languageManager
        self.refreshSettings = refreshSettings
        self.warmupSettings = warmupSettings
        self.ideScanSettings = ideScanSettings
        self.launchAtLoginModel = launchAtLoginModel
        self.notificationSettingsModel = notificationSettingsModel
        self.telemetryConsentModel = telemetryConsentModel
        self.applicationUpdateModel = applicationUpdateModel
        self.notificationController = notificationController
        self.telemetryController = telemetryController
        self.applicationUpdateController = applicationUpdateController
        self.applicationPlatform = applicationPlatform
        self.proxyUpdatePolling = proxyUpdatePolling
        self.tunnel = tunnel
        self.isCLIInstalled = isCLIInstalled
    }

    func prepareForLaunch() {
        telemetryController.prepareForLaunch()
        Task { [notificationController] in
            await notificationController.requestAuthorization()
        }
    }

    func applyAppearance() {
        appearanceManager.applyAppearance()
    }

    func loadDirectAuthFiles() async {
        await proxyManagement.loadDirectAuthFiles()
    }

    func connectStatusBar() {
        let windowPresenter = AppKitWindowPresenter()
        let dispatcher = StatusBarCommandDispatcher(
            handlers: StatusBarCommandHandlers(
                refreshAll: { [quotaController] in
                    await quotaController.refreshAll(force: true)
                },
                refreshProvider: { [quotaController] provider in
                    await quotaController.refresh(provider: provider)
                },
                refreshAccount: { [quotaController] account in
                    await quotaController.refresh(account: account)
                },
                toggleProxy: { [proxyManagement] in
                    await proxyManagement.toggleProxy()
                },
                toggleTunnel: { [tunnel] port in
                    await tunnel.toggle(port: port)
                },
                copyText: { [pasteboard] value in
                    pasteboard.copy(value)
                },
                switchAntigravityAccount: { [antigravityAccountScreenModel] email in
                    await antigravityAccountScreenModel.switchAccount(email: email)
                },
                isAntigravityIDERunning: { [antigravityAccountScreenModel] in
                    antigravityAccountScreenModel.switcher.isIDERunning()
                },
                confirmAntigravitySwitch: AntigravitySwitchConfirmationPresenter.confirm,
                openApp: { [weak statusBarManager, settingsScreenModel, windowPresenter] in
                    if settingsScreenModel.appShellPreferences.showInDock {
                        statusBarManager?.closeMenu()
                    }
                    windowPresenter.showMainWindow()
                },
                quit: { [applicationPlatform] in
                    applicationPlatform.terminate()
                },
                menuNeedsRebuild: { [weak statusBarManager] in
                    statusBarManager?.rebuildMenuInPlace()
                }
            )
        )
        statusBarManager.configureMenu(
            snapshotProvider: { [weak self] in
                guard let self else {
                    preconditionFailure("Status bar outlived application services")
                }
                return self.statusBarMenuSnapshot
            },
            commandDispatcher: dispatcher
        )
    }

    func setStatusBarStateChangeHandler(_ handler: (@MainActor () -> Void)?) {
        quotaController.setDidChangeHandler(handler)
        quotaScreenModel.setDidChangeHandler { _ in handler?() }
        proxyManagement.proxy.setDidChangeHandler { _ in handler?() }
        tunnel.setDidChangeHandler { _ in handler?() }
        menuBarSettings.setDidChangeHandler { _ in handler?() }
        modeManager.setDidChangeHandler { _ in handler?() }
        appearanceManager.setDidChangeHandler { _ in handler?() }
        languageManager.setDidChangeHandler { _ in handler?() }
    }

    func updateStatusBar() {
        statusBarManager.updateStatusBar(
            items: quotaItems,
            colorMode: menuBarSettings.colorMode,
            quotaDisplayMode: menuBarSettings.quotaDisplayMode,
            isRunning: !quotaScreenModel.providerQuotas.isEmpty,
            showMenuBarIcon: menuBarSettings.showMenuBarIcon,
            showQuota: menuBarSettings.showQuotaInMenuBar,
            appearanceMode: appearanceManager.appearanceMode,
            language: languageManager.currentLanguage
        )
    }

    func rebuildStatusBar() {
        statusBarManager.rebuildMenuInPlace()
    }

    func initializeFeatures() async {
        await tunnel.refreshInstallation()
        if modeManager.isLocalProxyMode {
            await proxyManagement.initialize()
        } else {
            await proxyManagement.loadDirectAuthFiles()
        }
        await quotaController.initialize()
        await warmupScreenModel.configure()
    }

    func checkForUpdatesInBackground() {
        applicationUpdateController.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        applicationUpdateController.checkForUpdates()
    }

    func startUpdatePolling() async {
        await proxyUpdatePolling.start()
    }

    func stopUpdatePolling() async {
        await proxyUpdatePolling.stop()
    }

    func shutdownOAuth() async {
        await warmupScreenModel.shutdown()
        await quotaController.shutdown()
    }

    func stopTunnel() async {
        await tunnel.shutdown()
    }

    func terminateProxyOnShutdown() async {
        await proxyManagement.shutdown()
    }

    func cleanupTunnelOrphans() async {
        await tunnel.cleanupOrphans()
    }

    private var statusBarMenuSnapshot: StatusBarMenuSnapshot {
        let knownStatuses = Dictionary(
            uniqueKeysWithValues: proxyManagement.agentSetup.agentStatuses.map {
                ($0.agent, $0.installed)
            }
        )
        let installedAgents = Set(CLIAgent.allCases.filter { agent in
            knownStatuses[agent] ?? isCLIInstalled(agent)
        })
        return StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: modeManager.currentMode,
            proxyPort: proxyManagement.proxy.port,
            isProxyRunning: proxyManagement.proxy.proxyStatus.running,
            tunnel: tunnel.tunnelState,
            directAuthProviders: Set(proxyManagement.directAuthFiles.map(\.provider)),
            monitorAccounts: accountsScreenModel.accounts,
            quota: quotaScreenModel.state,
            installedAgents: installedAgents,
            activeAntigravityEmail: antigravityAccountScreenModel.switcher.currentActiveAccount?.email,
            menuBarPreferences: menuBarSettings.preferences,
            appearanceMode: appearanceManager.appearanceMode,
            language: languageManager.currentLanguage
        )
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
