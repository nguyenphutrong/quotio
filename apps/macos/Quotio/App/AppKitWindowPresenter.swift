import AppKit

@MainActor
final class AppKitWindowPresenter {
    static let mainWindowID = "main"

    private let activate: @MainActor () -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private var openScene: (@MainActor (String) -> Void)?
    private var hasPendingRequest = false

    init(
        activate: @escaping @MainActor () -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        },
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            DispatchQueue.main.async { action() }
        }
    ) {
        self.activate = activate
        self.schedule = schedule
    }

    func registerSceneOpener(_ openScene: @escaping @MainActor (String) -> Void) {
        self.openScene = openScene
        if hasPendingRequest {
            showMainWindow()
        }
    }

    func showMainWindow() {
        guard openScene != nil else {
            hasPendingRequest = true
            return
        }

        hasPendingRequest = false
        // Let the status menu finish dismissing before opening and activating the scene.
        schedule { [weak self] in
            guard let self, let openScene = self.openScene else { return }
            openScene(Self.mainWindowID)
            self.activate()
        }
    }
}
