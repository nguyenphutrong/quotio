import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class QuotaFeatureController {
    enum OAuthLaunchMode {
        case manual
        case autoOpen
    }

    let quota: QuotaScreenModel
    let accounts: AccountsScreenModel
    let oauth: OAuthScreenModel
    let antigravityAccounts: AntigravityAccountScreenModel

    @ObservationIgnored private let modeManager: OperatingModeManager
    @ObservationIgnored private let refreshSettings: RefreshSettingsManager
    @ObservationIgnored private let menuBarSettings: MenuBarSettingsManager
    @ObservationIgnored private let notifications: any NotificationRequesting
    @ObservationIgnored private var authFiles: () -> [ManagedAuthFile]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var didChangeHandler: (@MainActor () -> Void)?

    private static let localProxyProviders: Set<QuotaProvider> = [
        .claude, .codex, .antigravity, .kiro, .copilot, .glm, .warp, .clinePass,
    ]

    private static let monitorProviders: Set<QuotaProvider> = [
        .claude, .codex, .antigravity, .kiro, .copilot, .factoryDroid,
        .devin, .grok, .openRouter, .amp, .glm, .warp, .clinePass,
    ]

    static func automaticallyRefreshedProviders(for mode: QuotaOperatingMode) -> Set<QuotaProvider> {
        switch mode {
        case .localProxy: localProxyProviders
        case .monitor: monitorProviders
        }
    }

    public init(
        quota: QuotaScreenModel,
        accounts: AccountsScreenModel,
        oauth: OAuthScreenModel,
        antigravityAccounts: AntigravityAccountScreenModel,
        modeManager: OperatingModeManager,
        refreshSettings: RefreshSettingsManager,
        menuBarSettings: MenuBarSettingsManager,
        notifications: any NotificationRequesting,
        authFiles: @escaping () -> [ManagedAuthFile]
    ) {
        self.quota = quota
        self.accounts = accounts
        self.oauth = oauth
        self.antigravityAccounts = antigravityAccounts
        self.modeManager = modeManager
        self.refreshSettings = refreshSettings
        self.menuBarSettings = menuBarSettings
        self.notifications = notifications
        self.authFiles = authFiles
        refreshSettings.addCadenceChangeHandler { [weak self] _ in
            self?.restartAutomaticRefresh()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var operatingMode: QuotaOperatingMode {
        modeManager.isMonitorMode ? .monitor : .localProxy
    }

    var oauthState: QuotaOAuthState? { QuotaOAuthState(oauth.state) }

    public func setAuthFilesProvider(_ provider: @escaping () -> [ManagedAuthFile]) {
        authFiles = provider
    }

    public func setDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        didChangeHandler = handler
    }

    public func initialize() async {
        await quota.bootstrap(mode: operatingMode)
        await accounts.reloadAuthFiles()
        await reloadAccounts()
        await refreshAll()
        restartAutomaticRefresh()
    }

    public func refreshAll(force: Bool = false) async {
        await quota.refreshAll(
            mode: operatingMode,
            providers: Self.automaticallyRefreshedProviders(for: operatingMode),
            force: force
        )
        await refreshImportedIDEQuotas()
        await antigravityAccounts.detectActiveAccount()
        await finishRefresh()
    }

    public func refresh(provider: QuotaProvider, force: Bool = true) async {
        guard provider.supportsQuotaOnlyMode else { return }
        await quota.refresh(provider: provider, mode: operatingMode, force: force)
        if provider == .antigravity {
            await antigravityAccounts.detectActiveAccount()
        }
        await finishRefresh()
    }

    public func refresh(account: QuotaAccountID) async {
        guard account.provider.supportsQuotaOnlyMode else { return }
        await quota.refresh(
            provider: account.provider,
            scope: .account(account.accountKey),
            mode: operatingMode,
            force: true
        )
        await finishRefresh()
    }

    func refreshAutoDetectedProviders() async {
        let providers = Self.automaticallyRefreshedProviders(for: operatingMode).filter {
            !$0.supportsManualAuth && !$0.isImportedFromLocalIDE
        }
        await quota.refreshAll(mode: operatingMode, providers: Set(providers), force: true)
        await finishRefresh()
    }

    func refreshImportedIDEQuotas() async {
        for provider in [QuotaProvider.cursor, .trae] {
            let keys = Set(quota.providerQuotas[provider]?.keys.map { $0 } ?? [])
            guard !keys.isEmpty else { continue }
            await quota.refresh(
                provider: provider,
                scope: .importedAccounts(keys),
                mode: operatingMode,
                force: true
            )
        }
    }

    func importIDEProvider(_ provider: QuotaProvider) async -> [String: ProviderQuota] {
        guard provider.isImportedFromLocalIDE else { return [:] }
        await quota.refresh(provider: provider, mode: operatingMode, force: true)
        await finishRefresh()
        return quota.providerQuotas[provider] ?? [:]
    }

    func remove(account: QuotaAccountID) async {
        if let storedAccount = accounts.accounts.first(where: {
            $0.providerID.rawValue == account.provider.rawValue && $0.accountKey == account.accountKey
        }), storedAccount.canDelete {
            if storedAccount.source == .localIDE {
                await accounts.setDisabled(false, accountID: storedAccount.id)
            } else {
                try? await accounts.delete(accountID: storedAccount.id)
            }
        }
        await quota.removeQuota(for: account, mode: operatingMode)
        await finishRefresh()
    }

    func setAccountDisabled(_ disabled: Bool, accountID: String) async {
        let account = accounts.accounts.first { $0.id == accountID }
        await accounts.setDisabled(disabled, accountID: accountID)
        if disabled, let account, let provider = QuotaProvider(rawValue: account.providerID.rawValue) {
            await quota.removeQuota(
                for: QuotaAccountID(provider: provider, accountKey: account.accountKey),
                mode: operatingMode
            )
        }
        await finishRefresh()
    }

    func saveAPIKey(
        provider: QuotaProvider,
        label: String,
        apiKey: String,
        existingAccountID: String? = nil
    ) async throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedKey.isEmpty else {
            throw QuotaCredentialInputError.invalidCredential
        }
        guard provider != .amp
            || trimmedLabel.caseInsensitiveCompare(ProviderAccountKey.ampNative) != .orderedSame else {
            throw QuotaCredentialInputError.invalidCredential
        }

        let previousAccount = existingAccountID.flatMap { id in
            accounts.accounts.first { $0.id == id && $0.providerID.rawValue == provider.rawValue }
        }
        do {
            try await accounts.saveAPIKey(
                providerID: AccountProviderID(rawValue: provider.rawValue),
                label: trimmedLabel,
                apiKey: trimmedKey,
                existingAccountID: existingAccountID
            )
        } catch is AccountServiceFailure {
            throw QuotaCredentialInputError.invalidCredential
        }
        if let previousAccount, previousAccount.accountKey != trimmedLabel {
            await quota.removeQuota(
                for: QuotaAccountID(provider: provider, accountKey: previousAccount.accountKey),
                mode: operatingMode
            )
        }
        await refresh(provider: provider)
    }

    func startOAuth(
        for provider: QuotaProvider,
        method: OAuthAuthorizationMethod = .providerDefault,
        launchMode: OAuthLaunchMode = .manual
    ) async {
        await oauth.start(OAuthAuthorizationRequest(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            method: method,
            automaticallyOpensBrowser: launchMode == .autoOpen
        ))
    }

    func completeMonitorOAuthCode(_ code: String, provider: QuotaProvider) async {
        guard modeManager.isMonitorMode, provider == .claude else { return }
        await oauth.completeManualCode(code)
    }

    func cancelOAuth() {
        Task { await oauth.cancel() }
    }

    func monitorStatus(for account: Account) -> (status: String?, message: String?) {
        guard let provider = QuotaProvider(rawValue: account.providerID.rawValue) else { return (nil, nil) }
        let accountID = QuotaAccountID(provider: provider, accountKey: account.accountKey)
        let updated = QuotaPolicy.lastUpdated(for: accountID, in: quota.providerQuotas)
        if let issue = quota.state.accountIssues[accountID], updated == nil || updated! <= issue.occurredAt {
            return ("outdated", message(for: issue))
        }
        if let issue = quota.state.issues[provider], updated == nil || updated! <= issue.occurredAt {
            return ("outdated", message(for: issue))
        }
        guard let updated else { return (nil, nil) }
        let staleAfter = refreshSettings.refreshCadence.intervalSeconds ?? 600
        if Date().timeIntervalSince(updated) > staleAfter {
            return (
                "outdated",
                String(format: "monitor.status.outdated".localized(), updated.formatted(date: .abbreviated, time: .shortened))
            )
        }
        return (
            "ready",
            String(format: "monitor.status.updated".localized(), updated.formatted(date: .omitted, time: .shortened))
        )
    }

    func synchronizeMenuBarSelection() {
        var available: [MenuBarQuotaItem] = []
        var seen = Set<String>()
        for (provider, quotas) in quota.providerQuotas {
            for key in quotas.keys {
                let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: key)
                if seen.insert(item.id).inserted { available.append(item) }
            }
        }
        for file in authFiles() {
            guard let provider = file.providerID else { continue }
            let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: file.menuBarAccountKey)
            if seen.insert(item.id).inserted { available.append(item) }
        }
        for file in accounts.authFiles {
            guard let provider = QuotaProvider(rawValue: file.providerID.rawValue) else { continue }
            let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: file.menuBarAccountKey)
            if seen.insert(item.id).inserted { available.append(item) }
        }
        menuBarSettings.pruneInvalidItems(validItems: available)
        menuBarSettings.autoSelectNewAccounts(availableItems: available)
    }

    public func shutdown() async {
        refreshTask?.cancel()
        refreshTask = nil
        await quota.shutdown()
        await oauth.shutdown()
    }

    private func finishRefresh() async {
        await reloadAccounts()
        checkQuotaNotifications()
        synchronizeMenuBarSelection()
        didChangeHandler?()
    }

    private func reloadAccounts() async {
        await accounts.reloadAccounts(merging: quota.providerQuotas)
    }

    private func restartAutomaticRefresh() {
        refreshTask?.cancel()
        guard let interval = refreshSettings.refreshCadence.intervalNanoseconds else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    private func checkQuotaNotifications() {
        let threshold = notifications.snapshot.preferences.quotaAlertThreshold
        for (provider, accountQuotas) in quota.providerQuotas {
            for (account, data) in accountQuotas {
                let values = data.models.map(\.percentage).filter { $0 >= 0 }
                guard let minimum = values.min() else { continue }
                if minimum <= threshold {
                    notifications.submit(.quotaLow(
                        provider: provider.displayName,
                        account: account,
                        remainingPercent: minimum
                    ))
                } else {
                    notifications.clearQuotaNotification(
                        provider: provider.rawValue,
                        account: account
                    )
                }
            }
        }
    }

    private func message(for issue: QuotaRefreshIssue) -> String {
        switch issue.kind {
        case .failed: "monitor.refresh.failed".localized()
        case .partial: "monitor.refresh.partial".localized()
        }
    }
}

