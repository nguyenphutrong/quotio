//
//  StatusBarMenuBuilder.swift
//  Quotio
//
//  Native NSMenu builder that matches MenuBarView layout:
//  - Header
//  - Proxy Info (Full Mode)
//  - Provider Segment Picker
//  - Account Cards (individual NSMenuItem, with submenu for Antigravity)
//  - Actions
//

import AppKit
import SwiftUI

// MARK: - Status Bar Menu Builder

@MainActor
final class StatusBarMenuBuilder {
    
    private let viewModel: QuotaViewModel
    private let modeManager = AppModeManager.shared
    private let menuWidth: CGFloat = 300
    
    // Selected provider from UserDefaults
    @AppStorage("menuBarSelectedProvider") private var selectedProviderRaw: String = ""
    
    init(viewModel: QuotaViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - Build Menu
    
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // 1. Header
        menu.addItem(buildHeaderItem())
        menu.addItem(NSMenuItem.separator())
        
        // 2. Proxy info (Full Mode only)
        if modeManager.isFullMode {
            menu.addItem(buildProxyInfoItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // 3. Provider segment picker + Account cards
        let providers = providersWithData
        if !providers.isEmpty {
            // Provider filter buttons
            menu.addItem(buildProviderPickerItem(providers: providers))
            menu.addItem(NSMenuItem.separator())
            
            // Account cards for selected provider
            let selectedProvider = resolveSelectedProvider(from: providers)
            let accounts = accountsForProvider(selectedProvider)
            
            for account in accounts {
                let accountItem = buildAccountCardItem(
                    email: account.email,
                    data: account.data,
                    provider: selectedProvider
                )
                menu.addItem(accountItem)
            }
            
            if accounts.isEmpty {
                menu.addItem(buildEmptyStateItem())
            }
            
            menu.addItem(NSMenuItem.separator())
        } else {
            menu.addItem(buildEmptyStateItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // 4. Action items
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
    
    private func resolveSelectedProvider(from providers: [AIProvider]) -> AIProvider {
        if !selectedProviderRaw.isEmpty,
           let provider = AIProvider(rawValue: selectedProviderRaw),
           providers.contains(provider) {
            return provider
        }
        return providers.first ?? .gemini
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
            port: Int(viewModel.proxyManager.port),
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
    
    // MARK: - Provider Picker Item
    
    private func buildProviderPickerItem(providers: [AIProvider]) -> NSMenuItem {
        let selectedProvider = resolveSelectedProvider(from: providers)
        let pickerView = MenuProviderPickerView(
            providers: providers,
            selectedProvider: selectedProvider,
            onSelect: { [weak self] provider in
                self?.selectedProviderRaw = provider.rawValue
                // Close and reopen menu to refresh
                if let menu = NSApp.mainMenu?.items.first?.submenu {
                    menu.cancelTracking()
                }
            }
        )
        return viewItem(for: pickerView)
    }
    
    // MARK: - Account Card Item (with submenu for Antigravity)
    
    private func buildAccountCardItem(
        email: String,
        data: ProviderQuotaData,
        provider: AIProvider
    ) -> NSMenuItem {
        let cardView = MenuAccountCardView(
            email: email,
            data: data,
            provider: provider,
            hasSubmenu: provider == .antigravity && data.hasGroupedModels
        )
        
        let item = viewItem(for: cardView)
        
        // Attach native submenu for Antigravity accounts
        if provider == .antigravity && data.hasGroupedModels {
            let submenu = buildAntigravitySubmenu(data: data)
            item.submenu = submenu
        }
        
        return item
    }
    
    // MARK: - Antigravity Submenu
    
    private func buildAntigravitySubmenu(data: ProviderQuotaData) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        for group in data.groupedModels {
            // Group header
            let groupItem = viewItem(for: MenuGroupDetailView(group: group))
            submenu.addItem(groupItem)
            
            // Individual models
            for model in group.models.sorted(by: { $0.name < $1.name }) {
                let modelItem = viewItem(for: MenuModelDetailView(model: model, indented: true))
                submenu.addItem(modelItem)
            }
            
            submenu.addItem(NSMenuItem.separator())
        }
        
        // Remove trailing separator
        if submenu.items.last?.isSeparatorItem == true {
            submenu.removeItem(at: submenu.items.count - 1)
        }
        
        return submenu
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

// MARK: Provider Picker View

private struct MenuProviderPickerView: View {
    let providers: [AIProvider]
    let selectedProvider: AIProvider
    let onSelect: (AIProvider) -> Void
    
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(providers) { provider in
                ProviderFilterButton(
                    provider: provider,
                    isSelected: selectedProvider == provider
                ) {
                    onSelect(provider)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: Provider Filter Button

private struct ProviderFilterButton: View {
    let provider: AIProvider
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ProviderIconMono(provider: provider, size: 14)
                
                Text(provider.shortName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.secondary.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Monochrome Provider Icon

private struct ProviderIconMono: View {
    let provider: AIProvider
    let size: CGFloat
    
    var body: some View {
        Group {
            if let assetName = provider.menuBarIconAsset,
               let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .colorMultiply(.primary)
            } else {
                Image(systemName: provider.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Account Card View

private struct MenuAccountCardView: View {
    let email: String
    let data: ProviderQuotaData
    let provider: AIProvider
    let hasSubmenu: Bool
    
    @State private var settings = MenuBarSettingsManager.shared
    @State private var isHovered = false
    
    private var displayEmail: String {
        email.masked(if: settings.hideSensitiveInfo)
    }
    
    // For Antigravity: use grouped models
    private var isAntigravity: Bool {
        provider == .antigravity && data.hasGroupedModels
    }
    
    private var heroPercentage: Double {
        if isAntigravity {
            return data.groupedModels.map(\.percentage).min() ?? 0
        }
        return data.models.map(\.percentage).min() ?? 0
    }
    
    private var heroGroup: GroupedModelQuota? {
        guard isAntigravity else { return nil }
        return data.groupedModels.min { $0.percentage < $1.percentage }
    }
    
    private var heroMetric: ModelQuota? {
        guard !isAntigravity else { return nil }
        return data.models.min { $0.percentage < $1.percentage }
    }
    
    private var secondaryGroups: [GroupedModelQuota] {
        guard isAntigravity, let hero = heroGroup else { return [] }
        return data.groupedModels.filter { $0.id != hero.id }
    }
    
    private var secondaryMetrics: [ModelQuota] {
        guard !isAntigravity, let hero = heroMetric else { return data.models }
        return data.models.filter { $0.name != hero.name }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Email + Plan + Submenu indicator
            cardHeader
            
            // Hero section
            if isAntigravity {
                if let hero = heroGroup {
                    heroGroupSection(group: hero)
                }
            } else {
                if let hero = heroMetric {
                    heroSection(metric: hero)
                }
            }
            
            // Secondary section
            if isAntigravity {
                if !secondaryGroups.isEmpty {
                    secondaryGroupsSection
                }
            } else {
                if !secondaryMetrics.isEmpty {
                    secondaryMetricsSection
                }
            }
        }
        .padding(10)
        .background(isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
    }
    
    // MARK: - Card Header
    
    private var cardHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayEmail)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                
                if let plan = data.planDisplayName {
                    Text(plan)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    // MARK: - Hero Section (Regular)
    
    private func heroSection(metric: ModelQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text(formatPercentage(metric.percentage))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(quotaColor(for: metric.percentage))
            }
            
            HeroProgressBar(percentage: metric.percentage)
            
            if !metric.formattedResetTime.isEmpty && metric.formattedResetTime != "—" {
                Text("Resets in \(metric.formattedResetTime)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    // MARK: - Hero Section (Antigravity Grouped)
    
    private func heroGroupSection(group: GroupedModelQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Image(systemName: group.group.icon)
                        .font(.system(size: 10))
                    Text(group.displayName)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                
                Spacer()
                
                Text(formatPercentage(group.percentage))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(quotaColor(for: group.percentage))
            }
            
            HeroProgressBar(percentage: group.percentage)
            
            if !group.formattedResetTime.isEmpty && group.formattedResetTime != "—" {
                Text("Resets in \(group.formattedResetTime)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    // MARK: - Secondary Section (Regular)
    
    private var secondaryMetricsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(secondaryMetrics.prefix(3)) { metric in
                SecondaryMetricRow(
                    name: metric.displayName,
                    percentage: metric.percentage
                )
            }
        }
        .padding(.top, 4)
    }
    
    // MARK: - Secondary Section (Antigravity Grouped)
    
    private var secondaryGroupsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(secondaryGroups.prefix(3)) { group in
                SecondaryGroupRow(group: group)
            }
        }
        .padding(.top, 4)
    }
    
    // MARK: - Helpers
    
    private func formatPercentage(_ value: Double) -> String {
        let remaining = Int(value)
        return remaining < 0 ? "—" : "\(remaining)%"
    }
    
    private func quotaColor(for percentage: Double) -> Color {
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
}

// MARK: Hero Progress Bar

private struct HeroProgressBar: View {
    let percentage: Double
    
    private func quotaColor(for percentage: Double) -> Color {
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                
                RoundedRectangle(cornerRadius: 3)
                    .fill(quotaColor(for: percentage))
                    .frame(width: proxy.size.width * min(1, max(0, percentage / 100)))
            }
        }
        .frame(height: 8)
    }
}

// MARK: Secondary Metric Row

private struct SecondaryMetricRow: View {
    let name: String
    let percentage: Double
    
    private func quotaColor(for percentage: Double) -> Color {
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(quotaColor(for: percentage))
                .frame(width: 6, height: 6)
            
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(formatPercentage(percentage))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
    
    private func formatPercentage(_ value: Double) -> String {
        let remaining = Int(value)
        return remaining < 0 ? "—" : "\(remaining)%"
    }
}

// MARK: Secondary Group Row (Antigravity)

private struct SecondaryGroupRow: View {
    let group: GroupedModelQuota
    
    private func quotaColor(for percentage: Double) -> Color {
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(quotaColor(for: group.percentage))
                .frame(width: 6, height: 6)
            
            HStack(spacing: 3) {
                Image(systemName: group.group.icon)
                    .font(.system(size: 9))
                Text(group.displayName)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(formatPercentage(group.percentage))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
    
    private func formatPercentage(_ value: Double) -> String {
        let remaining = Int(value)
        return remaining < 0 ? "—" : "\(remaining)%"
    }
}

// MARK: Group Detail View (for submenu)

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

// MARK: Model Detail View (for submenu)

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

// MARK: - AIProvider Extension

private extension AIProvider {
    var shortName: String {
        switch self {
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .codex: return "OpenAI"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .qwen: return "Qwen"
        case .iflow: return "iFlow"
        case .vertex: return "Vertex"
        case .kiro: return "Kiro"
        }
    }
}


