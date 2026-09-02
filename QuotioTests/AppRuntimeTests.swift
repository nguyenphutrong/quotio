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
        XCTAssertEqual(services.loadDirectAuthFilesCount, 1)
        XCTAssertEqual(services.connectStatusBarCount, 1)
        XCTAssertEqual(services.initializeFeaturesCount, 1)
        XCTAssertEqual(services.backgroundUpdateCheckCount, 1)
        XCTAssertEqual(services.startUpdatePollingCount, 1)
    }

    func testOnboardingDefersAndThenCompletesFullInitializationOnce() async {
        let services = FakeAppRuntimeServices()
        services.hasCompletedOnboarding = false
        let runtime = AppRuntime(services: services)

        await runtime.initializeIfNeeded()

        XCTAssertTrue(runtime.needsOnboarding)
        XCTAssertEqual(services.loadDirectAuthFilesCount, 0)
        XCTAssertEqual(services.startUpdatePollingCount, 1)

        async let firstCompletion: Void = runtime.completeOnboarding()
        async let secondCompletion: Void = runtime.completeOnboarding()
        _ = await (firstCompletion, secondCompletion)

        XCTAssertFalse(runtime.needsOnboarding)
        XCTAssertEqual(services.loadDirectAuthFilesCount, 1)
        XCTAssertEqual(services.initializeFeaturesCount, 1)
        XCTAssertEqual(services.backgroundUpdateCheckCount, 1)
    }

    func testQuotaCallbackUpdatesAndRebuildsStatusBarWithoutNotificationCenter() {
        let services = FakeAppRuntimeServices()
        let runtime = AppRuntime(services: services)

        services.quotaDataDidChangeHandler?()

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
        XCTAssertEqual(services.stopUpdatePollingCount, 1)
        XCTAssertEqual(services.stopTunnelCount, 1)
        XCTAssertEqual(services.proxyTerminationCount, 1)
    }

    func testShutdownTimeoutRequestsOrphanCleanup() async {
        let services = FakeAppRuntimeServices()
        services.tunnelStopDelay = .seconds(1)
        let runtime = AppRuntime(services: services)

        let completedCleanly = await runtime.shutdown(timeout: .milliseconds(10))

        XCTAssertFalse(completedCleanly)
        for _ in 0..<100 where services.orphanCleanupCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(services.orphanCleanupCount, 1)
    }
}

@MainActor
private final class FakeAppRuntimeServices: AppRuntimeServices {
    let viewModel = QuotaViewModel()
    let logsScreenModel: LogsScreenModel
    let menuBarSettings = MenuBarSettingsManager.shared
    let statusBarManager = StatusBarManager.shared
    let modeManager = OperatingModeManager.shared
    let appearanceManager = AppearanceManager.shared
    let languageManager = LanguageManager.shared
    let settingsScreenModel = SettingsScreenModel(
        proxyRepository: AppRuntimeTestPreferencesRepository(),
        tunnelRepository: AppRuntimeTestPreferencesRepository(),
        appShellRepository: AppRuntimeTestPreferencesRepository()
    )
    let refreshSettings = RefreshSettingsManager.shared
    let warmupSettings = WarmupSettingsManager.shared
    let ideScanSettings = IDEScanSettingsManager.shared
    let launchAtLoginManager = LaunchAtLoginManager.shared
    let updaterService = UpdaterService.shared
    let notificationManager = NotificationManager.shared
    let telemetrySettings = TelemetrySettings.shared
    let updatePollingService = AtomFeedUpdateService.shared

    var hasCompletedOnboarding = true
    var showInDock = true
    var canCheckForUpdates = true
    var initializationDelay = Duration.zero
    var tunnelStopDelay = Duration.zero
    var quotaDataDidChangeHandler: (@MainActor () -> Void)?

    private(set) var prepareForLaunchCount = 0
    private(set) var applyAppearanceCount = 0
    private(set) var loadDirectAuthFilesCount = 0
    private(set) var connectStatusBarCount = 0
    private(set) var updateStatusBarCount = 0
    private(set) var rebuildStatusBarCount = 0
    private(set) var initializeFeaturesCount = 0
    private(set) var backgroundUpdateCheckCount = 0
    private(set) var foregroundUpdateCheckCount = 0
    private(set) var startUpdatePollingCount = 0
    private(set) var stopUpdatePollingCount = 0
    private(set) var stopTunnelCount = 0

    private let proxyTerminations = LockedCounter()
    private let orphanCleanups = LockedCounter()

    init() {
        let logRepository = AppRuntimeTestProxyLogRepository()
        logsScreenModel = LogsScreenModel(
            loadLogs: LoadProxyLogsUseCase(
                repository: logRepository,
                timeProvider: SystemDateProvider()
            ),
            clearLogs: ClearProxyLogsUseCase(repository: logRepository),
            sleeper: ContinuousSleeper()
        )
    }

    nonisolated var proxyTerminationCount: Int { proxyTerminations.value }
    nonisolated var orphanCleanupCount: Int { orphanCleanups.value }

    func prepareForLaunch() {
        prepareForLaunchCount += 1
    }

    func applyAppearance() {
        applyAppearanceCount += 1
    }

    func loadDirectAuthFiles() async {
        loadDirectAuthFilesCount += 1
        try? await Task.sleep(for: initializationDelay)
    }

    func connectStatusBar() {
        connectStatusBarCount += 1
    }

    func setQuotaDataChangeHandler(_ handler: (@MainActor () -> Void)?) {
        quotaDataDidChangeHandler = handler
    }

    func updateStatusBar() {
        updateStatusBarCount += 1
    }

    func rebuildStatusBar() {
        rebuildStatusBarCount += 1
    }

    func initializeFeatures() async {
        initializeFeaturesCount += 1
    }

    func checkForUpdatesInBackground() {
        backgroundUpdateCheckCount += 1
    }

    func checkForUpdates() {
        foregroundUpdateCheckCount += 1
    }

    func startUpdatePolling() {
        startUpdatePollingCount += 1
    }

    func stopUpdatePolling() {
        stopUpdatePollingCount += 1
    }

    func stopTunnel() async {
        stopTunnelCount += 1
        try? await Task.sleep(for: tunnelStopDelay)
    }

    nonisolated func terminateProxyOnShutdown() {
        proxyTerminations.increment()
    }

    nonisolated func cleanupTunnelOrphans() {
        orphanCleanups.increment()
    }
}

private actor AppRuntimeTestProxyLogRepository: ProxyLogRepository {
    func fetchLogs(after timestamp: Int?) -> ProxyLogPage {
        ProxyLogPage(lines: [], latestTimestamp: nil)
    }

    func clearLogs() {}
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}
