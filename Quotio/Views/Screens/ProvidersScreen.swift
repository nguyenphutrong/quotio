//
//  ProvidersScreen.swift
//  Quotio
//
//  Providers table with expandable provider/account rows.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProvidersScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var isImporterPresented = false
    @State private var selectedProvider: AIProvider?
    @State private var projectId: String = ""
    @State private var showProxyRequiredAlert = false
    @State private var expandedProviderIDs: Set<String> = []
    @State private var modeManager = OperatingModeManager.shared
    
    // MARK: - Computed Properties
    
    /// Providers that can be added manually
    private var addableProviders: [AIProvider] {
        AIProvider.allCases.filter { $0.supportsManualAuth && $0 != .warp }
    }
    
    /// All accounts grouped by provider
    private var groupedAccounts: [AIProvider: [AccountRowData]] {
        var groups: [AIProvider: [AccountRowData]] = [:]

        for file in viewModel.authFiles {
            guard let provider = file.providerType else { continue }
            let data = AccountRowData.from(authFile: file)
            groups[provider, default: []].append(data)
        }

        // Add accounts reported by cpa-plusplus quota/account endpoints.
        for (provider, quotas) in viewModel.providerQuotas {
            if !provider.supportsManualAuth {
                for (accountKey, _) in quotas {
                    let data = AccountRowData.from(provider: provider, accountKey: accountKey)
                    groups[provider, default: []].append(data)
                }
            }
        }

        return groups
    }
    
    /// Providers shown in the table: all addable providers plus any provider with existing accounts.
    private var tableProviders: [AIProvider] {
        let providers = Set(addableProviders).union(groupedAccounts.keys)
        return providers.sorted { $0.displayName < $1.displayName }
    }
    
    /// Total account count across all providers
    private var totalAccountCount: Int {
        groupedAccounts.values.reduce(0) { $0 + $1.count }
    }

    private var accountsExpansionSignature: String {
        tableProviders.map { provider in
            "\(provider.rawValue):\(groupedAccounts[provider]?.count ?? 0)"
        }.joined(separator: "|")
    }
    
    // MARK: - Body
    
    var body: some View {
        List {
            // Section 1: Your Accounts (grouped by provider)
            accountsSection
            
            // Section 2: Custom Providers (Local Proxy Mode only)
            if modeManager.isLocalProxyMode {
                customProvidersSection
            }
        }
        .navigationTitle("nav.providers".localized())
        .toolbar {
            toolbarContent
        }
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider, projectId: $projectId) {
                selectedProvider = nil
                projectId = ""
                viewModel.oauthState = nil
            }
            .environment(viewModel)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await viewModel.importVertexServiceAccount(url: url) }
            }
            // Failure case is silently ignored - user can retry via UI
        }
        .alert("providers.proxyRequired.title".localized(), isPresented: $showProxyRequiredAlert) {
            Button("action.restartProxy".localized()) {
                Task { await viewModel.ensureProxyRunning() }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.proxyRequired.message".localized())
        }
        .onAppear {
            expandProvidersWithAccounts()
        }
        .onChange(of: accountsExpansionSignature) { _, _ in
            expandProvidersWithAccounts()
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                Task {
                    if modeManager.isLocalProxyMode && viewModel.proxyManager.proxyStatus.running {
                        await viewModel.refreshData()
                    } else {
                        await viewModel.manualRefresh()
                    }
                    await viewModel.refreshAutoDetectedProviders()
                }
            } label: {
                if viewModel.isLoadingQuotas {
                    SmallProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isLoadingQuotas)
            .help("action.refresh".localized())
        }
    }
    
    // MARK: - Accounts Section
    
    @ViewBuilder
    private var accountsSection: some View {
        Section {
            ProviderTableHeader()

            ForEach(tableProviders, id: \.self) { provider in
                let accounts = groupedAccounts[provider] ?? []
                let isExpanded = expandedProviderIDs.contains(provider.rawValue)

                ProviderTableProviderRow(
                    provider: provider,
                    accounts: accounts,
                    isExpanded: isExpanded,
                    onToggleExpanded: {
                        toggleExpanded(provider)
                    },
                    onAddConnection: {
                        handleAddProvider(provider)
                    }
                )

                if isExpanded {
                    ForEach(accounts) { account in
                        ProviderTableAccountRow(
                            account: account,
                            onDelete: account.canDelete ? {
                                Task<Void, Never> { await deleteAccount(account) }
                            } : nil,
                            onEdit: account.canEdit ? {
                                markCustomProviderAPISyncRequired()
                            } : nil,
                            onToggleDisabled: account.source == .proxy ? {
                                Task<Void, Never> { await toggleAccountDisabled(account) }
                            } : nil
                        )
                    }
                }
            }
        } header: {
            HStack {
                Label("providers.yourAccounts".localized(), systemImage: "person.2.badge.key")
                
                if totalAccountCount > 0 {
                    Spacer()
                    Text("\(totalAccountCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            MenuBarHintView()
        }
    }
    
    // MARK: - Custom Providers Section

    @ViewBuilder
    private var customProvidersSection: some View {
        Section {
            RequiresCPAPLUSPLUSAPISupportRow()
        } header: {
            HStack {
                Label("customProviders.title".localized(), systemImage: "puzzlepiece.extension.fill")
            }
        } footer: {
            Text("customProviders.footer".localized())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
    
    // MARK: - Helper Functions

    private func handleAddProvider(_ provider: AIProvider) {
        // In Local Proxy Mode, require proxy to be running for OAuth
        if modeManager.isLocalProxyMode && !viewModel.proxyManager.proxyStatus.running {
            showProxyRequiredAlert = true
            return
        }

        if provider == .vertex {
            isImporterPresented = true
        } else if provider == .warp {
            markCustomProviderAPISyncRequired()
        } else {
            viewModel.oauthState = nil
            selectedProvider = provider
        }
    }
    
    private func deleteAccount(_ account: AccountRowData) async {
        // Only proxy accounts can be deleted via API
        guard account.canDelete else { return }

        // Find the original AuthFile to delete
        if let authFile = viewModel.authFiles.first(where: { $0.id == account.id }) {
            await viewModel.deleteAuthFile(authFile)
        }
    }

    private func toggleAccountDisabled(_ account: AccountRowData) async {
        // Only proxy accounts can be disabled via API
        guard account.source == .proxy else { return }

        // Find the original AuthFile to toggle
        if let authFile = viewModel.authFiles.first(where: { $0.id == account.id }) {
            await viewModel.toggleAuthFileDisabled(authFile)
        }
    }

    private func markCustomProviderAPISyncRequired() {
        // TODO(cpa-plusplus): add typed Management API endpoints for GLM/Warp/custom-provider CRUD.
        viewModel.errorMessage = "Requires cpa++ API support."
    }

    private func toggleExpanded(_ provider: AIProvider) {
        let id = provider.rawValue
        if expandedProviderIDs.contains(id) {
            expandedProviderIDs.remove(id)
        } else {
            expandedProviderIDs.insert(id)
        }
    }

    private func expandProvidersWithAccounts() {
        for provider in tableProviders where !(groupedAccounts[provider] ?? []).isEmpty {
            expandedProviderIDs.insert(provider.rawValue)
        }
    }
}

// MARK: - Provider Table

private enum ProviderTableMetrics {
    static let providerWidth: CGFloat = 240
    static let statusWidth: CGFloat = 136
    static let actionsWidth: CGFloat = 184
}

private struct ProviderTableHeader: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("providers.table.provider".localized())
                .frame(width: ProviderTableMetrics.providerWidth, alignment: .leading)

            Text("providers.table.accountsKey".localized())
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("providers.table.status".localized())
                .frame(width: ProviderTableMetrics.statusWidth, alignment: .leading)

            Text("providers.table.actions".localized())
                .frame(width: ProviderTableMetrics.actionsWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }
}

private struct ProviderTableProviderRow: View {
    let provider: AIProvider
    let accounts: [AccountRowData]
    let isExpanded: Bool
    var onToggleExpanded: () -> Void
    var onAddConnection: () -> Void

    private var canExpand: Bool { !accounts.isEmpty }

    private var statusText: String {
        if accounts.isEmpty {
            return "providers.notConnected".localized()
        }

        let enabledCount = accounts.filter { !$0.isDisabled }.count
        if enabledCount == 0 {
            return "providers.disabled".localized()
        }
        return "status.connected".localized()
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                guard canExpand else { return }
                onToggleExpanded()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: canExpand ? (isExpanded ? "chevron.down" : "chevron.right") : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(canExpand ? Color.secondary : Color.clear)
                        .frame(width: 12)

                    ProviderIcon(provider: provider, size: 22)

                    Text(provider.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .frame(width: ProviderTableMetrics.providerWidth, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Text(accounts.isEmpty ? "providers.noAccounts".localized() : accountCountText)
                    .foregroundStyle(accounts.isEmpty ? .secondary : .primary)

                if accounts.allSatisfy({ $0.source == .autoDetected }) && !accounts.isEmpty {
                    Text("providers.autoDetected".localized())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(accounts.isEmpty ? .secondary : .primary)
                .frame(width: ProviderTableMetrics.statusWidth, alignment: .leading)

            Button {
                onAddConnection()
            } label: {
                Label("providers.addConnection".localized(), systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: ProviderTableMetrics.actionsWidth, alignment: .trailing)
            .disabled(!provider.supportsManualAuth)
        }
    }

    private var accountCountText: String {
        String(format: "providers.accountCountFormat".localized(), accounts.count)
    }
}

private struct ProviderTableAccountRow: View {
    let account: AccountRowData
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    var onToggleDisabled: (() -> Void)?

    @State private var settings = MenuBarSettingsManager.shared
    @State private var showWarning = false
    @State private var showMaxItemsAlert = false
    @State private var showDeleteConfirmation = false

    private var isMenuBarSelected: Bool {
        settings.isSelected(account.menuBarItem)
    }

    private var maskedDisplayName: String {
        account.displayName.masked(if: settings.hideSensitiveInfo)
    }

    private var statusColor: Color {
        switch account.status {
        case "ready": return account.isDisabled ? .gray : .green
        case "cooling": return .orange
        case "error": return .red
        default: return .gray
        }
    }

    private var statusText: String {
        if account.isDisabled {
            return "providers.disabled".localized()
        }
        if let status = account.status, !status.isEmpty {
            return status
        }
        return account.source.displayName
    }

    var body: some View {
        HStack(spacing: 16) {
            Color.clear
                .frame(width: ProviderTableMetrics.providerWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(maskedDisplayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let message = account.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(account.status == nil ? .secondary : statusColor)
                    .lineLimit(1)
            }
            .frame(width: ProviderTableMetrics.statusWidth, alignment: .leading)

            HStack(spacing: 6) {
                if account.provider == .antigravity {
                    Label("Requires cpa++ API support.", systemImage: "lock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.iconOnly)
                        .help("Requires cpa++ API support.")
                }

                MenuBarBadge(
                    isSelected: isMenuBarSelected,
                    onTap: handleMenuBarToggle
                )

                if account.source == .proxy, let onToggleDisabled {
                    Button {
                        onToggleDisabled()
                    } label: {
                        Image(systemName: account.isDisabled ? "xmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(account.isDisabled ? .red : .secondary)
                    }
                    .buttonStyle(.rowAction)
                    .help(account.isDisabled ? "providers.enable".localized() : "providers.disable".localized())
                    .accessibilityLabel(account.isDisabled ? "providers.enable".localized() : "providers.disable".localized())
                }

                if account.canEdit, let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.rowAction)
                    .help("action.edit".localized())
                }

                if account.canDelete, onDelete != nil {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.rowActionDestructive)
                    .help("action.delete".localized())
                }
            }
            .frame(width: ProviderTableMetrics.actionsWidth, alignment: .trailing)
        }
        .contextMenu {
            Button {
                handleMenuBarToggle()
            } label: {
                if isMenuBarSelected {
                    Label("menubar.hideFromMenuBar".localized(), systemImage: "chart.bar")
                } else {
                    Label("menubar.showOnMenuBar".localized(), systemImage: "chart.bar.fill")
                }
            }

            if account.source == .proxy, let onToggleDisabled {
                Button {
                    onToggleDisabled()
                } label: {
                    if account.isDisabled {
                        Label("providers.enable".localized(), systemImage: "checkmark.circle")
                    } else {
                        Label("providers.disable".localized(), systemImage: "minus.circle")
                    }
                }
            }

            if account.canDelete, onDelete != nil {
                Divider()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("action.delete".localized(), systemImage: "trash")
                }
            }
        }
        .confirmationDialog("providers.deleteConfirm".localized(), isPresented: $showDeleteConfirmation) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete?()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.deleteMessage".localized())
        }
        .alert("menubar.warning.title".localized(), isPresented: $showWarning) {
            Button("menubar.warning.confirm".localized()) {
                settings.toggleItem(account.menuBarItem)
            }
            Button("menubar.warning.cancel".localized(), role: .cancel) {}
        } message: {
            Text("menubar.warning.message".localized())
        }
        .alert("menubar.maxItems.title".localized(), isPresented: $showMaxItemsAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            Text(String(
                format: "menubar.maxItems.message".localized(),
                settings.menuBarMaxItems
            ))
        }
    }

    private func handleMenuBarToggle() {
        if isMenuBarSelected {
            settings.toggleItem(account.menuBarItem)
        } else if settings.isAtMaxItems {
            showMaxItemsAlert = true
        } else if settings.shouldWarnOnAdd {
            showWarning = true
        } else {
            settings.toggleItem(account.menuBarItem)
        }
    }
}

private struct RequiresCPAPLUSPLUSAPISupportRow: View {
    var body: some View {
        Label {
            Text("Requires cpa++ API support.")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Menu Bar Badge Component

struct MenuBarBadge: View {
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
                    .frame(width: 28, height: 28)

                Image(systemName: isSelected ? "chart.bar.fill" : "chart.bar")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
        }
        .buttonStyle(.plain)
        .nativeTooltip(isSelected ? "menubar.hideFromMenuBar".localized() : "menubar.showOnMenuBar".localized())
    }
}

// MARK: - Native Tooltip Support

private class TooltipWindow: NSWindow {
    static let shared = TooltipWindow()

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        return label
    }()

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.ignoresMouseEvents = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .toolTip
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -4)
        ])

        self.contentView = visualEffect
    }

    func show(text: String, near view: NSView) {
        label.stringValue = text
        label.sizeToFit()

        let labelSize = label.fittingSize
        let windowSize = NSSize(width: labelSize.width + 16, height: labelSize.height + 8)

        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        let viewFrameInScreen = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
        var origin = NSPoint(
            x: viewFrameInScreen.midX - windowSize.width / 2,
            y: viewFrameInScreen.minY - windowSize.height - 4
        )

        // Keep tooltip on screen
        if origin.x < screen.visibleFrame.minX {
            origin.x = screen.visibleFrame.minX
        }
        if origin.x + windowSize.width > screen.visibleFrame.maxX {
            origin.x = screen.visibleFrame.maxX - windowSize.width
        }
        if origin.y < screen.visibleFrame.minY {
            origin.y = viewFrameInScreen.maxY + 4
        }

        setFrame(NSRect(origin: origin, size: windowSize), display: true)
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }
}

