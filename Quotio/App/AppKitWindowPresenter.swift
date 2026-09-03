import AppKit

@MainActor
final class AppKitWindowPresenter {
    func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard let window = NSApplication.shared.windows.first(where: { $0.title == "Quotio" }) else {
            return
        }
        window.makeKeyAndOrderFront(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
    }
}

@MainActor
enum AntigravitySwitchConfirmationPresenter {
    static func confirm(email: String, isIDERunning: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "antigravity.switch.dialog.title".localized()
        alert.informativeText = String(
            format: "antigravity.switch.dialog.message".localized(),
            email
        )
        if isIDERunning {
            alert.informativeText += "\n\n⚠️ " + "antigravity.switch.dialog.warning".localized()
        }
        alert.alertStyle = isIDERunning ? .warning : .informational
        alert.addButton(withTitle: "antigravity.switch.title".localized())
        alert.addButton(withTitle: "action.cancel".localized())
        return alert.runModal() == .alertFirstButtonReturn
    }
}
