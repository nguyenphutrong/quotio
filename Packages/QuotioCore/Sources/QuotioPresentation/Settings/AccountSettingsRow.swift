import QuotioApplication
import QuotioDomain
import SwiftUI

/// One account under a provider. Collapsed it shows identity, state, and the common
/// actions; expanded it lists the login sources that feed the account.
struct AccountSettingsRow: View {
    let provider: QuotaProvider
    let descriptor: MonitoringProvider?
    let account: Account
    let row: AccountSettingsRowState
    let sourceIssues: [String: QuotaRefreshIssue]
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(MenuBarSettingsManager.self) private var menuBar
    @Environment(AccountsSettingsScreenModel.self) private var model

    private enum Recovery {
        case signIn
        case authorize(NativeSourcePermission)
        case retry
    }

    private var quotaID: QuotaAccountID { QuotaAccountID(provider: provider, accountKey: account.accountKey) }
    private var displayName: String { account.displayName.masked(if: menuBar.hideSensitiveInfo) }
    private var isRefreshing: Bool { quota.isRefreshing(provider: provider) }

    var body: some View {
        DisclosureGroup(isExpanded: expansion) {
            ForEach(account.sources) { source in
                LoginSourceRow(provider: provider, source: source,
                    isActive: account.sources.count > 1 && source.accountID == row.activeSourceID,
                    issue: account.isDisabled ? nil : sourceIssues[source.accountID])
            }
        } label: {
            HStack(spacing: 8) {
                AccountStatusDot(tone: row.tone, title: statusTitle)
                VStack(alignment: .leading, spacing: 2) {
                    SensitiveAccountText(value: account.displayName, isSensitive: menuBar.hideSensitiveInfo)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.needsAttention {
                        attentionDetail
                    } else {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(detail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(account.isDisabled ? 0.6 : 1)
                if isRefreshing { SmallProgressView() }
                if let recovery { recoveryButton(recovery) }
                pinButton
                accountMenu
            }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(get: { model.expandedAccountIDs.contains(account.id) }, set: { expanded in
            if expanded { model.expandedAccountIDs.insert(account.id) } else { model.expandedAccountIDs.remove(account.id) }
        })
    }

    private var statusTitle: String {
        switch row.tone {
        case .inactive: "settings.accounts.paused".localized()
        case .attention: "connections.attention".localized()
        case .connected, .unchecked: row.connection.title
        }
    }

    private var detail: String {
        var parts: [String] = []
        if account.isDisabled { parts.append("settings.accounts.paused".localized()) }
        if account.sources.count > 1 {
            parts.append(String(format: "settings.accounts.sourceCount".localized(), account.sources.count))
        } else if let source = account.sources.first {
            parts.append(source.title)
        }
        guard !account.isDisabled else { return parts.joined(separator: " · ") }
        let remaining = menuBar.totalUsagePercent(summary: row.summary)
        if remaining >= 0, row.quota != .notLoaded {
            parts.append(String(format: "settings.accounts.remaining".localized(), Int(remaining.rounded())))
        }
        if isRefreshing || row.quota == .refreshing {
            parts.append("status.refreshing".localized())
        } else if row.quota == .notLoaded || row.lastUpdated == nil {
            parts.append("settings.quota.notLoaded".localized())
        } else if let updated = row.lastUpdated {
            parts.append(row.quota == .stale
                ? "settings.quota.stale".localized() + " · " + updated.accountsSettingsTimestamp
                : String(format: "monitor.status.updated".localized(), updated.accountsSettingsTimestamp))
        }
        return parts.joined(separator: " · ")
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

    private var pinButton: some View {
        let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: account.accountKey, hostID: quota.state.hostID)
        let selected = menuBar.isSelected(item)
        let pinned = menuBar.selectedItems.filter { $0.hostID == quota.state.hostID }
        let title = (selected ? "settings.unpinAccount" : "settings.pinAccount").localized()
        return Button {
            if selected || pinned.count < menuBar.menuBarMaxItems {
                menuBar.toggleItem(item)
            } else {
                model.pendingPin = item
            }
        } label: {
            Image(systemName: selected ? "pin.fill" : "pin")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(Text(title + ": " + displayName))
    }

    private var accountMenu: some View {
        Menu {
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
            if account.canDelete {
                Divider()
                Button("action.remove".localized() + "…", role: .destructive) { model.removingAccount = account }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("settings.accountActions".localized())
        .accessibilityLabel(Text("settings.accountActions".localized() + ": " + displayName))
    }
}

private struct AccountStatusDot: View {
    let tone: AccountSettingsRowState.Tone
    let title: String

    var body: some View {
        Group {
            switch tone {
            case .connected: Circle().fill(Color.green)
            case .attention: Circle().fill(Color.orange)
            case .inactive: Circle().fill(Color.secondary.opacity(0.5))
            case .unchecked: Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .help(title)
        .accessibilityElement()
        .accessibilityLabel(Text(title))
    }
}

/// A login source that feeds an account: where it lives, whether quota currently uses
/// it, and its own pause/remove actions.
private struct LoginSourceRow: View {
    let provider: QuotaProvider
    let source: AccountLoginSource
    let isActive: Bool
    let issue: QuotaRefreshIssue?

    private var isPaused: Bool { source.enabled == false || source.status == .disabled }

    /// Quotio-owned logins have no meaningful external app name; show where they live instead.
    private var title: String {
        source.source == .quotioKeychain ? source.locationLabel : source.title
    }

    private var status: (text: String, help: String, color: Color) {
        if isPaused {
            let text = "settings.accounts.paused".localized()
            return (text, text, .secondary)
        }
        if let issue {
            return ("connections.attention".localized(), issue.explanation, .orange)
        }
        if source.status == .ready {
            let text = ConnectionState.connected.title
            return (text, text, .secondary)
        }
        return ("settings.sources.uncheckedShort".localized(), "settings.sources.unchecked".localized(), .secondary)
    }

    var body: some View {
        let status = status
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                if title != source.locationLabel {
                    Text(source.locationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.locationLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(isActive ? "settings.sources.inUse".localized() + " · " + status.text : status.text)
                .font(.caption)
                .foregroundStyle(status.color)
                .lineLimit(1)
                .fixedSize()
                .help(isActive ? "settings.sources.active".localized() + " · " + status.help : status.help)
            LoginSourceMenu(provider: provider, source: source)
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
