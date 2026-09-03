//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with native NSMenu for Liquid Glass appearance.
//  Uses NSMenu with SwiftUI hosting views for native macOS styling.
//

import AppKit
import QuotioDomain
import QuotioPresentation
import SwiftUI

@MainActor
@Observable
final class StatusBarManager: NSObject, NSMenuDelegate {
    static let shared = StatusBarManager()

    private struct Configuration: Equatable {
        let items: [MenuBarQuotaDisplayItem]
        let colorMode: MenuBarColorMode
        let quotaDisplayMode: QuotaDisplayMode
        let isRunning: Bool
        let showQuota: Bool
    }

    private struct RenderSignature: Equatable {
        let configuration: Configuration
        let usesDarkColorScheme: Bool
        let backingScaleFactor: CGFloat
        let language: AppLanguage
    }
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuContentVersion: Int = 0
    private var isRebuildingMenu = false
    private var hasPendingMenuRebuild = false
    private var configuration: Configuration?
    private var lastRenderSignature: RenderSignature?
    private var appearanceObservation: NSKeyValueObservation?
    
    // Native menu builder
    private var menuBuilder: StatusBarMenuBuilder?
    
    private override init() {
        super.init()
    }
    
    func setDependencies(
        proxyManagement: ProxyManagementScreenModel,
        quota: QuotaScreenModel,
        accounts: AccountsScreenModel,
        quotaController: QuotaFeatureController,
        antigravityAccounts: AntigravityAccountScreenModel
    ) {
        menuBuilder = StatusBarMenuBuilder(
            proxyManagement: proxyManagement,
            quota: quota,
            accounts: accounts,
            quotaController: quotaController,
            antigravityAccounts: antigravityAccounts
        )
        MenuActionHandler.shared.quotaController = quotaController
    }
    
