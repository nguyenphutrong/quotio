//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with native NSMenu for Liquid Glass appearance.
//  Uses NSMenu + SwiftUI hosting views for menu bar rendering.
//

import AppKit

@MainActor
@Observable
final class StatusBarManager: NSObject, NSMenuDelegate {
    static let shared = StatusBarManager()
    private static let statusBarIconSize = NSSize(width: 18, height: 18)

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

        // Show icon only and let AppKit manage sizing/layout natively.
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.attributedTitle = NSAttributedString(string: "")

        let iconImage = makeStatusBarIcon(
            items: items,
            isRunning: isRunning,
            showQuota: showQuota
        )
        // Menu bar icon assets are template-oriented; keep template rendering
        // to ensure correct contrast in light/dark menu bar appearances.
        iconImage?.isTemplate = true
        button.contentTintColor = nil
        button.image = iconImage
    }

    private func makeStatusBarIcon(
        items: [MenuBarQuotaDisplayItem],
        isRunning: Bool,
        showQuota: Bool
    ) -> NSImage? {
        func prepared(_ image: NSImage?) -> NSImage? {
            guard let image else { return nil }
            image.size = Self.statusBarIconSize
            return image
        }

        if showQuota, isRunning, let provider = items.first?.provider {
            if let assetName = provider.menuBarIconAsset {
                return prepared(NSImage(named: NSImage.Name(assetName)))
            }
            return prepared(NSImage(
                systemSymbolName: provider.iconName,
                accessibilityDescription: provider.displayName
            ))
        }

        let fallbackSymbol = isRunning
            ? "gauge.with.dots.needle.67percent"
            : "gauge.with.dots.needle.0percent"
        return prepared(NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: "Quotio"))
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
