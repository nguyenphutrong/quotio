//
//  StatusBarMenuBuilder.swift
//  Quotio
//
//  Native NSMenu builder with cascading submenus for provider accounts.
//  Follows RepoBar pattern: NSMenu → NSMenuItem → submenu: NSMenu
//

import AppKit
import SwiftUI

// MARK: - Menu Builder Protocol

@MainActor
protocol MenuItemProvider {
    func buildMenuItems() -> [NSMenuItem]
}

// MARK: - Status Bar Menu Builder

@MainActor
final class StatusBarMenuBuilder {
    
    private let viewModel: QuotaViewModel
    private let modeManager = AppModeManager.shared
    private let menuWidth: CGFloat = 300
    
    init(viewModel: QuotaViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - Build Menu
    
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // Header
        menu.addItem(buildHeaderItem())
        menu.addItem(NSMenuItem.separator())
        
        // Proxy info (Full Mode only)
        if modeManager.isFullMode {
            menu.addItem(buildProxyInfoItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // Provider sections with account submenus
        let providers = providersWithData
        if !providers.isEmpty {
            for provider in providers {
                menu.addItem(buildProviderSection(for: provider))
            }
            menu.addItem(NSMenuItem.separator())
        } else {
            menu.addItem(buildEmptyStateItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // Action items
        for item in buildActionItems() {
            menu.addItem(item)
        }
        
        return menu
    }
    
    // MARK: - Data Helpers
    
    private var providersWithData: [AIProvider] {
        var providers = Set<AIProvider>()
        for (provider, accountQuotas) in viewModel.providerQuotas {
            if !accountQuotas.isEmpty {
                providers.insert(provider)
            }
        }
        return providers.sorted { $0.displayName < $1.displayName }
    }
    
    private func accountsForProvider(_ provider: AIProvider) -> [(email: String, data: ProviderQuotaData)] {
        guard let quotas = viewModel.providerQuotas[provider] else { return [] }
        return quotas.map { ($0.key, $0.value) }.sorted { $0.email < $1.email }
    }
    
    // MARK: - Header Item
    
    private func buildHeaderItem() -> NSMenuItem {
        let headerView = MenuHeaderView(isLoading: viewModel.isLoadingQuotas)
        return viewItem(for: headerView)
    }
    
    // MARK: - Proxy Info Item
    
    private func buildProxyInfoItem() -> NSMenuItem {
        let proxyView = MenuProxyInfoView(
            port: viewModel.proxyManager.port,
            isRunning: viewModel.proxyManager.proxyStatus.running,
            onToggle: { [weak viewModel] in
                Task { await viewModel?.toggleProxy() }
            },
            onCopyURL: {
                let url = "http://localhost:\(self.viewModel.proxyManager.port)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        )
        return viewItem(for: proxyView)
    }
    
    // MARK: - Provider Section with Submenu
    
    private func buildProviderSection(for provider: AIProvider) -> NSMenuItem {
        let accounts = accountsForProvider(provider)
        
        // Provider header item
        let providerView = MenuProviderHeaderView(
            provider: provider,
            accountCount: accounts.count,
            lowestQuota: lowestQuotaPercent(for: provider)
        )
        
        let providerItem = viewItem(for: providerView)
        
        // Build submenu for accounts
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        for account in accounts {
            let accountItem = buildAccountItem(
                email: account.email,
                data: account.data,
                provider: provider
            )
            submenu.addItem(accountItem)
        }
        
        providerItem.submenu = submenu
        
        return providerItem
    }
    
    // MARK: - Account Item with Detail Submenu
    
    private func buildAccountItem(
        email: String,
        data: ProviderQuotaData,
        provider: AIProvider
    ) -> NSMenuItem {
        // Account summary view (shows in parent menu)
        let accountView = MenuAccountSummaryView(
            email: email,
            data: data,
            provider: provider
        )
        
        let accountItem = viewItem(for: accountView)
        
        // Build detail submenu for models/groups
        let detailSubmenu = NSMenu()
        detailSubmenu.autoenablesItems = false
        
        if provider == .antigravity && data.hasGroupedModels {
            // Grouped models for Antigravity
            for group in data.groupedModels {
                let groupItem = buildGroupDetailItem(group: group)
                detailSubmenu.addItem(groupItem)
                
                // Individual models under this group
                for model in group.models.sorted(by: { $0.name < $1.name }) {
                    let modelItem = buildModelDetailItem(model: model, indented: true)
                    detailSubmenu.addItem(modelItem)
                }
                
                detailSubmenu.addItem(NSMenuItem.separator())
            }
        } else {
            // Regular models
            for model in data.models.sorted(by: { $0.name < $1.name }) {
                let modelItem = buildModelDetailItem(model: model, indented: false)
                detailSubmenu.addItem(modelItem)
            }
        }
        
        // Only add submenu if there are items
        if detailSubmenu.items.count > 0 {
            accountItem.submenu = detailSubmenu
        }
        
        return accountItem
    }
    
    // MARK: - Group Detail Item
    
    private func buildGroupDetailItem(group: GroupedModelQuota) -> NSMenuItem {
        let groupView = MenuGroupDetailView(group: group)
        return viewItem(for: groupView)
    }
    
    // MARK: - Model Detail Item
    
    private func buildModelDetailItem(model: ModelQuota, indented: Bool) -> NSMenuItem {
        let modelView = MenuModelDetailView(model: model, indented: indented)
        return viewItem(for: modelView)
    }
    
    // MARK: - Empty State
    
    private func buildEmptyStateItem() -> NSMenuItem {
        let emptyView = MenuEmptyStateView()
        return viewItem(for: emptyView)
    }
    
    // MARK: - Action Items
    
    private func buildActionItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        
        // Refresh action
        let refreshItem = NSMenuItem(
            title: "action.refresh".localized(),
            action: #selector(MenuActionHandler.refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = MenuActionHandler.shared
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshItem.isEnabled = !viewModel.isLoadingQuotas
        items.append(refreshItem)
        
        // Open App action
        let openItem = NSMenuItem(
            title: "action.openApp".localized(),
            action: #selector(MenuActionHandler.openApp),
            keyEquivalent: "o"
        )
        openItem.target = MenuActionHandler.shared
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        items.append(openItem)
        
        items.append(NSMenuItem.separator())
        
        // Quit action
        let quitItem = NSMenuItem(
            title: "action.quit".localized(),
            action: #selector(MenuActionHandler.quit),
            keyEquivalent: "q"
        )
        quitItem.target = MenuActionHandler.shared
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        items.append(quitItem)
        
        return items
    }
    
    // MARK: - Helpers
    
    private func lowestQuotaPercent(for provider: AIProvider) -> Double? {
        guard let accounts = viewModel.providerQuotas[provider] else { return nil }
        
        var lowestPercent: Double? = nil
        for (_, quotaData) in accounts {
            for model in quotaData.models {
                if model.percentage >= 0 {
                    if lowestPercent == nil || model.percentage < lowestPercent! {
                        lowestPercent = model.percentage
                    }
                }
            }
        }
        return lowestPercent
    }
    
    /// Create NSMenuItem with SwiftUI view
    private func viewItem<V: View>(for view: V, width: CGFloat? = nil) -> NSMenuItem {
        let effectiveWidth = width ?? menuWidth
        let hostingView = NSHostingView(rootView: view.frame(width: effectiveWidth))
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }
}

// MARK: - Menu Action Handler

@MainActor
final class MenuActionHandler: NSObject {
    static let shared = MenuActionHandler()
    
    weak var viewModel: QuotaViewModel?
    
    private override init() {
        super.init()
    }
    
    @objc func refresh() {
        Task {
            await viewModel?.refreshQuotasUnified()
        }
    }
    
    @objc func openApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Quotio" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - SwiftUI Menu Components

// MARK: Header View

private struct MenuHeaderView: View {
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: Proxy Info View

private struct MenuProxyInfoView: View {
    let port: Int
    let isRunning: Bool
    let onToggle: () -> Void
    let onCopyURL: () -> Void
    
    var body: some View {
        VStack(spacing: 6) {
            // URL row
            HStack {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("http://localhost:\(port)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                
                Spacer()
                
                Button(action: onCopyURL) {
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
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: Provider Header View

private struct MenuProviderHeaderView: View {
    let provider: AIProvider
    let accountCount: Int
    let lowestQuota: Double?
    
    private var statusColor: Color {
        guard let percent = lowestQuota else { return .gray }
        let used = 100 - percent
        if used >= 90 { return .red }
        if used >= 70 { return .yellow }
        return .green
    }
    
    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 16)
            
            Text(provider.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
            
            Text("\(accountCount)")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())
            
            Spacer()
            
            if let quota = lowestQuota {
                Text(String(format: "%.0f%%", quota))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
            }
            
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: Account Summary View

private struct MenuAccountSummaryView: View {
    let email: String
    let data: ProviderQuotaData
    let provider: AIProvider
    
    @State private var settings = MenuBarSettingsManager.shared
    
    private var displayEmail: String {
        email.masked(if: settings.hideSensitiveInfo)
    }
    
    private var heroPercentage: Double {
        if provider == .antigravity && data.hasGroupedModels {
            return data.groupedModels.map(\.percentage).min() ?? 0
        }
        return data.models.map(\.percentage).min() ?? 0
    }
    
    private var statusColor: Color {
        let used = 100 - heroPercentage
        if used >= 90 { return .red }
        if used >= 70 { return .yellow }
        return .green
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(displayEmail)
                    .font(.caption)
                    .lineLimit(1)
                
                if let plan = data.planDisplayName {
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Text(String(format: "%.0f%%", heroPercentage))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(statusColor)
            
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: Group Detail View

private struct MenuGroupDetailView: View {
    let group: GroupedModelQuota
    
    @State private var settings = MenuBarSettingsManager.shared
    
    private var usedPercent: Double {
        100 - group.percentage
    }
    
    private var statusColor: Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .yellow }
        return .green
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode == .used ? usedPercent : group.percentage
        
        HStack(spacing: 8) {
            Image(systemName: group.group.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            
            Text(group.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
            
            Spacer()
            
            Text(String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized()))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(statusColor)
            
            if group.formattedResetTime != "—" && !group.formattedResetTime.isEmpty {
                Text(group.formattedResetTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.03))
    }
}

// MARK: Model Detail View

private struct MenuModelDetailView: View {
    let model: ModelQuota
    let indented: Bool
    
    @State private var settings = MenuBarSettingsManager.shared
    
    private var usedPercent: Double {
        model.usedPercentage
    }
    
    private var statusColor: Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .yellow }
        return .green
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode == .used ? usedPercent : model.percentage
        
        HStack(spacing: 8) {
            Text(model.displayName)
                .font(.caption)
                .foregroundStyle(indented ? .secondary : .primary)
                .lineLimit(1)
            
            Spacer()
            
            if let usage = model.formattedUsage {
                Text(usage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            Text(String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized()))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
            
            if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                Text(model.formattedResetTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, indented ? 28 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
    }
}

// MARK: Empty State View

private struct MenuEmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No quota data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
    }
}
