import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import QuotioPresentation
import XCTest
@testable import Quotio

@MainActor
final class AppRuntimeTests: XCTestCase {
    func testHeadlessAndWindowInitializationShareOneRuntimeAndInitializeServicesOnce() async {
        let services = FakeAppRuntimeServices()
        services.initializationDelay = .milliseconds(20)
        let runtime = AppRuntime(services: services)
        let delegate = AppDelegate(runtime: runtime)

        async let headlessLaunch: Void = runtime.initializeIfNeeded()
        async let windowLaunch: Void = runtime.initializeIfNeeded()
        _ = await (headlessLaunch, windowLaunch)

        XCTAssertTrue(delegate.runtime === runtime)
        XCTAssertTrue(runtime.hasInitialized)
        XCTAssertEqual(services.prepareForLaunchCount, 1)
        XCTAssertEqual(services.applyAppearanceCount, 1)
        XCTAssertEqual(services.connectStatusBarCount, 1)
        XCTAssertEqual(services.initializeFeaturesCount, 1)
        XCTAssertEqual(services.backgroundUpdateCheckCount, 1)
    }

    func testOnboardingAllowsMonitoringInitializationExactlyOnce() async {
        let services = FakeAppRuntimeServices()
        services.hasCompletedOnboarding = false
        let runtime = AppRuntime(services: services)

        await runtime.initializeIfNeeded()

        XCTAssertTrue(runtime.needsOnboarding)

        async let firstCompletion: Void = runtime.completeOnboarding(mode: .localProxy)
        async let secondCompletion: Void = runtime.completeOnboarding(mode: .localProxy)
        _ = await (firstCompletion, secondCompletion)

        XCTAssertFalse(runtime.needsOnboarding)
        XCTAssertEqual(services.modeManager.currentMode, .monitor)
        XCTAssertTrue(services.modeManager.hasCompletedOnboarding)
        XCTAssertEqual(services.initializeFeaturesCount, 1)
        XCTAssertEqual(services.backgroundUpdateCheckCount, 1)
    }

    func testStatusBarStateCallbackUpdatesAndRebuildsHeadlessMenu() async {
        let services = FakeAppRuntimeServices()
        let runtime = AppRuntime(services: services)

        services.statusBarStateDidChangeHandler?()

        XCTAssertEqual(services.updateStatusBarCount, 1)
        XCTAssertEqual(services.rebuildStatusBarCount, 1)
        withExtendedLifetime(runtime) {}
    }

    func testShutdownCompletesCleanupWithoutBlockingMainActor() async {
        let services = FakeAppRuntimeServices()
        let runtime = AppRuntime(services: services)

        let completedCleanly = await runtime.shutdown(timeout: .seconds(1))

        XCTAssertTrue(completedCleanly)
        XCTAssertTrue(runtime.hasShutDown)
        XCTAssertEqual(services.shutdownOAuthCount, 1)
    }

    func testShutdownRespectsTheHostCleanupTimeout() async {
        let services = FakeAppRuntimeServices()
        services.shutdownDelay = .seconds(1)
        let runtime = AppRuntime(services: services)

        let completedCleanly = await runtime.shutdown(timeout: .milliseconds(10))

        XCTAssertFalse(completedCleanly)
    }

    func testRepeatedShutdownStopsTheHostOnlyOnce() async {
        let services = FakeAppRuntimeServices()
        let runtime = AppRuntime(services: services)
        _ = await runtime.shutdown()
        _ = await runtime.shutdown()
        XCTAssertEqual(services.shutdownOAuthCount, 1)
    }
}

