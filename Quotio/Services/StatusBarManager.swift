//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with native NSMenu for Liquid Glass appearance.
//  Uses NSMenu + SwiftUI hosting views for menu bar rendering.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class StatusBarManager: NSObject, NSMenuDelegate {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuContentVersion: Int = 0
    private var isRebuildingMenu = false
    private var hasPendingMenuRebuild = false

    // Native menu builder
    private var menuBuilder: StatusBarMenuBuilder?
    private weak var viewModel: QuotaViewModel?

    private override init() {
        super.init()
    }

    func setViewModel(_ viewModel: QuotaViewModel) {
        self.viewModel = viewModel
        self.menuBuilder = StatusBarMenuBuilder(viewModel: viewModel)
        MenuActionHandler.shared.viewModel = viewModel
    }

    func updateStatusBar(
        items: [MenuBarQuotaDisplayItem],
        colorMode: MenuBarColorMode,
        isRunning: Bool,
        showMenuBarIcon: Bool,
        showQuota: Bool
    ) {
        guard showMenuBarIcon else {
            removeStatusItem()
            return
        }

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }

        self.menuContentVersion += 1

        // Create or update menu
        if menu == nil {
            menu = NSMenu()
            menu?.autoenablesItems = false
            menu?.delegate = self
        }

        // Attach menu to status item
        statusItem?.menu = menu

        guard let button = statusItem?.button else { return }

        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""
        button.image = nil

        let contentView: AnyView
        let isProviderIconOnly: Bool
        if !showQuota || !isRunning || items.isEmpty {
            isProviderIconOnly = false
            contentView = AnyView(StatusBarDefaultView(isRunning: isRunning))
        } else {
            // Keep current product behavior: show provider icon only in menu bar.
            isProviderIconOnly = true
            contentView = AnyView(StatusBarProviderOnlyView(items: items, colorMode: colorMode))
        }

        let hostingView = NSHostingView(rootView: contentView)
        // Remove default NSHostingView layout margins for tighter sizing
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = .intrinsicContentSize
        }
        hostingView.setFrameSize(hostingView.intrinsicContentSize)

        let contentSize = hostingView.intrinsicContentSize
        let containerHeight = max(22, contentSize.height)
        // Match native macOS status bar item sizing:
        // System icons (Wi-Fi, battery, etc.) typically use thickness (~22pt) as their width.
        let nativeIconWidth = NSStatusBar.system.thickness
        let targetWidth: CGFloat
        if isProviderIconOnly {
            // Provider icon (17pt) centered with minimal side insets, matching native icon items.
            targetWidth = nativeIconWidth
            statusItem?.length = targetWidth
        } else {
            // Default gauge icon: use content width but at least native icon width.
            targetWidth = max(nativeIconWidth, contentSize.width)
            statusItem?.length = targetWidth
        }

        let containerView = StatusBarContainerView(
            frame: NSRect(origin: .zero, size: NSSize(width: targetWidth, height: containerHeight))
        )
        containerView.addSubview(hostingView)
        hostingView.frame = NSRect(
            x: floor((targetWidth - contentSize.width) / 2),
            y: (containerHeight - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )

        button.addSubview(containerView)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        hasPendingMenuRebuild = false
        performMenuRebuild(using: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Cleanup
    }

    /// Force rebuild menu while it's open (e.g., when provider changes)
    func rebuildMenuInPlace() {
        guard let menu = menu else { return }

        if statusItem?.button?.isHighlighted != true {
            hasPendingMenuRebuild = true
            return
        }

        if isRebuildingMenu {
            hasPendingMenuRebuild = true
            return
        }

        performMenuRebuild(using: menu)
    }

    /// Close the menu programmatically
    func closeMenu() {
        menu?.cancelTracking()
    }

    private func performMenuRebuild(using menu: NSMenu) {
        if isRebuildingMenu {
            hasPendingMenuRebuild = true
            return
        }

        isRebuildingMenu = true
        defer {
            isRebuildingMenu = false
            if hasPendingMenuRebuild, statusItem?.button?.isHighlighted == true {
                hasPendingMenuRebuild = false
                DispatchQueue.main.async { [weak self] in
                    self?.rebuildMenuInPlace()
                }
            }
        }

        menu.removeAllItems()

        guard let builder = menuBuilder else { return }

        let nativeMenu = builder.buildMenu()
        for item in nativeMenu.items {
            nativeMenu.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - Menu Actions

    /// Force refresh menu content on next open
    func invalidateMenuContent() {
        menuContentVersion += 1
    }

    func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menu = nil
    }
}

// MARK: - Status Bar Container View

final class StatusBarContainerView: NSView {
    override var allowsVibrancy: Bool { true }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }
}

// MARK: - Status Bar Default View

struct StatusBarDefaultView: View {
    let isRunning: Bool

    var body: some View {
        Image(systemName: isRunning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            .font(.system(size: 14))
            .frame(height: 22)
    }
}

// MARK: - Status Bar Provider-Only View

struct StatusBarProviderOnlyView: View {
    let items: [MenuBarQuotaDisplayItem]
    let colorMode: MenuBarColorMode

    var body: some View {
        HStack(spacing: 6) {
            if let first = items.first {
                StatusBarProviderIconView(item: first, colorMode: colorMode)
            }
        }
        .padding(.horizontal, 0)
        .frame(height: 22)
        .fixedSize()
    }
}

struct StatusBarProviderIconView: View {
    let item: MenuBarQuotaDisplayItem
    let colorMode: MenuBarColorMode

    var body: some View {
        let iconSize: CGFloat = 17
        let symbolFontSize: CGFloat = 12

        Group {
            if let assetName = item.provider.menuBarIconAsset {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
            } else {
                Text(item.provider.menuBarSymbol)
                    .font(.system(size: symbolFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorMode == .colored ? item.provider.color : .primary)
                    .fixedSize()
            }
        }
        .fixedSize()
    }
}
