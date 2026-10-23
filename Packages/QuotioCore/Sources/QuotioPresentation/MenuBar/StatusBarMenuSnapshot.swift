import Foundation
import QuotioApplication
import QuotioDomain

struct StatusBarMenuQuotaWarning: Equatable, Sendable {
    let state: QuotaRefreshState
    let issue: QuotaRefreshIssue?
    let lastSuccessfulUpdate: Date?

    var isStale: Bool {
        if state == .stale { return true }
        guard lastSuccessfulUpdate != nil else { return false }
        if case .failed = state { return true }
        return issue?.kind == .failed
    }

    var recoveryAction: QuotaRecoveryAction? {
        if let action = issue?.recoveryAction { return action }
        let reason: QuotaRefreshFailureReason?
        if case .failed(let failure) = state {
            reason = issue?.reason ?? failure
        } else {
            reason = issue?.reason
        }
        switch reason {
        case .authentication: return .signIn
        case .credentialStorage, .localCredentialStorage: return .authorize
        case .ownerRefreshRequired: return .refreshInSourceApp
        case .sourceDisabled: return nil
        default: return .retry
        }
    }

    nonisolated static func resolve(accountID: QuotaAccountID, in snapshot: QuotaSnapshot) -> Self? {
        let updated = snapshot.quotas[accountID.provider]?[accountID.accountKey]?.lastUpdated
        let state = snapshot.accountStates[accountID]?.quota ?? .notLoaded
        let providerIssue = snapshot.issues[accountID.provider].flatMap { issue in
            state != .fresh && (updated.map { issue.occurredAt > $0 } ?? true) ? issue : nil
        }
        let issue = snapshot.accountIssues[accountID] ?? providerIssue
        switch state {
        case .stale, .failed:
            return Self(state: state, issue: issue, lastSuccessfulUpdate: updated)
        default:
            return issue.map { Self(state: state, issue: $0, lastSuccessfulUpdate: updated) }
        }
    }
}

struct StatusBarMenuAccountSnapshot: Equatable, Sendable {
    let id: QuotaAccountID
    let email: String
    let quota: ProviderQuota?
    let subscription: QuotaSubscriptionInfo?
    let warning: StatusBarMenuQuotaWarning?
    let isRefreshing: Bool
    let isRefreshBlocked: Bool

    @MainActor var hasDetail: Bool {
        warning != nil || quota.map { !$0.isForbidden && $0.models.contains { !$0.isStandaloneMetric } } == true
    }
}

struct StatusBarMenuProviderSnapshot: Equatable, Sendable {
    let displayName: String
    let provider: QuotaProvider
    let accounts: [StatusBarMenuAccountSnapshot]
    let warning: StatusBarMenuQuotaWarning?
    let isRefreshing: Bool
    let supportsScopedRefresh: Bool
}

struct StatusBarMenuDisplaySettings: Equatable, Sendable {
    let quotaDisplayMode: QuotaDisplayMode
    let quotaDisplayStyle: QuotaDisplayStyle
    let hideSensitiveInfo: Bool
    let modelAggregationMode: ModelAggregationMode


}

enum StatusBarRefreshSchedule: Equatable, Sendable {
    case manual
    case next(Date)

    /// Nil while the settings are unknown or a scheduled refresh is running.
    init?(refreshInterval: Int?, nextRefreshAt: Date?) {
        switch refreshInterval {
        case nil: return nil
        case 0: self = .manual
        default:
            guard let nextRefreshAt else { return nil }
            self = .next(nextRefreshAt)
        }
    }
}

public struct StatusBarMenuSnapshot: Equatable, Sendable {
    let providers: [StatusBarMenuProviderSnapshot]
    let hostWarning: StatusBarMenuQuotaWarning?
    let selectedProvider: QuotaProvider?
    let isLoadingQuotas: Bool
    let canRefresh: Bool
    let refreshSchedule: StatusBarRefreshSchedule?
    let displaySettings: StatusBarMenuDisplaySettings
    let language: AppLanguage

    /// What `StatusBarMenuRenderer.buildMenu` turns into items; anything else updates in place.
    struct Layout: Equatable {
        struct Card: Equatable {
            let id: QuotaAccountID
            let hasQuota: Bool
            let hasDetail: Bool
        }
        struct Section: Equatable {
            let provider: QuotaProvider
            let cards: [Card]
            let hasWarning: Bool
        }
        let sections: [Section]
        let quotaDisplayStyle: QuotaDisplayStyle
    }

    @MainActor var layout: Layout {
        Layout(
            sections: providers.map { provider in
                Layout.Section(
                    provider: provider.provider,
                    cards: provider.accounts.map {
                        Layout.Card(id: $0.id, hasQuota: $0.quota != nil, hasDetail: $0.hasDetail)
                    },
                    hasWarning: provider.warning != nil
                )
            },
            quotaDisplayStyle: displaySettings.quotaDisplayStyle
        )
    }
}

