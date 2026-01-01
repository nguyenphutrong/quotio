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
        
        // 3. Provider picker + Account cards (separate items for submenu support)
        let providers = providersWithData
        if !providers.isEmpty {
            // Provider picker as separate item with callback to rebuild menu
            let pickerView = MenuProviderPickerView(providers: providers) {
                // Rebuild menu in place to show new provider's accounts
                // Uses StatusBarManager singleton to ensure it works across desktop switches
                DispatchQueue.main.async {
                    StatusBarManager.shared.rebuildMenuInPlace()
                }
            }
            menu.addItem(viewItem(for: pickerView))
            
            menu.addItem(NSMenuItem.separator())
            
            // Account cards as individual items (enables native submenu on hover)
            let selectedProvider = resolveSelectedProvider(from: providers)
            let accounts = accountsForProvider(selectedProvider)
            
            if accounts.isEmpty {
                menu.addItem(buildEmptyStateItem())
            } else {
                for account in accounts {
                    let cardItem = buildAccountCardItem(
                        email: account.email,
                        data: account.data,
                        provider: selectedProvider
                    )
                    menu.addItem(cardItem)
                }
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
            hasSubmenu: provider == .antigravity && !data.models.isEmpty
        )
        
        let item = viewItem(for: cardView)
        
        // Attach native submenu for Antigravity accounts
        if provider == .antigravity && !data.models.isEmpty {
            let submenu = buildAntigravitySubmenu(data: data)
            item.submenu = submenu
        }
        
        return item
    }
    
    // MARK: - Antigravity Submenu
    
    private func buildAntigravitySubmenu(data: ProviderQuotaData) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        
        let allModels = data.models.sorted { $0.name < $1.name }
        
        for model in allModels {
            let modelItem = viewItem(for: MenuModelDetailView(model: model, showRawName: true))
            submenu.addItem(modelItem)
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
        let actionsView = MenuActionsView()
        return [viewItem(for: actionsView)]
    }
    
    // MARK: - Helpers
    
    private func viewItem<V: View>(for view: V, width: CGFloat? = nil) -> NSMenuItem {
        let effectiveWidth = width ?? menuWidth
        let rootView = view
            .frame(width: effectiveWidth)
            .environment(viewModel)
        let hostingView = NSHostingView(rootView: rootView)
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

// MARK: - Provider Picker View (separate from accounts for submenu support)

private struct MenuProviderPickerView: View {
    @AppStorage("menuBarSelectedProvider") private var selectedProviderRaw: String = ""
    
    let providers: [AIProvider]
    let onProviderChanged: () -> Void
    
    private var selectedProvider: AIProvider {
        if !selectedProviderRaw.isEmpty,
           let provider = AIProvider(rawValue: selectedProviderRaw),
           providers.contains(provider) {
            return provider
        }
        return providers.first ?? .gemini
    }
    
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(providers) { provider in
                ProviderFilterButton(
                    provider: provider,
                    isSelected: selectedProvider == provider
                ) {
                    selectedProviderRaw = provider.rawValue
                    // Trigger menu rebuild to show new provider's accounts
                    onProviderChanged()
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
    
    private var isAntigravity: Bool {
        provider == .antigravity && !data.models.isEmpty
    }
    
    private var antigravityGroups: [AntigravityDisplayGroup] {
        guard isAntigravity else { return [] }
        
        var groups: [AntigravityDisplayGroup] = []
        
        let gemini3ProModels = data.models.filter { 
            $0.name.contains("gemini-3-pro") && !$0.name.contains("image") 
        }
        if !gemini3ProModels.isEmpty {
            let minQuota = gemini3ProModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Pro", percentage: minQuota))
        }
        
        let gemini3FlashModels = data.models.filter { $0.name.contains("gemini-3-flash") }
        if !gemini3FlashModels.isEmpty {
            let minQuota = gemini3FlashModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Flash", percentage: minQuota))
        }
        
        let geminiImageModels = data.models.filter { $0.name.contains("image") }
        if !geminiImageModels.isEmpty {
            let minQuota = geminiImageModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Image", percentage: minQuota))
        }
        
        let claudeModels = data.models.filter { $0.name.contains("claude") }
        if !claudeModels.isEmpty {
            let minQuota = claudeModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Claude 4.5", percentage: minQuota))
        }
        
        return groups.sorted { $0.percentage < $1.percentage }
    }
    
    private var heroMetric: ModelQuota? {
        guard !isAntigravity else { return nil }
        return data.models.min { $0.percentage < $1.percentage }
    }
    
    private var secondaryMetrics: [ModelQuota] {
        guard !isAntigravity else { return [] }
        guard let hero = heroMetric else { return data.models }
        return data.models.filter { $0.name != hero.name }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
            
            if isAntigravity {
                antigravityModelsSection
            } else {
                if let hero = heroMetric {
                    heroSection(metric: hero)
                }
                
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
    
    // MARK: - Antigravity Groups Section (4 groups)
    
    private var antigravityModelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(antigravityGroups) { group in
                AntigravityGroupRow(group: group)
            }
        }
    }
    
    // MARK: - Hero Section (for non-Antigravity)
    
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
    
    // MARK: - Secondary Section (for non-Antigravity)
    
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

// MARK: Antigravity Display Group

private struct AntigravityDisplayGroup: Identifiable {
    let name: String
    let percentage: Double
    
    var id: String { name }
}

private struct AntigravityGroupRow: View {
    let group: AntigravityDisplayGroup
    
    private func quotaColor(for percentage: Double) -> Color {
        let used = 100 - percentage
        if used >= 90 { return Color(red: 0.9, green: 0.45, blue: 0.3) }
        if used >= 70 { return Color(red: 0.85, green: 0.65, blue: 0.25) }
        return Color(red: 0.35, green: 0.68, blue: 0.45)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Text(group.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 100, alignment: .leading)
            
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(quotaColor(for: group.percentage))
                        .frame(width: proxy.size.width * min(1, max(0, group.percentage / 100)))
                }
            }
            .frame(height: 6)
            
            Text(formatPercentage(group.percentage))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(quotaColor(for: group.percentage))
                .frame(width: 36, alignment: .trailing)
        }
    }
    
    private func formatPercentage(_ value: Double) -> String {
        let remaining = Int(value)
        return remaining < 0 ? "—" : "\(remaining)%"
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

// MARK: Model Detail View (for submenu)

private struct MenuModelDetailView: View {
    let model: ModelQuota
    let showRawName: Bool
    
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
            Text(showRawName ? model.name : model.displayName)
                .font(.system(size: 11, design: showRawName ? .monospaced : .default))
                .foregroundStyle(.primary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: Empty State View

private struct MenuEmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("menubar.noData".localized())
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

// MARK: - Menu Actions View

private struct MenuActionsView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    var body: some View {
        VStack(spacing: 0) {
            MenuBarActionButton(
                icon: "arrow.clockwise",
                title: "action.refresh".localized(),
                isLoading: viewModel.isLoadingQuotas
            ) {
                Task { await viewModel.refreshQuotasUnified() }
            }
            .disabled(viewModel.isLoadingQuotas)
            
            MenuBarActionButton(
                icon: "macwindow",
                title: "action.openApp".localized()
            ) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Quotio" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            
            Divider()
                .padding(.vertical, 4)
            
            MenuBarActionButton(
                icon: "xmark.circle",
                title: "action.quit".localized()
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Menu Bar Action Button

private struct MenuBarActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    @State private var rotation: Double = 0
    @State private var timer: Timer?
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                    .rotationEffect(.degrees(rotation))
                
                Text(title)
                    .font(.system(size: 13))
                
                Spacer()
                
                if isLoading {
                    SmallProgressView(size: 12)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovered = $0 }
        .onAppear {
            updateTimer()
        }
        .onChange(of: isLoading) { _, _ in
            updateTimer()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
    
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        
        if isLoading {
            // Use Timer with .common mode for reliable animation when NSMenu is open
            // Default scheduledTimer uses .default mode which doesn't fire during menu tracking
            let newTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in
                    rotation += 18 // 360° / 20 steps = 18° per step
                    if rotation >= 360 {
                        rotation = 0
                    }
                }
            }
            RunLoop.main.add(newTimer, forMode: .common)
            timer = newTimer
        } else {
            rotation = 0
        }
    }
}

