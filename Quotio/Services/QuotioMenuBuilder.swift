//
//  QuotioMenuBuilder.swift
//  Quotio
//
//  Native NSMenu builder with cascading submenus for Antigravity accounts.
//  Uses NSMenuItem.submenu for native macOS submenu behavior on hover.
//

import AppKit
import SwiftUI

/// Builds native NSMenu for menu bar dropdown with cascading submenus
@MainActor
final class QuotioMenuBuilder {
    
    private let menuWidth: CGFloat = 280
    private weak var viewModel: QuotaViewModel?
    
    // MARK: - Initialization
    
    init(viewModel: QuotaViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - Public API
    
    /// Build the complete menu for the status bar item
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // Header section
        addHeaderSection(to: menu)
        
        // Proxy info section (Full Mode only)
        if AppModeManager.shared.isFullMode {
            menu.addItem(NSMenuItem.separator())
            addProxyInfoSection(to: menu)
        }
        
        // Provider quota sections
        let providersWithData = getProvidersWithData()
        if !providersWithData.isEmpty {
            menu.addItem(NSMenuItem.separator())
            addProviderSections(to: menu, providers: providersWithData)
        } else {
            menu.addItem(NSMenuItem.separator())
            addEmptyStateSection(to: menu)
        }
        
        // Actions section
        menu.addItem(NSMenuItem.separator())
        addActionsSection(to: menu)
        
        return menu
    }
    
    // MARK: - Header Section
    
    private func addHeaderSection(to menu: NSMenu) {
        let headerView = MenuBuilderHeaderView(isLoading: viewModel?.isLoadingQuotas ?? false)
        let item = makeViewItem(for: headerView)
        menu.addItem(item)
    }
    
    // MARK: - Proxy Info Section
    
    private func addProxyInfoSection(to menu: NSMenu) {
        guard let viewModel = viewModel else { return }
        
        let proxyView = MenuBuilderProxyInfoView(
            port: viewModel.proxyManager.port,
            isRunning: viewModel.proxyManager.proxyStatus.running,
            onToggle: { [weak viewModel] in
                Task { await viewModel?.toggleProxy() }
            }
        )
        let item = makeViewItem(for: proxyView)
        menu.addItem(item)
    }
    
    // MARK: - Provider Sections
    
    private func addProviderSections(to menu: NSMenu, providers: [AIProvider]) {
        guard let viewModel = viewModel else { return }
        
        for provider in providers {
            guard let accountQuotas = viewModel.providerQuotas[provider] else { continue }
            
            // Provider header
            let headerItem = NSMenuItem()
            headerItem.attributedTitle = NSAttributedString(
                string: provider.displayName,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            
            // Account rows
            let sortedAccounts = accountQuotas.sorted { $0.key < $1.key }
            for (email, quotaData) in sortedAccounts {
                let accountItem = makeAccountItem(
                    email: email,
                    quotaData: quotaData,
                    provider: provider
                )
                menu.addItem(accountItem)
            }
        }
    }
    
    // MARK: - Account Item with Submenu
    
    private func makeAccountItem(email: String, quotaData: ProviderQuotaData, provider: AIProvider) -> NSMenuItem {
        let isAntigravity = provider == .antigravity && quotaData.hasGroupedModels
        let settings = MenuBarSettingsManager.shared
        let displayEmail = email.masked(if: settings.hideSensitiveInfo)
        
        // Create the account row view
        let accountView = MenuBuilderAccountRow(
            email: displayEmail,
            quotaData: quotaData,
            provider: provider,
            hasSubmenu: isAntigravity
        )
        
        let item = makeViewItem(for: accountView)
        
        // For Antigravity accounts, attach a native submenu
        if isAntigravity {
            let submenu = buildAntigravitySubmenu(groups: quotaData.groupedModels)
            item.submenu = submenu
        }
        
        return item
    }
    
    // MARK: - Antigravity Submenu
    
    private func buildAntigravitySubmenu(groups: [GroupedModelQuota]) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        for (index, group) in groups.enumerated() {
            // Group header
            let groupView = MenuBuilderGroupHeader(group: group)
            let headerItem = makeViewItem(for: groupView)
            submenu.addItem(headerItem)
            
            // Individual models in the group
            for model in group.models {
                let modelView = MenuBuilderModelRow(model: model)
                let modelItem = makeViewItem(for: modelView)
                submenu.addItem(modelItem)
            }
            
            // Add separator between groups (but not after the last one)
            if index < groups.count - 1 {
                submenu.addItem(NSMenuItem.separator())
            }
        }
        
        return submenu
    }
    
    // MARK: - Empty State Section
    
    private func addEmptyStateSection(to menu: NSMenu) {
        let emptyView = MenuBuilderEmptyState()
        let item = makeViewItem(for: emptyView)
        menu.addItem(item)
    }
    
    // MARK: - Actions Section
    