public enum StatusBarMenuSnapshotMapper {
    nonisolated public static func makeSnapshot(
        monitorAccounts: [Account],
        quota: QuotaSnapshot,
        menuBarPreferences: MenuBarPreferences,
        language: AppLanguage,
        trackingPreferences: ProviderTrackingPreferences = ProviderTrackingPreferences(),
        refreshInterval: Int? = nil,
        nextRefreshAt: Date? = nil
    ) -> StatusBarMenuSnapshot {
        let disabledAccounts = Set(monitorAccounts.lazy.filter(\.isDisabled).map {
            "\($0.providerID.rawValue):\($0.accountKey)"
        })
        let accountProviders = quota.accountIssues.keys.map(\.provider)
        let failedProviders = quota.accountStates.compactMap { id, state -> QuotaProvider? in
            if case .failed = state.quota { return id.provider }
            return nil
        }
        let candidates = Set(quota.quotas.keys).union(quota.issues.keys)
            .union(accountProviders).union(failedProviders)
        let availableProviders = candidates.filter { provider in
            guard trackingPreferences.isEnabled(provider) else { return false }
            let hasQuota = quota.quotas[provider]?.contains { accountKey, _ in
                !disabledAccounts.contains("\(provider.rawValue):\(accountKey)")
            } ?? false
            let knownAccounts = monitorAccounts.filter { $0.providerID.rawValue == provider.rawValue }
            let hasIssue = quota.issues[provider] != nil || accountProviders.contains(provider)
                || failedProviders.contains(provider)
            return hasQuota || (hasIssue && (knownAccounts.isEmpty || knownAccounts.contains { !$0.isDisabled }))
        }

        func displayName(_ provider: QuotaProvider) -> String { quota.providerNames[provider] ?? provider.displayName }
        let providers = availableProviders.sorted { displayName($0) < displayName($1) }.map { provider in
            let metricAccounts = orderedAccounts(
                (quota.quotas[provider] ?? [:]).filter { accountKey, _ in
                    !disabledAccounts.contains("\(provider.rawValue):\(accountKey)")
                }
            ).map { account in
                let accountID = QuotaAccountID(provider: provider, accountKey: account.accountKey)
                return StatusBarMenuAccountSnapshot(
                    id: accountID,
                    email: account.email,
                    quota: account.data,
                    subscription: quota.subscriptions[provider]?[account.accountKey],
                    warning: StatusBarMenuQuotaWarning.resolve(accountID: accountID, in: quota),
                    isRefreshing: quota.refreshingProviders.contains(provider),
                    isRefreshBlocked: !quota.canRefresh || quota.refreshingProviders.contains(provider)
                )
            }
            let warningAccounts = Set(quota.accountStates.keys).union(quota.accountIssues.keys)
                .filter {
                    $0.provider == provider && quota.quotas[provider]?[$0.accountKey] == nil
                        && !disabledAccounts.contains("\(provider.rawValue):\($0.accountKey)")
                }
                .compactMap { id -> StatusBarMenuAccountSnapshot? in
                    guard let warning = StatusBarMenuQuotaWarning.resolve(accountID: id, in: quota) else { return nil }
                    let label = monitorAccounts.first {
                        $0.providerID.rawValue == provider.rawValue && $0.accountKey == id.accountKey
                    }?.displayName ?? id.accountKey
                    return StatusBarMenuAccountSnapshot(
                        id: id, email: label, quota: nil, subscription: quota.subscriptions[provider]?[id.accountKey],
                        warning: warning, isRefreshing: quota.refreshingProviders.contains(provider),
                        isRefreshBlocked: !quota.canRefresh || quota.refreshingProviders.contains(provider)
                    )
                }
            let accounts = (metricAccounts + warningAccounts).sorted {
                if $0.email == $1.email { return $0.id.accountKey < $1.id.accountKey }
                return $0.email.localizedStandardCompare($1.email) == .orderedAscending
            }
            let warning = quota.issues[provider].flatMap { issue in
                accounts.contains { $0.warning?.issue == issue } ? nil
                    : StatusBarMenuQuotaWarning(state: .failed(issue.reason), issue: issue, lastSuccessfulUpdate: nil)
            }
            return StatusBarMenuProviderSnapshot(
                displayName: displayName(provider),
                provider: provider,
                accounts: accounts,
                warning: warning,
                isRefreshing: quota.refreshingProviders.contains(provider),
                supportsScopedRefresh: quota.canRefresh
            )
        }

        return StatusBarMenuSnapshot(
            providers: providers,
            hostWarning: quota.hostIssue.map {
                StatusBarMenuQuotaWarning(state: .failed($0.reason), issue: $0, lastSuccessfulUpdate: nil)
            },
            selectedProvider: menuBarPreferences.selectedProvider.flatMap { selected in
                providers.contains(where: { $0.provider == selected }) ? selected : nil
            },
            isLoadingQuotas: !quota.refreshingProviders.isEmpty,
            canRefresh: quota.canRefresh,
            refreshSchedule: StatusBarRefreshSchedule(refreshInterval: refreshInterval, nextRefreshAt: nextRefreshAt),
            displaySettings: StatusBarMenuDisplaySettings(
                quotaDisplayMode: menuBarPreferences.quotaDisplayMode,
                quotaDisplayStyle: menuBarPreferences.quotaDisplayStyle,
                hideSensitiveInfo: menuBarPreferences.hideSensitiveInfo,
                modelAggregationMode: menuBarPreferences.modelAggregationMode
            ),
            language: language
        )
    }

    nonisolated static func orderedAccounts(
        _ quotas: [String: ProviderQuota]
    ) -> [(accountKey: String, email: String, data: ProviderQuota)] {
        quotas.map { (accountKey: $0.key, email: $0.value.accountDisplayName ?? $0.key, data: $0.value) }
            .sorted {
                if $0.email == $1.email { return $0.accountKey < $1.accountKey }
                return $0.email.localizedStandardCompare($1.email) == .orderedAscending
            }
    }
}
