import QuotioApplication
import QuotioDomain
import SwiftUI

/// A provider and everything under it: the monitoring switch, logins waiting for
/// access, provider-wide failures, and one row per account.
struct ProviderAccountsSection: View {
    let state: ProviderSettingsState
    let visibleAccounts: [Account]
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller

    private var provider: QuotaProvider { state.provider }
    private var descriptor: MonitoringProvider? { controller.providers.first { $0.id == provider } }
    private var name: String { descriptor?.displayName ?? provider.displayName }
    private var tracked: Bool { controller.trackingPreferences.isEnabled(provider) }

    var body: some View {
        let summary = ProviderAccountsSummary(state: state, snapshot: quota.state, tracked: tracked)
        Section {
            header(summary)
                .id(provider)
            if tracked {
                ForEach(state.permissions) { source in
                    PendingPermissionRow(source: source, descriptor: descriptor, providerName: name)
                }
                ForEach(state.accountsNeedingIdentification) { account in
                    ForEach(account.sources) { source in
                        UnidentifiedSourceRow(provider: provider, source: source)
                    }
                }
                if let issue = summary.providerIssue {
                    ProviderIssueRow(provider: provider, issue: issue)
                }
                ForEach(visibleAccounts) { account in
                    AccountSettingsRow(provider: provider, descriptor: descriptor, account: account,
                        row: AccountSettingsRowState(account: account, provider: provider, snapshot: quota.state, tracked: tracked))
                }
            }
        }
    }

    private func header(_ summary: ProviderAccountsSummary) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: provider, size: 22)
                .opacity(tracked ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(tracked ? .primary : .secondary)
                HStack(spacing: 0) {
                    Text(summaryText(summary)).foregroundStyle(.secondary)
                    if summary.attentionCount > 0 {
                        Text(String.localizedStringWithFormat("settings.accounts.issueCount".localized(), summary.attentionCount))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .help(captionText(summary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if quota.isRefreshing(provider: provider) {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 12) {
                if let descriptor, ProviderConnectMenu.isConnectable(descriptor) {
                    let title = String(format: "settings.addAccountFor".localized(), name)
                    Menu {
                        ProviderConnectMenu(provider: descriptor)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .help(title)
                    .accessibilityLabel(Text(title))
                }
                Text("settings.track".localized())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("settings.track".localized(), isOn: Binding(get: { tracked }, set: { enabled in
                    Task { await controller.setProviderEnabled(enabled, provider: provider) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(tracked ? String(format: "settings.track.help".localized(), name) : "settings.trackingPaused".localized())
                .accessibilityLabel(Text("settings.track".localized() + ": " + name))
                .disabled(!controller.canManageSettings || controller.monitoringSettings == nil || controller.isUpdatingSettings)
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func captionText(_ summary: ProviderAccountsSummary) -> String {
        var text = summaryText(summary)
        if summary.attentionCount > 0 {
            text += String.localizedStringWithFormat("settings.accounts.issueCount".localized(), summary.attentionCount)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
    }

    private func summaryText(_ summary: ProviderAccountsSummary) -> String {
        var parts: [String] = []
        if !summary.tracked { parts.append("settings.accounts.trackingOff".localized()) }
        if summary.accountCount > 0 {
            parts.append(String.localizedStringWithFormat("settings.accounts.count".localized(), summary.accountCount))
        }
        if summary.tracked, summary.attentionCount == 0, let updated = summary.lastUpdated {
            parts.append(String(format: "monitor.status.updated".localized(), updated.accountsSettingsTimestamp))
        }
        let text = parts.joined(separator: " · ")
        return summary.attentionCount > 0 && !text.isEmpty ? text + " · " : text
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keychain · " + source.keychainItemName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.explanationLocalizationKey.localized() + " " + "settings.authorize.alwaysAllow".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.failedAuthorizationID == source.id {
                    Text((accounts.nativeAuthorizationFailure ?? .unknown).message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if accounts.authorizingNativeSourceID == source.id {
                ProgressView().controlSize(.small)
            }
            Button("settings.authorize".localized()) {
                Task { await model.authorize(source, accounts: accounts, controller: controller) }
            }
            .controlSize(.small)
            .disabled(descriptor?.actions.contains("authorize_native") != true || accounts.authorizingNativeSourceID != nil)
        }
        .help(String(format: "settings.permissionExplanation".localized(), source.keychainItemName, providerName))
    }
}

/// A login source whose owner could not be identified, so it is not counted as an account.
private struct UnidentifiedSourceRow: View {
    let provider: QuotaProvider
    let source: AccountLoginSource
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .lineLimit(1)
                    .help(source.locationLabel)
                Text("settings.sources.unidentifiedHelp".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RefreshButton(title: "action.retry".localized(), isRefreshing: quota.isRefreshing(provider: provider)) {
                await controller.refresh(provider: provider)
            }
            .controlSize(.small)
        }
        .contextMenu { LoginSourceMenu(provider: provider, source: source) }
    }
}

/// A provider-wide refresh failure that no account refresh has superseded.
private struct ProviderIssueRow: View {
    let provider: QuotaProvider
    let issue: QuotaRefreshIssue
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16)
            Text(issue.explanation)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(issue.reason == nil ? "settings.reasonMissing".localized() : issue.explanation)
            RefreshButton(title: "action.retry".localized(), isRefreshing: quota.isRefreshing(provider: provider)) {
                await controller.refresh(provider: provider)
            }
            .controlSize(.small)
        }
    }
}
