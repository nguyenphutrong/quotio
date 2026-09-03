//
//  ProvidersScreen.swift
//  Quotio
//
//  Redesigned ProvidersScreen with improved UI/UX:
//  - Consolidated from 5-6 sections to 2 main sections
//  - Accounts grouped by provider using DisclosureGroup
//  - Add Provider moved to toolbar popover
//  - IDE Scan integrated into toolbar and empty state
//

import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI
import UniformTypeIdentifiers

struct ProvidersScreen: View {
    @Environment(ProxyManagementScreenModel.self) private var proxyManagement
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var quotaController
    @Environment(AntigravityAccountScreenModel.self) private var antigravityAccounts
    @Environment(ProvidersScreenModel.self) private var providersModel
    @Environment(WarpTokenScreenModel.self) private var warpTokens
    @Environment(OperatingModeManager.self) private var modeManager
    @State private var isImporterPresented = false
    @State private var selectedProvider: QuotaProvider?
    @State private var showProxyRequiredAlert = false
    @State private var showIDEScanSheet = false
    @State private var customProviderSheetMode: CustomProviderSheetMode?
    @State private var showWarpConnectionSheet = false
    @State private var editingWarpToken: WarpToken?
    @State private var showGLMConnectionSheet = false
    @State private var editingGLMProvider: CustomProvider?
    @State private var monitorAPIKeyProvider: QuotaProvider?
    @State private var editingMonitorAPIKeyAccount: Account?
    @State private var showAddProviderPopover = false
    @State private var switchingAccount: AccountRowData?
    
    // MARK: - Computed Properties
    
    /// Providers that can be added manually
    private var addableProviders: [QuotaProvider] {
        if modeManager.isLocalProxyMode {
            return QuotaProvider.allCases.filter {
                ![.factoryDroid, .openRouter, .amp].contains($0) && ($0.supportsManualAuth || $0 == .clinePass)
            }
        } else {
            return QuotaProvider.allCases.filter {
                $0.supportsQuotaOnlyMode
                    && ($0.supportsManualAuth || $0 == .glm || $0 == .clinePass)
                    && ($0 != .amp || modeManager.isMonitorMode)
            }
        }
    }
    
    /// All accounts grouped by provider
    private var groupedAccounts: [QuotaProvider: [AccountRowData]] {
        var groups: [QuotaProvider: [AccountRowData]] = [:]

        if modeManager.isLocalProxyMode && proxyManagement.proxy.proxyStatus.running {
            // From proxy auth files (proxy running)
            for file in proxyManagement.authFiles {
                guard let provider = file.providerID else { continue }
                let data = AccountRowData.from(authFile: file, provider: provider)
                groups[provider, default: []].append(data)
            }
        } else if modeManager.isMonitorMode {
            for account in accounts.accounts where ![.glm, .warp, .clinePass].contains(account.provider) {
                let state = quotaController.monitorStatus(for: account)
                let data = AccountRowData.from(
                    monitorAccount: account,
                    status: state.status,
                    statusMessage: state.message
                )
                groups[account.provider, default: []].append(data)
            }
        } else {
            // From direct auth files (proxy not running or quota-only mode)
            for file in proxyManagement.directAuthFiles {
                guard let data = AccountRowData.from(directAuthFile: file) else { continue }
                groups[data.provider, default: []].append(data)
            }
        }

        // Add auto-detected accounts (Cursor, Trae)
        // API-key providers are added from their own storage below.
        for (provider, quotas) in quota.providerQuotas where !modeManager.isMonitorMode {
            if !provider.supportsManualAuth && provider != .glm && provider != .clinePass {
                for (accountKey, _) in quotas {
                    let data = AccountRowData.from(provider: provider, accountKey: accountKey)
                    groups[provider, default: []].append(data)
                }
            }
        }

        // Add GLM providers from CustomProviderService
        for glmProvider in providersModel.customProviders.filter({
            $0.type == .glmCompatibility && $0.isEnabled
        }) {
            // Use provider name as display name (store provider ID for editing)
            let data = AccountRowData(
                id: glmProvider.id.uuidString,
                provider: .glm,
                displayName: glmProvider.name.isEmpty ? "GLM" : glmProvider.name,
                menuBarAccountKey: glmProvider.name,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.glm, default: []].append(data)
        }

        // ClinePass API keys are stored as custom providers but shown as first-class accounts.
        for clinePassProvider in providersModel.customProviders.filter({
            $0.type == .clinePass && $0.isEnabled
        }) {
            let data = AccountRowData(
                id: clinePassProvider.id.uuidString,
                provider: .clinePass,
                displayName: clinePassProvider.name,
                menuBarAccountKey: clinePassProvider.name,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.clinePass, default: []].append(data)
        }

        for warpToken in warpTokens.tokens.filter({ $0.isEnabled }) {
            let data = AccountRowData(
                id: warpToken.id.uuidString,
                provider: .warp,
                displayName: warpToken.name.isEmpty ? "Warp" : warpToken.name,
                menuBarAccountKey: warpToken.name,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.warp, default: []].append(data)
        }

        return groups
    }
    
