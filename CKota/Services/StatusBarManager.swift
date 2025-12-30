//
//  StatusBarManager.swift
//  CKota
//
//  Custom NSStatusBar manager with single combined status item using NSHostingView
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class StatusBarManager {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    private init() {}

    func updateStatusBar(
        items: [MenuBarQuotaDisplayItem],
        colorMode: MenuBarColorMode,
        isRunning: Bool,
        showMenuBarIcon: Bool,
        showQuota: Bool,
        menuContentProvider: @escaping () -> AnyView
    ) {
        guard showMenuBarIcon else {
            removeStatusItem()
            return
        }

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }

        if popover == nil {
            popover = NSPopover()
            popover?.behavior = .transient
            popover?.animates = true
        }
        popover?.contentViewController = NSHostingController(rootView: menuContentProvider())

        guard let button = statusItem?.button else { return }

        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""
        button.image = nil

        let contentView = if !showQuota || !isRunning || items.isEmpty {
            AnyView(
                StatusBarDefaultView(isRunning: isRunning)
            )
        } else {
            AnyView(
                StatusBarQuotaView(items: items, colorMode: colorMode)
            )
        }

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(hostingView.intrinsicContentSize)

        let containerView = StatusBarContainerView(frame: NSRect(origin: .zero, size: hostingView.intrinsicContentSize))
        containerView.addSubview(hostingView)
        hostingView.frame = containerView.bounds

        button.addSubview(containerView)
        button.frame = NSRect(origin: .zero, size: hostingView.intrinsicContentSize)

        button.action = #selector(statusItemClicked(_:))
        button.target = self
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let popover else { return }

        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)

            // Activate the popover window to receive focus immediately
            if let popoverWindow = popover.contentViewController?.view.window {
                popoverWindow.makeKey()
            }

            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
                .leftMouseDown,
                .rightMouseDown,
            ]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    func closePopover() {
        popover?.close()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func removeStatusItem() {
        closePopover()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}

class StatusBarContainerView: NSView {
    override var allowsVibrancy: Bool { true }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }
}

struct StatusBarDefaultView: View {
    let isRunning: Bool

    var body: some View {
        Image(systemName: isRunning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            .font(.system(size: 14))
            .frame(height: 22)
    }
}

struct StatusBarQuotaView: View {
    let items: [MenuBarQuotaDisplayItem]
    let colorMode: MenuBarColorMode

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                StatusBarQuotaItemView(item: item, colorMode: colorMode)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .fixedSize()
    }
}

struct StatusBarQuotaItemView: View {
    let item: MenuBarQuotaDisplayItem
    let colorMode: MenuBarColorMode

    @State private var settings = MenuBarSettingsManager.shared

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode.displayValue(from: item.percentage)

        HStack(spacing: 2) {
            if let assetName = item.provider.menuBarIconAsset {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
            } else {
                Text(item.provider.menuBarSymbol)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorMode == .colored ? item.provider.color : .primary)
                    .fixedSize()
            }

            Text(formatPercentage(displayPercent))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(colorMode == .colored ? item.statusColor : .primary)
                .fixedSize()
        }
        .fixedSize()
    }

    private func formatPercentage(_ value: Double) -> String {
        if value < 0 { return "--%" }
        return String(format: "%.0f%%", value.rounded())
    }
}
