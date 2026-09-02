import Foundation
import QuotioPresentation

@MainActor
protocol AppRuntimeServices: AnyObject, Sendable {
    var viewModel: QuotaViewModel { get }
    var logsScreenModel: LogsScreenModel { get }
    var menuBarSettings: MenuBarSettingsManager { get }
    var statusBarManager: StatusBarManager { get }
    var modeManager: OperatingModeManager { get }
    var appearanceManager: AppearanceManager { get }
    var languageManager: LanguageManager { get }
    var settingsScreenModel: SettingsScreenModel { get }
    var refreshSettings: RefreshSettingsManager { get }
    var warmupSettings: WarmupSettingsManager { get }
    var ideScanSettings: IDEScanSettingsManager { get }
    var launchAtLoginManager: LaunchAtLoginManager { get }
    var updaterService: UpdaterService { get }
    var notificationManager: NotificationManager { get }
    var telemetrySettings: TelemetrySettings { get }
    var updatePollingService: AtomFeedUpdateService { get }
    var hasCompletedOnboarding: Bool { get }
    var showInDock: Bool { get }
    var canCheckForUpdates: Bool { get }

    func prepareForLaunch()
    func applyAppearance()
    func loadDirectAuthFiles() async
    func connectStatusBar()
    func setQuotaDataChangeHandler(_ handler: (@MainActor () -> Void)?)
    func updateStatusBar()
    func rebuildStatusBar()
    func initializeFeatures() async
    func checkForUpdatesInBackground()
    func checkForUpdates()
    func startUpdatePolling()
    func stopUpdatePolling()
    func stopTunnel() async
    nonisolated func terminateProxyOnShutdown()
    nonisolated func cleanupTunnelOrphans()
}

@MainActor
final class AppRuntime {
    private let services: any AppRuntimeServices
    private var initializationTask: Task<Void, Never>?
    private var fullInitializationTask: Task<Void, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var orphanCleanupTask: Task<Void, Never>?
    private var didPrepareForLaunch = false
    private var didStartUpdatePolling = false
    private var didCompleteFullInitialization = false

    private(set) var hasInitialized = false
    private(set) var needsOnboarding = false
    private(set) var hasShutDown = false

    var viewModel: QuotaViewModel { services.viewModel }
    var logsScreenModel: LogsScreenModel { services.logsScreenModel }
    var menuBarSettings: MenuBarSettingsManager { services.menuBarSettings }
    var statusBarManager: StatusBarManager { services.statusBarManager }
    var modeManager: OperatingModeManager { services.modeManager }
    var appearanceManager: AppearanceManager { services.appearanceManager }
    var languageManager: LanguageManager { services.languageManager }
    var settingsScreenModel: SettingsScreenModel { services.settingsScreenModel }
    var refreshSettings: RefreshSettingsManager { services.refreshSettings }
    var warmupSettings: WarmupSettingsManager { services.warmupSettings }
    var ideScanSettings: IDEScanSettingsManager { services.ideScanSettings }
    var launchAtLoginManager: LaunchAtLoginManager { services.launchAtLoginManager }
    var updaterService: UpdaterService { services.updaterService }
    var notificationManager: NotificationManager { services.notificationManager }
    var telemetrySettings: TelemetrySettings { services.telemetrySettings }
    var updatePollingService: AtomFeedUpdateService { services.updatePollingService }
    var showInDock: Bool { services.showInDock }
    var canCheckForUpdates: Bool { services.canCheckForUpdates }

    init(services: any AppRuntimeServices) {
        self.services = services
        services.setQuotaDataChangeHandler { [weak self] in
            self?.handleQuotaDataChange()
        }
    }

    func prepareForLaunch() {
        guard !didPrepareForLaunch else { return }
        didPrepareForLaunch = true
        services.prepareForLaunch()

        let services = services
        orphanCleanupTask = Task.detached(priority: .utility) {
            services.cleanupTunnelOrphans()
        }
    }

    func initializeIfNeeded() async {
        prepareForLaunch()

        if let initializationTask {
            await initializationTask.value
            startUpdatePollingIfNeeded()
            return
        }
        guard !hasInitialized else {
            startUpdatePollingIfNeeded()
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performInitialInitialization()
        }
        initializationTask = task
        await task.value
        initializationTask = nil
        startUpdatePollingIfNeeded()
    }

    func completeOnboarding() async {
        needsOnboarding = false
        await performFullInitializationIfNeeded()
    }

    func updateStatusBar() {
        services.updateStatusBar()
    }

    func rebuildStatusBar() {
        services.rebuildStatusBar()
    }

    func checkForUpdates() {
        services.checkForUpdates()
    }

    @discardableResult
    func shutdown(timeout: Duration = .milliseconds(1_500)) async -> Bool {
        if let shutdownTask {
            return await shutdownTask.value
        }
        guard !hasShutDown else { return true }

        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            return await performShutdown(timeout: timeout)
        }
        shutdownTask = task
        let completedCleanly = await task.value
        shutdownTask = nil
        hasShutDown = true
        return completedCleanly
    }

    private func performInitialInitialization() async {
        services.applyAppearance()

        if !services.hasCompletedOnboarding {
            needsOnboarding = true
            hasInitialized = true
            return
        }

        await performFullInitializationIfNeeded()
        hasInitialized = true
    }

    private func performFullInitializationIfNeeded() async {
        if let fullInitializationTask {
            await fullInitializationTask.value
            return
        }
        guard !didCompleteFullInitialization else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await services.loadDirectAuthFiles()
            services.connectStatusBar()
            services.updateStatusBar()
            await services.initializeFeatures()
            services.checkForUpdatesInBackground()
        }
        fullInitializationTask = task
        await task.value
        fullInitializationTask = nil
        didCompleteFullInitialization = true
    }

    private func startUpdatePollingIfNeeded() {
        guard !didStartUpdatePolling else { return }
        didStartUpdatePolling = true
        services.startUpdatePolling()
    }

    private func handleQuotaDataChange() {
        services.updateStatusBar()
        services.rebuildStatusBar()
    }

    private func performShutdown(timeout: Duration) async -> Bool {
        services.setQuotaDataChangeHandler(nil)
        services.stopUpdatePolling()
        initializationTask?.cancel()
        fullInitializationTask?.cancel()
        orphanCleanupTask?.cancel()

        let (events, continuation) = AsyncStream<Bool>.makeStream()
        let services = services
        let cleanupTask = Task { @MainActor in
            let proxyTask = Task.detached(priority: .utility) {
                services.terminateProxyOnShutdown()
            }
            async let tunnel: Void = services.stopTunnel()
            await tunnel
            await proxyTask.value
            guard !Task.isCancelled else { return }
            continuation.yield(true)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(false)
            } catch {
                return
            }
        }

        var iterator = events.makeAsyncIterator()
        let completedCleanly = await iterator.next() ?? false
        continuation.finish()
        cleanupTask.cancel()
        timeoutTask.cancel()

        if !completedCleanly {
            orphanCleanupTask = Task.detached(priority: .utility) {
                services.cleanupTunnelOrphans()
            }
        }
        return completedCleanly
    }
}
