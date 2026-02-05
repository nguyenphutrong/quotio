//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with native NSMenu for Liquid Glass appearance.
//  Uses NSMenu with SwiftUI hosting views for native macOS styling.
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
        if !showQuota || !isRunning || items.isEmpty {
            contentView = AnyView(
                StatusBarDefaultView(isRunning: isRunning)
            )
        } else {
            contentView = AnyView(
                StatusBarQuotaView(items: items, colorMode: colorMode)
            )
        }
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        
        // Add horizontal padding to align with native status bar spacing
        let horizontalPadding: CGFloat = 4
        let contentSize = hostingView.intrinsicContentSize
        let containerSize = NSSize(
            width: contentSize.width + horizontalPadding * 2,
            height: max(22, contentSize.height)
        )
        
        let containerView = StatusBarContainerView(frame: NSRect(origin: .zero, size: containerSize))
        containerView.addSubview(hostingView)
        hostingView.frame = NSRect(
            x: horizontalPadding,
            y: (containerSize.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        
        button.addSubview(containerView)
        button.frame = NSRect(origin: .zero, size: containerSize)
        statusItem?.length = containerSize.width
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        populateMenu()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        // Cleanup
    }
    
    /// Force rebuild menu while it's open (e.g., when provider changes)
    func rebuildMenuInPlace() {
        guard let menu = menu else { return }
        populateMenu()
        menu.update()
    }

    /// Close the menu programmatically
    func closeMenu() {
        menu?.cancelTracking()
    }

    private func populateMenu() {
        guard let menu = menu else { return }
        
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

// MARK: - Status Bar Quota View

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

// MARK: - Status Bar Quota Item View

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
            
            if item.isForbidden {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if item.percentage >= 0 {
                Text(formatPercentage(displayPercent))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(colorMode == .colored ? item.statusColor : .primary)
                    .fixedSize()
            }
        }
        .fixedSize()
    }
    
    private func formatPercentage(_ value: Double) -> String {
        if value < 0 { return "--%"}
        // Defensive clamp to valid 0-100 range
        let clamped = min(100, max(0, value))
        return String(format: "%.0f%%", clamped.rounded())
    }
}
