import Foundation
import QuotioApplication
import QuotioDomain

/// Display state for one account row. Issues are resolved per account and per login
/// source so that one failing login never marks sibling accounts as broken.
struct AccountSettingsRowState: Equatable {
    enum Tone: Equatable {
        case connected
        case attention
        case inactive
        case unchecked
    }

    let tone: Tone
    let connection: ConnectionState
    let quota: QuotaRefreshState
    let issue: QuotaRefreshIssue?
    let issueSourceID: String?
    let activeSourceID: String?
    let plan: String?
    /// Distinct kinds of the account's login sources, in source order.
    let sourceKinds: [AccountSource]

    var needsAttention: Bool { tone == .attention }

    init(account: Account, provider: QuotaProvider, snapshot: QuotaSnapshot, tracked: Bool) {
        let id = QuotaAccountID(provider: provider, accountKey: account.accountKey)
        let monitoring = snapshot.accountStates[id] ?? AccountMonitoringState(connection: .notConnected, quota: .notLoaded)
        let activeSourceID = snapshot.accountIDs[provider]?[account.accountKey]
        connection = monitoring.connection
        quota = monitoring.quota
        self.activeSourceID = activeSourceID
        plan = [snapshot.quotas[provider]?[account.accountKey]?.planType,
                snapshot.subscriptions[provider]?[account.accountKey]?.effectiveTier?.name]
            .compactMap { $0 }.first { !$0.isEmpty }
        sourceKinds = account.sources.map(\.source).reduce(into: []) { kinds, kind in
            if !kinds.contains(kind) { kinds.append(kind) }
        }

        guard tracked, !account.isDisabled else {
            tone = .inactive
            issue = nil
            issueSourceID = nil
            return
        }

        var candidates: [(sourceID: String?, issue: QuotaRefreshIssue)] = []
        if case .failed = monitoring.quota, let issue = snapshot.accountIssues[id] {
            candidates.append((activeSourceID, issue))
        }
        let sourceIssues = snapshot.sourceIssues[provider] ?? [:]
        for source in account.sources where source.enabled != false {
            if let issue = sourceIssues[source.accountID] { candidates.append((source.accountID, issue)) }
        }
        let latest = candidates.max { $0.issue.occurredAt < $1.issue.occurredAt }
        issue = latest?.issue
        issueSourceID = latest?.sourceID

        if latest != nil || monitoring.connection == .permissionRequired || monitoring.connection == .reauthenticationRequired {
            tone = .attention
        } else if case .failed = monitoring.quota {
            tone = .attention
        } else if monitoring.connection == .connected {
            tone = .connected
        } else {
            tone = .unchecked
        }
    }
}

extension Date {
    /// Time only for today, so the common case stays short in a one-line caption;
    /// older stamps drop the year to fit narrow layouts.
    var accountsSettingsTimestamp: String {
        Calendar.current.isDateInToday(self)
            ? formatted(date: .omitted, time: .shortened)
            : formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// Attention facts for one provider: the sidebar badge count and any provider-wide failure.
struct ProviderAccountsSummary: Equatable {
    let attentionCount: Int
    /// A provider-wide failure that is newer than every successful account refresh.
    let providerIssue: QuotaRefreshIssue?

    init(state: ProviderSettingsState, snapshot: QuotaSnapshot, tracked: Bool) {
        let updated = snapshot.quotas[state.provider]?.values.map(\.lastUpdated).max()
        guard tracked else {
            attentionCount = 0
            providerIssue = nil
            return
        }
        let rowAttention = state.accounts.filter {
            AccountSettingsRowState(account: $0, provider: state.provider, snapshot: snapshot, tracked: tracked).needsAttention
        }.count
        let unidentifiedSources = state.accountsNeedingIdentification.reduce(0) { $0 + $1.sources.count }
        if let issue = snapshot.issues[state.provider], !state.isUnconnected,
           updated.map({ issue.occurredAt > $0 }) ?? true {
            providerIssue = issue
        } else {
            providerIssue = nil
        }
        attentionCount = rowAttention + state.permissions.count + unidentifiedSources + (providerIssue == nil ? 0 : 1)
    }

    static func totalAttention(
        providers: [MonitoringProvider], accounts: [Account], permissions: [NativeSourcePermission],
        snapshot: QuotaSnapshot, tracking: ProviderTrackingPreferences
    ) -> Int {
        providers.reduce(0) { total, descriptor in
            let state = ProviderSettingsState(provider: descriptor.id, accounts: accounts, permissions: permissions,
                quota: snapshot, tracking: tracking)
            return total + Self(state: state, snapshot: snapshot, tracked: tracking.isEnabled(descriptor.id)).attentionCount
        }
    }
}
