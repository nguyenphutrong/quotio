import QuotioApplication
import QuotioDomain

struct OnboardingProviderOverview: Sendable {
    struct FoundProvider: Identifiable, Sendable {
        enum Issue: Equatable, Sendable {
            case permissionRequired
            case signInRequired
            case quotaFailed
        }

        let state: ProviderSettingsState
        let name: String

        var id: QuotaProvider { state.provider }
        var accountCount: Int { state.accounts.count }

        var connectionIssue: Issue? {
            if !state.permissions.isEmpty || state.connection == .permissionRequired { return .permissionRequired }
            if state.connection == .reauthenticationRequired || state.accounts.isEmpty { return .signInRequired }
            return nil
        }

        var issue: Issue? {
            if let connectionIssue { return connectionIssue }
            if case .failed = quotaState { return .quotaFailed }
            return nil
        }

        var hasQuota: Bool { quotaState == .fresh || quotaState == .stale }

        var quotaState: QuotaRefreshState? {
            let states = state.accounts.filter { !$0.isDisabled }.compactMap { state.accountStates[$0.id]?.quota }
            if states.contains(.fresh) { return .fresh }
            if states.contains(.refreshing) { return .refreshing }
            if states.contains(.stale) { return .stale }
            if let failed = states.first(where: { if case .failed = $0 { true } else { false } }) { return failed }
            return states.isEmpty ? nil : .notLoaded
        }
    }

    struct ConnectableProvider: Identifiable, Sendable {
        let provider: QuotaProvider
        let name: String
        let supportsBrowserSignIn: Bool
        let supportsAPIKey: Bool
        let inputs: [MonitoringProvider.Input]

        var id: QuotaProvider { provider }
    }

    let found: [FoundProvider]
    let connectable: [ConnectableProvider]
    let pendingPermissions: [NativeSourcePermission]
    let hasStorageProblem: Bool
    private let authorizableProviders: Set<QuotaProvider>
    private let names: [QuotaProvider: String]

    var needsAccess: Bool { hasStorageProblem || !pendingPermissions.isEmpty }
    var readyProviders: [FoundProvider] { found.filter { $0.issue == nil && $0.hasQuota } }
    var loadingProviders: [FoundProvider] { found.filter { $0.issue == nil && !$0.hasQuota && $0.quotaState != nil } }
    var attentionProviders: [FoundProvider] { found.filter { $0.issue != nil } }

    init(
        providers: [MonitoringProvider],
        accounts: [Account],
        permissions: [NativeSourcePermission],
        quota: QuotaSnapshot,
        tracking: ProviderTrackingPreferences,
        hasStorageProblem: Bool
    ) {
        let tracked = providers.filter { tracking.isEnabled($0.id) }
        let states = tracked.map { descriptor in
            (descriptor, ProviderSettingsState(
                provider: descriptor.id, accounts: accounts, permissions: permissions,
                quota: quota, tracking: tracking
            ))
        }
        found = states.filter { !$0.1.isUnconnected }
            .map { FoundProvider(state: $0.1, name: $0.0.displayName) }
            .sorted {
                if $0.state.needsAttention != $1.state.needsAttention { return $0.state.needsAttention }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        connectable = states.filter { descriptor, state in
            state.isUnconnected && (descriptor.actions.contains("start_oauth") || descriptor.actions.contains("add_api_key"))
        }
        .map { descriptor, _ in
            ConnectableProvider(
                provider: descriptor.id,
                name: descriptor.displayName,
                supportsBrowserSignIn: descriptor.actions.contains("start_oauth"),
                supportsAPIKey: descriptor.actions.contains("add_api_key"),
                inputs: descriptor.inputs
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let trackedIDs = Set(tracked.map(\.id))
        pendingPermissions = permissions.filter { trackedIDs.contains($0.provider) }
        authorizableProviders = Set(tracked.filter { $0.actions.contains("authorize_native") }.map(\.id))
        names = Dictionary(providers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        self.hasStorageProblem = hasStorageProblem
    }

    func canAuthorize(_ permission: NativeSourcePermission) -> Bool {
        authorizableProviders.contains(permission.provider)
    }

    func name(for provider: QuotaProvider) -> String {
        names[provider] ?? provider.displayName
    }
}
