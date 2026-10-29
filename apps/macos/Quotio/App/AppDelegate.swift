import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime: AppRuntime

    private var terminationTask: Task<Void, Never>?

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
        // A visible window can stay in accessory mode; opening it must not override this preference.
        NSApp.setActivationPolicy(runtime.showInDock ? .regular : .accessory)

        Task {
            await runtime.initializeIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.windowPresenter.showMainWindow()
        return false
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

    deinit {
        terminationTask?.cancel()
    }
}
