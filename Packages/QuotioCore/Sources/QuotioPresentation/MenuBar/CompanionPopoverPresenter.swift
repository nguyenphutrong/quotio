import AppKit
import SwiftUI

@MainActor
final class CompanionPopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var model: CompanionScreenModel?
    var isShown: Bool { popover?.isShown == true }

    func show(relativeTo anchor: NSView, model: CompanionScreenModel,
              pasteboard: PasteboardScreenModel, locale: Locale) {
        guard anchor.window != nil else { return }
        if let popover, popover.isShown, self.model === model {
            model.presentPairing(in: .menuBar)
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        close()
        self.model = model
        model.presentPairing(in: .menuBar)
        let content = CompanionPopoverContent(model: model, close: { [weak self] in self?.close() })
            .frame(width: 400)
            .environment(pasteboard)
            .environment(\.locale, locale)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = hosting.view.fittingSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        hosting.view.window?.makeKey()
    }

    func close() {
        let closing = popover
        popover = nil
        closing?.delegate = nil
        closing?.close()
        closing?.contentViewController = nil
        model?.hidePairing(in: .menuBar)
        model = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        close()
    }
}

private struct CompanionPopoverContent: View {
    @Bindable var model: CompanionScreenModel
    let close: () -> Void

    var body: some View {
        CompanionPairingView(model: model, presentation: .menuBar)
            .onChange(of: model.presentation) { _, presentation in
                if presentation != .menuBar { close() }
            }
    }
}