private class TooltipTrackingView: NSView {
    var text: String = ""

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        TooltipWindow.shared.show(text: text, near: self)
    }

    override func mouseExited(with event: NSEvent) {
        TooltipWindow.shared.hide()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct NativeTooltipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TooltipTrackingView {
        let view = TooltipTrackingView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: TooltipTrackingView, context: Context) {
        nsView.text = text
    }
}

private extension View {
    func nativeTooltip(_ text: String) -> some View {
        self.overlay(NativeTooltipView(text: text))
    }
}

// MARK: - Menu Bar Hint View

struct MenuBarHintView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.blue)
                .font(.caption2)
            Text("menubar.hint".localized())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - OAuth Sheet

struct OAuthSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let provider: AIProvider
    @Binding var projectId: String
    let onDismiss: () -> Void
    
    @State private var hasStartedAuth = false
    
    private var isPolling: Bool {
        viewModel.oauthState?.status == .polling || viewModel.oauthState?.status == .waiting
    }
    
    private var isSuccess: Bool {
        viewModel.oauthState?.status == .success
    }
    
    private var isError: Bool {
        guard let status = viewModel.oauthState?.status else { return false }
        return status == .failed || status == .expired || status == .cancelled
    }
    
    var body: some View {
        VStack(spacing: 28) {
            ProviderIcon(provider: provider, size: 64)
            
            VStack(spacing: 8) {
                Text("oauth.connect".localized() + " " + provider.displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("oauth.authenticateWith".localized() + " " + provider.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            if let state = viewModel.oauthState, state.provider == provider {
                OAuthStatusView(
                    status: state.status,
                    error: state.error,
                    authURL: state.authURL,
                    verificationURI: state.verificationURI,
                    userCode: state.userCode,
                    provider: provider
                )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            
            HStack(spacing: 16) {
                Button("action.cancel".localized(), role: .cancel) {
                    viewModel.cancelOAuth()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                
                if isError {
                    Button {
                        hasStartedAuth = false
                        Task {
                            await viewModel.startOAuth(
                                for: provider,
                                projectId: projectId.isEmpty ? nil : projectId,
                                launchMode: .autoOpen
                            )
                        }
                    } label: {
                        Label("oauth.retry".localized(), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else if !isSuccess {
                    Button {
                        hasStartedAuth = true
                        Task {
                            await viewModel.startOAuth(
                                for: provider,
                                projectId: projectId.isEmpty ? nil : projectId,
                                launchMode: .autoOpen
                            )
                        }
                    } label: {
                        if isPolling {
                            SmallProgressView()
                        } else {
                            Label("oauth.authenticate".localized(), systemImage: "key.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(provider.color)
                    .disabled(isPolling)
                }
            }
        }
        .padding(40)
        .frame(width: 480)
        .frame(minHeight: 350)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: viewModel.oauthState?.status)
        .onChange(of: viewModel.oauthState?.status) { _, newStatus in
            if newStatus == .success {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    onDismiss()
                }
            }
        }
    }
}

private struct OAuthStatusView: View {
    let status: OAuthState.OAuthStatus
    let error: String?
    let authURL: String?
    let verificationURI: String?
    let userCode: String?
    let provider: AIProvider
    
    /// Stable rotation angle for spinner animation (fixes UUID() infinite re-render)
    @State private var rotationAngle: Double = 0
    
    /// Visual feedback for copy action
    @State private var copied = false
    
    var body: some View {
        Group {
            switch status {
            case .waiting:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("oauth.openingBrowser".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                
            case .polling:
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(provider.color.opacity(0.2), lineWidth: 4)
                            .frame(width: 60, height: 60)
                        
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(provider.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 60, height: 60)
                            .rotationEffect(.degrees(rotationAngle - 90))
                            .onAppear {
                                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                    rotationAngle = 360
                                }
                            }
                        
                        Image(systemName: "person.badge.key.fill")
                            .font(.title2)
                            .foregroundStyle(provider.color)
                    }
                    
                    // Device-code providers expose a user code through the canonical session.
                    if let deviceCode = userCode, !deviceCode.isEmpty {
                        VStack(spacing: 8) {
                            Text("oauth.enterCodeInBrowser".localized())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 12) {
                                Text(deviceCode)
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundStyle(provider.color)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(provider.color.opacity(0.1))
                                    .cornerRadius(8)
                                
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(deviceCode, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.title3)
                                }
                                .buttonStyle(.subtle)
                                .help("action.copyCode".localized())
                            }
                            
                            Text("oauth.waitingForAuth".localized())
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let urlString = authURL ?? verificationURI,
                               let url = URL(string: urlString) {
                                OAuthURLFallbackView(
                                    urlString: urlString,
                                    url: url,
                                    provider: provider,
                                    copied: $copied
                                )
                            }
                        }
                    } else {
                        Text("oauth.waitingForAuth".localized())
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        // Show auth URL with copy/open buttons
                        if let urlString = authURL ?? verificationURI, let url = URL(string: urlString) {
                            OAuthURLFallbackView(
                                urlString: urlString,
                                url: url,
                                provider: provider,
                                copied: $copied
                            )
                        } else {
                            Text("oauth.completeBrowser".localized())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 16)
                
            case .success:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    
                    Text("oauth.success".localized())
                        .font(.headline)
                        .foregroundStyle(.green)
                    
                    Text("oauth.closingSheet".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                
            case .failed, .expired, .cancelled:
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    
                    Text(status.failureTitle)
                        .font(.headline)
                        .foregroundStyle(.red)
                    
                    if let error = error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .frame(minHeight: 100)
    }
}

private struct OAuthURLFallbackView: View {
    let urlString: String
    let url: URL
    let provider: AIProvider
    @Binding var copied: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text("oauth.copyLinkOrOpen".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(provider.color)
                    Text(urlString)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(urlString)

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "oauth.copied".localized() : "oauth.copyLink".localized(), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("oauth.openLink".localized(), systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .tint(provider.color)
            }
        }
    }
}

private extension OAuthState.OAuthStatus {
    var failureTitle: String {
        switch self {
        case .expired:
            return "OAuth session expired"
        case .cancelled:
            return "OAuth session cancelled"
        case .failed:
            return "oauth.failed".localized()
        case .waiting, .polling, .success:
            return ""
        }
    }
}