    private func addActionsSection(to menu: NSMenu) {
        // Refresh action
        let refreshItem = NSMenuItem(
            title: "action.refresh".localized(),
            action: #selector(MenuActionHandler.refreshAction),
            keyEquivalent: "r"
        )
        refreshItem.target = MenuActionHandler.shared
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshItem.isEnabled = !(viewModel?.isLoadingQuotas ?? false)
        menu.addItem(refreshItem)
        
        // Open App action
        let openAppItem = NSMenuItem(
            title: "action.openApp".localized(),
            action: #selector(MenuActionHandler.openAppAction),
            keyEquivalent: ""
        )
        openAppItem.target = MenuActionHandler.shared
        openAppItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openAppItem)
        
        // Quit action
        let quitItem = NSMenuItem(
            title: "action.quit".localized(),
            action: #selector(MenuActionHandler.quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = MenuActionHandler.shared
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quitItem)
    }
    
    // MARK: - Helper Methods
    
    private func getProvidersWithData() -> [AIProvider] {
        guard let viewModel = viewModel else { return [] }
        
        var providers = Set<AIProvider>()
        for (provider, accountQuotas) in viewModel.providerQuotas {
            if !accountQuotas.isEmpty {
                providers.insert(provider)
            }
        }
        return providers.sorted { $0.displayName < $1.displayName }
    }
    
    private func makeViewItem<V: View>(for view: V) -> NSMenuItem {
        let hostingView = NSHostingView(rootView: view.frame(width: menuWidth))
        hostingView.setFrameSize(hostingView.fittingSize)
        
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }
}

// MARK: - Menu Action Handler

/// Singleton to handle menu actions (NSMenuItem target must be an object)
@MainActor
final class MenuActionHandler: NSObject {
    static let shared = MenuActionHandler()
    
    private override init() {
        super.init()
    }
    
    @objc func refreshAction() {
        Task {
            // Get the QuotaViewModel from StatusBarManager context
            // Note: This works because StatusBarManager holds a reference
            await StatusBarManager.shared.triggerRefresh()
        }
    }
    
    @objc func openAppAction() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Quotio" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - SwiftUI Views for Menu Items

/// Header view showing "Quotio" title and loading indicator
private struct MenuBuilderHeaderView: View {
    let isLoading: Bool
    
    var body: some View {
        HStack {
            Text("Quotio")
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
            
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Proxy info section for Full Mode
private struct MenuBuilderProxyInfoView: View {
    let port: UInt16
    let isRunning: Bool
    let onToggle: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            // Proxy URL
            HStack {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("http://localhost:\(port)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                
                Spacer()
                
                Button {
                    let url = "http://localhost:\(port)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            // Status row
            HStack {
                Circle()
                    .fill(isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                
                Text(isRunning ? "status.running".localized() : "status.stopped".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: onToggle) {
                    Text(isRunning ? "action.stop".localized() : "action.start".localized())
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isRunning ? .red : .green)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
    }
}

/// Account row showing email, plan, and quota percentage
private struct MenuBuilderAccountRow: View {
    let email: String
    let quotaData: ProviderQuotaData
    let provider: AIProvider
    let hasSubmenu: Bool
    
    private var lowestPercentage: Double {
        let validPercentages = quotaData.models.map(\.percentage).filter { $0 >= 0 }
        return validPercentages.min() ?? -1
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Quota indicator dot
            Circle()
                .fill(quotaColor(for: lowestPercentage))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(email)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                
                if let plan = quotaData.planDisplayName {
                    Text(plan)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Percentage
            Text(formatPercentage(lowestPercentage))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(quotaColor(for: lowestPercentage))
            
            // Submenu indicator for Antigravity
            if hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    private func formatPercentage(_ value: Double) -> String {
        if value < 0 { return "—" }
        return "\(Int(value))%"
    }
    
    private func quotaColor(for percentage: Double) -> Color {
        if percentage < 0 { return .gray }
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
}

/// Group header in Antigravity submenu
private struct MenuBuilderGroupHeader: View {
    let group: GroupedModelQuota
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.group.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            
            Text(group.displayName)
                .font(.system(size: 12, weight: .semibold))
            
            Spacer()
            
            Text(formatPercentage(group.percentage))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(quotaColor(for: group.percentage))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    private func formatPercentage(_ value: Double) -> String {
        if value < 0 { return "—" }
        return "\(Int(value))%"
    }
    
    private func quotaColor(for percentage: Double) -> Color {
        if percentage < 0 { return .gray }
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
}

/// Individual model row in Antigravity submenu
private struct MenuBuilderModelRow: View {
    let model: ModelQuota
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(quotaColor(for: model.percentage))
                .frame(width: 6, height: 6)
            
            Text(model.displayName)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            Text(formatPercentage(model.percentage))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            
            // Mini progress bar
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(quotaColor(for: model.percentage))
                        .frame(width: proxy.size.width * min(1, max(0, model.percentage / 100)))
                }
            }
            .frame(width: 40, height: 4)
        }
        .padding(.leading, 20) // Indent under group header
        .padding(.trailing, 12)
        .padding(.vertical, 4)
    }
    
    private func formatPercentage(_ value: Double) -> String {
        if value < 0 { return "—" }
        return "\(Int(value))%"
    }
    
    private func quotaColor(for percentage: Double) -> Color {
        if percentage < 0 { return .gray }
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
}

/// Empty state when no quota data available
private struct MenuBuilderEmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No quota data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
