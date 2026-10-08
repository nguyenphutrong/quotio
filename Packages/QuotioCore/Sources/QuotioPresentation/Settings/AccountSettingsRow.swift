import QuotioApplication
import QuotioDomain
import SwiftUI

/// One account under a provider: its name and a `plan · source` caption. Actions live in
/// a context menu and a `…` menu that appears while the pointer is over the row.
struct AccountSettingsRow: View {
    let provider: QuotaProvider
    let descriptor: MonitoringProvider?
    let account: Account
    let row: AccountSettingsRowState
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(MenuBarSettingsManager.self) private var menuBar
    @Environment(AccountsSettingsScreenModel.self) private var model
    @State private var isHovering = false

    private enum Recovery {
        case signIn
        case authorize(NativeSourcePermission)
        case retry
    }

    private var quotaID: QuotaAccountID { QuotaAccountID(provider: provider, accountKey: account.accountKey) }
    private var displayName: String { account.displayName.masked(if: menuBar.hideSensitiveInfo) }
    private var isRefreshing: Bool { quota.isRefreshing(provider: provider) }
    private var menuBarItem: MenuBarQuotaItem {
        MenuBarQuotaItem(provider: provider.rawValue, accountKey: account.accountKey, hostID: quota.state.hostID)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SensitiveAccountText(value: account.displayName, isSensitive: menuBar.hideSensitiveInfo)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.needsAttention {
                    attentionDetail
                } else if !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(account.isDisabled ? 0.6 : 1)
            if let recovery { recoveryButton(recovery) }
            if menuBar.isSelected(menuBarItem) {
                let title = "settings.pinnedToMenuBar".localized()
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(title)
                    .accessibilityLabel(Text(title))
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .help("settings.accountActions".localized())
            .accessibilityLabel(Text("settings.accountActions".localized() + ": " + displayName))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { actions }
    }

    /// `plan · source`, led by "Paused" when the account is paused.
    private var caption: String {
        var parts: [String] = []
        if account.isDisabled { parts.append("settings.accounts.paused".localized()) }
        if let plan = row.plan { parts.append(plan) }
        var sources: [String] = []
        for label in row.sourceKinds.map(\.shortLabel) where !sources.contains(label) {
            sources.append(label)
        }
        return (parts + sources).joined(separator: " · ")
    }

    private var issueText: String {
        let base = row.issue?.explanation ?? (row.connection == .permissionRequired || row.connection == .reauthenticationRequired
            ? row.connection.title : row.quota.title)
        if account.sources.count > 1, let sourceID = row.issueSourceID,
           let source = account.sources.first(where: { $0.accountID == sourceID }) {
            return source.title + ": " + base
        }
        return base
    }

    private var attentionDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(issueText).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .help(issueHelp ?? issueText)
            if case .authorize(let source) = recovery, model.failedAuthorizationID == source.id {
                Text((accounts.nativeAuthorizationFailure ?? .unknown).message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var issueHelp: String? {
        if let issue = row.issue, issue.reason == nil { return "settings.reasonMissing".localized() }
        if row.issue?.recoveryAction == .refreshInSourceApp { return "connections.signInOwner".localized() }
        if case .retry = recovery, row.issue?.recoveryAction == .signIn { return "connections.signInOwner".localized() }
        return nil
    }

    private var recovery: Recovery? {
        guard row.needsAttention else { return nil }
        let source = account.sources.first { $0.accountID == (row.issueSourceID ?? row.activeSourceID) } ?? account.sources.first
        let fallback: QuotaRecoveryAction = switch row.connection {
        case .reauthenticationRequired: .signIn
        case .permissionRequired: .authorize
        default: .retry
        }
        switch row.issue?.recoveryAction ?? fallback {
        case .signIn:
            let canSignIn = descriptor?.actions.contains("start_oauth") == true && source?.source == .quotioKeychain
            return canSignIn ? .signIn : .retry
        case .authorize:
            guard let source, let kind = source.credentialReference else { return .retry }
            return .authorize(NativeSourcePermission(provider: provider, kind: kind, location: source.location,
                keychainAccount: source.keychainAccount))
        case .refreshInSourceApp, .retry:
            return .retry
        }
    }

    @ViewBuilder
    private func recoveryButton(_ recovery: Recovery) -> some View {
        switch recovery {
        case .signIn:
            Button("action.login".localized()) { model.sheet = .oauth(provider) }
                .controlSize(.small)
        case .authorize(let source):
            if accounts.authorizingNativeSourceID == source.id {
                ProgressView().controlSize(.small)
            }
            Button("settings.authorize".localized()) {
                Task { await model.authorize(source, accounts: accounts, controller: controller) }
            }
            .controlSize(.small)
            .disabled(accounts.authorizingNativeSourceID != nil)
            .help(String(format: "settings.permissionExplanation".localized(), source.keychainItemName,
                descriptor?.displayName ?? provider.displayName))
        case .retry:
            Button("action.retry".localized()) { Task { await controller.refresh(account: quotaID) } }
                .controlSize(.small)
                .disabled(isRefreshing)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let selected = menuBar.isSelected(menuBarItem)
        Button((selected ? "settings.unpinAccount" : "settings.pinAccount").localized()) {
            let pinned = menuBar.selectedItems.filter { $0.hostID == quota.state.hostID }
            if selected || pinned.count < menuBar.menuBarMaxItems {
                menuBar.toggleItem(menuBarItem)
            } else {
                model.pendingPin = menuBarItem
            }
        }
        Button("action.refresh".localized()) { Task { await controller.refresh(account: quotaID) } }
            .disabled(account.isDisabled || isRefreshing)
        Divider()
        Toggle("settings.pauseAccount".localized(), isOn: Binding(
            get: { account.isDisabled },
            set: { disabled in Task { await controller.setAccountDisabled(disabled, accountID: account.id) } }
        ))
        .disabled(!account.capabilities.contains(.disable))
        if account.capabilities.contains(.edit), descriptor?.actions.contains("add_api_key") == true {
            Button("action.edit".localized() + "…") { model.sheet = .apiKey(provider, account) }
        }
        if account.capabilities.contains(.rename) {
            Button("settings.renameAccount".localized() + "…") { model.beginRename(account) }
            Button("settings.resetAccountName".localized()) {
                Task {
                    do { try await accounts.renameAccount(id: account.id, userLabel: nil) }
                    catch { model.actionFailed = true }
                }
            }
        }
        let sources = account.sources.filter(LoginSourceMenu.hasActions)
        if !sources.isEmpty {
            Divider()
            ForEach(sources) { source in
                Menu(source.source.shortLabel + " · " + source.locationLabel) {
                    LoginSourceMenu(provider: provider, source: source)
                }
            }
        }
        if account.canDelete {
            Divider()
            Button("action.remove".localized() + "…", role: .destructive) { model.removingAccount = account }
        }
    }
}

extension MenuBarQuotaItem {
    @MainActor
    func settingsTitle(accounts: [Account], masked: Bool) -> String {
        let providerName = QuotaProvider(rawValue: provider)?.displayName ?? provider
        let accountName = accounts.first {
            $0.providerID.rawValue == provider && $0.accountKey == accountKey
        }?.displayName ?? accountKey
        return providerName + " · " + accountName.masked(if: masked)
    }
}
