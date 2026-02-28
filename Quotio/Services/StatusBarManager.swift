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

        // Clean up any legacy subviews from previous rendering approach
        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""

        // Render SwiftUI content to NSImage and assign to button.image.
        // This is the only way to get native system-level compact sizing
        // (identical to Wi-Fi, Bluetooth, Control Center icons).
        let contentView: AnyView
        let useTemplate: Bool
        if !showQuota || !isRunning || items.isEmpty {
            contentView = AnyView(StatusBarDefaultView(isRunning: isRunning))
            useTemplate = true
        } else {
            let isColored = colorMode == .colored
            contentView = AnyView(StatusBarProviderOnlyView(items: items, colorMode: colorMode))
            // Template mode enables native highlight + dark mode;
            // disable it only when user explicitly wants colored icons.
            useTemplate = !isColored
        }

        let image = renderSwiftUIToImage(contentView)
        image.isTemplate = useTemplate
        button.image = image
    }

    // MARK: - SwiftUI → NSImage Rendering

    /// Renders a SwiftUI view into an NSImage at the correct scale for the status bar.
    private func renderSwiftUIToImage(_ view: some View) -> NSImage {
        let hostingView = NSHostingView(rootView: view)
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = .intrinsicContentSize
        }
        let size = hostingView.intrinsicContentSize
        hostingView.frame = NSRect(origin: .zero, size: size)

        let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)!
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        let image = NSImage(size: size)
        image.addRepresentation(bitmapRep)
        return image
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
        HStack(spacing: 4) {
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
