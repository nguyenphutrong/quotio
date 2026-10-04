import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI
import UniformTypeIdentifiers

struct ProvidersScreen: View {
    let provider: QuotaProvider?
    @Environment(NavigationScreenModel.self) private var navigation

    init(provider: QuotaProvider? = nil) { self.provider = provider }

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
    @State private var showNativePermissionError = false

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
                    && ![.antigravity, .kiro, .vertex].contains($0)
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
            for account in accounts.accounts {
                let state = quotaController.monitorStatus(for: account)
                let data = AccountRowData.from(
                    monitorAccount: account,
                    status: state.status,
                    statusMessage: state.status == "failed" || state.status == "partial" ? nil : state.message
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

        // Local-proxy credentials stay owned by CLIProxyAPI/custom-provider storage.
        for glmProvider in providersModel.customProviders.filter({
            !modeManager.isMonitorMode && $0.type == .glmCompatibility && $0.isEnabled
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
            !modeManager.isMonitorMode && $0.type == .clinePass && $0.isEnabled
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

        for warpToken in warpTokens.tokens.filter({ !modeManager.isMonitorMode && $0.isEnabled }) {
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
    
    /// Account count per provider (for AddProviderPopover badge display)
    private var providerAccountCounts: [QuotaProvider: Int] {
        groupedAccounts.mapValues { $0.count }
    }
    
    // MARK: - Body
    
    var body: some View {
        List {
            if let provider {
                providerHeader(provider)
                if modeManager.isMonitorMode, !permissions(for: provider).isEmpty {
                    nativePermissionsSection
                }
                if let issue = latestIssue(for: provider) {
                    Section {
                        Label(issue.explanation, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    } header: {
                        Text("connections.quotaStatus".localized())
                    } footer: {
                        Text("connections.quotaFailureHint".localized())
                    }
                }
                Section("connections.sources".localized()) {
                    ForEach(groupedAccounts[provider] ?? []) { account in
                        connectionRow(account)
                    }
                    if groupedAccounts[provider, default: []].isEmpty {
                        Text("connections.noAccount".localized())
                            .foregroundStyle(.secondary)
                    }
                    if modeManager.isMonitorMode, provider.hasDiscoverableNativeLogin {
                        Button {
                            Task {
                                await accounts.rescanNativeAccounts(for: provider)
                                await quotaController.refresh(provider: provider)
                            }
                        } label: {
                            if accounts.discoveringProvider == provider {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("connections.rescan".localized(), systemImage: "magnifyingglass")
                            }
                        }
                        .disabled(accounts.discoveringProvider != nil)
                    }
                    if addableProviders.contains(provider) {
                        Button("providers.addAccount".localized()) { handleAddProvider(provider) }
                    } else if groupedAccounts[provider, default: []].isEmpty {
                        Text("connections.signInOwner".localized())
                            .foregroundStyle(.secondary)
                    }
                }
                if !(quota.providerQuotas[provider] ?? [:]).isEmpty {
                    Section {
                        DisclosureGroup("nav.quota".localized()) {
                            ProviderQuotaView(
                                provider: provider,
                                authFiles: proxyManagement.authFiles.filter { $0.providerID == provider },
                                quotaData: quota.providerQuotas[provider] ?? [:],
                                subscriptionInfos: quota.subscriptionInfos[provider] ?? [:],
                                aliases: quota.state.accountAliases[provider] ?? [:],
                                isLoading: quota.isRefreshing(provider: provider)
                            )
                        }
                    }
                }
            } else {
                providerDirectory
                if modeManager.isLocalProxyMode { customProvidersSection }
            }
        }
        .listStyle(.inset)
        .navigationTitle(provider?.displayName ?? "connections.all".localized())
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
            if modeManager.isLocalProxyMode { await warpTokens.load() }
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
        .alert("providers.nativePermission.failedTitle".localized(), isPresented: $showNativePermissionError) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            Text((accounts.nativeAuthorizationFailure ?? .unknown).message)
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
            MonitorAPIKeyConnectionSheet(provider: provider, account: editingMonitorAPIKeyAccount) { label, apiKey, fields in
                try await quotaController.saveAPIKey(
                    provider: provider,
                    label: label,
                    apiKey: apiKey,
                    existingAccountID: editingMonitorAPIKeyAccount?.id,
                    fields: fields
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
            Menu {
                if let provider, addableProviders.contains(provider) {
                    Button("providers.addAccount".localized()) { handleAddProvider(provider) }
                } else {
                    Button("providers.addAccount".localized()) { showAddProviderPopover = true }
                }
                Button("action.upload".localized()) { uploadAuthFile() }
                Button("connections.scan".localized()) { showIDEScanSheet = true }
                if modeManager.isLocalProxyMode {
                    Button("customProviders.title".localized()) {
                        customProviderSheetMode = .add(.openaiCompatibility)
                    }
                }
            } label: {
                Label("connections.add".localized(), systemImage: "plus")
            }
        }

        ToolbarItem(placement: .automatic) {
            RefreshButton(title: "action.refresh".localized(), isRefreshing: quota.isLoadingQuotas) {
                if let provider {
                    await quotaController.refresh(provider: provider)
                } else if modeManager.isMonitorMode {
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
            .labelStyle(.iconOnly)
            .help("action.refresh".localized())
        }


    }
    
    // MARK: - Accounts Section

    private var nativePermissionsSection: some View {
        Section {
            ForEach(accounts.nativeSourcePermissions.filter { provider == nil || $0.provider == provider }) { permission in
                HStack(spacing: 12) {
                    ProviderIcon(provider: permission.provider, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.provider.displayName)
                            .font(.body.weight(.medium))
                        Text(permission.explanationLocalizationKey.localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("action.connect".localized()) {
                        Task {
                            do {
                                try await accounts.authorizeNativeSource(permission)
                                await quotaController.refresh(provider: permission.provider)
                            } catch {
                                showNativePermissionError = true
                            }
                        }
                    }
                    .disabled(accounts.authorizingNativeSourceID != nil)
                }
            }
        } header: {
            Label("providers.nativePermission.title".localized(), systemImage: "key.fill")
        }
    }

    private func permissions(for provider: QuotaProvider) -> [NativeSourcePermission] {
        modeManager.isMonitorMode ? accounts.nativeSourcePermissions.filter { $0.provider == provider } : []
    }

    private func latestIssue(for provider: QuotaProvider) -> QuotaRefreshIssue? {
        let rows = groupedAccounts[provider, default: []].filter { !$0.isDisabled }
        guard !rows.isEmpty else { return nil }
        let issues = rows.compactMap { row -> QuotaRefreshIssue? in
            let id = QuotaAccountID(provider: provider, accountKey: row.menuBarAccountKey)
            guard let issue = quota.state.accountIssues[id] else { return nil }
            let updated = quota.providerQuotas[provider]?[row.menuBarAccountKey]?.lastUpdated
            return updated == nil || updated! <= issue.occurredAt ? issue : nil
        }
        return issues.max { $0.occurredAt < $1.occurredAt }
    }

    private func connectionState(for provider: QuotaProvider) -> ProviderConnectionState {
        let rows = groupedAccounts[provider, default: []]
        return .resolve(
            hasAccounts: !rows.isEmpty,
            hasEnabledAccounts: rows.contains { !$0.isDisabled },
            needsPermission: !permissions(for: provider).isEmpty,
            hasIssue: latestIssue(for: provider) != nil
        )
    }

    private var directoryProviders: [QuotaProvider] {
        QuotaProvider.allCases.filter { !modeManager.isMonitorMode || $0.supportsQuotaOnlyMode }
            .sorted { $0.displayName < $1.displayName }
    }

    private var providerDirectory: some View {
        Group {
            directorySection("connections.configured", states: [.configured])
            directorySection("connections.attention", states: [.permissionRequired, .attention])
            directorySection("connections.available", states: [.available])
            directorySection("connections.disabled", states: [.disabled])
        }
    }

    @ViewBuilder
    private func directorySection(_ title: String, states: [ProviderConnectionState]) -> some View {
        let providers = directoryProviders.filter { states.contains(connectionState(for: $0)) }
        if !providers.isEmpty {
            Section(title.localized()) {
                ForEach(providers) { provider in
                    Button { navigation.selectProvider(provider) } label: {
                        HStack(spacing: 12) {
                            ProviderIcon(provider: provider, size: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.displayName).fontWeight(.medium)
                                if let row = groupedAccounts[provider]?.first {
                                    Text(row.sourceLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            let state = connectionState(for: provider)
                            Label(state.localizationKey.localized(), systemImage: state.symbol)
                                .font(.caption).foregroundStyle(state.color)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func providerHeader(_ provider: QuotaProvider) -> some View {
        Section {
            HStack(spacing: 12) {
                ProviderIcon(provider: provider, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName).font(.title2.weight(.semibold))
                    Text("connections.providerHint".localized())
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                let state = connectionState(for: provider)
                Label(state.localizationKey.localized(), systemImage: state.symbol)
                    .foregroundStyle(state.color)
            }
            .padding(.vertical, 12)
        }
    }

    private func connectionRow(_ account: AccountRowData) -> some View {
        AccountRow(
            account: account,
            onDelete: { Task { await deleteAccount(account) } },
            onEdit: {
                if modeManager.isMonitorMode {
                    handleEditMonitorAPIKeyAccount(account)
                } else if account.provider == .glm {
                    handleEditGlmAccount(account)
                } else if account.provider == .clinePass {
                    handleEditClinePassAccount(account)
                } else if account.provider == .warp {
                    handleEditWarpAccount(account)
                } else {
                    handleEditMonitorAPIKeyAccount(account)
                }
            },
            onSwitch: account.provider == .antigravity && account.displayName.contains("@")
                ? { switchingAccount = account } : nil,
            onToggleDisabled: { Task { await toggleAccountDisabled(account) } },
            onDownload: account.canDownloadAuthFile ? { Task { await downloadAccountAuthFile(account) } } : nil,
            isActiveInIDE: account.provider == .antigravity && antigravityAccounts.isActive(email: account.displayName)
        )
        .padding(.vertical, 6)
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
        if modeManager.isMonitorMode, provider.usesAPIKeyAuth {
            editingMonitorAPIKeyAccount = nil
            monitorAPIKeyProvider = provider
            return
        }
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

extension NativeSourcePermission {
    var explanationLocalizationKey: String {
        switch (kind, location) {
        case ("antigravity_native", "gemini_keychain"):
            "providers.nativePermission.antigravity"
        case ("factory_native", _):
            "providers.nativePermission.factory"
        case ("claude_native", "code_keychain"):
            "providers.nativePermission.claude"
        default:
            "providers.nativePermission.message"
        }
    }
}

// MARK: - Custom Provider Row

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
