import Foundation
import QuotioDomain
import QuotioPresentation

@MainActor
protocol AppRuntimeServices: AnyObject, Sendable {
    var proxyScreenModel: ProxyScreenModel { get }
    var quotaController: QuotaFeatureController { get }
    var quotaScreenModel: QuotaScreenModel { get }
    var quotaHistory: QuotaHistoryServiceModel { get }
    var accountsScreenModel: AccountsScreenModel { get }
    var navigationScreenModel: NavigationScreenModel { get }
    var pasteboard: PasteboardScreenModel { get }
    var providerImageModel: ProviderImageScreenModel { get }
    var platformActions: PlatformActionScreenModel { get }
    var menuBarSettings: MenuBarSettingsManager { get }
    var statusBarManager: StatusBarManager { get }
    var modeManager: OperatingModeManager { get }
    var appearanceManager: AppearanceManager { get }
    var languageManager: LanguageManager { get }
    var settingsScreenModel: SettingsScreenModel { get }
    var launchAtLoginModel: LaunchAtLoginScreenModel { get }
    var notificationSettingsModel: NotificationSettingsScreenModel { get }
    var applicationUpdateModel: ApplicationUpdateScreenModel { get }
    var credentialMigrationModel: CredentialMigrationScreenModel { get }
    var hasCompletedOnboarding: Bool { get }
    var showInDock: Bool { get }
    var canCheckForUpdates: Bool { get }

    func prepareForLaunch()
    func applyAppearance()
    func connectStatusBar()
    func setStatusBarStateChangeHandler(_ handler: (@MainActor () -> Void)?)
    func updateStatusBar()
    func rebuildStatusBar()
    func initializeFeatures() async
    func checkForUpdatesInBackground()
    func checkForUpdates()
    func shutdownOAuth() async
}

@MainActor
final class AppRuntime {
    private let services: any AppRuntimeServices
    private var initializationTask: Task<Void, Never>?
    private var fullInitializationTask: Task<Void, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var didPrepareForLaunch = false
    private var didCompleteFullInitialization = false

    private(set) var hasInitialized = false
    private(set) var needsOnboarding = false
    private(set) var hasShutDown = false

    var proxyScreenModel: ProxyScreenModel { services.proxyScreenModel }
    var quotaController: QuotaFeatureController { services.quotaController }
    var quotaScreenModel: QuotaScreenModel { services.quotaScreenModel }
    var quotaHistory: QuotaHistoryServiceModel { services.quotaHistory }
    var accountsScreenModel: AccountsScreenModel { services.accountsScreenModel }
    var navigationScreenModel: NavigationScreenModel { services.navigationScreenModel }
    var pasteboard: PasteboardScreenModel { services.pasteboard }
    var providerImageModel: ProviderImageScreenModel { services.providerImageModel }
    var platformActions: PlatformActionScreenModel { services.platformActions }
    var menuBarSettings: MenuBarSettingsManager { services.menuBarSettings }
    var statusBarManager: StatusBarManager { services.statusBarManager }
    var modeManager: OperatingModeManager { services.modeManager }
    var appearanceManager: AppearanceManager { services.appearanceManager }
    var languageManager: LanguageManager { services.languageManager }
    var settingsScreenModel: SettingsScreenModel { services.settingsScreenModel }
    var launchAtLoginModel: LaunchAtLoginScreenModel { services.launchAtLoginModel }
    var notificationSettingsModel: NotificationSettingsScreenModel {
        services.notificationSettingsModel
    }
    var applicationUpdateModel: ApplicationUpdateScreenModel { services.applicationUpdateModel }
    var credentialMigrationModel: CredentialMigrationScreenModel { services.credentialMigrationModel }
    var showInDock: Bool { services.showInDock }
    var canCheckForUpdates: Bool { services.canCheckForUpdates }

    init(services: any AppRuntimeServices) {
        self.services = services
        services.setStatusBarStateChangeHandler { [weak self] in
            self?.handleStatusBarStateChange()
        }
    }

    func prepareForLaunch() {
        guard !didPrepareForLaunch else { return }
        didPrepareForLaunch = true
        services.prepareForLaunch()
    }

    func initializeIfNeeded() async {
        prepareForLaunch()

        if let initializationTask {
            await initializationTask.value
            return
        }
        guard !hasInitialized else {
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performInitialInitialization()
        }
        initializationTask = task
        await task.value
        initializationTask = nil
    }

    func completeOnboarding(mode: OperatingMode) async {
        services.modeManager.completeOnboarding(mode: mode)
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

    private func handleStatusBarStateChange() {
        services.updateStatusBar()
        services.rebuildStatusBar()
    }

    private func performShutdown(timeout: Duration) async -> Bool {
        services.setStatusBarStateChangeHandler(nil)
        initializationTask?.cancel()
        fullInitializationTask?.cancel()

        let (events, continuation) = AsyncStream<Bool>.makeStream()
        let services = services
        let cleanupTask = Task { @MainActor in
            await services.shutdownOAuth()
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

        return completedCleanly
    }
}
