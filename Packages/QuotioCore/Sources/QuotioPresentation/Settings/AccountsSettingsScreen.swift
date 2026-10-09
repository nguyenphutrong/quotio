import QuotioApplication
import QuotioDomain
import SwiftUI

struct AccountsSettingsScreen: View {
    @Environment(NavigationScreenModel.self) private var navigation
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(MenuBarSettingsManager.self) private var menuBar
    @State private var model = AccountsSettingsScreenModel()
    @State private var search = ""
    @State private var showUnconnected = false

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var providers: [MonitoringProvider] {
        controller.providers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var lastUpdated: Date? {
        quota.state.quotas.values.flatMap(\.values).map(\.lastUpdated).max()
    }

    var body: some View {
        let list = AccountsSettingsList(providers: providers, accounts: accounts.accounts,
            permissions: accounts.nativeSourcePermissions, quota: quota.state,
            tracking: controller.trackingPreferences, search: query)
        ScrollViewReader { proxy in
            Form {
                AccountStorageAccessSection()
                if let error = controller.settingsError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                if list.connected.isEmpty && query.isEmpty {
                    Section {
                        Text("settings.accounts.empty".localized()).foregroundStyle(.secondary)
                    }
                }
                ForEach(list.connected, id: \.provider) { state in
                    ProviderAccountsSection(state: state, visibleAccounts: list.visibleAccounts(in: state))
                }
                if !list.unconnected.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: Binding(
                            get: { showUnconnected || !query.isEmpty || list.connected.isEmpty },
                            set: { showUnconnected = $0 }
                        )) {
                            ForEach(list.unconnected, id: \.provider) { state in
                                UnconnectedProviderRow(provider: state.provider).id(state.provider)
                            }
                        } label: {
                            Text(String(format: "settings.unconnectedCount".localized(), list.unconnected.count))
                        }
                    }
                }
                if list.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("nav.accounts".localized())
            .navigationSubtitle(lastUpdated.map {
                String(format: "monitor.status.updated".localized(), $0.accountsSettingsTimestamp)
            } ?? "")
            .searchable(text: $search, prompt: "settings.accounts.search".localized())
            .toolbar { toolbar }
            .task(id: navigation.selectedProvider) {
                guard let provider = navigation.selectedProvider else { return }
                search = ""
                let state = ProviderSettingsState(provider: provider, accounts: accounts.accounts,
                    permissions: accounts.nativeSourcePermissions, quota: quota.state,
                    tracking: controller.trackingPreferences)
                if state.isUnconnected { showUnconnected = true }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation { proxy.scrollTo(provider, anchor: .top) }
            }
        }
        .environment(model)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .oauth(let provider):
                OAuthSheet(provider: provider) { model.sheet = nil }
            case .apiKey(let provider, let account):
                let descriptor = controller.providers.first { $0.id == provider }
                MonitorAPIKeyConnectionSheet(provider: provider, account: account, inputs: descriptor?.inputs ?? [],
                    providerName: descriptor?.displayName ?? provider.displayName) { label, key, fields in
                    try await controller.saveAPIKey(provider: provider, label: label, apiKey: key,
                        existingAccountID: account?.id, fields: fields)
                }
            }
        }
        .confirmationDialog("settings.replacePinnedAccount".localized(), isPresented: Binding(
            get: { model.pendingPin != nil }, set: { if !$0 { model.pendingPin = nil } }
        ), titleVisibility: .visible, presenting: model.pendingPin) { replacement in
            ForEach(menuBar.selectedItems.filter { $0.hostID == quota.state.hostID }) { item in
                Button(pinTitle(item)) { menuBar.replaceItem(item, with: replacement) }
            }
            Button("action.cancel".localized(), role: .cancel) { model.pendingPin = nil }
        } message: { replacement in
            Text(String(format: "settings.replacePinnedAccountMessage".localized(), pinTitle(replacement)))
        }
        .onChange(of: quota.state.hostID) { _, _ in model.pendingPin = nil }
        .alert("settings.renameAccount".localized(), isPresented: Binding(
            get: { model.renamingAccount != nil }, set: { if !$0 { model.renamingAccount = nil } }
        )) {
            TextField("settings.accountLabel".localized(), text: $model.newName)
            Button("action.cancel".localized(), role: .cancel) { model.renamingAccount = nil }
            Button("action.save".localized()) {
                guard let account = model.renamingAccount else { return }
                let name = model.newName
                Task {
                    do { try await accounts.renameAccount(id: account.id, userLabel: name) }
                    catch { model.actionFailed = true }
                    model.renamingAccount = nil
                }
            }
            .disabled(model.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("settings.sources.remove".localized(), isPresented: Binding(
            get: { model.removingSource != nil }, set: { if !$0 { model.removingSource = nil } }
        )) {
            Button("action.cancel".localized(), role: .cancel) { model.removingSource = nil }
            Button("action.remove".localized(), role: .destructive) {
                guard let removal = model.removingSource else { return }
                Task {
                    do {
                        try await accounts.unlinkSource(sourceID: removal.source.accountID)
                        await controller.refresh(provider: removal.provider)
                    } catch { model.actionFailed = true }
                    model.removingSource = nil
                }
            }
        } message: {
            if let removal = model.removingSource {
                Text(removal.source.title + " · " + removal.source.locationLabel)
            }
        }
        .alert("settings.removeAccount".localized(), isPresented: Binding(
            get: { model.removingAccount != nil }, set: { if !$0 { model.removingAccount = nil } }
        )) {
            Button("action.cancel".localized(), role: .cancel) { model.removingAccount = nil }
            Button("action.remove".localized(), role: .destructive) {
                guard let account = model.removingAccount else { return }
                Task {
                    do {
                        try await accounts.delete(accountID: account.id)
                        if let provider = QuotaProvider(rawValue: account.providerID.rawValue) {
                            await controller.refresh(provider: provider)
                        }
                    } catch { model.actionFailed = true }
                    model.removingAccount = nil
                }
            }
        } message: {
            if let account = model.removingAccount {
                Text(account.displayName.masked(if: menuBar.hideSensitiveInfo))
            }
        }
        .alert("settings.actionFailed".localized(), isPresented: $model.actionFailed) {
            Button("action.ok".localized(), role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            RefreshButton(title: "action.refreshQuota".localized(), isRefreshing: quota.isLoadingQuotas) {
                await controller.refreshAll(force: true)
            }
            .help("action.refreshQuota".localized())
            let connectable = providers.filter(ProviderConnectMenu.isConnectable)
            Menu {
                ForEach(connectable) { provider in
                    Menu(provider.displayName) {
                        ProviderConnectMenu(provider: provider)
                    }
                }
            } label: {
                Label("action.addAccount".localized(), systemImage: "plus")
            }
            .disabled(connectable.isEmpty)
            .help("action.addAccount".localized())
        }
    }

    private func pinTitle(_ item: MenuBarQuotaItem) -> String {
        item.settingsTitle(accounts: accounts.accounts, masked: menuBar.hideSensitiveInfo)
    }
}

/// A provider with nothing to manage yet, offering its connection methods in place.
struct UnconnectedProviderRow: View {
    let provider: QuotaProvider
    @Environment(QuotaFeatureController.self) private var controller

    var body: some View {
        let descriptor = controller.providers.first { $0.id == provider }
        HStack(spacing: 10) {
            ProviderIcon(provider: provider, size: 18)
            Text(descriptor?.displayName ?? provider.displayName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let descriptor, ProviderConnectMenu.isConnectable(descriptor) {
                Menu("action.connect".localized()) {
                    ProviderConnectMenu(provider: descriptor)
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

/// Providers split into those with something to manage and those not connected yet.
/// Tracking-off providers stay in place so that flipping the switch never moves a row.
struct AccountsSettingsList {
    let connected: [ProviderSettingsState]
    let unconnected: [ProviderSettingsState]
    private let accountQuery: String?
    private let nameMatches: Set<QuotaProvider>

    var isEmpty: Bool { connected.isEmpty && unconnected.isEmpty }

    init(providers: [MonitoringProvider], accounts: [Account], permissions: [NativeSourcePermission],
         quota: QuotaSnapshot, tracking: ProviderTrackingPreferences, search: String) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var nameMatches = Set<QuotaProvider>()
        let states = providers.filter { descriptor in
            if query.isEmpty || descriptor.displayName.localizedCaseInsensitiveContains(query) {
                nameMatches.insert(descriptor.id)
                return true
            }
            return accounts.contains {
                $0.providerID.rawValue == descriptor.id.rawValue && $0.displayName.localizedCaseInsensitiveContains(query)
            }
        }.map {
            ProviderSettingsState(provider: $0.id, accounts: accounts, permissions: permissions,
                quota: quota, tracking: tracking)
        }
        connected = states.filter { !$0.isUnconnected }
        unconnected = states.filter(\.isUnconnected)
        self.nameMatches = nameMatches
        accountQuery = query.isEmpty ? nil : query
    }

    /// When the search matched account names rather than the provider, only those accounts show.
    func visibleAccounts(in state: ProviderSettingsState) -> [Account] {
        guard let accountQuery, !nameMatches.contains(state.provider) else { return state.accounts }
        return state.accounts.filter { $0.displayName.localizedCaseInsensitiveContains(accountQuery) }
    }
}
