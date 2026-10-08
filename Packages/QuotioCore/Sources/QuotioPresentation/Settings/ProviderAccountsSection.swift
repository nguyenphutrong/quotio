import QuotioApplication
import QuotioDomain
import SwiftUI

/// A provider and its accounts. The header row carries the provider's actions in a context
/// menu and a `…` menu that appears while the pointer is over it.
struct ProviderAccountsSection: View {
    let state: ProviderSettingsState
    let visibleAccounts: [Account]
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller
    @State private var isHovering = false

    private var provider: QuotaProvider { state.provider }
    private var descriptor: MonitoringProvider? { controller.providers.first { $0.id == provider } }
    private var name: String { descriptor?.displayName ?? provider.displayName }
    private var tracked: Bool { controller.trackingPreferences.isEnabled(provider) }

    var body: some View {
        Section {
            header.id(provider)
            if tracked {
                ForEach(visibleAccounts) { account in
                    AccountSettingsRow(provider: provider, descriptor: descriptor, account: account,
                        row: AccountSettingsRowState(account: account, provider: provider, snapshot: quota.state, tracked: tracked))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: provider, size: 16)
                .opacity(tracked ? 1 : 0.5)
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(tracked ? .primary : .secondary)
            if !tracked {
                Text("settings.accounts.paused".localized())
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if tracked, quota.isRefreshing(provider: provider) {
                ProgressView().controlSize(.small)
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
            .help("settings.providerActions".localized())
            .accessibilityLabel(Text("settings.providerActions".localized() + ": " + name))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { actions }
        .help(tracked ? "" : "settings.trackingPaused".localized())
    }

    @ViewBuilder
    private var actions: some View {
        if let descriptor, ProviderConnectMenu.isConnectable(descriptor) {
            Menu("action.addAccount".localized()) {
                ProviderConnectMenu(provider: descriptor)
            }
            Divider()
        }
        Toggle(String(format: "settings.trackProvider".localized(), name), isOn: Binding(get: { tracked }, set: { enabled in
            Task { await controller.setProviderEnabled(enabled, provider: provider) }
        }))
        .disabled(!controller.canManageSettings || controller.monitoringSettings == nil || controller.isUpdatingSettings)
    }
}

/// Provider-level problems collected from every monitored provider: logins waiting for
/// Keychain access, logins that could not be identified, and provider-wide failures.
/// Account-level problems stay on their account rows.
struct AccountsAttentionSection: View {
    let states: [ProviderSettingsState]
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller

    var body: some View {
        let items = states.filter { controller.trackingPreferences.isEnabled($0.provider) }.map { state in
            (state: state, issue: ProviderAccountsSummary(state: state, snapshot: quota.state, tracked: true).providerIssue)
        }
        if items.contains(where: { !$0.state.permissions.isEmpty || !$0.state.accountsNeedingIdentification.isEmpty || $0.issue != nil }) {
            Section("connections.attention".localized()) {
                ForEach(items, id: \.state.provider) { item in
                    let provider = item.state.provider
                    let descriptor = controller.providers.first { $0.id == provider }
                    let name = descriptor?.displayName ?? provider.displayName
                    ForEach(item.state.permissions) { source in
                        PendingPermissionRow(source: source, descriptor: descriptor, providerName: name)
                    }
                    ForEach(item.state.accountsNeedingIdentification) { account in
                        ForEach(account.sources) { source in
                            UnidentifiedSourceRow(provider: provider, providerName: name, source: source)
                        }
                    }
                    if let issue = item.issue {
                        ProviderIssueRow(provider: provider, providerName: name, issue: issue)
                    }
                }
            }
        }
    }
}

/// One line in the attention section: provider icon, a single-line title, and trailing controls.
private struct AttentionRow<Trailing: View>: View {
    let provider: QuotaProvider
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 16)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

/// A login found on this Mac that Quotio cannot read until the user grants Keychain access.
private struct PendingPermissionRow: View {
    let source: NativeSourcePermission
    let descriptor: MonitoringProvider?
    let providerName: String
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(AccountsSettingsScreenModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AttentionRow(provider: source.provider, title: providerName + " · Keychain · " + source.keychainItemName) {
                if accounts.authorizingNativeSourceID == source.id {
                    ProgressView().controlSize(.small)
                }
                Button("settings.authorize".localized()) {
                    Task { await model.authorize(source, accounts: accounts, controller: controller) }
                }
                .controlSize(.small)
                .disabled(descriptor?.actions.contains("authorize_native") != true || accounts.authorizingNativeSourceID != nil)
            }
            if model.failedAuthorizationID == source.id {
                Text((accounts.nativeAuthorizationFailure ?? .unknown).message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(source.explanationLocalizationKey.localized() + " " + "settings.authorize.alwaysAllow".localized())
    }
}

/// A login source whose owner could not be identified, so it is not counted as an account.
private struct UnidentifiedSourceRow: View {
    let provider: QuotaProvider
    let providerName: String
    let source: AccountLoginSource
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller

    var body: some View {
        AttentionRow(provider: provider, title: providerName + " · " + source.title) {
            RefreshButton(title: "action.retry".localized(), isRefreshing: quota.isRefreshing(provider: provider)) {
                await controller.refresh(provider: provider)
            }
            .controlSize(.small)
        }
        .help(source.locationLabel + "\n" + "settings.sources.unidentifiedHelp".localized())
        .contextMenu { LoginSourceMenu(provider: provider, source: source) }
    }
}

/// A provider-wide refresh failure that no account refresh has superseded.
private struct ProviderIssueRow: View {
    let provider: QuotaProvider
    let providerName: String
    let issue: QuotaRefreshIssue
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller

    var body: some View {
        AttentionRow(provider: provider, title: providerName + " · " + issue.explanation) {
            RefreshButton(title: "action.retry".localized(), isRefreshing: quota.isRefreshing(provider: provider)) {
                await controller.refresh(provider: provider)
            }
            .controlSize(.small)
        }
        .help(issue.reason == nil ? "settings.reasonMissing".localized() : issue.explanation)
    }
}
