//
//  StatusBarMenuBuilder.swift
//  Quotio
//
//  Native NSMenu builder that matches MenuBarView layout:
//  - Header
//  - Proxy Info (Full Mode)
//  - Provider Segment Picker
//  - Account Cards (individual items)
//  - Actions
//

import AppKit
import SwiftUI

// MARK: - Status Bar Menu Builder

@MainActor
final class StatusBarMenuBuilder {
    
    private let viewModel: QuotaViewModel
    private let modeManager = OperatingModeManager.shared
    private let menuWidth: CGFloat = 320
    
    // Selected provider from UserDefaults
    @AppStorage("menuBarSelectedProvider") private var selectedProviderRaw: String = ""
    private var showAllAccounts: Bool = false
    private var suppressResetOnce: Bool = false
    
    init(viewModel: QuotaViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - Build Menu
    
    func buildMenu() -> NSMenu {
        if suppressResetOnce {
            suppressResetOnce = false
        } else {
            showAllAccounts = false
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // 1. Header
        menu.addItem(buildHeaderItem())
        menu.addItem(NSMenuItem.separator())
        
        // 2. Network info (Proxy + Tunnel) - Local Proxy Mode only
        if modeManager.isLocalProxyMode {
            menu.addItem(buildNetworkInfoItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // 3. Provider picker + Account cards (individual items for submenu support)
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
            
            // Account cards as individual items (max 3 + "view more", enables native submenu on hover)
            let selectedProvider = resolveSelectedProvider(from: providers)
            let accounts = accountsForProvider(selectedProvider)

            if accounts.isEmpty {
                menu.addItem(buildEmptyStateItem())
            } else {
                let maxVisibleAccounts = 3
                let displayAccounts = showAllAccounts ? accounts : Array(accounts.prefix(maxVisibleAccounts))
                for account in displayAccounts {
                    let cardItem = buildAccountCardItem(
                        email: account.email,
                        data: account.data,
                        provider: selectedProvider
                    )
                    menu.addItem(cardItem)
                }

                if accounts.count > maxVisibleAccounts {
                    let remainingCount = showAllAccounts ? 0 : (accounts.count - maxVisibleAccounts)
                    menu.addItem(buildViewMoreAccountsItem(remainingCount: remainingCount, isExpanded: showAllAccounts))
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
        
        // From direct auth files (scanned from filesystem - available immediately)
        for file in viewModel.directAuthFiles {
            providers.insert(file.provider)
        }
        
        // From quota data (available after API calls complete)
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

    // MARK: - Network Info Item (Proxy + Tunnel combined)

    private func buildNetworkInfoItem() -> NSMenuItem {
        let networkView = MenuNetworkInfoView(
            port: String(viewModel.proxyManager.port),
            isProxyRunning: viewModel.proxyManager.proxyStatus.running,
            onProxyToggle: { [weak viewModel] in
                Task { await viewModel?.toggleProxy() }
            },
            onCopyProxyURL: {
                let url = "http://127.0.0.1:\(self.viewModel.proxyManager.port)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            },
            onTunnelToggle: { [weak viewModel] in
                guard let viewModel = viewModel else { return }
                Task {
                    await TunnelManager.shared.toggle(port: viewModel.proxyManager.port)
                }
            },
            onCopyTunnelURL: {
                TunnelManager.shared.copyURLToClipboard()
            }
        )
        return viewItem(for: networkView)
    }

    // MARK: - Account Card Item (with submenu for Antigravity)

    private func buildAccountCardItem(
        email: String,
        data: ProviderQuotaData,
        provider: AIProvider
    ) -> NSMenuItem {
        let subscriptionInfo = viewModel.subscriptionInfos[provider]?[email]
        let isActiveInIDE = provider == .antigravity && viewModel.isAntigravityAccountActive(email: email)

        let cardView = MenuAccountCardView(
            email: email,
            data: data,
            provider: provider,
            subscriptionInfo: subscriptionInfo,
            isActiveInIDE: isActiveInIDE,
            onUseAccount: provider == .antigravity && !isActiveInIDE ? { [weak viewModel] in
                Self.showSwitchConfirmation(email: email, viewModel: viewModel)
            } : nil
        )

        let item = viewItem(for: cardView)

        if provider == .antigravity && !data.models.isEmpty {
            let submenu = buildAntigravitySubmenu(data: data)
            item.submenu = submenu
        }

        return item
    }

    private func buildViewMoreAccountsItem(remainingCount: Int, isExpanded: Bool) -> NSMenuItem {
        let view = MenuViewMoreAccountsView(remainingCount: remainingCount, isExpanded: isExpanded) { [self] in
            self.showAllAccounts.toggle()
            self.suppressResetOnce = true
            StatusBarManager.shared.rebuildMenuInPlace()
        }
        return viewItem(for: view)
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

    // MARK: - Switch Account Confirmation
    
    private static func showSwitchConfirmation(email: String, viewModel: QuotaViewModel?) {
        guard let viewModel = viewModel else { return }
        
        let isIDERunning = viewModel.antigravitySwitcher.isIDERunning()
        
        let alert = NSAlert()
        alert.messageText = "antigravity.switch.dialog.title".localized()
        alert.informativeText = String(format: "antigravity.switch.dialog.message".localized(), email)
        
        if isIDERunning {
            alert.informativeText += "\n\n⚠️ " + "antigravity.switch.dialog.warning".localized()
        }
        
        alert.alertStyle = isIDERunning ? .warning : .informational
        alert.addButton(withTitle: "antigravity.switch.title".localized())
        alert.addButton(withTitle: "action.cancel".localized())
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                await viewModel.switchAntigravityAccount(email: email)
                StatusBarManager.shared.rebuildMenuInPlace()
            }
        }
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
        Self.openMainWindow()
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    static func openMainWindow() {
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        if showInDock {
            StatusBarManager.shared.closeMenu()
        }

        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window = NSApplication.shared.windows.first(where: { $0.title == "Quotio" }) {
            window.makeKeyAndOrderFront(nil)

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            window.orderFrontRegardless()
        }
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



// MARK: - Provider Picker View (separate from accounts list)

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
        // Wrap providers in a flexible layout
        FlowLayout(spacing: 6) {
            ForEach(providers) { provider in
                ProviderFilterButton(
                    provider: provider,
                    isSelected: selectedProvider == provider
                ) {
                    selectedProviderRaw = provider.rawValue
                    onProviderChanged()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: Provider Filter Button

private struct ProviderFilterButton: View {
    let provider: AIProvider
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProviderIconMono(provider: provider, size: 14)
                    .opacity(isSelected ? 1.0 : 0.7)
                
                Text(provider.shortName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
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

// MARK: - Network Info View (Proxy + Tunnel Combined)

private struct MenuNetworkInfoView: View {
    let port: String
    let isProxyRunning: Bool
    let onProxyToggle: () -> Void
    let onCopyProxyURL: () -> Void
    let onTunnelToggle: () -> Void
    let onCopyTunnelURL: () -> Void

    private let tunnelManager = TunnelManager.shared
    private var tunnelStatus: CloudflareTunnelStatus { tunnelManager.tunnelState.status }
    private var tunnelURL: String? { tunnelManager.tunnelState.publicURL }
    private var proxyURL: String { "http://127.0.0.1:" + port }

    @State private var didCopyProxy = false
    @State private var didCopyTunnel = false

    private enum CopyTarget {
        case proxy
        case tunnel
    }

    var body: some View {
        VStack(spacing: 8) {
            // Proxy Row
            HStack(spacing: 8) {
                Circle()
                    .fill(isProxyRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)

                Text("providers.source.proxy".localized())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                if isProxyRunning {
                    Text(proxyURL)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    copyButton(
                        isCopied: didCopyProxy,
                        helpText: "action.copy".localized()
                    ) {
                        onCopyProxyURL()
                        triggerCopyState(.proxy)
                    }
                }

                Spacer()

                Button(action: onProxyToggle) {
                    Image(systemName: isProxyRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isProxyRunning ? .red : .green)
                }
                .buttonStyle(.plain)
            }

            // Tunnel Row (only show when proxy is running)
            if isProxyRunning {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tunnelStatus == .active ? Color.blue : Color.gray)
                        .frame(width: 6, height: 6)

                    Text(tunnelStatus == .active ? "tunnel.action.stop".localized() : "tunnel.action.start".localized())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    if tunnelStatus == .active, let url = tunnelURL {
                        Text(url.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        copyButton(
                            isCopied: didCopyTunnel,
                            helpText: "action.copy".localized()
                        ) {
                            onCopyTunnelURL()
                            triggerCopyState(.tunnel)
                        }
                    } else if tunnelStatus == .starting {
                        Text("status.starting".localized())
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button(action: onTunnelToggle) {
                        Image(systemName: tunnelStatus == .active || tunnelStatus == .starting ? "stop.fill" : "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(tunnelStatus == .active ? .red : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(tunnelStatus == .starting || tunnelStatus == .stopping)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func triggerCopyState(_ target: CopyTarget) {
        setCopied(target, value: true)

        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                setCopied(target, value: false)
            }
        }
    }

    private func setCopied(_ target: CopyTarget, value: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch target {
            case .proxy:
                didCopyProxy = value
            case .tunnel:
                didCopyTunnel = value
            }
        }
    }

    @ViewBuilder
    private func copyButton(isCopied: Bool, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(isCopied ? .green : .secondary)
                .scaleEffect(isCopied ? 1.05 : 1)
                .animation(.easeInOut(duration: 0.2), value: isCopied)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

// MARK: Account Card View

private struct MenuAccountCardView: View {
    let email: String
    let data: ProviderQuotaData
    let provider: AIProvider
    let subscriptionInfo: SubscriptionInfo?
    let isActiveInIDE: Bool
    let onUseAccount: (() -> Void)?
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    @State private var isHovered = false
    @State private var isUseHovered = false
    @State private var isUsingAccount = false
    
    private var displayEmail: String {
        email.masked(if: settings.hideSensitiveInfo)
    }
    
    // Modern Tier Badge Config
    private var tierConfig: (name: String, bgColor: Color, textColor: Color)? {
        if let info = subscriptionInfo {
            let tierId = info.tierId.lowercased()
            let tierName = info.tierDisplayName.lowercased()
            
            if tierId.contains("ultra") || tierName.contains("ultra") {
                return ("Ultra", .orange.opacity(0.15), .orange)
            }
            if tierId.contains("pro") || tierName.contains("pro") {
                return ("Pro", .blue.opacity(0.15), .blue)
            }
            if tierId.contains("standard") || tierId.contains("free") ||
               tierName.contains("standard") || tierName.contains("free") {
                return ("Free", .secondary.opacity(0.1), .secondary)
            }
            return (info.tierDisplayName, .secondary.opacity(0.1), .secondary)
        }
        
        guard let planName = data.planDisplayName else { return nil }
        return planConfig(for: planName)
    }
    
    private func planConfig(for planName: String) -> (name: String, bgColor: Color, textColor: Color) {
        let lowercased = planName.lowercased()
        
        if lowercased.contains("ultra") {
            return ("Ultra", .orange.opacity(0.15), .orange)
        }
        if lowercased.contains("pro") {
            return ("Pro", .blue.opacity(0.15), .blue)
        }
        if lowercased.contains("plus") {
            return ("Plus", .blue.opacity(0.15), .blue)
        }
        if lowercased.contains("team") {
            return ("Team", .orange.opacity(0.15), .orange)
        }
        if lowercased.contains("enterprise") {
            return ("Enterprise", .red.opacity(0.15), .red)
        }
        if lowercased.contains("business") {
            return ("Business", .red.opacity(0.15), .red)
        }
        if lowercased.contains("free") || lowercased.contains("standard") {
            return ("Free", .secondary.opacity(0.1), .secondary)
        }
        
        return (planName, .secondary.opacity(0.1), .secondary)
    }
    
    private var isAntigravity: Bool {
        provider == .antigravity && !data.models.isEmpty
    }
    
    private var antigravityGroups: [AntigravityDisplayGroup] {
        guard isAntigravity else { return [] }
        var groups: [AntigravityDisplayGroup] = []

        let settings = MenuBarSettingsManager.shared
        
        let gemini3ProModels = data.models.filter {
            $0.name.contains("gemini-3-pro") && !$0.name.contains("image")
        }
        if !gemini3ProModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(gemini3ProModels.map(\.percentage))
            let minModel = gemini3ProModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Pro", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let gemini3FlashModels = data.models.filter { $0.name.contains("gemini-3-flash") }
        if !gemini3FlashModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(gemini3FlashModels.map(\.percentage))
            let minModel = gemini3FlashModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Flash", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let geminiImageModels = data.models.filter { $0.name.contains("image") }
        if !geminiImageModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(geminiImageModels.map(\.percentage))
            let minModel = geminiImageModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Image", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        let claudeModels = data.models.filter { $0.name.contains("claude") }
        if !claudeModels.isEmpty {
            let aggregatedPercent = settings.aggregateModelPercentages(claudeModels.map(\.percentage))
            let minModel = claudeModels.min(by: { $0.percentage < $1.percentage })
            groups.append(AntigravityDisplayGroup(name: "Claude 4.5", percentage: aggregatedPercent, resetTime: minModel?.resetTime))
        }

        return groups.sorted { $0.percentage < $1.percentage }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            
            quotaContentSection
            
            footerSection
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(alignment: .center, spacing: 8) {
            // Provider Icon
            ProviderIconMono(provider: provider, size: 16)
                .foregroundStyle(.secondary)
                .opacity(0.8)
            
            // Email
            Text(displayEmail)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            // Tier Badge
            if let config = tierConfig {
                Text(config.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(config.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(config.bgColor)
                    .clipShape(Capsule())
            }
            
            // Active/Use Badge
            if isActiveInIDE {
                Text("antigravity.active".localized())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(Capsule())
            } else if let onUse = onUseAccount {
                Button {
                    isUsingAccount = true
                    Task { @MainActor in
                        onUse()
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        isUsingAccount = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isUsingAccount {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("antigravity.useInIDE".localized() + " " + "→".localized())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isUseHovered ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.secondary.opacity(isUseHovered ? 0.45 : 0.25), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isUsingAccount)
                .onHover { isUseHovered = $0 }
            }
        }
    }
    
    // MARK: - Quota Content
    
    private var quotaContentSection: some View {
        let models: [ModelBadgeData] = {
            if isAntigravity {
                return antigravityGroups.map { ModelBadgeData(name: $0.name, percentage: $0.percentage, resetTime: $0.resetTime) }
            } else {
                return data.models.map { ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime) }
            }
        }()
        
        let displayStyle = settings.quotaDisplayStyle
        
        return Group {
            if models.isEmpty {
                Text("dashboard.noQuotaData".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if displayStyle == .lowestBar {
                // Modern Lowest Bar: Big highlighted row for bottleneck, others compact
                LowestBarLayout(models: models)
            } else if displayStyle == .ring {
                // Ring Grid
                RingGridLayout(models: models)
            } else {
                // Standard Card Grid (Bars)
                CardGridLayout(models: models)
            }
        }
    }
    
    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 12) {
            // Reset info is now shown inside each metric, so only show last update here
            Spacer()

            // Last Update
            Text(data.lastUpdated.formatted(.relative(presentation: .named)))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
    
    private var displayStyle: QuotaDisplayStyle { settings.quotaDisplayStyle }
    
    private var primaryResetModel: ModelQuota? {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        
        let validModels = data.models.filter { model in
            guard let date = formatter.date(from: model.resetTime) else { return false }
            return date > now
        }
        
        return validModels.sorted { m1, m2 in
            if abs(m1.percentage - m2.percentage) > 0.1 {
                return m1.percentage < m2.percentage
            }
            let d1 = formatter.date(from: m1.resetTime) ?? Date.distantFuture
            let d2 = formatter.date(from: m2.resetTime) ?? Date.distantFuture
            return d1 < d2
        }.first
    }
    
    private func formatLocalTime(_ isoString: String) -> String {
        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: isoString)
              ?? isoFormatterStandard.date(from: isoString) else { return "" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct ModelBadgeData: Identifiable {
    let name: String
    let percentage: Double
    let resetTime: String?

    var id: String { name }

    var formattedResetTime: String? {
        guard let resetTime = resetTime else { return nil }

        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: resetTime)
              ?? isoFormatterStandard.date(from: resetTime) else { return nil }

        let now = Date()
        let diff = date.timeIntervalSince(now)
        guard diff > 0 else { return nil }

        let totalMinutes = Int(diff) / 60
        let days = totalMinutes / 1440  // 24 * 60
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d\(hours)h"
        } else if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

private struct AntigravityDisplayGroup: Identifiable {
    let name: String
    let percentage: Double
    let resetTime: String?

    var id: String { name }
}

private func menuDisplayPercent(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Double {
    displayMode.displayValue(from: remainingPercent)
}

private func menuStatusColor(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Color {
    let usedPercent = 100 - remainingPercent
    let checkValue = displayMode == .used ? usedPercent : remainingPercent

    if displayMode == .used {
        if checkValue < 70 { return .green }
        if checkValue < 90 { return .yellow }
        return .red
    } else {
        if checkValue > 50 { return .green }
        if checkValue > 20 { return .orange }
        return .red
    }
}

// MARK: - Layout Subviews

private struct LowestBarLayout: View {
    let models: [ModelBadgeData]
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var sorted: [ModelBadgeData] {
        models.sorted { $0.percentage < $1.percentage }
    }

    private var lowest: ModelBadgeData? {
        sorted.first
    }

    private var others: [ModelBadgeData] {
        Array(sorted.dropFirst())
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        
        VStack(spacing: 8) {
            if let lowest = lowest {
                // Hero Row for Lowest with reset time
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                        PercentageBadge(percentage: lowest.percentage, style: .textOnly)
                    }

                    ModernProgressBar(percentage: lowest.percentage, height: 8)

                    if let resetTime = lowest.formattedResetTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9))
                            Text(resetTime)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
                .background(menuStatusColor(remainingPercent: lowest.percentage, displayMode: displayMode).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(menuStatusColor(remainingPercent: lowest.percentage, displayMode: displayMode).opacity(0.2), lineWidth: 1)
                )
            }

            // Others as text rows (one per line)
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others, id: \.name) { (model: ModelBadgeData) in
                        HStack(spacing: 6) {
                            Text(model.name)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let resetTime = model.formattedResetTime {
                                Text(resetTime)
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(Int(menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode)))%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct RingGridLayout: View {
    let models: [ModelBadgeData]
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var columnCount: Int {
        min(max(models.count, 1), 4)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible()), count: columnCount)
    }

    private var ringSize: CGFloat {
        columnCount >= 4 ? 36 : 40
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        
        // Auto-distribute 1-4 columns, cap at 4
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(models, id: \.name) { (model: ModelBadgeData) in
                VStack(spacing: 4) {
                    RingProgressView(percent: menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode), size: ringSize, lineWidth: 4, tint: menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode), showLabel: true)

                    Text(model.name)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let resetTime = model.formattedResetTime {
                        Text(resetTime)
                            .font(.system(size: 8, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CardGridLayout: View {
    let models: [ModelBadgeData]
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var columns: [GridItem] {
        // Single metric: full width. Multiple: 2 columns
        if models.count == 1 {
            return [GridItem(.flexible())]
        } else {
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(models, id: \.name) { (model: ModelBadgeData) in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.name)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if let resetTime = model.formattedResetTime {
                            Text(resetTime)
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(Int(menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode)))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                    }

                    ModernProgressBar(percentage: model.percentage, height: 4)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

}

// MARK: - Shared Components

private struct ModernProgressBar: View {
    let percentage: Double
    let height: CGFloat
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    
    private var displayPercent: Double {
        menuDisplayPercent(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * min(1, max(0, displayPercent / 100)))
            }
        }
        .frame(height: height)
    }
}

private struct PercentageBadge: View {
    let percentage: Double
    var style: Style = .pill
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    
    enum Style { case pill, textOnly }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }
    
    private var displayPercent: Double {
        menuDisplayPercent(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }
    
    var body: some View {
        switch style {
        case .pill:
            Text("\(Int(displayPercent))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
        case .textOnly:
            Text("\(Int(displayPercent))%")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: Model Detail View (for submenu)

private struct MenuModelDetailView: View {
    let model: ModelQuota
    let showRawName: Bool

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var statusColor: Color {
        menuStatusColor(remainingPercent: model.percentage, displayMode: settings.quotaDisplayMode)
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayStyle = settings.quotaDisplayStyle
        let displayPercent = menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode)

        HStack(spacing: 8) {
            Text(showRawName ? model.name : model.displayName)
                .font(.system(size: 11, weight: .medium, design: showRawName ? .monospaced : .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if let usage = model.formattedUsage {
                Text(usage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if displayStyle != .ring {
                Text(String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized()))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor)
            }

            if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                Text(model.formattedResetTime)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if displayStyle == .ring {
                RingProgressView(percent: displayPercent, size: 14, lineWidth: 2, tint: statusColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

// MARK: View More Accounts

private struct MenuViewMoreAccountsView: View {
    let remainingCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)

                Text(isExpanded ? "menubar.hideAccounts".localized() : "menubar.viewMoreAccounts".localized())
                    .font(.system(size: 12, weight: .medium))

                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                        .opacity(isExpanded ? 0 : 1)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
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
        case .glm: return "GLM"
        case .warp: return "Warp"
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
                MenuActionHandler.openMainWindow()
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
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovered = $0 }
    }
}
