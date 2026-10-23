//
//  StatusBarMenuRenderer.swift
//  QuotioPresentation
//
//  Native NSMenu renderer that matches MenuBarView layout:
//  - Header
//  - Proxy Info (Full Mode)
//  - Provider Segment Picker
//  - Account Cards (individual items)
//  - Actions
//

import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI

@MainActor
@Observable
final class StatusBarProviderFilterController {
    enum Scope {
        case provider(QuotaProvider)
        case allProvidersOnly
    }

    var selectedProvider: QuotaProvider?

    @ObservationIgnored private weak var menu: NSMenu?
    @ObservationIgnored private var scopes: [ObjectIdentifier: Scope] = [:]
    @ObservationIgnored private let onSelectionChanged: (QuotaProvider?) -> Void

    init(
        selectedProvider: QuotaProvider?,
        onSelectionChanged: @escaping (QuotaProvider?) -> Void
    ) {
        self.selectedProvider = selectedProvider
        self.onSelectionChanged = onSelectionChanged
    }

    func register(_ item: NSMenuItem, scope: Scope) {
        scopes[ObjectIdentifier(item)] = scope
        item.isHidden = !isVisible(scope)
    }

    func activate(in menu: NSMenu) {
        self.menu = menu
        applySelection()
    }

    func select(_ provider: QuotaProvider?) {
        guard selectedProvider != provider else { return }
        selectedProvider = provider
        applySelection()
        onSelectionChanged(provider)
    }

    private func applySelection() {
        guard let menu else { return }
        for item in menu.items {
            guard let scope = scopes[ObjectIdentifier(item)] else { continue }
            item.isHidden = !isVisible(scope)
        }
        menu.update()
    }

    private func isVisible(_ scope: Scope) -> Bool {
        switch scope {
        case .provider(let provider):
            selectedProvider == nil || selectedProvider == provider
        case .allProvidersOnly:
            selectedProvider == nil
        }
    }
}

/// Mirrors the menu's own item highlight so custom item views can draw the
/// same feedback for pointer and keyboard navigation.
@MainActor
@Observable
final class StatusBarMenuHighlightController {
    private(set) var highlightedItem: ObjectIdentifier?

    func highlight(_ item: NSMenuItem?) {
        highlightedItem = item.map(ObjectIdentifier.init)
    }
}

// MARK: - Command Menu Item

/// Native menu item for top-level commands, so they keep system highlight,
/// keyboard navigation, key equivalents, and accessibility roles.
@MainActor
private final class StatusBarCommandMenuItem: NSMenuItem {
    private var command: StatusBarCommand
    private let commands: StatusBarCommandDispatcher

    init(
        title: String,
        symbolName: String,
        keyEquivalent: String,
        command: StatusBarCommand,
        commands: StatusBarCommandDispatcher
    ) {
        self.command = command
        self.commands = commands
        super.init(title: title, action: #selector(performCommand), keyEquivalent: keyEquivalent)
        target = self
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
    func update(title: String, symbolName: String, command: StatusBarCommand) {
        self.title = title
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        self.command = command
    }


    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func performCommand() {
        commands.dispatch(command)
    }
}

private final class StatusBarMenuHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        super.layout()
        let height = intrinsicContentSize.height
        guard height > 0, abs(frame.height - height) > 0.5 else { return }
        setFrameSize(NSSize(width: frame.width, height: height))
        enclosingMenuItem?.menu?.update()
    }
}

// MARK: - Status Bar Menu Renderer

@MainActor
@Observable
final class StatusBarMenuRenderer {
    private var snapshot: StatusBarMenuSnapshot
    @ObservationIgnored private weak var refreshItem: NSMenuItem?
    @ObservationIgnored private weak var hostStatusItem: NSMenuItem?
    @ObservationIgnored private var recoveryItems: [(item: StatusBarCommandMenuItem, separator: NSMenuItem, accountID: QuotaAccountID)] = []
    private let commands: StatusBarCommandDispatcher
    private let providerFilterController: StatusBarProviderFilterController
    private let highlightController = StatusBarMenuHighlightController()
    private let menuWidth: CGFloat = 360

    init(
        snapshot: StatusBarMenuSnapshot,
        commands: StatusBarCommandDispatcher
    ) {
        self.snapshot = snapshot
        self.commands = commands
        let availableProviders = snapshot.providers.map(\.provider)
        let selectedProvider = snapshot.selectedProvider.flatMap { provider in
            availableProviders.contains(provider) ? provider : nil
        }
        self.providerFilterController = StatusBarProviderFilterController(
            selectedProvider: selectedProvider,
            onSelectionChanged: { provider in
                commands.dispatch(.selectProvider(provider))
            }
        )
    }
    
    // MARK: - Build Menu
    
