//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with native NSMenu for Liquid Glass appearance.
//  Uses NSStatusBarButton native image/title rendering for compact menu bar layout.
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
        button.attributedTitle = NSAttributedString(string: "")
        button.image = nil
        button.imagePosition = .imageLeft
        
        if !isRunning || items.isEmpty {
            button.image = NSImage(
                systemSymbolName: isRunning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent",
                accessibilityDescription: "Quotio"
            )
            button.image?.size = NSSize(width: 18, height: 18)
            button.imageScaling = .scaleProportionallyUpOrDown
            statusItem?.length = NSStatusItem.variableLength
            return
        }

        let primaryItem = items[0]

        if let assetName = primaryItem.provider.menuBarIconAsset,
           let image = NSImage(named: assetName) {
            let iconSize: CGFloat = primaryItem.provider == .copilot ? 17 : 18
            image.size = NSSize(width: iconSize, height: iconSize)
            button.imageScaling = .scaleProportionallyUpOrDown
            button.image = image
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            // Fallback: symbol letter only
            button.image = nil
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let symbol = primaryItem.provider.menuBarSymbol
            button.attributedTitle = NSAttributedString(
                string: symbol,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            let textWidth = (symbol as NSString).size(withAttributes: [.font: font]).width
            statusItem?.length = ceil(textWidth + 6)
            return
        }
        statusItem?.length = NSStatusItem.variableLength
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