private enum QuotaCredentialInputError: LocalizedError {
    case invalidCredential

    var errorDescription: String? {
        "The Monitor credential file is invalid."
    }
}

struct QuotaOAuthState: Identifiable, Equatable {
    let provider: QuotaProvider
    var status: OAuthStatus
    var state: String?
    var error: String?
    var authURL: String?

    @MainActor
    init?(_ flowState: OAuthFlowState) {
        let providerID: AccountProviderID
        let prompt: OAuthPrompt?
        switch flowState {
        case .idle:
            return nil
        case .authorizing(let id):
            providerID = id
            prompt = nil
            status = .waiting
        case .awaitingUser(let id, let value):
            providerID = id
            prompt = value
            status = .polling
        case .awaitingManualCode(let id, let value, let manualState):
            providerID = id
            prompt = value
            state = manualState
            status = .polling
        case .succeeded(let id, _):
            providerID = id
            prompt = nil
            status = .success
        case .failed(let id, let failure):
            providerID = id
            prompt = nil
            status = .error
            error = failure.displayMessage
        }
        guard let provider = QuotaProvider(rawValue: providerID.rawValue) else { return nil }
        self.provider = provider
        state = state ?? prompt?.userCode
        authURL = prompt?.authorizationURL?.absoluteString
        if error == nil {
            error = prompt?.message
                ?? prompt?.userCode.map { String(format: "oauth.enterDeviceCode".localizedStatic(), $0) }
        }
    }

    var id: String { provider.rawValue }

    enum OAuthStatus {
        case waiting, polling, success, error
    }
}

private extension OAuthFlowFailure {
    var displayMessage: String {
        switch self {
        case .unsupportedProvider:
            "Quotio-managed login is not available for this provider."
        case .invalidResponse:
            "The OAuth provider returned an invalid response."
        case .expired:
            "The device authorization expired. Please try again."
        case .stateMismatch:
            "The OAuth callback state did not match the login request."
        case .browserOpenFailed:
            "Quotio could not open the OAuth page in your browser."
        case .provider(let message):
            message
        case .unknown:
            "The OAuth request failed. Please try again."
        }
    }
}
