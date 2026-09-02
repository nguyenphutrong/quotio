import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime: AppRuntime

    private nonisolated(unsafe) var windowWillCloseObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeKeyObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeMainObserver: NSObjectProtocol?
    private nonisolated(unsafe) var appDidResignActiveObserver: NSObjectProtocol?
    private var terminationTask: Task<Void, Never>?
    private var pendingForegroundReassert = false
    private weak var trackedDashboardWindow: NSWindow?
    private var lastDashboardActivationDate: Date?
    private var hasTriggeredAntiDropForCurrentActivation = false

    override init() {
        runtime = CompositionRoot.makeProduction()
        super.init()
    }

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppEnvironment.isRunningUnitTests else { return }

        runtime.prepareForLaunch()
        NSApp.setActivationPolicy(runtime.showInDock ? .regular : .accessory)

        Task {
            await runtime.initializeIfNeeded()
        }

        installWindowObservers()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        _ = bringMainWindowToFront(in: sender)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppEnvironment.isRunningUnitTests else { return .terminateNow }
        guard !runtime.hasShutDown else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task {
            let completedCleanly = await runtime.shutdown()
            if !completedCleanly {
                Log.warning("Tunnel cleanup timed out; requested orphan cleanup")
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let keyWindowIsDashboardCandidate = NSApp.keyWindow.map(isDashboardWindowCandidate) ?? false

        if keyWindowIsDashboardCandidate {
            promoteToRegularPolicyWithRetry(remainingAttempts: 3)
            lastDashboardActivationDate = Date()
            hasTriggeredAntiDropForCurrentActivation = false
        }

        guard pendingForegroundReassert else { return }
        guard let window = mainWindow(in: NSApp) else {
            pendingForegroundReassert = false
            return
        }

        window.makeKeyAndOrderFront(nil)
        pendingForegroundReassert = false
    }

    private func installWindowObservers() {
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let closingWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.handleWindowWillClose(closingWindow)
            }
        }

        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey()
            }
        }

        windowDidBecomeMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let mainWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeMain(mainWindow)
            }
        }

        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationDidResignActive()
            }
        }
    }

    private var shouldUseAccessoryPolicy: Bool {
        !runtime.showInDock
    }

    private func ensureRegularPolicyForMainWindowForeground(in app: NSApplication) -> Bool {
        guard shouldUseAccessoryPolicy else { return true }

        if app.activationPolicy() == .regular {
            return true
        }

        return app.setActivationPolicy(.regular)
    }

    private func promoteToRegularPolicyIfNeeded() -> Bool {
        guard shouldUseAccessoryPolicy else { return true }

        if NSApp.activationPolicy() == .regular {
            return true
        }

        _ = NSApp.setActivationPolicy(.regular)
        return NSApp.activationPolicy() == .regular
    }

    private func promoteToRegularPolicyWithRetry(remainingAttempts: Int) {
        guard remainingAttempts > 0 else { return }

        if promoteToRegularPolicyIfNeeded() {
            if let window = mainWindow(in: NSApp) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.promoteToRegularPolicyWithRetry(remainingAttempts: remainingAttempts - 1)
        }
    }

    private func restoreAccessoryPolicyIfNeeded(in app: NSApplication) {
        guard shouldUseAccessoryPolicy else { return }

        let hasVisibleMainCapableWindow = app.windows.contains { window in
            window.canBecomeMain && window.isVisible && !window.isMiniaturized
        }

        if !hasVisibleMainCapableWindow && app.activationPolicy() != .accessory {
            app.setActivationPolicy(.accessory)
        }
    }

    private func bringMainWindowToFront(in app: NSApplication) -> Bool {
        guard let window = mainWindow(in: app) else { return false }
        guard ensureRegularPolicyForMainWindowForeground(in: app) else { return false }

        trackedDashboardWindow = window
        pendingForegroundReassert = true

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])

            if let refreshedWindow = self.mainWindow(in: app) {
                self.trackedDashboardWindow = refreshedWindow
                refreshedWindow.makeKeyAndOrderFront(nil)
            }

            if !app.isActive {
                window.orderFrontRegardless()
            } else {
                self.pendingForegroundReassert = false
            }
        }

        return true
    }

    private func mainWindow(in app: NSApplication) -> NSWindow? {
        if let trackedDashboardWindow,
           app.windows.contains(where: { $0 === trackedDashboardWindow }),
           isDashboardWindowCandidate(trackedDashboardWindow) {
            return trackedDashboardWindow
        }

        return app.windows.first { isDashboardWindowCandidate($0) }
    }

    private func isDashboardWindowCandidate(_ window: NSWindow) -> Bool {
        window.canBecomeMain && window.level == .normal
    }

    private func handleWindowDidBecomeMain(_ window: NSWindow?) {
        guard let window, isDashboardWindowCandidate(window) else { return }
        trackedDashboardWindow = window
    }

    private func handleApplicationDidResignActive() {
        guard !hasTriggeredAntiDropForCurrentActivation else { return }
        guard let activationDate = lastDashboardActivationDate else { return }
        guard Date().timeIntervalSince(activationDate) <= 0.5 else { return }
        guard let dashboardWindow = mainWindow(in: NSApp), dashboardWindow.isVisible else { return }

        hasTriggeredAntiDropForCurrentActivation = true

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            dashboardWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func handleWindowDidBecomeKey() {
        guard let keyWindow = NSApp.keyWindow else { return }
        guard let appMainWindow = mainWindow(in: NSApp), keyWindow === appMainWindow else { return }

        promoteToRegularPolicyWithRetry(remainingAttempts: 3)
        guard ensureRegularPolicyForMainWindowForeground(in: NSApp) else { return }

        if !NSApp.isActive {
            pendingForegroundReassert = true
            NSApp.activate(ignoringOtherApps: true)
            keyWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func handleWindowWillClose(_ closingWindow: NSWindow?) {
        let isClosingDashboardWindow = closingWindow.map {
            ($0 === trackedDashboardWindow) || isDashboardWindowCandidate($0)
        } ?? false

        guard isClosingDashboardWindow else { return }

        DispatchQueue.main.async {
            self.restoreAccessoryPolicyIfNeeded(in: NSApp)
        }
    }

    deinit {
        terminationTask?.cancel()
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowDidBecomeMainObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
