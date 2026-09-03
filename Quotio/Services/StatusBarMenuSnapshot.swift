import Foundation
import QuotioApplication
import QuotioDomain

struct StatusBarMenuAccountSnapshot: Equatable, Sendable {
    let id: QuotaAccountID
    let email: String
    let quota: ProviderQuota
    let subscription: QuotaSubscriptionInfo?
    let isActiveInIDE: Bool
    let isRefreshing: Bool
    let isRefreshBlocked: Bool
}

struct StatusBarMenuProviderSnapshot: Equatable, Sendable {
    let provider: QuotaProvider
    let accounts: [StatusBarMenuAccountSnapshot]
    let isRefreshing: Bool
    let supportsScopedRefresh: Bool
}

struct StatusBarMenuDisplaySettings: Equatable, Sendable {
    let quotaDisplayMode: QuotaDisplayMode
    let quotaDisplayStyle: QuotaDisplayStyle
    let hideSensitiveInfo: Bool
    let modelAggregationMode: ModelAggregationMode

    func aggregateModelPercentages(_ percentages: [Double]) -> Double {
        let validPercentages = percentages.filter { $0 >= 0 }
        guard !validPercentages.isEmpty else { return -1 }

        switch modelAggregationMode {
        case .lowest:
            return validPercentages.min() ?? -1
        case .average:
            return validPercentages.reduce(0, +) / Double(validPercentages.count)
        }
    }
}

struct StatusBarMenuSnapshot: Equatable, Sendable {
    let isLocalProxyMode: Bool
    let proxyPort: UInt16
    let isProxyRunning: Bool
    let tunnel: CloudflareTunnelSnapshot
    let providers: [StatusBarMenuProviderSnapshot]
    let isLoadingQuotas: Bool
    let displaySettings: StatusBarMenuDisplaySettings
    let appearanceMode: AppearanceMode
    let language: AppLanguage
}

enum StatusBarMenuSnapshotMapper {
    nonisolated static func makeSnapshot(
        mode: OperatingMode,
        proxyPort: UInt16,
        isProxyRunning: Bool,
        tunnel: CloudflareTunnelSnapshot,
        directAuthProviders: Set<QuotaProvider>,
        monitorAccounts: [MonitorAccount],
        quota: QuotaSnapshot,
        installedAgents: Set<CLIAgent>,
        activeAntigravityEmail: String?,
        menuBarPreferences: MenuBarPreferences,
        appearanceMode: AppearanceMode,
        language: AppLanguage
    ) -> StatusBarMenuSnapshot {
        var availableProviders = directAuthProviders
        availableProviders.formUnion(quota.quotas.compactMap { provider, accounts in
            accounts.isEmpty ? nil : provider
        })
        if mode == .monitor {
            availableProviders.formUnion(monitorProviders(monitorAccounts))
        }

        let providers = filterProviders(
            availableProviders,
            isMonitorMode: mode == .monitor,
            installedAgents: installedAgents
        ).map { provider in
            let accounts = orderedAccounts(
                quota.quotas[provider] ?? [:],
                provider: provider,
                activeAntigravityEmail: activeAntigravityEmail
            ).map { account in
                let accountID = QuotaAccountID(provider: provider, accountKey: account.accountKey)
                return StatusBarMenuAccountSnapshot(
                    id: accountID,
                    email: account.email,
                    quota: account.data,
                    subscription: quota.subscriptions[provider]?[account.accountKey],
                    isActiveInIDE: provider == .antigravity
                        && emailsMatch(account.email, activeAntigravityEmail),
                    isRefreshing: quota.refreshingProviders.contains(provider),
                    isRefreshBlocked: quota.refreshingProviders.contains(provider)
                )
            }
            return StatusBarMenuProviderSnapshot(
                provider: provider,
                accounts: accounts,
                isRefreshing: quota.refreshingProviders.contains(provider),
                supportsScopedRefresh: provider.supportsQuotaOnlyMode
            )
        }

        return StatusBarMenuSnapshot(
            isLocalProxyMode: mode == .localProxy,
            proxyPort: proxyPort,
            isProxyRunning: isProxyRunning,
            tunnel: tunnel,
            providers: providers,
            isLoadingQuotas: !quota.refreshingProviders.isEmpty,
            displaySettings: StatusBarMenuDisplaySettings(
                quotaDisplayMode: menuBarPreferences.quotaDisplayMode,
                quotaDisplayStyle: menuBarPreferences.quotaDisplayStyle,
                hideSensitiveInfo: menuBarPreferences.hideSensitiveInfo,
                modelAggregationMode: menuBarPreferences.modelAggregationMode
            ),
            appearanceMode: appearanceMode,
            language: language
        )
    }

    nonisolated static func monitorProviders(_ accounts: [MonitorAccount]) -> Set<QuotaProvider> {
        Set(accounts.lazy.filter { !$0.isDisabled }.map(\.provider))
    }

    nonisolated static func filterProviders(
        _ providers: Set<QuotaProvider>,
        isMonitorMode: Bool,
        installedAgents: Set<CLIAgent>
    ) -> [QuotaProvider] {
        let sorted = providers.sorted { $0.displayName < $1.displayName }
        guard !isMonitorMode else { return sorted }
        return sorted.filter { provider in
            guard let agent = provider.cliAgent else { return true }
            return installedAgents.contains(agent)
        }
    }

    nonisolated static func orderedAccounts(
        _ quotas: [String: ProviderQuota],
        provider: QuotaProvider,
        activeAntigravityEmail: String?
    ) -> [(accountKey: String, email: String, data: ProviderQuota)] {
        let sorted = quotas
            .map { (accountKey: $0.key, email: $0.value.accountDisplayName ?? $0.key, data: $0.value) }
            .sorted { $0.email < $1.email }

        guard provider == .antigravity else { return sorted }
        return AccountSorting.prioritizingActive(sorted) {
            emailsMatch($0.email, activeAntigravityEmail)
        }
    }

    nonisolated private static func emailsMatch(_ email: String, _ activeEmail: String?) -> Bool {
        guard let activeEmail, !email.isEmpty, !activeEmail.isEmpty else { return false }
        return email.caseInsensitiveCompare(activeEmail) == .orderedSame
    }
}