    func buildMenu() -> NSMenu {
        recoveryItems.removeAll()
        let menu = makeMenu()

        // 1. Header
        menu.addItem(buildHeaderItem())
        menu.addItem(NSMenuItem.separator())

        // 3. Provider picker and account groups
        let providers = snapshot.providers
        if !providers.isEmpty {
            let pickerView = MenuProviderPickerView(
                providers: providers,
                controller: providerFilterController
            )
            menu.addItem(viewItem(for: pickerView))
            menu.addItem(NSMenuItem.separator())

            for (index, providerSnapshot) in providers.enumerated() {
                let headerView = MenuContent {
                    let current = self.snapshot.providers.first { $0.provider == providerSnapshot.provider } ?? providerSnapshot
                    return MenuProviderSectionHeader(
                        provider: current.provider,
                        displayName: current.displayName,
                        isRefreshing: current.isRefreshing,
                        supportsScopedRefresh: current.supportsScopedRefresh,
                        onRefresh: {
                            await self.commands.dispatch(.refreshProvider(current.provider))?.value
                        }
                    )
                }
                let headerItem = viewItem(for: headerView, title: providerSnapshot.displayName)
                providerFilterController.register(headerItem, scope: .allProvidersOnly)
                menu.addItem(headerItem)

                if providerSnapshot.warning != nil {
                    let warningItem = buildProviderWarningItem(providerSnapshot)
                    providerFilterController.register(warningItem, scope: .provider(providerSnapshot.provider))
                    menu.addItem(warningItem)
                }
                if providerSnapshot.accounts.isEmpty {
                    if providerSnapshot.warning == nil {
                        let emptyItem = buildEmptyStateItem()
                        providerFilterController.register(emptyItem, scope: .provider(providerSnapshot.provider))
                        menu.addItem(emptyItem)
                    }
                } else {
                    for (accountIndex, account) in providerSnapshot.accounts.enumerated() {
                        if accountIndex > 0 && snapshot.displaySettings.quotaDisplayStyle != .compact {
                            let separator = NSMenuItem.separator()
                            providerFilterController.register(
                                separator,
                                scope: .provider(providerSnapshot.provider)
                            )
                            menu.addItem(separator)
                        }
                        let cardItem = buildAccountCardItem(account)
                        providerFilterController.register(
                            cardItem,
                            scope: .provider(providerSnapshot.provider)
                        )
                        menu.addItem(cardItem)
                    }
                }

                // Separator between provider groups (not after the last one)
                if index < providers.count - 1 {
                    let separator = NSMenuItem.separator()
                    providerFilterController.register(separator, scope: .allProvidersOnly)
                    menu.addItem(separator)
                }
            }

            menu.addItem(NSMenuItem.separator())
        } else {
            menu.addItem(buildHostStatusItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // 4. Action items
        for item in buildActionItems() {
            menu.addItem(item)
        }

        providerFilterController.activate(in: menu)
        
        return menu
    }

    func activateProviderFilter(in menu: NSMenu) {
        providerFilterController.activate(in: menu)
    }

    func highlight(_ item: NSMenuItem?) {
        highlightController.highlight(item)
    }

    var layout: StatusBarMenuSnapshot.Layout { snapshot.layout }

    func update(snapshot: StatusBarMenuSnapshot) {
        self.snapshot = snapshot
        refreshItem?.isEnabled = snapshot.canRefresh && !snapshot.isLoadingQuotas
        hostStatusItem?.identifier = hostIssueIdentifier
        for recovery in recoveryItems {
            let account = snapshot.providers.first { $0.provider == recovery.accountID.provider }?
                .accounts.first { $0.id == recovery.accountID }
            guard let warning = account?.warning,
                  let action = recoveryCommand(warning: warning, provider: recovery.accountID.provider, accountID: recovery.accountID) else {
                recovery.item.isEnabled = false
                recovery.item.isHidden = true
                recovery.separator.isHidden = true
                continue
            }
            recovery.item.update(title: action.title.localized(), symbolName: action.symbol, command: action.command)
            recovery.item.isHidden = false
            recovery.separator.isHidden = false
            recovery.item.isEnabled = warning.recoveryAction != .retry || account?.isRefreshBlocked == false
        }
    }

    // MARK: - Header Item
    
    private func buildHeaderItem() -> NSMenuItem {
        let headerView = MenuContent { MenuHeaderView(isLoading: self.snapshot.isLoadingQuotas) }
        return viewItem(for: headerView, title: "Quotio")
    }

    // MARK: - Account Card Item

    private func buildAccountCardItem(_ account: StatusBarMenuAccountSnapshot) -> NSMenuItem {
        let provider = account.id.provider
        let item = NSMenuItem()
        item.title = snapshot.displaySettings.hideSensitiveInfo
            ? "privacy.accountHidden".localized()
            : account.email

        item.submenu = buildAccountDetailSubmenu(account)

        let hasDetail = item.submenu != nil
        let itemID = ObjectIdentifier(item)
        let cardView = MenuContent {
            let current = self.snapshot.providers.first { $0.provider == provider }?
                .accounts.first { $0.id == account.id }
            return Group {
                if let current, let data = current.quota {
                    MenuAccountCardView(
                        email: current.email, data: data, provider: provider, subscriptionInfo: current.subscription,
                        warning: current.warning,
                        onRecover: {
                            if let warning = current.warning {
                                self.recover(warning: warning, provider: provider, accountID: current.id)
                            }
                        },
                        isRefreshing: current.isRefreshing, canRefresh: !current.isRefreshBlocked,
                        hasDetail: hasDetail, itemID: itemID, highlightController: self.highlightController,
                        settings: self.snapshot.displaySettings,
                        onRefresh: { await self.commands.dispatch(.refreshAccount(account.id))?.value }
                    )
                } else if let current, let warning = current.warning {
                    MenuAccountWarningView(
                        email: current.email, provider: provider, warning: warning, hasDetail: hasDetail,
                        settings: self.snapshot.displaySettings, canRetry: !current.isRefreshBlocked,
                        isHighlighted: self.highlightController.highlightedItem == itemID,
                        onRecover: { self.recover(warning: warning, provider: provider, accountID: current.id) }
                    )
                }
            }
        }
        item.view = hostingView(for: cardView)
        return item
    }

    /// Charts every limit beside the menu instead of inside it, so the menu
    /// stays short on small screens.
    private func buildAccountDetailSubmenu(_ account: StatusBarMenuAccountSnapshot) -> NSMenu? {
        guard account.hasDetail else { return nil }
        let submenu = makeMenu()
        submenu.addItem(viewItem(for: MenuContent {
            let current = self.snapshot.providers.first { $0.provider == account.id.provider }?
                .accounts.first { $0.id == account.id }
            return Group {
                if let current, let data = current.quota {
                    MenuAccountDetailView(
                        email: current.email, data: data, provider: account.id.provider, warning: current.warning,
                        settings: self.snapshot.displaySettings,
                        loadHistory: { metricID, range in
                            await self.commands.history(account: account.id, metricID: metricID, range: range)
                        }
                    )
                } else if let current, let warning = current.warning {
                    MenuAccountWarningView(
                        email: current.email, provider: account.id.provider, warning: warning, hasDetail: false,
                        settings: self.snapshot.displaySettings, canRetry: false, isHighlighted: false, onRecover: nil
                    )
                }
            }
        }, width: 380))
        if account.id.provider == .codex, let analytics = account.quota?.analytics, !analytics.isEmpty {
            submenu.addItem(.separator())
            let analyticsItem = NSMenuItem(title: "quota.detail.analytics".localized(), action: nil, keyEquivalent: "")
            analyticsItem.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
            analyticsItem.submenu = buildCodexAnalyticsSubmenu(analytics: analytics, accountID: account.id)
            submenu.addItem(analyticsItem)
        }
        let recovery = account.warning.flatMap {
            recoveryCommand(warning: $0, provider: account.id.provider, accountID: account.id)
        }
        let separator = NSMenuItem.separator()
        separator.isHidden = recovery == nil
        submenu.addItem(separator)
        let item = commandItem(recovery?.title ?? "action.retry", symbol: recovery?.symbol ?? "arrow.clockwise",
                               key: "", command: recovery?.command ?? .refreshAccount(account.id))
        item.identifier = NSUserInterfaceItemIdentifier("quotaRecovery")
        item.isHidden = recovery == nil
        item.isEnabled = recovery != nil && (account.warning?.recoveryAction != .retry || !account.isRefreshBlocked)
        recoveryItems.append((item, separator, account.id))
        submenu.addItem(item)
        if account.quota != nil {
            submenu.addItem(.separator())
            submenu.addItem(commandItem("quota.detail.openHistory", symbol: "clock.arrow.circlepath", key: "",
                                        command: .openHistory(account.id)))
        }
        return submenu
    }

    private func buildCodexAnalyticsSubmenu(analytics: QuotaAnalytics, accountID: QuotaAccountID) -> NSMenu {
        let submenu = makeMenu()
        submenu.addItem(viewItem(for: MenuContent {
            let current = self.snapshot.providers.first { $0.provider == accountID.provider }?
                .accounts.first { $0.id == accountID }?.quota?.analytics ?? analytics
            return AnalyticsDetailSection(analytics: current)
        }, width: 640))
        return submenu
    }

    // MARK: - Empty State
    
    private func buildEmptyStateItem() -> NSMenuItem {
        viewItem(for: MenuEmptyStateView(), title: "menubar.noData".localized())
    }

    private func buildHostStatusItem() -> NSMenuItem {
        let item = viewItem(for: MenuContent {
            Group {
                if let warning = self.snapshot.hostWarning {
                    MenuQuotaWarningView(
                        warning: warning,
                        canRetry: self.snapshot.canRefresh && !self.snapshot.isLoadingQuotas,
                        onRecover: { self.recover(warning: warning, provider: nil) }
                    )
                    .padding(.horizontal, MenuItemMetrics.contentInset)
                    .padding(.vertical, 8)
                } else {
                    MenuEmptyStateView()
                }
            }
        }, title: "menubar.noData".localized())
        item.identifier = hostIssueIdentifier
        hostStatusItem = item
        return item
    }

    private func buildProviderWarningItem(_ providerSnapshot: StatusBarMenuProviderSnapshot) -> NSMenuItem {
        let item = viewItem(for: MenuContent {
            let current = self.snapshot.providers.first { $0.provider == providerSnapshot.provider }
            return Group {
                if let current, let warning = current.warning {
                    MenuQuotaWarningView(
                        warning: warning,
                        canRetry: current.supportsScopedRefresh && !current.isRefreshing,
                        onRecover: {
                            self.recover(warning: warning, provider: current.provider)
                        }
                    )
                }
            }
            .padding(.horizontal, MenuItemMetrics.contentInset)
            .padding(.vertical, 8)
        }, title: providerSnapshot.displayName)
        item.representedObject = providerSnapshot.provider.rawValue
        item.identifier = NSUserInterfaceItemIdentifier("quotaProviderIssue")
        return item
    }

    private var hostIssueIdentifier: NSUserInterfaceItemIdentifier? {
        snapshot.hostWarning == nil ? nil : NSUserInterfaceItemIdentifier("quotaHostIssue")
    }

    
    // MARK: - Action Items

    private func buildActionItems() -> [NSMenuItem] {
        let refresh = commandItem("action.refresh", symbol: "arrow.clockwise", key: "r", command: .refreshAll)
        refresh.isEnabled = snapshot.canRefresh && !snapshot.isLoadingQuotas
        refreshItem = refresh
        refresh.view = hostingView(for: MenuContent {
            RefreshButton(title: "action.refresh".localized(), isRefreshing: self.snapshot.isLoadingQuotas) {
                await self.commands.dispatch(.refreshAll)?.value
            }
            .buttonStyle(.plain)
            .disabled(!self.snapshot.canRefresh)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let schedule = self.snapshot.refreshSchedule {
                    MenuRefreshScheduleText(schedule: schedule)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, MenuItemMetrics.contentInset)
            .padding(.vertical, 6)
        })
        return [
            refresh,
            commandItem("companion.pair", symbol: "iphone", key: "", command: .pairIPhone),
            commandItem("action.openApp", symbol: "gearshape", key: ",", command: .openApp),
            .separator(),
            commandItem("action.quit", symbol: "xmark.circle", key: "q", command: .quit),
        ]
    }

    // MARK: - Helpers
    private func recoveryCommand(
        warning: StatusBarMenuQuotaWarning,
        provider: QuotaProvider?,
        accountID: QuotaAccountID? = nil
    ) -> (title: String, symbol: String, command: StatusBarCommand)? {
        switch warning.recoveryAction {
        case .retry:
            let command = accountID.map(StatusBarCommand.refreshAccount)
                ?? provider.map(StatusBarCommand.refreshProvider) ?? .refreshAll
            return ("action.retry", "arrow.clockwise", command)
        case .signIn, .authorize, .refreshInSourceApp:
            return ("menubar.quota.reviewAccount", "gearshape", .openProviderSettings(provider))
        case nil:
            return nil
        }
    }

    private func recover(warning: StatusBarMenuQuotaWarning, provider: QuotaProvider?, accountID: QuotaAccountID? = nil) {
        guard let recovery = recoveryCommand(warning: warning, provider: provider, accountID: accountID) else { return }
        if warning.recoveryAction == .retry {
            guard snapshot.canRefresh,
                  !snapshot.providers.contains(where: { (provider == nil || $0.provider == provider) && $0.isRefreshing }) else { return }
        }
        commands.dispatch(recovery.command)
    }


    private func commandItem(
        _ titleKey: String,
        symbol: String,
        key: String,
        command: StatusBarCommand
    ) -> StatusBarCommandMenuItem {
        StatusBarCommandMenuItem(
            title: titleKey.localized(),
            symbolName: symbol,
            keyEquivalent: key,
            command: command,
            commands: commands
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    /// The title is never drawn for view items, but AppKit still uses it for
    /// type-select.
    private func viewItem<V: View>(for view: V, title: String = "", width: CGFloat? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = hostingView(for: view, width: width)
        return item
    }

    /// Item views inherit the menu's appearance, so AppKit and SwiftUI resolve
    /// the same light or dark context as the system menu material.
    private func hostingView<V: View>(for view: V, width: CGFloat? = nil) -> NSView {
        let rootView = view
            .frame(width: width ?? menuWidth)
            .environment(\.locale, snapshot.language.locale)
        let hostingView = StatusBarMenuHostingView(rootView: rootView)
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        return hostingView
    }
}

// MARK: - SwiftUI Menu Components

private struct MenuContent<Content: View>: View {
    let content: () -> Content

    var body: some View { content() }
}

// MARK: Header View

private struct MenuHeaderView: View {
    let isLoading: Bool
    
    var body: some View {
        HStack {
            Text("Quotio")
                .font(.headline)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, MenuItemMetrics.contentInset)
        .padding(.vertical, 6)
    }
}

// MARK: - Provider Section Header

private struct MenuProviderSectionHeader: View {
    let provider: QuotaProvider
    let displayName: String
    let isRefreshing: Bool
    let supportsScopedRefresh: Bool
    let onRefresh: @MainActor () async -> Void

    var body: some View {
        HStack(spacing: 6) {
            ProviderIconMono(provider: provider, size: 14)
            Text(displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()

            RefreshButton(title: "action.refreshQuota".localized(), isRefreshing: isRefreshing, action: onRefresh)
            .labelStyle(.iconOnly)
            .font(.subheadline.weight(.medium))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(!supportsScopedRefresh)
            .help("action.refreshQuota".localized())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, MenuItemMetrics.contentInset)
        .padding(.vertical, 3)
    }
}

// MARK: - Provider Picker View (separate from accounts list)

private struct MenuProviderPickerView: View {
    let providers: [StatusBarMenuProviderSnapshot]
    let controller: StatusBarProviderFilterController
    
    var body: some View {
        FlowLayout(spacing: 6) {
            ProviderFilterChip(
                title: "menubar.providers.all".localized(),
                isSelected: controller.selectedProvider == nil,
                action: { controller.select(nil) }
            ) {
                Image(systemName: "square.grid.2x2")
                    .font(.subheadline)
            }

            ForEach(providers, id: \.provider) { item in
                ProviderFilterChip(
                    title: item.displayName,
                    isSelected: controller.selectedProvider == item.provider,
                    action: { controller.select(item.provider) }
                ) {
                    ProviderIconMono(provider: item.provider, size: 14)
                }
            }
        }
        .padding(.horizontal, MenuItemMetrics.contentInset)
        .padding(.vertical, 6)
    }
}

// MARK: Provider Filter Chip

/// The selected filter is the only tinted control in the menu; selection is
/// also exposed through weight and the accessibility selected trait.
private struct ProviderFilterChip<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().fill(.fill.quaternary)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Monochrome Provider Icon

private struct ProviderIconMono: View {
    let provider: QuotaProvider
    let size: CGFloat
    
    var body: some View {
        Group {
            if let assetName = provider.menuBarIconAsset,
               let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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

private struct MenuAccountWarningView: View {
    let email: String
    let provider: QuotaProvider
    let warning: StatusBarMenuQuotaWarning
    let hasDetail: Bool
    let settings: StatusBarMenuDisplaySettings
    let canRetry: Bool
    let isHighlighted: Bool
    let onRecover: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIconMono(provider: provider, size: 16)
                    .foregroundStyle(.secondary)
                SensitiveAccountText(value: email, isSensitive: settings.hideSensitiveInfo)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            MenuQuotaWarningView(warning: warning, canRetry: canRetry, onRecover: onRecover)
        }
        .padding(.horizontal, MenuItemMetrics.contentInset)
        .padding(.vertical, settings.quotaDisplayStyle == .compact ? 6 : 8)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: MenuItemMetrics.highlightCornerRadius, style: .continuous)
                    .fill(.fill.tertiary)
                    .padding(.horizontal, MenuItemMetrics.highlightInset)
            }
        }
    }
}

private struct MenuAccountCardView: View {
    let email: String
    let data: ProviderQuota
    let provider: QuotaProvider
    let subscriptionInfo: QuotaSubscriptionInfo?
    let warning: StatusBarMenuQuotaWarning?
    let onRecover: @MainActor () -> Void
    let isRefreshing: Bool
    let canRefresh: Bool
    let hasDetail: Bool
    let itemID: ObjectIdentifier
    let highlightController: StatusBarMenuHighlightController
    let settings: StatusBarMenuDisplaySettings
    let onRefresh: @MainActor () async -> Void

    private var planName: String? {
        data.planType ?? subscriptionInfo?.tierDisplayName
    }

    private var isHighlighted: Bool {
        highlightController.highlightedItem == itemID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.quotaDisplayStyle == .compact {
                MenuCompactAccountRow(email: email, data: data, provider: provider,
                                      hasDetail: hasDetail, settings: settings)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    headerSection
                    quotaContentSection
                }
            }
            if let warning {
                MenuQuotaWarningView(warning: warning, canRetry: canRefresh, onRecover: onRecover)
            }
        }
        .padding(.horizontal, MenuItemMetrics.contentInset)
        .padding(.vertical, settings.quotaDisplayStyle == .compact ? 6 : 8)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: MenuItemMetrics.highlightCornerRadius, style: .continuous)
                    .fill(.fill.tertiary)
                    .padding(.horizontal, MenuItemMetrics.highlightInset)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 6) {
            ProviderIconMono(provider: provider, size: 16)
                .foregroundStyle(.secondary)

            SensitiveAccountText(value: email, isSensitive: settings.hideSensitiveInfo)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let planName {
                Text(planName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            RefreshButton(title: "action.refreshQuota".localized(), isRefreshing: isRefreshing, action: onRefresh)
            .labelStyle(.iconOnly)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(!canRefresh)
            .help("action.refreshQuota".localized())

            if hasDetail {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Quota Content

    private var quotaContentSection: some View {
        let groups = data.metricGroups
        let standaloneModels = data.models.filter(\.isStandaloneMetric)
        let isDetailed = settings.quotaDisplayStyle == .detailed

        return VStack(spacing: 10) {
            if data.isForbidden {
                MenuSignInAgainLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if groups.isEmpty && standaloneModels.isEmpty {
                Text("dashboard.noQuotaData".localized())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                if let name = group.name {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(group.models) { metric in
                    let meter = QuotaMeter(metric: metric, displayMode: settings.quotaDisplayMode)
                    if meter.isExhausted {
                        QuotaExhaustedBanner(meter: meter)
                    } else {
                        QuotaLimitRow(meter: meter, showsInsight: isDetailed)
                    }
                }
            }

            ForEach(standaloneModels) { model in
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.formattedUsage ?? "—")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .menuNativeTooltip(model.tooltip ?? "")
            }
        }
    }
}

private struct MenuQuotaWarningView: View {
    let warning: StatusBarMenuQuotaWarning
    let canRetry: Bool
    let onRecover: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(warning.issue?.explanation ?? "menubar.quota.stale".localized(),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let onRecover, let action = warning.recoveryAction {
                    Button(action == .retry ? "action.retry".localized() : "menubar.quota.reviewAccount".localized(),
                           action: onRecover)
                        .buttonStyle(.borderless)
                        .disabled(action == .retry && !canRetry)
                        .fixedSize()
                }
            }
            if let updated = warning.lastSuccessfulUpdate {
                Text(String(format: (warning.isStale ? "menubar.quota.staleTimestamp" : "menubar.quota.lastSuccess").localized(),
                            updated.formatted(date: .abbreviated, time: .shortened)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }
}

/// When the host fetches next, beside the Refresh command.
private struct MenuRefreshScheduleText: View {
    let schedule: StatusBarRefreshSchedule

    var body: some View {
        Group {
            switch schedule {
            case .manual:
                Text("menubar.refresh.manual".localized())
            case .next(let date):
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(String(format: "menubar.refresh.next".localized(),
                                QuotaTimeText.duration(until: date, now: context.date)))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The account's submenu: a chart for each paced limit, drawn from recorded
/// history when there is some, and a plain row with the week's use for limits
/// without a window.
private struct MenuAccountDetailView: View {
    let email: String
    let data: ProviderQuota
    let provider: QuotaProvider
    let warning: StatusBarMenuQuotaWarning?
    let settings: StatusBarMenuDisplaySettings
    let loadHistory: @MainActor (String, QuotaHistoryRange) async -> [QuotaHistoryPoint]
    @State private var history: [String: [QuotaHistoryPoint]] = [:]

    private var meters: [QuotaMeter] {
        data.metricGroups.flatMap(\.models).map { QuotaMeter(metric: $0, displayMode: settings.quotaDisplayMode) }
    }

    var body: some View {
        let meters = meters
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProviderIconMono(provider: provider, size: 14)
                    .foregroundStyle(.secondary)
                SensitiveAccountText(value: email, isSensitive: settings.hideSensitiveInfo)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(String(format: "quota.detail.updated".localized(),
                            data.lastUpdated.formatted(.relative(presentation: .named))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let warning {
                MenuQuotaWarningView(warning: warning, canRetry: false, onRecover: nil)
            }
            ForEach(meters, id: \.metric.id) { meter in
                if meter.isExhausted {
                    QuotaExhaustedBanner(meter: meter)
                } else if let pace = meter.pace {
                    QuotaBurnCard(meter: meter, pace: pace, history: history[meter.metric.id] ?? [])
                } else {
                    QuotaLimitRow(meter: meter,
                                  trendPerDay: history[meter.metric.id].flatMap { QuotaHistoryPoint.usedPerDay($0) })
                }
            }
            if meters.contains(where: { $0.pace != nil && !$0.isExhausted }) {
                QuotaBurnLegend()
            }
        }
        .padding(.horizontal, MenuItemMetrics.contentInset)
        .padding(.vertical, 10)
        .task {
            for meter in meters where !meter.isExhausted && meter.hasData {
                // Without a window, the last week of use stands in for pace.
                let range = meter.pace.map { Self.range(for: $0.windowDuration) } ?? .week
                history[meter.metric.id] = await loadHistory(meter.metric.id, range)
            }
        }
    }

    /// The shortest history range that covers the whole window.
    private static func range(for window: TimeInterval) -> QuotaHistoryRange {
        if window <= 86_400 { return .day }
        if window <= 7 * 86_400 { return .week }
        return .month
    }
}

/// Compact density: one line per account with a mini bar per limit and the
/// value of whichever limit runs out first.
private struct MenuCompactAccountRow: View {
    let email: String
    let data: ProviderQuota
    let provider: QuotaProvider
    let hasDetail: Bool
    let settings: StatusBarMenuDisplaySettings

    private var meters: [QuotaMeter] {
        data.metricGroups.flatMap(\.models)
            .map { QuotaMeter(metric: $0, displayMode: settings.quotaDisplayMode) }
            .filter(\.hasData)
    }

    var body: some View {
        let meters = meters
        let binding = meters.min { $0.remaining < $1.remaining }
        let isOut = binding?.isExhausted ?? false
        HStack(spacing: 8) {
            ProviderIconMono(provider: provider, size: 16)
                .foregroundStyle(.secondary)
            SensitiveAccountText(value: email, isSensitive: settings.hideSensitiveInfo)
                .font(.callout)
                .foregroundStyle(isOut ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if data.isForbidden {
                MenuSignInAgainLabel()
            } else if let binding {
                VStack(spacing: 3) {
                    ForEach(Self.barMeters(meters), id: \.metric.id) { meter in
                        QuotaPaceBar(meter: meter, height: 4, tickOverhang: 2)
                    }
                }
                .frame(width: 56)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(binding.valueText)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(binding.valueColor)
                    detail(for: binding)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .frame(minWidth: 64, alignment: .trailing)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            if hasDetail {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .help(meters.map { "\($0.name) \($0.valueText)" }.joined(separator: "\n"))
    }

    @ViewBuilder private func detail(for meter: QuotaMeter) -> some View {
        if meter.isExhausted, let reset = meter.resetsAt, reset > Date() {
            Text(meter.resetsOnDate
                ? QuotaTimeText.day(reset)
                : String(format: "quota.countdown.in".localized(), QuotaTimeText.duration(until: reset)))
                .foregroundStyle(.secondary)
        } else if meter.tone == .behind, let empty = meter.pace?.projectedEmpty {
            Text(String(format: "quota.pace.emptyShort".localized(), QuotaTimeText.weekday(empty)))
                .foregroundStyle(.orange)
        } else if let reset = meter.resetsAt, reset > Date() {
            let when = meter.resetsOnDate ? QuotaTimeText.day(reset)
                : reset.timeIntervalSinceNow < 86_400 ? QuotaTimeText.duration(until: reset) : QuotaTimeText.weekday(reset)
            Text(Self.shortName(meter) + " · " + when)
                .foregroundStyle(.secondary)
        }
    }

    /// The two tightest limits in their original order, so the bars always
    /// include the one whose value the row shows.
    private static func barMeters(_ meters: [QuotaMeter]) -> [QuotaMeter] {
        let tightest = Set(meters.sorted { $0.remaining < $1.remaining }.prefix(2).map(\.metric.id))
        return meters.filter { tightest.contains($0.metric.id) }
    }

    private static func shortName(_ meter: QuotaMeter) -> String {
        switch meter.metric.windowDuration {
        case 18_000: "5h"
        case 86_400: "quota.window.day".localized()
        case 604_800: "quota.window.week".localized()
        default: meter.name
        }
    }
}

private struct MenuSignInAgainLabel: View {
    var body: some View {
        Label("quota.signInAgain".localized(), systemImage: "exclamationmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.red)
            .lineLimit(1)
    }
}

/// Geometry shared by custom item views so their padding and highlight match
/// the system rows they sit beside.
private enum MenuItemMetrics {
    static let contentInset: CGFloat = 16
    static let highlightInset: CGFloat = 5
    static let highlightCornerRadius: CGFloat = 7
}

private struct AnalyticsDetailSection: View {
    let analytics: QuotaAnalytics

    @State private var trendMode: AnalyticsTrendMode = .daily

    private static let primaryMetricRowIDs = [
        "codex-lifetime-tokens",
        "codex-peak-daily",
        "codex-longest-task",
        "codex-current-streak",
        "codex-longest-streak"
    ]

    private static let usageMetricRowIDs = [
        "codex-extra-usage",
        "today",
        "yesterday",
        "last-30-days"
    ]

    private static let hiddenRowIDs = Set(primaryMetricRowIDs + usageMetricRowIDs)
    private static let resetCreditsSummaryID = "codex-rate-limit-resets"
    private static let resetCreditRowPrefix = "codex-rate-limit-reset-"

    private var metricRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.primaryMetricRowIDs)
    }

    private var usageRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.usageMetricRowIDs)
    }

    private var shouldShowNote: Bool {
        metricRows.isEmpty && usageRows.isEmpty && resetCreditsSummary == nil
    }

    private func metricRows(for ids: [String]) -> [QuotaAnalyticsRow] {
        let rowsByID = analytics.rows.reduce(into: [String: QuotaAnalyticsRow]()) { result, row in
            result[row.id] = result[row.id] ?? row
        }
        return ids.compactMap { rowsByID[$0] }
    }

    private var detailRows: [QuotaAnalyticsRow] {
        analytics.rows.filter {
            !Self.hiddenRowIDs.contains($0.id)
                && $0.id != Self.resetCreditsSummaryID
                && !$0.id.hasPrefix(Self.resetCreditRowPrefix)
        }
    }

    private var resetCreditsSummary: QuotaAnalyticsRow? {
        analytics.rows.first { $0.id == Self.resetCreditsSummaryID }
    }

    private var resetCreditRows: [QuotaAnalyticsRow] {
        analytics.rows.filter { $0.id.hasPrefix(Self.resetCreditRowPrefix) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !metricRows.isEmpty {
                AnalyticsMetricStripView(rows: metricRows)
            }

            if !usageRows.isEmpty {
                AnalyticsMetricStripView(rows: usageRows)
            }

            if let resetCreditsSummary {
                ResetCreditsInventoryView(summary: resetCreditsSummary, credits: resetCreditRows)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Usage Trend")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    if analytics.trend.isEmpty {
                        Text("No data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        AnalyticsTrendModePicker(selection: $trendMode)
                    }
                }

                if !analytics.trend.isEmpty {
                    UsageTrendHeatmap(points: analytics.trend, mode: trendMode)
                        .id(trendMode)
                }
            }

            ForEach(detailRows) { row in
                AnalyticsRowView(row: row)
            }

            if shouldShowNote, let note = analytics.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }
}

private struct ResetCreditsInventoryView: View {
    let summary: QuotaAnalyticsRow
    let credits: [QuotaAnalyticsRow]

    private var countLabel: String {
        let count = summary.value.split(separator: " ").first.map(String.init) ?? "0"
        return "\(count) resets available"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gift")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(countLabel)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                    ResetCreditChip(
                        label: compactRelativeLabel(credit.value),
                        tooltip: creditTooltip(credit),
                        isNext: index == 0
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func compactRelativeLabel(_ value: String) -> String {
        let lowercased = value.lowercased()
        let parts = lowercased.split(separator: " ")
        guard parts.count >= 3, parts.first == "in", let number = parts.dropFirst().first else {
            return value.isEmpty ? "∞" : value
        }

        let unit = parts.dropFirst(2).first ?? ""
        if unit.hasPrefix("day") { return "\(number)d" }
        if unit.hasPrefix("hour") { return "\(number)h" }
        if unit.hasPrefix("minute") { return "\(number)m" }
        return String(number)
    }

    private func creditTooltip(_ credit: QuotaAnalyticsRow) -> String {
        let suffix = credit.value.isEmpty ? "" : " - \(credit.value)"
        return "Expires: \(credit.title)\(suffix)"
    }
}

private struct ResetCreditChip: View {
    let label: String
    let tooltip: String
    let isNext: Bool

    var body: some View {
        Text(label)
            .font(.callout.weight(isNext ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(isNext ? .primary : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isNext ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.quaternary), in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .menuNativeTooltip(tooltip)
    }
}

private struct AnalyticsMetricStripView: View {
    let rows: [QuotaAnalyticsRow]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AnalyticsMetricTileView(row: row)
                    .frame(maxWidth: .infinity)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 34)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AnalyticsMetricTileView: View {
    let row: QuotaAnalyticsRow

    private var displayValue: String {
        switch row.id {
        case "codex-lifetime-tokens", "codex-peak-daily":
            row.value.replacingOccurrences(of: " tokens", with: "")
        default:
            row.value
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(displayValue)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(row.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .frame(minWidth: 82)
    }
}

private enum AnalyticsTrendMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .cumulative: "Cumulative"
        }
    }
}

private struct AnalyticsTrendModePicker: View {
    @Binding var selection: AnalyticsTrendMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnalyticsTrendMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.caption.weight(selection == mode ? .semibold : .regular))
                        .foregroundStyle(selection == mode ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
    }
}

private enum AnalyticsTrendSeries {
    typealias ParsedPoint = (date: Date, point: QuotaAnalyticsPoint)

    static func dailyPoints(from points: [QuotaAnalyticsPoint]) -> [QuotaAnalyticsPoint] {
        parsedPoints(from: points).map { item in
            QuotaAnalyticsPoint(
                date: dayLabel(for: item.date),
                value: item.point.value,
                label: "on \(shortDateLabel(for: item.date))",
                valueLabel: item.point.valueLabel.isEmpty ? tokenLabel(item.point.value) : item.point.valueLabel
            )
        }
    }

    static func weeklyBuckets(from points: [QuotaAnalyticsPoint], mode: AnalyticsTrendMode) -> [AnalyticsTrendBucket] {
        let parsed = parsedPoints(from: points)
        let grouped = Dictionary(grouping: parsed) { item in
            startOfWeek(containing: item.date)
        }
        switch mode {
        case .daily, .weekly:
            return grouped.keys.sorted().map { weekStart in
                let weeklyValue = grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                return AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: weeklyValue,
                    valueLabel: tokenLabel(weeklyValue),
                    tooltipLabel: "on week of \(longDateLabel(for: weekStart))"
                )
            }
        case .cumulative:
            let sortedWeeks = grouped.keys.sorted()
            guard let first = sortedWeeks.first, let last = sortedWeeks.last else {
                return []
            }

            var buckets: [AnalyticsTrendBucket] = []
            var runningTotal = 0.0
            var weekStart = first

            while weekStart <= last {
                runningTotal += grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                buckets.append(AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: runningTotal,
                    valueLabel: tokenLabel(runningTotal),
                    tooltipLabel: "through week of \(longDateLabel(for: weekStart))"
                ))

                guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
                    break
                }
                weekStart = nextWeek
            }

            return buckets
        }
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }

    static func dayLabel(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "Unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parsedPoints(from points: [QuotaAnalyticsPoint]) -> [ParsedPoint] {
        points.compactMap { point in
            guard let date = date(from: point.date) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private static func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private static func date(from string: String) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func longDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func tokenLabel(_ value: Double) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000_000 {
            return "\(compactNumber(value / 1_000_000_000))B tokens"
        }
        if absoluteValue >= 1_000_000 {
            return "\(compactNumber(value / 1_000_000))M tokens"
        }
        if absoluteValue >= 1_000 {
            return "\(compactNumber(value / 1_000))K tokens"
        }
        return "\(Int(value.rounded())) tokens"
    }

    private static func compactNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}

private struct AnalyticsTrendBucket: Identifiable {
    var id: String { AnalyticsTrendSeries.dayLabel(for: weekStart) }
    let weekStart: Date
    let value: Double
    let valueLabel: String
    let tooltipLabel: String
}

private struct UsageTrendHeatmap: View {
    let points: [QuotaAnalyticsPoint]
    let mode: AnalyticsTrendMode

    @State private var hoveredCellID: String?
    @State private var hoveredText: String?

    private let cellSize: CGFloat = 9
    private let spacing: CGFloat = 2.4

    private var calendar: Calendar {
        AnalyticsTrendSeries.calendar
    }

    private var parsedPoints: [(date: Date, point: QuotaAnalyticsPoint)] {
        AnalyticsTrendSeries.dailyPoints(from: points).compactMap { point in
            guard let date = Self.date(from: point.date, calendar: calendar) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private var heatmapData: HeatmapData {
        switch mode {
        case .daily:
            dailyHeatmapData()
        case .weekly, .cumulative:
            weeklyHeatmapData()
        }
    }

    private func dailyHeatmapData() -> HeatmapData {
        let parsed = parsedPoints
        guard let last = parsed.last?.date else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let pointByDate = parsed.reduce(into: [Date: QuotaAnalyticsPoint]()) { result, item in
            result[item.date] = item.point
        }
        let maxValue = max(parsed.map(\.point.value).max() ?? 0, 1)
        let first = displayStartDate(endingAt: last)
        let start = startOfWeek(containing: first)
        let days = max(calendar.dateComponents([.day], from: start, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let cells = (0..<7).map { weekdayIndex -> HeatmapCell in
                let dayOffset = weekIndex * 7 + weekdayIndex
                let date = calendar.date(byAdding: .day, value: dayOffset, to: start) ?? start
                let point = pointByDate[date]
                let intensity = point.map { point in
                    point.value <= 0 ? 0 : max(0.18, min(point.value / maxValue, 1))
                } ?? 0
                let isInRange = date >= first && date <= last
                return HeatmapCell(
                    id: "\(weekIndex)-\(weekdayIndex)",
                    date: date,
                    point: point,
                    intensity: intensity,
                    isInRange: isInRange
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: start, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    private func weeklyHeatmapData() -> HeatmapData {
        let buckets = AnalyticsTrendSeries.weeklyBuckets(from: points, mode: mode)
        guard let last = buckets.last?.weekStart else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let bucketByWeek = buckets.reduce(into: [Date: AnalyticsTrendBucket]()) { result, bucket in
            result[bucket.weekStart] = bucket
        }
        let maxValue = max(buckets.map(\.value).max() ?? 0, 1)
        let first = startOfWeek(containing: displayStartDate(endingAt: last))
        let days = max(calendar.dateComponents([.day], from: first, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let weekStart = calendar.date(byAdding: .day, value: weekIndex * 7, to: first) ?? first
            let bucket = bucketByWeek[weekStart]
            let normalizedValue = bucket.map { $0.value <= 0 ? 0 : max(0.14, min($0.value / maxValue, 1)) } ?? 0
            let filledRows = normalizedValue <= 0 ? 0 : max(1, min(Int((normalizedValue * 7).rounded(.up)), 7))

            let cells = (0..<7).map { rowIndex -> HeatmapCell in
                let isFilled = rowIndex >= 7 - filledRows
                let point = bucket.map { bucket -> QuotaAnalyticsPoint in
                    QuotaAnalyticsPoint(
                        date: AnalyticsTrendSeries.dayLabel(for: weekStart),
                        value: bucket.value,
                        label: bucket.tooltipLabel,
                        valueLabel: bucket.valueLabel
                    )
                }

                return HeatmapCell(
                    id: "\(weekIndex)-\(rowIndex)",
                    date: weekStart,
                    point: isFilled ? point : nil,
                    intensity: isFilled ? normalizedValue : 0,
                    isInRange: true
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: first, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    var body: some View {
        let data = heatmapData

        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(data.monthLabels) { label in
                        Text(label.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: monthLabelWidth(for: label, in: data), alignment: .leading)
                    }
                }
                .frame(width: data.width, height: 13, alignment: .leading)

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(data.weeks) { week in
                        VStack(spacing: spacing) {
                            ForEach(week.cells) { cell in
                                heatmapCell(cell)
                            }
                        }
                    }
                }
                .frame(width: data.width, alignment: .leading)
            }

            if let hoveredText {
                Text(hoveredText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.separator, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .offset(y: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func heatmapCell(_ cell: HeatmapCell) -> some View {
        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
            .fill(fillColor(for: cell))
            .frame(width: cellSize, height: cellSize)
            .opacity(cell.isInRange ? 1 : 0)
            .overlay {
                if hoveredCellID == cell.id, cell.point != nil {
                    RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
            .onHover { hovering in
                updateHover(hovering, cell: cell)
            }
    }

    private func fillColor(for cell: HeatmapCell) -> Color {
        guard cell.intensity > 0 else {
            return Color.primary.opacity(0.06)
        }
        return Color.accentColor.opacity(0.16 + cell.intensity * 0.78)
    }

    private func updateHover(_ hovering: Bool, cell: HeatmapCell) {
        guard let point = cell.point else {
            if !hovering, hoveredCellID == cell.id {
                hoveredCellID = nil
                hoveredText = nil
            }
            return
        }

        if hovering {
            hoveredCellID = cell.id
            hoveredText = point.label.isEmpty
                ? "\(point.valueLabel) on \(Self.shortDateLabel(for: cell.date))"
                : "\(point.valueLabel) \(point.label)"
        } else if hoveredCellID == cell.id {
            hoveredCellID = nil
            hoveredText = nil
        }
    }

    private func monthLabelWidth(for label: MonthLabel, in data: HeatmapData) -> CGFloat {
        guard let index = data.monthLabels.firstIndex(where: { $0.id == label.id }) else {
            return 0
        }
        let nextColumn = data.monthLabels.dropFirst(index + 1).first?.column ?? data.weeks.count
        let columns = max(nextColumn - label.column, 1)
        return CGFloat(columns) * cellSize + CGFloat(max(columns - 1, 0)) * spacing
    }

    private func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private func displayStartDate(endingAt date: Date) -> Date {
        calendar.date(byAdding: .day, value: -370, to: date)
            .map { calendar.startOfDay(for: $0) } ?? date
    }

    private func monthLabels(from start: Date, first: Date, last: Date, weekCount: Int) -> [MonthLabel] {
        var labels: [MonthLabel] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"

        var components = calendar.dateComponents([.year, .month], from: first)
        components.day = 1
        var monthStart = calendar.date(from: components) ?? first
        if monthStart < first {
            monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? first
        }

        while monthStart <= last {
            let column = max(calendar.dateComponents([.day], from: start, to: monthStart).day ?? 0, 0) / 7
            if column < weekCount {
                labels.append(MonthLabel(
                    id: AnalyticsTrendSeries.dayLabel(for: monthStart),
                    title: formatter.string(from: monthStart),
                    column: column
                ))
            }
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { break }
            monthStart = nextMonth
        }
        return labels
    }

    private static func date(from string: String, calendar: Calendar) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private struct HeatmapData {
        let weeks: [HeatmapWeek]
        let monthLabels: [MonthLabel]
        let width: CGFloat
    }

    private struct HeatmapWeek: Identifiable {
        let id: Int
        let cells: [HeatmapCell]
    }

    private struct HeatmapCell: Identifiable {
        let id: String
        let date: Date
        let point: QuotaAnalyticsPoint?
        let intensity: Double
        let isInRange: Bool
    }

    private struct MonthLabel: Identifiable {
        let id: String
        let title: String
        let column: Int
    }
}

private struct AnalyticsRowView: View {
    let row: QuotaAnalyticsRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }
}

// MARK: Empty State View

private struct MenuEmptyStateView: View {
    var body: some View {
        Text("menubar.noData".localized())
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, MenuItemMetrics.contentInset)
    }
}