@MainActor
private final class FakeAppRuntimeServices: AppRuntimeServices {
    private lazy var dependencies = CompositionRoot.makeProduction()
    var proxyScreenModel: ProxyScreenModel { dependencies.proxyScreenModel }
    var quotaController: QuotaFeatureController { dependencies.quotaController }
    var quotaScreenModel: QuotaScreenModel { dependencies.quotaScreenModel }
    var quotaHistory: QuotaHistoryServiceModel { dependencies.quotaHistory }
    var accountsScreenModel: AccountsScreenModel { dependencies.accountsScreenModel }
    var navigationScreenModel: NavigationScreenModel { dependencies.navigationScreenModel }
    let pasteboard = PasteboardScreenModel(writer: MacOSPasteboardAdapter())
    var providerImageModel: ProviderImageScreenModel { dependencies.providerImageModel }
    var platformActions: PlatformActionScreenModel { dependencies.platformActions }
    var menuBarSettings: MenuBarSettingsManager { dependencies.menuBarSettings }
    let statusBarManager = StatusBarManager()
    var modeManager: OperatingModeManager { dependencies.modeManager }
    var appearanceManager: AppearanceManager { dependencies.appearanceManager }
    var languageManager: LanguageManager { dependencies.languageManager }
    let settingsScreenModel = SettingsScreenModel(
        proxyRepository: AppRuntimeTestPreferencesRepository(),
        tunnelRepository: AppRuntimeTestPreferencesRepository(),
        appShellRepository: AppRuntimeTestPreferencesRepository()
    )
    var launchAtLoginModel: LaunchAtLoginScreenModel { dependencies.launchAtLoginModel }
    var notificationSettingsModel: NotificationSettingsScreenModel {
        dependencies.notificationSettingsModel
    }
    var applicationUpdateModel: ApplicationUpdateScreenModel { dependencies.applicationUpdateModel }
    var credentialMigrationModel: CredentialMigrationScreenModel { dependencies.credentialMigrationModel }

    var hasCompletedOnboarding = true
    var showInDock = true
    var canCheckForUpdates = true
    var initializationDelay = Duration.zero
    var shutdownDelay = Duration.zero
    var statusBarStateDidChangeHandler: (@MainActor () -> Void)?

    private(set) var prepareForLaunchCount = 0
    private(set) var applyAppearanceCount = 0
    private(set) var connectStatusBarCount = 0
    private(set) var updateStatusBarCount = 0
    private(set) var rebuildStatusBarCount = 0
    private(set) var initializeFeaturesCount = 0
    private(set) var backgroundUpdateCheckCount = 0
    private(set) var foregroundUpdateCheckCount = 0
    private(set) var shutdownOAuthCount = 0


    func prepareForLaunch() {
        prepareForLaunchCount += 1
    }

    func applyAppearance() {
        applyAppearanceCount += 1
    }

    func connectStatusBar() {
        connectStatusBarCount += 1
    }

    func setStatusBarStateChangeHandler(_ handler: (@MainActor () -> Void)?) {
        statusBarStateDidChangeHandler = handler
    }

    func updateStatusBar() {
        updateStatusBarCount += 1
    }

    func rebuildStatusBar() {
        rebuildStatusBarCount += 1
    }

    func initializeFeatures() async {
        initializeFeaturesCount += 1
        try? await Task.sleep(for: initializationDelay)
    }

    func checkForUpdatesInBackground() {
        backgroundUpdateCheckCount += 1
    }

    func checkForUpdates() {
        foregroundUpdateCheckCount += 1
    }

    func shutdownOAuth() async {
        shutdownOAuthCount += 1
        try? await Task.sleep(for: shutdownDelay)
    }

}

private final class AppRuntimeTestPreferencesRepository:
    ProxyPreferencesRepository,
    TunnelPreferencesRepository,
    AppShellPreferencesRepository,
    @unchecked Sendable
{
    private var proxyPreferences = ProxyPreferences()
    private var tunnelPreferences = TunnelPreferences()
    private var appShellPreferences = AppShellPreferences()

    func load() -> ProxyPreferences {
        proxyPreferences
    }

    func load() -> TunnelPreferences {
        tunnelPreferences
    }

    func load() -> AppShellPreferences {
        appShellPreferences
    }

    func setAutoStartProxy(_ enabled: Bool) {
        proxyPreferences.autoStartProxy = enabled
    }

    func setAllowNetworkAccess(_ enabled: Bool) {
        proxyPreferences.allowNetworkAccess = enabled
    }

    func setLoggingToFile(_ enabled: Bool) {
        proxyPreferences.loggingToFile = enabled
    }

    func setProxyURL(_ proxyURL: String?) {
        proxyPreferences.proxyURL = proxyURL
    }

    func setAutoStartTunnel(_ enabled: Bool) {
        tunnelPreferences.autoStartTunnel = enabled
    }

    func setAutoRestartTunnel(_ enabled: Bool) {
        tunnelPreferences.autoRestartTunnel = enabled
    }

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        appShellPreferences.autoCheckUpdates = enabled
    }

    func setShowInDock(_ enabled: Bool) {
        appShellPreferences.showInDock = enabled
    }

    func setHideGettingStarted(_ hidden: Bool) {
        appShellPreferences.hideGettingStarted = hidden
    }
}