    /// Sorted providers for consistent display order
    private var sortedProviders: [QuotaProvider] {
        groupedAccounts.keys.sorted { $0.displayName < $1.displayName }
    }
    
    /// Total account count across all providers
    private var totalAccountCount: Int {
        groupedAccounts.values.reduce(0) { $0 + $1.count }
    }

    /// Account count per provider (for AddProviderPopover badge display)
    private var providerAccountCounts: [QuotaProvider: Int] {
        groupedAccounts.mapValues { $0.count }
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
        .navigationTitle(modeManager.isMonitorMode ? "nav.accounts".localized() : "nav.providers".localized())
        .toolbar {
            toolbarContent
        }
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider) {
                selectedProvider = nil
                quotaController.cancelOAuth()
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await proxyManagement.importVertexServiceAccount(url: url) }
            }
            // Failure case is silently ignored - user can retry via UI
        }
        .task {
            providersModel.reloadCustomProviders()
            await warpTokens.load()
            await proxyManagement.loadDirectAuthFiles()
        }
        .alert("providers.proxyRequired.title".localized(), isPresented: $showProxyRequiredAlert) {
            Button("action.startProxy".localized()) {
                Task { await proxyManagement.startProxy() }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.proxyRequired.message".localized())
        }
        .sheet(isPresented: $showIDEScanSheet) {
            IDEScanSheet {}
        }
        .sheet(item: $customProviderSheetMode) { mode in
            CustomProviderSheet(
                provider: mode.provider,
                initialProviderType: mode.initialProviderType
            ) { provider in
                saveCustomProvider(provider)
                if provider.type == .clinePass {
                    Task { await quotaController.refresh(provider: .clinePass) }
                }
            }
        }
        .sheet(isPresented: $showWarpConnectionSheet) {
            WarpConnectionSheet(token: editingWarpToken) { name, token in
                if let existing = editingWarpToken {
                    var updated = existing
                    updated.name = name
                    updated.token = token
                    await warpTokens.update(updated)
                } else {
                    await warpTokens.add(name: name, token: token)
                }
                editingWarpToken = nil
                await quotaController.refresh(provider: .warp)
            }
        }
        .sheet(isPresented: $showGLMConnectionSheet) {
            GLMAPIKeySheet(provider: editingGLMProvider) { provider in
                saveCustomProvider(provider)
                editingGLMProvider = nil
                Task { await quotaController.refresh(provider: .glm) }
            }
        }
        .sheet(item: $monitorAPIKeyProvider) { provider in
            MonitorAPIKeyConnectionSheet(provider: provider, account: editingMonitorAPIKeyAccount) { label, apiKey in
                try await quotaController.saveAPIKey(
                    provider: provider,
                    label: label,
                    apiKey: apiKey,
                    existingAccountID: editingMonitorAPIKeyAccount?.id
                )
                editingMonitorAPIKeyAccount = nil
            }
        }
        .sheet(isPresented: $showAddProviderPopover) {
            AddProviderPopover(
                providers: addableProviders,
                existingCounts: providerAccountCounts,
                onSelectProvider: { provider in
                    handleAddProvider(provider)
                },
                onScanIDEs: {
                    showIDEScanSheet = true
                },
                onAddCustomProvider: {
                    customProviderSheetMode = .add(.openaiCompatibility)
                },
                onDismiss: {
                    showAddProviderPopover = false
                }
            )
        }
        .sheet(item: $switchingAccount) { account in
            SwitchAccountSheet(
                accountEmail: account.displayName,
                onDismiss: {
                    switchingAccount = nil
                }
            )
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddProviderPopover = true
            } label: {
                Image(systemName: "plus")
            }
            .help("providers.addAccount".localized())
        }
        
        ToolbarItem(placement: .automatic) {
            Button {
                Task {
                    if modeManager.isMonitorMode {
                        await quotaController.refreshAll(force: true)
                    } else if modeManager.isLocalProxyMode && proxyManagement.proxy.proxyStatus.running {
                        await proxyManagement.refreshData()
                    } else {
                        await proxyManagement.loadDirectAuthFiles()
                    }
                    if !modeManager.isMonitorMode {
                        await quotaController.refreshAutoDetectedProviders()
                    }
                }
            } label: {
                if quota.isLoadingQuotas {
                    SmallProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(quota.isLoadingQuotas)
            .help("action.refresh".localized())
        }

        ToolbarItem(placement: .automatic) {
            Button {
                uploadAuthFile()
            } label: {
                Image(systemName: "arrow.up.circle")
            }
            .help("action.upload".localized())
        }
    }
    
    // MARK: - Accounts Section
    
    @ViewBuilder
    private var accountsSection: some View {
        Section {
            if groupedAccounts.isEmpty {
                // Empty state
                AccountsEmptyState(
                    onScanIDEs: {
                        showIDEScanSheet = true
                    },
                    onAddProvider: {
                        showAddProviderPopover = true
                    }
                )
            } else {
                // Grouped accounts by provider
                ForEach(sortedProviders, id: \.self) { provider in
                    ProviderDisclosureGroup(
                        provider: provider,
                        accounts: groupedAccounts[provider] ?? [],
                        onDeleteAccount: { account in
                            Task { await deleteAccount(account) }
                        },
                        onEditAccount: { account in
                            if provider == .glm {
                                handleEditGlmAccount(account)
                            } else if provider == .clinePass {
                                handleEditClinePassAccount(account)
                            } else if provider == .warp {
                                handleEditWarpAccount(account)
                            } else if [.factoryDroid, .openRouter, .amp].contains(provider) {
                                handleEditMonitorAPIKeyAccount(account)
                            }
                        },
                        onSwitchAccount: provider == .antigravity ? { account in
                            switchingAccount = account
                        } : nil,
                        onToggleDisabled: { account in
                            Task { await toggleAccountDisabled(account) }
                        },
                        onDownloadAccount: { account in
                            Task { await downloadAccountAuthFile(account) }
                        },
                        isAccountActive: provider == .antigravity ? { account in
                            antigravityAccounts.isActive(email: account.displayName)
                        } : nil
                    )
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
            if !groupedAccounts.isEmpty {
                MenuBarHintView()
            }
        }
    }
    
    // MARK: - Custom Providers Section

    @ViewBuilder
    private var customProvidersSection: some View {
        // API-key providers with first-class quota tracking are shown in Your Accounts.
        let genericProviders = providersModel.customProviders.filter {
            $0.type != .glmCompatibility && $0.type != .clinePass
        }

        Section {
            // List existing custom providers
            ForEach(genericProviders) { provider in
                CustomProviderRow(
                    provider: provider,
                    onEdit: {
                        customProviderSheetMode = .edit(provider)
                    },
                    onDelete: {
                        deleteCustomProvider(id: provider.id)
                    },
                    onToggle: {
                        var updated = provider
                        updated.isEnabled.toggle()
                        saveCustomProvider(updated)
                    }
                )
            }
        } header: {
            HStack {
                Label("customProviders.title".localized(), systemImage: "puzzlepiece.extension.fill")

                if !genericProviders.isEmpty {
                    Spacer()
                    Text("\(genericProviders.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("customProviders.footer".localized())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
    
    // MARK: - Helper Functions

    private func handleAddProvider(_ provider: QuotaProvider) {
        if provider == .clinePass {
            customProviderSheetMode = .add(.clinePass)
            return
        }
        if provider == .glm {
            editingGLMProvider = nil
            showGLMConnectionSheet = true
            return
        }
        if [.factoryDroid, .openRouter, .amp].contains(provider) {
            editingMonitorAPIKeyAccount = nil
            monitorAPIKeyProvider = provider
            return
        }

        // In Local Proxy Mode, require proxy to be running for OAuth
        if modeManager.isLocalProxyMode && !proxyManagement.proxy.proxyStatus.running {
            showProxyRequiredAlert = true
            return
        }

        if provider == .vertex {
            isImporterPresented = true
        } else if provider == .warp {
            editingWarpToken = nil
            showWarpConnectionSheet = true
        } else {
            quotaController.cancelOAuth()
            selectedProvider = provider
        }
    }
    
    private func deleteAccount(_ account: AccountRowData) async {
        // Only proxy accounts can be deleted via API
        guard account.canDelete else { return }

        if modeManager.isMonitorMode, case .monitor = account.source {
            await quotaController.remove(account: QuotaAccountID(
                provider: account.provider,
                accountKey: account.menuBarAccountKey
            ))
            return
        }

        // Handle auto-detected IDE accounts (Cursor, Trae) imported via "Scan for IDEs"
        if account.source == .autoDetected {
            await quotaController.remove(account: QuotaAccountID(
                provider: account.provider,
                accountKey: account.menuBarAccountKey
            ))
            return
        }

        // Handle GLM accounts (stored in CustomProviderService)
        if account.provider == .glm {
            // GLM accounts are stored as custom providers
            // Find the GLM provider by ID and delete it
            if let glmProvider = providersModel.customProviders.first(where: {
                $0.id.uuidString == account.id
            }) {
                deleteCustomProvider(id: glmProvider.id)
            }
            return
        }

        if account.provider == .clinePass {
            if let provider = providersModel.customProviders.first(where: {
                $0.id.uuidString == account.id
            }) {
                deleteCustomProvider(id: provider.id)
                await quotaController.refresh(provider: .clinePass)
            }
            return
        }
        
        if account.provider == .warp {
            if let uuid = UUID(uuidString: account.id) {
                await warpTokens.delete(id: uuid)
                await quotaController.refresh(provider: .warp)
            }
            return
        }

        // Find the original AuthFile to delete
        if let authFile = proxyManagement.authFiles.first(where: { $0.id == account.id }) {
            await proxyManagement.deleteAuthFile(authFile)
        }
    }

    private func toggleAccountDisabled(_ account: AccountRowData) async {
        if modeManager.isMonitorMode, case .monitor = account.source {
            await quotaController.setAccountDisabled(!account.isDisabled, accountID: account.id)
            return
        }

        guard account.source == .proxy else { return }

        // Find the original AuthFile to toggle
        if let authFile = proxyManagement.authFiles.first(where: { $0.id == account.id }) {
            await proxyManagement.toggleAuthFileDisabled(authFile)
        }
    }

    private func downloadAccountAuthFile(_ account: AccountRowData) async {
        guard let filename = account.authFileName else { return }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = filename.hasSuffix(".json") ? filename : filename + ".json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            try await proxyManagement.exportAuthFile(name: filename, to: url)
        } catch {
            proxyManagement.errorMessage = proxyManagementErrorMessage(error)
        }
    }

    private func handleEditGlmAccount(_ account: AccountRowData) {
        if let glmProvider = providersModel.customProviders.first(where: {
            $0.id.uuidString == account.id
        }) {
            editingGLMProvider = glmProvider
            showGLMConnectionSheet = true
        }
    }

    private func handleEditClinePassAccount(_ account: AccountRowData) {
        if let provider = providersModel.customProviders.first(where: {
            $0.id.uuidString == account.id
        }) {
            customProviderSheetMode = .edit(provider)
        }
    }

    private func uploadAuthFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.json]
        openPanel.canChooseDirectories = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            Task {
                do {
                    try await proxyManagement.importAuthFile(from: url)
                } catch {
                    proxyManagement.errorMessage = proxyManagementErrorMessage(error)
                }
            }
        }
    }

    private func handleEditWarpAccount(_ account: AccountRowData) {
        if let token = warpTokens.tokens.first(where: { $0.id.uuidString == account.id }) {
            editingWarpToken = token
            showWarpConnectionSheet = true
        }
    }

    private func handleEditMonitorAPIKeyAccount(_ account: AccountRowData) {
        guard let monitorAccount = accounts.accounts.first(where: { $0.id == account.id }) else { return }
        editingMonitorAPIKeyAccount = monitorAccount
        monitorAPIKeyProvider = monitorAccount.provider
    }

    private func saveCustomProvider(_ provider: CustomProvider) {
        do {
            try providersModel.save(provider)
            syncCustomProvidersToConfig()
        } catch {
            proxyManagement.errorMessage = customProviderErrorMessage(error)
        }
    }

    private func deleteCustomProvider(id: UUID) {
        do {
            try providersModel.deleteCustomProvider(id: id)
            syncCustomProvidersToConfig()
        } catch {
            proxyManagement.errorMessage = customProviderErrorMessage(error)
        }
    }

    private func syncCustomProvidersToConfig() {
        // Silent failure - custom provider sync is non-critical
        // Config will be synced on next proxy start
        try? providersModel.synchronizeCustomProviders(
            at: proxyManagement.proxy.configPath
        )
    }
}

// MARK: - Custom Provider Row

struct CustomProviderRow: View {
    let provider: CustomProvider
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void
    
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Provider type icon
            ZStack {
                Circle()
                    .fill(provider.type.color.opacity(0.1))
                    .frame(width: 32, height: 32)
                
                Image(provider.type.providerIconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }
            
            // Provider info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .fontWeight(.medium)
                    
                    if !provider.isEnabled {
                        Text("customProviders.disabled".localized())
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
                
                HStack(spacing: 6) {
                    Text(provider.type.localizedDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    let keyCount = provider.apiKeys.count
                    Text("\(keyCount) \(keyCount == 1 ? "customProviders.key".localized() : "customProviders.keys".localized())")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Toggle button
            Button {
                onToggle()
            } label: {
                Image(systemName: provider.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(provider.isEnabled ? .green : .secondary)
            }
            .buttonStyle(.subtle)
            .help(provider.isEnabled ? "customProviders.disable".localized() : "customProviders.enable".localized())
        }
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("action.edit".localized(), systemImage: "pencil")
            }
            
            Button {
                onToggle()
            } label: {
                Label(provider.isEnabled ? "customProviders.disable".localized() : "customProviders.enable".localized(), systemImage: provider.isEnabled ? "xmark.circle" : "checkmark.circle")
            }
            
            Divider()
            
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("action.delete".localized(), systemImage: "trash")
            }
        }
        .confirmationDialog("customProviders.deleteConfirm".localized(), isPresented: $showDeleteConfirmation) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("customProviders.deleteMessage".localized())
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
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        return label
    }()

    init() {
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
    weak var tooltipWindow: TooltipWindow?

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
        tooltipWindow?.show(text: text, near: self)
    }

    override func mouseExited(with event: NSEvent) {
        tooltipWindow?.hide()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct NativeTooltipView: NSViewRepresentable {
    let text: String

    @MainActor
    final class Coordinator {
        let tooltipWindow = TooltipWindow()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TooltipTrackingView {
        let view = TooltipTrackingView()
        view.text = text
        view.tooltipWindow = context.coordinator.tooltipWindow
        return view
    }

    func updateNSView(_ nsView: TooltipTrackingView, context: Context) {
        nsView.text = text
        nsView.tooltipWindow = context.coordinator.tooltipWindow
    }

    static func dismantleNSView(_ nsView: TooltipTrackingView, coordinator: Coordinator) {
        coordinator.tooltipWindow.hide()
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
    @Environment(ProxyManagementScreenModel.self) private var proxyManagement
    @Environment(QuotaFeatureController.self) private var viewModel
    @Environment(OperatingModeManager.self) private var modeManager
    let provider: QuotaProvider
    let onDismiss: () -> Void
    
    @State private var hasStartedAuth = false
    @State private var selectedKiroMethod: OAuthAuthorizationMethod = .kiroImport
    @State private var manualOAuthCode = ""
    
    private var isPolling: Bool {
        viewModel.oauthState?.status == .polling || viewModel.oauthState?.status == .waiting
    }
    
    private var isSuccess: Bool {
        viewModel.oauthState?.status == .success
    }
    
    private var isError: Bool {
        viewModel.oauthState?.status == .error
    }
    
    private var kiroAuthMethods: [OAuthAuthorizationMethod] {
        if modeManager.isMonitorMode { return [.kiroAWSDeviceCode] }
        return [.kiroImport, .kiroGoogle, .kiroAWSBrowser, .kiroAWSDeviceCode]
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
            
            if provider == .kiro {
                VStack(alignment: .leading, spacing: 6) {
                    Text("oauth.authMethod".localized())
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker("", selection: $selectedKiroMethod) {
                        ForEach(kiroAuthMethods, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    

                }
                .frame(maxWidth: 320)
            }

            if !modeManager.isMonitorMode,
               proxyManagement.isLegacyAuthWarningNeeded(for: provider) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(proxyManagement.upstreamCompatibilityWarning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 320, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
            if let state = viewModel.oauthState, state.provider == provider {
                OAuthStatusView(status: state.status, error: state.error, state: state.state, authURL: state.authURL, provider: provider)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            if modeManager.isMonitorMode, provider == .claude, viewModel.oauthState?.status == .polling {
                HStack(spacing: 8) {
                    TextField("oauth.authorizationCode".localized(), text: $manualOAuthCode)
                        .textFieldStyle(.roundedBorder)
                    Button("oauth.complete".localized()) {
                        Task { await viewModel.completeMonitorOAuthCode(manualOAuthCode, provider: provider) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualOAuthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: 360)
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
                                method: provider == .kiro ? selectedKiroMethod : .providerDefault
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
                                method: provider == .kiro ? selectedKiroMethod : .providerDefault
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

private extension OAuthAuthorizationMethod {
    var displayName: String {
        switch self {
        case .providerDefault: "Default"
        case .kiroGoogle: "Google OAuth"
        case .kiroAWSDeviceCode: "AWS Builder ID (Device Code)"
        case .kiroAWSBrowser: "AWS Builder ID (Browser)"
        case .kiroImport: "Import from Kiro IDE"
        }
    }
}

private struct OAuthStatusView: View {
    let status: QuotaOAuthState.OAuthStatus
    let error: String?
    let state: String?
    let authURL: String?
    let provider: QuotaProvider
    @Environment(PasteboardScreenModel.self) private var pasteboard
    @Environment(PlatformActionScreenModel.self) private var platformActions
    
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
                    
                    // For Copilot Device Code flow, show device code with copy button
                    if (provider == .copilot || provider == .kiro), let deviceCode = state, !deviceCode.isEmpty {
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
                                    pasteboard.copy(deviceCode)
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
                        }
                    } else if (provider == .copilot || provider == .kiro), let message = error {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 350)
                    } else {
                        Text("oauth.waitingForAuth".localized())
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        // Show auth URL with copy/open buttons
                        if let urlString = authURL, let url = URL(string: urlString) {
                            VStack(spacing: 12) {
                                Text("oauth.copyLinkOrOpen".localized())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                HStack(spacing: 12) {
                                    Button {
                                        pasteboard.copy(urlString)
                                        copied = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            copied = false
                                        }
                                    } label: {
                                        Label(copied ? "oauth.copied".localized() : "oauth.copyLink".localized(), systemImage: copied ? "checkmark" : "doc.on.doc")
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button {
                                        platformActions.open(url)
                                    } label: {
                                        Label("oauth.openLink".localized(), systemImage: "safari")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(provider.color)
                                }
                            }
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
                
            case .error:
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    
                    Text("oauth.failed".localized())
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

// MARK: - Custom Provider Sheet Mode

enum CustomProviderSheetMode: Identifiable {
    case add(CustomProviderType)
    case edit(CustomProvider)

    var id: String {
        switch self {
        case .add(let type):
            return "add-\(type.rawValue)"
        case .edit(let provider):
            return provider.id.uuidString
        }
    }

    var provider: CustomProvider? {
        switch self {
        case .add:
            return nil
        case .edit(let provider):
            return provider
        }
    }

    var initialProviderType: CustomProviderType {
        switch self {
        case .add(let type):
            return type
        case .edit(let provider):
            return provider.type
        }
    }
}
