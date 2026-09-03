// Menu-native tooltip support for status bar SwiftUI content.

import AppKit
import SwiftUI

@MainActor
private final class MenuTooltipPresenter {
    private let window = MenuTooltipWindow()

    func show(text: String, near view: NSView) {
        window.show(text: text, near: view)
    }

    func hide() {
        window.hide()
    }
}

@MainActor
private final class MenuTooltipWindow: NSWindow {
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .transient]
        ignoresMouseEvents = true

        let effectView = NSVisualEffectView()
        effectView.material = .toolTip
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 6

        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -5)
        ])
        contentView = effectView
    }

    func show(text: String, near view: NSView) {
        guard !text.isEmpty else {
            hide()
            return
        }

        label.stringValue = text
        label.sizeToFit()
        let labelSize = label.fittingSize
        let windowSize = NSSize(width: min(labelSize.width + 18, 360), height: labelSize.height + 10)

        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let viewFrame = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
        var origin = NSPoint(
            x: viewFrame.midX - windowSize.width / 2,
            y: viewFrame.maxY + 5
        )
        if origin.x < screenFrame.minX {
            origin.x = screenFrame.minX
        }
        if origin.x + windowSize.width > screenFrame.maxX {
            origin.x = screenFrame.maxX - windowSize.width
        }
        if origin.y + windowSize.height > screenFrame.maxY {
            origin.y = viewFrame.minY - windowSize.height - 5
        }
        if origin.y < screenFrame.minY {
            origin.y = screenFrame.minY
        }

        setFrame(NSRect(origin: origin, size: windowSize), display: true)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

@MainActor
private final class MenuTooltipTrackingView: NSView {
    let presenter: MenuTooltipPresenter
    var text = ""

    init(presenter: MenuTooltipPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        presenter.show(text: text, near: self)
    }

    override func mouseMoved(with event: NSEvent) {
        presenter.show(text: text, near: self)
    }

    override func mouseExited(with event: NSEvent) {
        presenter.hide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            presenter.hide()
        }
    }

    override func removeFromSuperview() {
        presenter.hide()
        super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct MenuNativeTooltipView: NSViewRepresentable {
    @MainActor
    final class Coordinator {
        let presenter = MenuTooltipPresenter()
    }

    let text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MenuTooltipTrackingView {
        let view = MenuTooltipTrackingView(presenter: context.coordinator.presenter)
        view.text = text
        return view
    }

    func updateNSView(_ nsView: MenuTooltipTrackingView, context: Context) {
        nsView.text = text
    }

    static func dismantleNSView(_ nsView: MenuTooltipTrackingView, coordinator: Coordinator) {
        coordinator.presenter.hide()
    }
}

extension View {
    func menuNativeTooltip(_ text: String) -> some View {
        overlay(MenuNativeTooltipView(text: text))
    }
}
