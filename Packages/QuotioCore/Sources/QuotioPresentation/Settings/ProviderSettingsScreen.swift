import QuotioApplication
import QuotioDomain
import SwiftUI

struct ProviderSettingsScreen: View {
    let provider: QuotaProvider
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(MenuBarSettingsManager.self) private var menuBar
    @State private var oauthPresented = false
    @State private var apiKeyPresented = false
    @State private var editingAccount: Account?
    @State private var removingAccount: Account?
    @State private var renamingAccount: Account?
    @State private var newName = ""
    @State private var removingSource: AccountLoginSource?
    @State private var permission: NativeSourcePermission?
    @State private var actionFailed = false
    @State private var pendingPin: MenuBarQuotaItem?

    private var descriptor: MonitoringProvider? { controller.providers.first { $0.id == provider } }
    private var supportsOAuth: Bool { descriptor?.actions.contains("start_oauth") == true }
    private var providerName: String { descriptor?.displayName ?? provider.displayName }
    private var tracked: Bool { controller.trackingPreferences.isEnabled(provider) }
    private var pinnedItems: [MenuBarQuotaItem] {
        menuBar.selectedItems.filter { $0.hostID == quota.state.hostID }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let state = ProviderSettingsState(provider: provider, accounts: accounts.accounts,
                permissions: accounts.nativeSourcePermissions, quota: quota.state,
                tracking: controller.trackingPreferences)
            Form {
                AccountStorageAccessSection()
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        ProviderIcon(provider: provider, size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(providerName).font(.title2.weight(.semibold))
                            Label(state.connection.title, systemImage: state.connection.symbol)
                                .foregroundStyle(state.connection.color)
                            Text(String(format: "settings.accountsCount".localized(), state.accounts.count))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("settings.track".localized(), isOn: Binding(get: { tracked }, set: { enabled in
                            Task { await controller.setProviderEnabled(enabled, provider: provider) }
                        }))
                        .disabled(!controller.canManageSettings || controller.monitoringSettings == nil || controller.isUpdatingSettings)
                        .toggleStyle(.switch)
                        .fixedSize()
                    }
                }
                if let error = controller.settingsError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if !tracked {
                    Section {
                        Label("settings.trackingPaused".localized(), systemImage: "pause.circle")
                    }
                } else {
                    ForEach(state.permissions) { source in
                        Section {
                            Text(source.explanationLocalizationKey.localized())
                            Button("settings.authorize".localized()) { permission = source }
                                .disabled(descriptor?.actions.contains("authorize_native") != true)
                        }
                    }
                    if let issue = state.latestIssue, issue.reason != nil {
                        Section {
                            Label(issue.explanation, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            if let account = (state.accounts + state.accountsNeedingIdentification).first(where: { $0.id == state.latestIssueAccountID }) {
                                Text(account.displayName.masked(if: menuBar.hideSensitiveInfo)).font(.caption)
                            }
                            recoveryAction(issue, accounts: (state.accounts + state.accountsNeedingIdentification).filter { $0.id == state.latestIssueAccountID }, sourceID: state.latestIssueSourceID)
                        }
                    }
                }
                Section {
                    if state.accounts.isEmpty {
                        Text("connections.noAccount".localized()).foregroundStyle(.secondary)
                    }
                    ForEach(state.accounts) { account in
                        DisclosureGroup {
                            ForEach(account.sources) { source in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(source.title)
                                        Text(source.locationLabel).font(.caption).foregroundStyle(.secondary)
                                        if quota.state.accountIDs[provider]?[account.accountKey] == source.accountID {
                                            Text("settings.sources.active".localized()).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if source.status == .disabled {
                                        Text(ConnectionState.disabled.title).font(.caption)
                                    } else if let issue = state.sourceIssues[source.accountID] {
                                        Text(issue.explanation).font(.caption).foregroundStyle(.orange)
                                    } else if source.status == .ready {
                                        Text(ConnectionState.connected.title).font(.caption)
                                    } else {
                                        Text("settings.sources.unchecked".localized()).font(.caption).foregroundStyle(.secondary)
                                    }
                                    sourceMenu(source)
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(account.displayName.masked(if: menuBar.hideSensitiveInfo))
                                    if let monitoring = state.accountStates[account.id] {
                                        Text(monitoring.connection.title + " · " + monitoring.quota.title)
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let updated = quota.providerQuotas[provider]?[account.accountKey]?.lastUpdated {
                                            Text(updated, style: .relative).font(.caption).foregroundStyle(.secondary)
                                        }
                                        if case .failed(nil) = monitoring.quota {
                                            Text("connections.failure.unknown".localized()).font(.caption)
                                            Text("settings.reasonMissing".localized()).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                pinButton(account)
                                accountMenu(account)
                            }
                        }
                    }
                } header: {
                    Text(String(format: "settings.accountsCount".localized(), state.accounts.count))
                } footer: {
                    Text(String(format: "settings.menuBarPinnedCount".localized(), pinnedItems.count, menuBar.menuBarMaxItems))
                }
                if !state.accountsNeedingIdentification.isEmpty {
                    Section {
                        ForEach(state.accountsNeedingIdentification) { account in
                            ForEach(account.sources) { source in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(source.title)
                                        Text(source.locationLabel).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    sourceMenu(source)
                                }
                            }
                        }
                        Button("action.retry".localized()) {
                            Task { await controller.refresh(provider: provider) }
                        }
                    } header: {
                        Text("settings.sources.needsSignIn".localized())
                    } footer: {
                        Text("settings.sources.unidentifiedHelp".localized())
                    }
                }
                Section("settings.connectMore".localized()) {
                    if supportsOAuth {
                        LabeledContent("settings.browserLogin".localized()) {
                            Button("action.login".localized()) { oauthPresented = true }
                        }
                    }
                    if descriptor?.actions.contains("add_api_key") == true {
                        LabeledContent("settings.apiKey".localized()) {
                            Button("settings.addAPIKey".localized()) {
                                editingAccount = nil
                                apiKeyPresented = true
                            }
                        }
                    }
                    if descriptor?.actions.contains("discover_native") == true {
                        if accounts.failedDiscoveryProviders.contains(provider) {
                            Text("settings.discoveryFailed".localized()).font(.caption).foregroundStyle(.orange)
                        }
                        LabeledContent("settings.existingLogin".localized()) {
                            Button("settings.rescan".localized()) {
                                Task {
                                    await accounts.rescanNativeAccounts(for: provider)
                                    await controller.refresh(provider: provider)
                                }
                            }
                            .disabled(accounts.discoveringProvider != nil)
                        }
                        if let scanned = accounts.lastScannedAt[provider] {
                            Text(String(format: "settings.scanResult".localized(),
                                state.accounts.count + state.accountsNeedingIdentification.count + state.permissions.count,
                                scanned.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!tracked)
            }
            .formStyle(.grouped)
        }
        .navigationTitle(providerName)
        .sheet(isPresented: $oauthPresented) {
            OAuthSheet(provider: provider) { oauthPresented = false }
        }
        .sheet(isPresented: $apiKeyPresented) {
            MonitorAPIKeyConnectionSheet(provider: provider, account: editingAccount, inputs: descriptor?.inputs ?? [], providerName: providerName) { label, key, fields in
                try await controller.saveAPIKey(provider: provider, label: label, apiKey: key, existingAccountID: editingAccount?.id, fields: fields)
            }
        }
        .sheet(item: $permission) { source in NativePermissionSheet(source: source) }
        .confirmationDialog("settings.replacePinnedAccount".localized(), isPresented: Binding(
            get: { pendingPin != nil }, set: { if !$0 { pendingPin = nil } }
        ), titleVisibility: .visible, presenting: pendingPin) { replacement in
            ForEach(pinnedItems) { item in
                Button(pinTitle(item)) { menuBar.replaceItem(item, with: replacement) }
            }
            Button("action.cancel".localized(), role: .cancel) { pendingPin = nil }
        } message: { replacement in
            Text(String(format: "settings.replacePinnedAccountMessage".localized(), pinTitle(replacement)))
        }
        .onChange(of: quota.state.hostID) { _, _ in pendingPin = nil }
        .alert("settings.renameAccount".localized(), isPresented: Binding(
            get: { renamingAccount != nil }, set: { if !$0 { renamingAccount = nil } }
        )) {
            TextField("settings.accountLabel".localized(), text: $newName)
            Button("action.cancel".localized(), role: .cancel) { renamingAccount = nil }
            Button("action.save".localized()) {
                guard let account = renamingAccount else { return }
                Task {
                    do { try await accounts.renameAccount(id: account.id, userLabel: newName) }
                    catch { actionFailed = true }
                    renamingAccount = nil
                }
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("settings.sources.remove".localized(), isPresented: Binding(
            get: { removingSource != nil }, set: { if !$0 { removingSource = nil } }
        )) {
            Button("action.cancel".localized(), role: .cancel) { removingSource = nil }
            Button("action.remove".localized(), role: .destructive) {
                guard let source = removingSource else { return }
                Task {
                    do {
                        try await accounts.unlinkSource(sourceID: source.accountID)
                        await controller.refresh(provider: provider)
                    } catch { actionFailed = true }
                    removingSource = nil
                }
            }
        }
        .alert("settings.removeAccount".localized(), isPresented: Binding(
            get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }
        )) {
            Button("action.cancel".localized(), role: .cancel) { removingAccount = nil }
            Button("action.remove".localized(), role: .destructive) {
                guard let account = removingAccount else { return }
                Task {
                    do {
                        try await accounts.delete(accountID: account.id)
                        await controller.refresh(provider: provider)
                    } catch { actionFailed = true }
                    removingAccount = nil
                }
            }
        }
        .alert("settings.actionFailed".localized(), isPresented: $actionFailed) {
            Button("action.ok".localized(), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func sourceMenu(_ source: AccountLoginSource) -> some View {
        if source.actions?.isEmpty == false {
            Menu {
                if source.actions?.contains("set_source_enabled") == true {
                    Toggle("settings.sources.pause".localized(), isOn: Binding(
                        get: { source.enabled == false },
                        set: { paused in
                            Task {
                                do {
                                    try await accounts.setSourceEnabled(!paused, sourceID: source.accountID)
                                    await controller.refresh(provider: provider)
                                } catch { actionFailed = true }
                            }
                        }
                    ))
                }
                if source.actions?.contains("remove_source") == true {
                    Button("action.remove".localized(), role: .destructive) { removingSource = source }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("settings.sources.actions".localized())
        }
    }

    private func pinButton(_ account: Account) -> some View {
        let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: account.accountKey, hostID: quota.state.hostID)
        let selected = menuBar.isSelected(item)
        return Button {
            if selected || pinnedItems.count < menuBar.menuBarMaxItems {
                menuBar.toggleItem(item)
            } else {
                pendingPin = item
            }
        } label: {
            Label((selected ? "settings.accountPinned" : "settings.pinAccount").localized(),
                  systemImage: selected ? "pin.fill" : "pin")
        }
        .buttonStyle(.borderless)
        .help((selected ? "settings.unpinAccount" : "settings.pinAccount").localized())
        .accessibilityLabel(Text((selected ? "settings.unpinAccount" : "settings.pinAccount").localized() + ": " + pinTitle(item)))
    }

    private func pinTitle(_ item: MenuBarQuotaItem) -> String {
        let providerName = QuotaProvider(rawValue: item.provider)?.displayName ?? item.provider
        let accountName = accounts.accounts.first {
            $0.providerID.rawValue == item.provider && $0.accountKey == item.accountKey
        }?.displayName ?? item.accountKey
        return providerName + " · " + accountName.masked(if: menuBar.hideSensitiveInfo)
    }

    private func accountMenu(_ account: Account) -> some View {
        Menu {
            Toggle("settings.pauseAccount".localized(), isOn: Binding(
                get: { account.isDisabled }, set: { disabled in Task { await controller.setAccountDisabled(disabled, accountID: account.id) } }
            ))
            .disabled(!account.capabilities.contains(.disable))
            if account.capabilities.contains(.edit), descriptor?.actions.contains("add_api_key") == true {
                Button("action.edit".localized()) { editingAccount = account; apiKeyPresented = true }
            }
            if account.capabilities.contains(.rename) {
                Button("settings.renameAccount".localized()) {
                    newName = account.displayName
                    renamingAccount = account
                }
                Button("settings.resetAccountName".localized()) {
                    Task {
                        do { try await accounts.renameAccount(id: account.id, userLabel: nil) }
                        catch { actionFailed = true }
                    }
                }
            }
            if account.canDelete {
                Button("action.remove".localized(), role: .destructive) { removingAccount = account }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("settings.accountActions".localized())
    }

    @ViewBuilder
    private func recoveryAction(_ issue: QuotaRefreshIssue, accounts: [Account], sourceID: String?) -> some View {
        switch issue.recoveryAction {
        case .signIn:
            if supportsOAuth, accounts.flatMap(\.sources).contains(where: { $0.accountID == sourceID && $0.source == .quotioKeychain }) {
                Button("action.login".localized()) { oauthPresented = true }
            } else {
                Text("connections.signInOwner".localized())
                Button("action.retry".localized()) { Task { await controller.refresh(provider: provider) } }
            }
        case .authorize:
            if let source = accounts.flatMap(\.sources).first(where: {
                $0.accountID == sourceID
            }), let kind = source.credentialReference {
                Button("settings.authorize".localized()) {
                    permission = NativeSourcePermission(provider: provider, kind: kind, location: source.location, keychainAccount: source.keychainAccount)
                }
            }
        case .refreshInSourceApp:
            Text("connections.signInOwner".localized())
            Button("action.retry".localized()) { Task { await controller.refresh(provider: provider) } }
        case .retry:
            Button("action.retry".localized()) { Task { await controller.refresh(provider: provider) } }
        case nil: EmptyView()
        }
    }
}

struct NativePermissionSheet: View {
    let source: NativeSourcePermission
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var controller
    @State private var failed = false
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.authorize".localized()).font(.title2)
            Text(String(format: "settings.permissionExplanation".localized(), source.keychainItemName, source.provider.displayName))
                .fixedSize(horizontal: false, vertical: true)
            if let account = source.keychainAccount {
                LabeledContent("settings.keychainAccount".localized(), value: account)
            }
            if failed { Text((accounts.nativeAuthorizationFailure ?? .unknown).message).foregroundStyle(.red) }
            if isSubmitting {
                ProgressView("settings.authorization.pending".localized())
                    .controlSize(.small)
            }
            HStack {
                Spacer()
                Button((isSubmitting ? "action.close" : "action.cancel").localized()) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("onboarding.button.continue".localized()) {
                    isSubmitting = true
                    failed = false
                    Task {
                        defer { isSubmitting = false }
                        do {
                            try await accounts.authorizeNativeSource(source)
                            await controller.refresh(provider: source.provider)
                            dismiss()
                        } catch { failed = true }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || accounts.authorizingNativeSourceID != nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