    /// Highest backing scale factor across all active screens to ensure sharp rendering in multi-monitor setups
    private var targetBackingScaleFactor: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
    }
    
    func updateStatusBar(
        items: [MenuBarQuotaDisplayItem],
        colorMode: MenuBarColorMode,
        quotaDisplayMode: QuotaDisplayMode,
        isRunning: Bool,
        showMenuBarIcon: Bool,
        showQuota: Bool
    ) {
        guard showMenuBarIcon else {
            removeStatusItem()
            return
        }

        configuration = Configuration(
            items: items,
            colorMode: colorMode,
            quotaDisplayMode: quotaDisplayMode,
            isRunning: isRunning,
            showQuota: showQuota
        )
        menuContentVersion += 1

        renderStatusBar()
    }

    private func renderStatusBar() {
        guard let configuration else { return }
        
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            observeStatusBarAppearance()
        }
        
        // Create or update menu
        if menu == nil {
            menu = NSMenu()
            menu?.autoenablesItems = false
            menu?.delegate = self
            menu?.appearance = AppearanceManager.shared.appearanceMode.appKitAppearance
        }
        
        // Attach menu to status item
        statusItem?.menu = menu
        
        guard let button = statusItem?.button else { return }

        let usesDarkColorScheme = button.isHighlighted
            || button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale = targetBackingScaleFactor
        let signature = RenderSignature(
            configuration: configuration,
            usesDarkColorScheme: usesDarkColorScheme,
            backingScaleFactor: scale,
            language: LanguageManager.shared.currentLanguage
        )
        guard signature != lastRenderSignature else { return }
        
        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""
        button.image = nil
        
        if !configuration.showQuota || !configuration.isRunning || configuration.items.isEmpty {
            let imageName = configuration.isRunning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent"
            if let image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Quotio") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
            }
            button.setAccessibilityLabel("Quotio")
            statusItem?.length = NSStatusItem.variableLength
            lastRenderSignature = signature
            return
        }
        
        let colorScheme: ColorScheme = usesDarkColorScheme ? .dark : .light
        
        let quotaView = StatusBarQuotaView(
            items: configuration.items,
            colorMode: configuration.colorMode,
            quotaDisplayMode: configuration.quotaDisplayMode
        )
        .environment(\.colorScheme, colorScheme)
        
        let renderer = ImageRenderer(content: quotaView)
        renderer.scale = scale
        renderer.isOpaque = false
        
        if let cgImage = renderer.cgImage {
            let width = CGFloat(cgImage.width) / scale
            let height = CGFloat(cgImage.height) / scale
            let size = NSSize(width: width, height: height)
            let image = NSImage(cgImage: cgImage, size: size)
            if configuration.colorMode == .monochrome {
                image.isTemplate = true
            }
            
            let description = accessibilityDescription(
                for: configuration.items,
                displayMode: configuration.quotaDisplayMode
            )
            image.accessibilityDescription = description
            button.setAccessibilityLabel(description)
            
            button.image = image
            button.imagePosition = .imageOnly
            statusItem?.length = width
            lastRenderSignature = signature
        }
    }

    private func observeStatusBarAppearance() {
        guard let button = statusItem?.button else { return }

        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.renderStatusBar()
            }
        }
    }
    
    private func accessibilityDescription(for items: [MenuBarQuotaDisplayItem], displayMode: QuotaDisplayMode) -> String {
        let itemDescriptions = items.map { item -> String in
            let providerName = item.provider.displayName
            if item.isForbidden {
                return "\(providerName): \("status.error".localized())"
            }
            if let pair = item.quotaPair {
                let topDesc = "\(pair.top.labelKey.localized()): \(StatusBarQuotaItemView.accessibilityValue(for: pair.top, displayMode: displayMode))"
                let bottomDesc = "\(pair.bottom.labelKey.localized()): \(StatusBarQuotaItemView.accessibilityValue(for: pair.bottom, displayMode: displayMode))"
                return "\(providerName): \(topDesc), \(bottomDesc)"
            }
            if item.percentage >= 0 {
                let displayedValue = displayMode.displayValue(from: item.percentage)
                let clamped = min(100, max(0, displayedValue))
                let percentString = String(format: "%lld percent".localized(), Int64(clamped.rounded()))
                return "\(providerName): \(percentString)"
            }
            return "\(providerName): \("quota.noDataYet".localized())"
        }
        return "Quotio, " + itemDescriptions.joined(separator: ", ")
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        hasPendingMenuRebuild = false
        renderStatusBar()
        performMenuRebuild(using: menu)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            self?.renderStatusBar()
        }
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

        menu.appearance = AppearanceManager.shared.appearanceMode.appKitAppearance
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
        appearanceObservation = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menu = nil
        configuration = nil
        lastRenderSignature = nil
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
    let quotaDisplayMode: QuotaDisplayMode
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                StatusBarQuotaItemView(
                    item: item,
                    colorMode: colorMode,
                    quotaDisplayMode: quotaDisplayMode
                )
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
    var quotaDisplayMode: QuotaDisplayMode = .used
    
    var body: some View {
        let displayPercent = quotaDisplayMode.displayValue(from: item.percentage)
        
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
            } else if let quotaPair = item.quotaPair {
                VStack(alignment: .trailing, spacing: 0) {
                    compactQuotaText(quotaPair.top.remainingPercentage)
                    compactQuotaText(quotaPair.bottom.remainingPercentage)
                }
                .frame(height: 18)
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
        if value < 0 { return "—" }
        // Defensive clamp to valid 0-100 range
        let clamped = min(100, max(0, value))
        return String(format: "%.0f%%", clamped.rounded())
    }

    private func compactQuotaText(_ remainingValue: Double) -> some View {
        let displayedValue = remainingValue < 0
            ? -1
            : quotaDisplayMode.displayValue(from: remainingValue)
        let quotaColor: Color = remainingValue < 0
            ? .secondary
            : item.statusColor(for: remainingValue)

        return Text(formatPercentage(displayedValue))
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(colorMode == .colored ? quotaColor : .primary)
            .fixedSize()
    }

    static func accessibilityValue(for metric: MenuBarQuotaMetric, displayMode: QuotaDisplayMode) -> String {
        guard metric.remainingPercentage >= 0 else {
            return "quota.noDataYet".localized()
        }

        let displayedValue = displayMode.displayValue(from: metric.remainingPercentage)
        let clamped = min(100, max(0, displayedValue))
        return String(format: "%lld percent".localized(), Int64(clamped.rounded()))
    }
}
