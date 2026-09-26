import QuotioHostClient
import Foundation
import CryptoKit
import QuotioApplication
import QuotioDomain

public actor QuotioCLIBackend: AccountManaging, QuotaCoordinating, MonitoringSettingsManaging {
    private struct Empty: Decodable, Sendable {}
    private struct RefreshBody: Encodable {
        let providers: [String]
        let accountId: String?
        let force: Bool
    }
    private struct EnabledBody: Encodable { let enabled: Bool }
    private struct NativeSourceBody: Encodable {
        let kind: String
        let location: String?
        let entryKey: String?
    }
    public private(set) var snapshot = QuotaSnapshot()
    private var client: QuotioHostHTTPClient?
    private var reportedAccounts: [Account] = []
    private var hostSnapshot: QuotioHostSnapshot?
    private var connectionID = UUID()
    private var snapshotRequestID = UUID()
    private var activeMode: QuotaOperatingMode = .monitor
    private var continuations: [UUID: AsyncStream<QuotaSnapshot>.Continuation] = [:]
    private let logger: (any ApplicationLogging)?
    private let session: URLSession?
    private let localization: @MainActor @Sendable () -> (bundle: Bundle, locale: Locale)
    private var storageRequiresAuthorization = false
    private var discoveryState: QuotioHostDiscovery?

    public init(
        session: URLSession? = nil,
        logger: (any ApplicationLogging)? = nil,
        localization: @escaping @MainActor @Sendable () -> (bundle: Bundle, locale: Locale) = { (.main, .current) }
    ) {
        self.session = session
        self.logger = logger
        self.localization = localization
    }

    public func connect(_ connection: QuotioHostConnection) {
        connectionID = UUID()
        hostSnapshot = nil
        discoveryState = nil
        reportedAccounts = []
        snapshot = QuotaSnapshot()
        client = QuotioHostHTTPClient(connection: connection, session: session)
    }

    public func disconnect() {
        connectionID = UUID()
        client = nil
        markFailure(for: knownProviders)
    }

    public func states() -> AsyncStream<QuotaSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func bootstrap(mode: QuotaOperatingMode) async -> QuotaSnapshot {
        selectMode(mode)
        await loadSnapshot(mode: mode)
        return snapshot
    }

    public func refresh(_ request: QuotaFetchRequest) async -> QuotaSnapshot {
        selectMode(request.mode)
        let provider = request.provider.rawValue
        var resolvedAccountID: String?
        if case .account(let accountKey) = request.scope {
            resolvedAccountID = await accountID(provider: provider, accountKey: accountKey)
            guard resolvedAccountID != nil else {
                markFailure(for: [request.provider])
                return snapshot
            }
        }
        let importedAccounts: Set<String>? = if case .importedAccounts(let keys) = request.scope { keys } else { nil }
        await performRefresh(
            providers: [provider],
            accountID: resolvedAccountID,
            mode: request.mode,
            force: request.force,
            importedAccounts: importedAccounts
        )
        return snapshot
    }

    public func refreshAll(
        mode: QuotaOperatingMode,
        providers: Set<QuotaProvider>? = nil,
        force: Bool = false
    ) async -> QuotaSnapshot {
        selectMode(mode)
        let selected = providers?.map(\.rawValue) ?? []
        await performRefresh(providers: selected, accountID: nil, mode: mode, force: force)
        return snapshot
    }

    public func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) {
        snapshot.quotas[account.provider]?[account.accountKey] = nil
        snapshot.accountIDs[account.provider]?[account.accountKey] = nil
        snapshot.accountAliases[account.provider]?.filter { $0.value == account.accountKey }
            .forEach { snapshot.accountAliases[account.provider]?[$0.key] = nil }
        snapshot.subscriptions[account.provider]?[account.accountKey] = nil
        snapshot.accountIssues[account] = nil
        snapshot.accountStates[account] = nil
        publish()
    }

    public func cancel(provider: QuotaProvider) {
        snapshot.refreshingProviders.remove(provider)
        publish()
    }

    public func cancelForTermination() {
        snapshot.refreshingProviders.removeAll()
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    public func registerDetectedNativeAccounts() async {
        await discoverNativeAccounts(providerID: nil)
    }

    private func discoverNativeAccounts(providerID: String?, restoreRemoved: Bool = false) async {
        guard let client else { return }
        let providers = providerID.map { [$0] } ?? []
        do {
            let body = try JSONSerialization.data(withJSONObject: ["providers": providers, "restore_removed": restoreRemoved])
            try await mutate(client: client, path: "v2/discovery", method: "POST", body: body, timeout: .seconds(180))
            _ = try await readDiscovery()
        } catch {
            if Self.failureCategory(error) == "account_storage" { storageRequiresAuthorization = true }
            await logger?.write(.warning, message: "Native discovery failed=\(Self.failureCategory(error))")
        }
    }

    private func readDiscovery() async throws -> QuotioHostDiscovery {
        guard let client else { throw QuotioHostClientError.disconnected }
        let epoch = connectionID
        let report: QuotioHostDiscovery = try await client.request("v2/discovery")
        guard connectionID == epoch else { throw QuotioHostClientError.disconnected }
        guard report.schemaVersion == 2 else { throw QuotioHostClientError.incompatible }
        discoveryState = report
        return report
    }

    public func rescanNativeAccounts(for provider: QuotaProvider) async {
        let id = provider.rawValue
        await discoverNativeAccounts(providerID: id, restoreRemoved: true)
    }

    public func rescanAllNativeAccounts() async {
        await discoverNativeAccounts(providerID: nil, restoreRemoved: true)
    }

    public func nativeDiscoverySnapshot() async -> NativeDiscoverySnapshot {
        let report = (try? await readDiscovery()) ?? discoveryState
        return .init(
            permissions: (report?.permissions ?? []).compactMap(Self.permission),
            knownSources: (report?.knownSources ?? []).compactMap(Self.permission),
            scannedAt: Dictionary((report?.scans ?? []).compactMap { scan in
                QuotaProvider(rawValue: scan.provider).map { ($0, scan.at) }
            }, uniquingKeysWith: { _, latest in latest }),
            failedProviders: Set((report?.failures ?? []).compactMap { QuotaProvider(rawValue: $0.provider) })
        )
    }

    private static func permission(_ value: QuotioHostDiscovery.Permission) -> NativeSourcePermission? {
        guard let provider = QuotaProvider(rawValue: value.provider) else { return nil }
        return .init(provider: provider, kind: value.kind, location: value.location, keychainAccount: value.keychainAccount)
    }

    public func authorizeNativeSource(_ source: NativeSourcePermission) async throws {
        guard let client else { throw QuotioHostClientError.disconnected }
        let body = try JSONEncoder.quotioCLI.encode(NativeSourceBody(kind: source.kind, location: source.location, entryKey: source.keychainAccount))
        do {
            try await mutate(
                client: client,
                path: "v2/sources/authorize",
                method: "POST",
                body: body,
                idempotencyKey: "quotio-native-permission-" + UUID().uuidString,
                timeout: .seconds(300)
            )
        } catch {
            switch error {
            case QuotioHostClientError.response(_, "quotio_vault_access_failed"),
                 QuotioHostClientError.response(_, "credential_storage_unavailable"):
                throw NativeSourceAuthorizationFailure.quotioVault
            case QuotioHostClientError.response(_, "native_keychain_access_failed"):
                throw NativeSourceAuthorizationFailure.nativeKeychain
            case QuotioHostClientError.response(_, "native_login_required"):
                throw NativeSourceAuthorizationFailure.nativeLogin
            case QuotioHostClientError.response(_, "native_credential_invalid"):
                throw NativeSourceAuthorizationFailure.invalidCredential
            case QuotioHostClientError.timeout:
                throw NativeSourceAuthorizationFailure.timeout
            default:
                throw NativeSourceAuthorizationFailure.unknown
            }
        }
        await discoverNativeAccounts(providerID: source.provider.rawValue)
    }

    public func accountStorageRequiresAuthorization() async -> Bool { storageRequiresAuthorization }

    public func authorizeAccountStorage() async throws {
        guard let client else { throw NativeSourceAuthorizationFailure.unknown }
        do {
            try await mutate(client: client, path: "v2/account-vault/authorize", method: "POST", body: Data("{}".utf8), timeout: .seconds(300))
            storageRequiresAuthorization = false
            await registerDetectedNativeAccounts()
        } catch {
            throw NativeSourceAuthorizationFailure.quotioVault
        }
    }

    public func accounts() async -> [Account] {
        await loadSnapshot(mode: activeMode)
        return reportedAccounts
    }

    func resolvedAccounts() async throws -> QuotioHostAccountList {
        guard let client else { throw QuotioHostClientError.disconnected }
        let result: QuotioHostAccountList = try await client.request("v2/accounts")
        guard result.schemaVersion == 2, result.host.apiVersions.contains(2) else {
            throw QuotioHostClientError.incompatible
        }
        return result
    }

    func resolvedAccount(id: String) async throws -> Account {
        guard let client else { throw QuotioHostClientError.disconnected }
        let value: QuotioHostSnapshot.Account = try await client.request(QuotioHostAccountTarget.account(id).path)
        guard let account = Self.resolvedAccount(value) else { throw QuotioHostClientError.incompatible }
        return account
    }

    public func renameResolvedAccount(id: String, userLabel: String?) async throws {
        guard let client else { throw QuotioHostClientError.disconnected }
        let body = try JSONSerialization.data(withJSONObject: ["user_label": userLabel.map { $0 as Any } ?? NSNull()])
        try await mutate(client: client, path: QuotioHostAccountTarget.account(id).path, method: "PATCH", body: body)
    }

    public func setSourceEnabled(_ enabled: Bool, sourceID: String) async throws {
        try await setResolvedEnabled(enabled, target: .source(sourceID))
    }

    public func unlinkSource(sourceID: String) async throws {
        try await removeResolved(.source(sourceID))
    }

    func setResolvedEnabled(_ enabled: Bool, target: QuotioHostAccountTarget) async throws {
        guard let client else { throw QuotioHostClientError.disconnected }
        let body = try JSONEncoder.quotioCLI.encode(EnabledBody(enabled: enabled))
        try await mutate(client: client, path: target.path, method: "PATCH", body: body)
    }

    func removeResolved(_ target: QuotioHostAccountTarget) async throws {
        guard let client else { throw QuotioHostClientError.disconnected }
        try await mutate(client: client, path: target.path, method: "DELETE", body: nil)
    }

    public func importLegacyAccount(_ account: Account, credential: StoredCredential, disabled: Bool) async throws {
        guard let client else { throw QuotioHostClientError.disconnected }
        struct Import: Encodable {
            let legacyId: String
            let provider: String
            let label: String
            let enabled: Bool
            let credential: StoredCredential
        }
        guard let domainProvider = QuotaProvider(rawValue: canonicalLegacyMacProviderID(account.providerID.rawValue)) else {
            throw QuotioHostClientError.incompatible
        }
        let provider = domainProvider.rawValue
        var credential = credential
        if domainProvider == .antigravity {
            let parameters = AntigravityAccountSwitcher.oauthClientParameters
            credential.extra["clientId"] = parameters["client_id"]
            credential.extra["clientSecret"] = parameters["client_secret"]
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else {
                throw QuotioHostClientError.incompatible
            }
            var container = encoder.singleValueContainer()
            try container.encode(Int64(seconds))
        }
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Import(
            legacyId: account.id, provider: provider, label: account.accountKey,
            enabled: !disabled, credential: credential
        ))
        try await mutate(client: client, path: "v2/migrations/accounts", method: "POST", body: body,
                         idempotencyKey: "quotio-monitor-v1-" + SHA256.hash(data: Data(account.id.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    public func setDisabled(_ disabled: Bool, accountID: String) async {
        guard let client else { return }
        let body = try? JSONEncoder.quotioCLI.encode(EnabledBody(enabled: !disabled))
        guard let body else { return }
        try? await mutate(
            client: client,
            path: "v2/accounts/\(accountID)",
            method: "PATCH",
            body: body
        )
    }

    public func delete(accountID: String) async throws {
        guard let client else { throw AccountServiceFailure.accountNotFound }
        do {
            try await mutate(
                client: client,
                path: "v2/accounts/\(accountID)",
                method: "DELETE",
                body: nil
            )
        } catch {
            throw Self.accountFailure(error)
        }
    }

    public func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?,
        fields: [String: String] = [:]
    ) async throws {
        guard let client,
              let provider = QuotaProvider(rawValue: providerID.rawValue) else {
            throw AccountServiceFailure.invalidCredential
        }
        let cliProvider = provider.rawValue
        do {
            if let id = existingAccountID {
                let host = try await client.snapshot()
                guard let account = host.accounts.first(where: { $0.id == id && $0.providerId == cliProvider }) else {
                    throw AccountServiceFailure.accountNotFound
                }
                let sources = account.sources.filter { $0.actions.contains { $0.kind == "replace_api_key" && $0.available } }
                guard sources.count == 1 else { throw AccountServiceFailure.invalidCredential }
                var payload = try Self.apiKeyFields(fields)
                payload["api_key"] = apiKey
                let body = try JSONSerialization.data(withJSONObject: payload)
                try await mutate(client: client, path: QuotioHostAccountTarget.source(sources[0].id).path, method: "PATCH", body: body)
            } else {
                var payload = try Self.apiKeyFields(fields)
                payload["provider"] = cliProvider
                payload["label"] = label
                payload["api_key"] = apiKey
                let body = try JSONSerialization.data(withJSONObject: payload)
                try await mutate(client: client, path: "v2/accounts", method: "POST", body: body)
            }
        } catch {
            throw Self.accountFailure(error)
        }
    }

    private static func apiKeyFields(_ fields: [String: String]) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        var settings: [String: String] = [:]
        for (path, value) in fields where !value.isEmpty {
            if path == "region" || path == "organization" {
                payload[path] = value
            } else if path.hasPrefix("settings.") {
                let key = String(path.dropFirst("settings.".count))
                guard !key.isEmpty, !key.contains(".") else { throw AccountServiceFailure.invalidCredential }
                settings[key] = value
            } else { throw AccountServiceFailure.invalidCredential }
        }
        if !settings.isEmpty { payload["settings"] = settings }
        return payload
    }

    func beginOAuth(provider: String) async throws -> QuotioCLIOAuthSession {
        guard let client else { throw QuotioHostClientError.disconnected }
        let body = try JSONSerialization.data(withJSONObject: [
            "provider": provider,
        ])
        return try await client.request(
            "v2/auth/sessions",
            method: "POST",
            body: body,
            idempotencyKey: UUID().uuidString
        )
    }

    func oauthSession(id: String) async throws -> QuotioCLIOAuthSession {
        guard let client else { throw QuotioHostClientError.disconnected }
        return try await client.request("v2/auth/sessions/\(id)")
    }

    func completeOAuth(id: String, callbackURL: String? = nil, code: String? = nil) async throws -> QuotioCLIOAuthSession {
        guard let client else { throw QuotioHostClientError.disconnected }
        var value: [String: String] = [:]
        if let callbackURL { value["callback_url"] = callbackURL }
        if let code { value["code"] = code }
        let body = try JSONSerialization.data(withJSONObject: value)
        return try await client.request(
            "v2/auth/sessions/\(id)/callback",
            method: "POST",
            body: body,
            timeout: 60
        )
    }

    func cancelOAuth(id: String) async {
        guard let client else { return }
        let _: QuotioCLIOAuthSession? = try? await client.request(
            "v2/auth/sessions/\(id)",
            method: "DELETE"
        )
    }

    public func monitoringProviders() async throws -> [MonitoringProvider] {
        guard let client else { throw QuotioHostClientError.disconnected }
        let epoch = connectionID
        let catalog: QuotioHostProviders = try await client.request("v2/providers")
        guard epoch == connectionID else { throw QuotioHostClientError.disconnected }
        guard catalog.schemaVersion == 2 else { throw QuotioHostClientError.incompatible }
        let providers = try catalog.providers.map { value in
            guard let id = QuotaProvider(rawValue: value.id) else { throw QuotioHostClientError.incompatible }
            return MonitoringProvider(id: id, displayName: value.displayName,
                actions: Set(value.actions.filter(\.available).map(\.kind)),
                inputs: value.capabilities.settings.map { .init(name: $0.name, fieldPath: $0.fieldPath, required: $0.required, values: $0.values) })
        }
        guard Set(providers.map(\.id)).count == providers.count else { throw QuotioHostClientError.incompatible }
        let names = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.displayName) })
        if names != snapshot.providerNames {
            snapshot.providerNames = names
            publish()
        }
        return providers
    }

    public func monitoringSettings() async throws -> MonitoringSettings {
        guard let client else { throw QuotioHostClientError.disconnected }
        let epoch = connectionID
        let value: QuotioHostSettings = try await client.request("v2/settings")
        guard epoch == connectionID else { throw QuotioHostClientError.disconnected }
        return Self.monitoringSettings(value)
    }

    public func updateMonitoringSettings(_ settings: MonitoringSettings) async throws -> MonitoringSettings {
        guard let client else { throw QuotioHostClientError.disconnected }
        let epoch = connectionID
        let body = try JSONSerialization.data(withJSONObject: [
            "revision": settings.revision,
            "enabled_providers": settings.enabledProviders.sorted(),
            "disabled_providers": settings.disabledProviders.sorted(),
            "automatically_discover_logins": settings.automaticallyDiscoverLogins,
            "refresh_interval": settings.refreshInterval,
        ])
        let value: QuotioHostSettings = try await client.request("v2/settings", method: "PATCH", body: body)
        guard epoch == connectionID else { throw QuotioHostClientError.disconnected }
        return Self.monitoringSettings(value)
    }

    private static func monitoringSettings(_ value: QuotioHostSettings) -> MonitoringSettings {
        return MonitoringSettings(
            revision: value.revision,
            enabledProviders: Set(value.enabledProviders),
            disabledProviders: Set(value.disabledProviders),
            automaticallyDiscoverLogins: value.automaticallyDiscoverLogins,
            refreshInterval: value.refreshInterval
        )
    }

    private func performRefresh(
        providers: [String],
        accountID: String?,
        mode: QuotaOperatingMode,
        force: Bool,
        importedAccounts: Set<String>? = nil
    ) async {
        guard let client, activeMode == mode else { return }
        let domainProviders = Set(providers.compactMap(QuotaProvider.init(rawValue:)))
        snapshot.refreshingProviders.formUnion(domainProviders)
        publish()
        do {
            let body = try JSONEncoder.quotioCLI.encode(RefreshBody(
                providers: providers,
                accountId: accountID,
                force: force
            ))
            var operation: QuotioCLIOperation = try await client.request(
                "v2/refresh",
                method: "POST",
                body: body
            )
            let deadline = ContinuousClock.now + .seconds(180)
            while operation.status == "running" {
                guard ContinuousClock.now < deadline else { throw QuotioHostClientError.timeout }
                try await Task.sleep(for: .milliseconds(300))
                operation = try await client.request("v2/operations/\(operation.id)")
            }
            guard operation.status == "completed" else {
                throw QuotioHostClientError.response(500, operation.error ?? operation.status)
            }
            await loadSnapshot(mode: mode, refreshedProviders: domainProviders, importedAccounts: importedAccounts)
        } catch {
            await logger?.write(.warning, message: "Quota refresh failed=\(Self.failureCategory(error))")
            guard activeMode == mode else { return }
            snapshot.refreshingProviders.subtract(domainProviders)
            markFailure(for: domainProviders)
        }
    }

    private func loadSnapshot(
        mode: QuotaOperatingMode,
        refreshedProviders: Set<QuotaProvider>? = nil,
        importedAccounts: Set<String>? = nil
    ) async {
        guard let client else {
            markFailure(for: refreshedProviders ?? knownProviders)
            return
        }
        let requestConnection = connectionID
        let requestID = UUID()
        snapshotRequestID = requestID
        do {
            let host = try await client.snapshot()
            let localization = await localization()
            guard activeMode == mode, connectionID == requestConnection, snapshotRequestID == requestID else { return }
            var frame = host
            if let previous = hostSnapshot, previous.host.id == host.host.id {
                if host.revision < previous.revision { return }
                if host.revision == previous.revision { frame = previous }
            }
            let refreshing = snapshot.refreshingProviders
            var next = QuotioHostPresentationMapper.resolvedSnapshot(frame, bundle: localization.bundle, locale: localization.locale)
            next.refreshingProviders = refreshing.subtracting(refreshedProviders ?? [])
            next.providerNames = snapshot.providerNames
            let accounts = frame.accounts.compactMap(Self.resolvedAccount)
            let changed = snapshot != next || reportedAccounts != accounts
            snapshot = next
            hostSnapshot = frame
            reportedAccounts = accounts
            storageRequiresAuthorization = false
            if changed { publish() }
        } catch {
            guard activeMode == mode, connectionID == requestConnection, snapshotRequestID == requestID else { return }
            if Self.failureCategory(error) == "account_storage" { storageRequiresAuthorization = true }
            await logger?.write(.warning, message: "Quota snapshot failed=\(Self.failureCategory(error))")
            markFailure(for: refreshedProviders ?? knownProviders)
        }
    }

    private func selectMode(_ mode: QuotaOperatingMode) {
        guard activeMode != mode else { return }
        activeMode = mode
        snapshot = QuotaSnapshot()
        reportedAccounts = []
        publish()
    }

    private func accountID(provider: String, accountKey: String) async -> String? {
        hostSnapshot?.accounts.first { $0.providerId == provider && $0.id == accountKey }?.id
    }

    private static func resolvedAccount(_ value: QuotioHostSnapshot.Account) -> Account? {
        guard let provider = QuotaProvider(rawValue: value.providerId) else { return nil }
        func sourceKind(_ origin: String) -> AccountSource {
            switch origin {
            case "owned": .quotioKeychain
            case "borrowed_proxy": .legacyCLIProxy
            default: .nativeCredential
            }
        }
        func status(_ state: String) -> AccountStatus {
            switch state {
            case "ready": .ready
            case "disabled": .disabled
            case "needs_login": .expired
            case "needs_authorization", "unavailable": .unavailable
            default: .unknown
            }
        }
        var capabilities: Set<AccountCapability> = []
        if value.actions.contains(where: { $0.kind == "rename" && $0.available }) { capabilities.insert(.rename) }
        if value.actions.contains(where: { $0.kind == "remove" && $0.available }) { capabilities.insert(.delete) }
        if value.actions.contains(where: { $0.kind == "set_enabled" && $0.available }) { capabilities.insert(.disable) }
        let editable = value.sources.filter { $0.actions.contains { $0.kind == "replace_api_key" && $0.available } }
        if editable.count == 1 { capabilities.insert(.edit) }
        let source = value.sources.first(where: \.selected) ?? value.sources.first
        return Account(
            identity: AccountIdentity(id: value.id, providerID: .init(rawValue: provider.rawValue), accountKey: value.id),
            displayName: value.displayName, source: sourceKind(source?.origin ?? ""),
            credentialReference: source?.kind, capabilities: capabilities,
            status: status(value.state), enabled: value.enabled,
            sources: value.sources.map { source in
                AccountLoginSource(accountID: source.id, source: sourceKind(source.origin), credentialReference: source.kind,
                    status: status(source.state), location: source.location, enabled: source.enabled, actions: Set(source.actions.filter(\.available).map(\.kind)), keychainAccount: source.keychainAccount)
            },
            isIdentityVerified: value.identity.evidence == "verified"
        )
    }

    private func mutate(
        client: QuotioHostHTTPClient,
        path: String,
        method: String,
        body: Data?,
        idempotencyKey: String = UUID().uuidString,
        timeout: Duration = .seconds(60)
    ) async throws {
        var operation: QuotioCLIOperation = try await client.request(
            path,
            method: method,
            body: body,
            idempotencyKey: idempotencyKey
        )
        let deadline = ContinuousClock.now + timeout
        while operation.status == "running" {
            guard ContinuousClock.now < deadline else { throw QuotioHostClientError.timeout }
            try await Task.sleep(for: .milliseconds(100))
            operation = try await client.request("v2/operations/\(operation.id)")
        }
        guard operation.status == "completed" else {
            throw QuotioHostClientError.response(500, operation.error ?? operation.status)
        }
    }

    private func markFailure(for providers: Set<QuotaProvider>) {
        guard providers.contains(where: { snapshot.issues[$0]?.kind != .failed || snapshot.issues[$0]?.reason != nil || snapshot.refreshingProviders.contains($0) }) else { return }
        let now = Date()
        snapshot.refreshingProviders.subtract(providers)
        for provider in providers {
            snapshot.issues[provider] = QuotaRefreshIssue(kind: .failed, occurredAt: now)
        }
        publish()
    }

    private func publish() {
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func failureCategory(_ error: Error) -> String {
        switch error {
        case QuotioHostClientError.response(_, "credential_storage_unavailable"),
             QuotioHostClientError.response(_, "account_storage_unavailable"),
             QuotioHostClientError.response(_, "account_storage_disabled"):
            "account_storage"
        case QuotioHostClientError.response(_, "duplicate_account"): "duplicate_account"
        case QuotioHostClientError.response(_, "credential_validation_failed"): "credential_validation"
        case QuotioHostClientError.response(let status, _): "http_\(status)"
        case QuotioHostClientError.timeout: "timeout"
        case QuotioHostClientError.disconnected: "disconnected"
        default: "unclassified"
        }
    }

    private static func accountFailure(_ error: Error) -> AccountServiceFailure {
        guard case let QuotioHostClientError.response(_, code) = error else {
            return .invalidCredential
        }
        switch code {
        case "account_not_found": return .accountNotFound
        case "duplicate_account": return .duplicateAccount
        case "unsupported_operation": return .deletionNotAllowed
        default: return .invalidCredential
        }
    }

    private var knownProviders: Set<QuotaProvider> {
        Set(snapshot.providerNames.keys).union(snapshot.quotas.keys)
    }

}

private extension JSONEncoder {
    static var quotioCLI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
