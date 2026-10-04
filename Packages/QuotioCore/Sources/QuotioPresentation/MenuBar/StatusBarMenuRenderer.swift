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
    private let command: StatusBarCommand
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

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func performCommand() {
        commands.dispatch(command)
    }
}

// MARK: - Status Bar Menu Renderer

@MainActor
final class StatusBarMenuRenderer {
    private let snapshot: StatusBarMenuSnapshot
    private let appearance: NSAppearance?
    private let commands: StatusBarCommandDispatcher
    private let providerFilterController: StatusBarProviderFilterController
    private let highlightController = StatusBarMenuHighlightController()
    private let menuWidth: CGFloat = 360

    init(
        snapshot: StatusBarMenuSnapshot,
        appearance: NSAppearance? = nil,
        commands: StatusBarCommandDispatcher
    ) {
        self.snapshot = snapshot
        self.appearance = appearance
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
                let headerView = MenuProviderSectionHeader(
                    provider: providerSnapshot.provider,
                    displayName: providerSnapshot.displayName,
                    isRefreshing: providerSnapshot.isRefreshing,
                    supportsScopedRefresh: providerSnapshot.supportsScopedRefresh,
                    onRefresh: {
                        self.commands.dispatch(.refreshProvider(providerSnapshot.provider))
                    }
                )
                let headerItem = viewItem(for: headerView, title: providerSnapshot.displayName)
                providerFilterController.register(headerItem, scope: .allProvidersOnly)
                menu.addItem(headerItem)

                if providerSnapshot.accounts.isEmpty {
                    let emptyItem = buildEmptyStateItem()
                    providerFilterController.register(
                        emptyItem,
                        scope: .provider(providerSnapshot.provider)
                    )
                    menu.addItem(emptyItem)
                } else {
                    for (accountIndex, account) in providerSnapshot.accounts.enumerated() {
                        if accountIndex > 0 {
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
            menu.addItem(buildEmptyStateItem())
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

    // MARK: - Header Item
    
    private func buildHeaderItem() -> NSMenuItem {
        let headerView = MenuHeaderView(isLoading: snapshot.isLoadingQuotas)
        return viewItem(for: headerView, title: "Quotio")
    }

    // MARK: - Account Card Item

    private func buildAccountCardItem(_ account: StatusBarMenuAccountSnapshot) -> NSMenuItem {
        let provider = account.id.provider
        let item = NSMenuItem()
        item.title = snapshot.displaySettings.hideSensitiveInfo
            ? "privacy.accountHidden".localized()
            : account.email

        if provider == .codex, let analytics = account.quota.analytics, !analytics.isEmpty {
            item.submenu = buildCodexAnalyticsSubmenu(analytics: analytics)
        }

        let cardView = MenuAccountCardView(
            email: account.email,
            data: account.quota,
            provider: provider,
            subscriptionInfo: account.subscription,
            isRefreshing: account.isRefreshing,
            canRefresh: !account.isRefreshBlocked,
            hasDetail: item.submenu != nil,
            itemID: ObjectIdentifier(item),
            highlightController: highlightController,
            settings: snapshot.displaySettings,
            onRefresh: {
                self.commands.dispatch(.refreshAccount(account.id))
            }
        )
        item.view = hostingView(for: cardView)
        return item
    }

    private func buildCodexAnalyticsSubmenu(analytics: QuotaAnalytics) -> NSMenu {
        let submenu = makeMenu()
        submenu.addItem(viewItem(for: AnalyticsDetailSection(analytics: analytics), width: 640))
        return submenu
    }

    // MARK: - Empty State
    
    private func buildEmptyStateItem() -> NSMenuItem {
        let emptyView = MenuEmptyStateView()
        return viewItem(for: emptyView, title: "menubar.noData".localized())
    }
    
    // MARK: - Action Items

    private func buildActionItems() -> [NSMenuItem] {
        let refresh = commandItem("action.refresh", symbol: "arrow.clockwise", key: "r", command: .refreshAll)
        refresh.isEnabled = snapshot.canRefresh && !snapshot.isLoadingQuotas
        if snapshot.isLoadingQuotas {
            refresh.view = hostingView(for: HStack(spacing: 6) {
                SmallProgressView()
                Text("status.refreshing".localized())
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuItemMetrics.contentInset)
            .padding(.vertical, 6))
        }
        return [
            refresh,
            commandItem("companion.pair", symbol: "iphone", key: "", command: .pairIPhone),
            commandItem("action.openApp", symbol: "gearshape", key: ",", command: .openApp),
            .separator(),
            commandItem("action.quit", symbol: "xmark.circle", key: "q", command: .quit),
        ]
    }

    // MARK: - Helpers

    private func commandItem(
        _ titleKey: String,
        symbol: String,
        key: String,
        command: StatusBarCommand
    ) -> NSMenuItem {
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
        menu.appearance = appearance
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
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        return hostingView
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
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ProviderIconMono(provider: provider, size: 14)
            Text(displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing || !supportsScopedRefresh)
            .help("action.refreshQuota".localized())
            .accessibilityLabel("action.refreshQuota".localized())
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

private struct MenuAccountCardView: View {
    let email: String
    let data: ProviderQuota
    let provider: QuotaProvider
    let subscriptionInfo: QuotaSubscriptionInfo?
    let isRefreshing: Bool
    let canRefresh: Bool
    let hasDetail: Bool
    let itemID: ObjectIdentifier
    let highlightController: StatusBarMenuHighlightController
    let settings: StatusBarMenuDisplaySettings
    let onRefresh: () -> Void

    private var planName: String? {
        data.planType ?? subscriptionInfo?.tierDisplayName
    }

    private var isHighlighted: Bool {
        highlightController.highlightedItem == itemID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            quotaContentSection

            footerSection
        }
        .padding(.horizontal, MenuItemMetrics.contentInset)
        .padding(.vertical, 8)
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

            if let planName {
                Text(planName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.fill.quaternary, in: Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 4)

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(!canRefresh)
            .help("action.refreshQuota".localized())
            .accessibilityLabel("action.refreshQuota".localized())

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

        return VStack(spacing: 8) {
            if groups.isEmpty && standaloneModels.isEmpty {
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
                quotaLayout(models: group.models.map {
                    ModelBadgeData(id: $0.id, name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime)
                })
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

    @ViewBuilder
    private func quotaLayout(models: [ModelBadgeData]) -> some View {
        switch settings.quotaDisplayStyle {
        case .lowestBar:
            LowestBarLayout(models: models, displayMode: settings.quotaDisplayMode)
        case .ring:
            RingGridLayout(models: models, displayMode: settings.quotaDisplayMode)
        case .card:
            CardGridLayout(models: models, displayMode: settings.quotaDisplayMode)
        }
    }
    
    // MARK: - Footer

    private var footerSection: some View {
        Text(data.lastUpdated.formatted(.relative(presentation: .named)))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
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

private struct ModelBadgeData: Identifiable {
    let id: String
    let name: String
    let percentage: Double
    let resetTime: String?
    let usage: String?

    init(id: String, name: String, percentage: Double, resetTime: String?, usage: String? = nil) {
        self.id = id
        self.name = name
        self.percentage = percentage
        self.resetTime = resetTime
        self.usage = usage
    }


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

private func menuDisplayPercent(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Double {
    displayMode.displayValue(from: remainingPercent)
}

/// Formatted percentage for menu rows. A negative remaining percentage means
/// "no data yet" and renders as a placeholder instead of a fake value like 101%.
private func menuPercentText(remainingPercent: Double, displayMode: QuotaDisplayMode) -> String {
    guard remainingPercent >= 0 else { return "—" }
    return "\(Int(menuDisplayPercent(remainingPercent: remainingPercent, displayMode: displayMode)))%"
}

/// Status tint for quota meters. Numbers stay in label colors so the value is
/// readable on the menu material regardless of tint.
private func menuStatusColor(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Color {
    guard remainingPercent >= 0 else { return .secondary }
    let usedPercent = 100 - remainingPercent
    let checkValue = displayMode == .used ? usedPercent : remainingPercent

    if displayMode == .used {
        if checkValue < 70 { return .green }
        if checkValue < 90 { return .orange }
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
    let displayMode: QuotaDisplayMode

    private var sorted: [ModelBadgeData] {
        models.sorted { $0.percentage < $1.percentage }
    }

    var body: some View {
        VStack(spacing: 6) {
            if let lowest = sorted.first {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(lowest.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(menuPercentText(remainingPercent: lowest.percentage, displayMode: displayMode))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }

                    ModernProgressBar(
                        percentage: lowest.percentage,
                        height: 6,
                        displayMode: displayMode
                    )

                    if let resetTime = lowest.formattedResetTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text(resetTime)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ForEach(sorted.dropFirst(), id: \.name) { (model: ModelBadgeData) in
                HStack(spacing: 6) {
                    Text(model.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let resetTime = model.formattedResetTime {
                        Text(resetTime)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .font(.caption)
                .padding(.horizontal, 8)
            }
        }
    }
}

private struct RingGridLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

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
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(models, id: \.name) { (model: ModelBadgeData) in
                VStack(spacing: 3) {
                    RingProgressView(percent: menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode), size: ringSize, lineWidth: 4, tint: menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode), showLabel: true)

                    Text(model.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let resetTime = model.formattedResetTime {
                        Text(resetTime)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .help(model.name)
            }
        }
    }
}

private struct CardGridLayout: View {
    let models: [ModelBadgeData]
    let displayMode: QuotaDisplayMode

    private var columns: [GridItem] {
        // Single metric: full width. Multiple: 2 columns
        if models.count == 1 {
            return [GridItem(.flexible())]
        } else {
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(models, id: \.name) { (model: ModelBadgeData) in
                let resetTime = model.formattedResetTime
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(model.name)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(model.usage ?? menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .font(.caption)

                    if model.usage == nil {
                        ModernProgressBar(
                            percentage: model.percentage,
                            height: 4,
                            displayMode: displayMode
                        )
                    }
                    Text(resetTime ?? " ")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(resetTime == nil)
                }
                .padding(8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help(model.name)
            }
        }
    }
}

// MARK: - Shared Components

private struct ModernProgressBar: View {
    let percentage: Double
    let height: CGFloat
    let displayMode: QuotaDisplayMode

    private var displayPercent: Double {
        menuDisplayPercent(remainingPercent: percentage, displayMode: displayMode)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.fill.tertiary)

                Capsule()
                    .fill(menuStatusColor(remainingPercent: percentage, displayMode: displayMode))
                    .frame(width: proxy.size.width * min(1, max(0, displayPercent / 100)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
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
