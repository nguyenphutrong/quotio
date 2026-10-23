import QuotioHostClient
import Foundation
import CryptoKit
import QuotioApplication
import QuotioDomain

public actor QuotioCLIBackend: AccountManaging, QuotaCoordinating, MonitoringSettingsManaging, QuotaHistoryReading, QuotaHistoryManaging {
    private struct Empty: Decodable, Sendable {}
    private struct RefreshBody: Encodable {
        let providers: [String]
        let accountId: String?
        let force: Bool
    }
    private struct OAuthSessionBody: Encodable {
        let provider: String
        /// Omitted for GitHub.com; the helper rejects it for non-Copilot providers.
        let host: String?
    }
    private struct EnabledBody: Encodable { let enabled: Bool }
    private struct NativeSourceBody: Encodable {
        let kind: String
        let location: String?
        let entryKey: String?
        let configDir: String?
    }
    private struct LocalSourceBody: Encodable {
        let kind: String
        let configDir: String
        let entryKey: String?
        let label: String?
    }
    private struct LocalEntryDiscoveryBody: Encodable {
        let provider: String
        let kind: String
        let configDir: String
        let inspect = true
    }
    private struct LocalEntryDiscovery: Decodable, Sendable {
        struct Candidate: Decodable, Sendable {
            struct Source: Decodable, Sendable { let entryKey: String }
            let label: String
            let source: Source
        }
        let candidates: [Candidate]
    }
    public private(set) var snapshot = QuotaSnapshot()
    private var client: QuotioHostHTTPClient?
    private var reportedAccounts: [Account] = []
    private var hostSnapshot: QuotioHostSnapshot?
    /// Refresh failures the host snapshot does not report, kept until the host publishes a newer revision.
    private var refreshFailures: [QuotaFailure] = []
    private var connectionID = UUID()
    private var snapshotRequestID = UUID()
    private var activeMode: QuotaOperatingMode = .monitor
    private var continuations: [UUID: AsyncStream<QuotaSnapshot>.Continuation] = [:]
    private let logger: (any ApplicationLogging)?
    private let session: URLSession?
    private let localization: @MainActor @Sendable () -> (bundle: Bundle, locale: Locale)
    private var storageProblem: AccountStorageProblem?
    private var discoveryState: QuotioHostDiscovery?
    private var historyRequests: [UUID: @Sendable () -> Void] = [:]


    public func historyAvailability() -> QuotaHistoryAvailability {
        QuotioHistoryMapper.availability(hostSnapshot?.host, connected: client != nil)
    }

    private func historyRequest<T: Sendable>(write: Bool = false, _ operation: @escaping @Sendable (QuotioHostHTTPClient) async throws -> T) async throws -> T {
        let availability = historyAvailability()
        guard let client, availability.connected else { throw QuotaHistoryError.offline }
        guard availability.canRead else { throw availability.readFailure ?? QuotaHistoryError.unsupported }
        guard !write || availability.canWrite else { throw QuotaHistoryError.unauthorized }
        let epoch = connectionID
        let id = UUID()
        let task = Task { try await operation(client) }
        historyRequests[id] = { task.cancel() }
        defer { historyRequests[id] = nil }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard connectionID == epoch else { throw QuotaHistoryError.offline }
            return value
        } catch {
            if connectionID != epoch { throw QuotaHistoryError.offline }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let value = error as? QuotaHistoryError { throw value }
            if let value = error as? QuotioHostClientError {
                switch value {
                case .disconnected: throw QuotaHistoryError.offline
                case .incompatible: throw QuotaHistoryError.invalidResponse
                case .response(let status, let code):
                    if status == 403 { throw QuotaHistoryError.unauthorized }
                    if code.contains("storage") { throw QuotaHistoryError.storage }
                    throw QuotaHistoryError.requestFailed
                case .timeout: throw QuotaHistoryError.requestFailed
                @unknown default: throw QuotaHistoryError.requestFailed
                }
            }
            if let network = error as? URLError, [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(network.code) {
                throw QuotaHistoryError.offline
            }
            if error is DecodingError { throw QuotaHistoryError.invalidResponse }
            throw QuotaHistoryError.requestFailed
        }
    }

    public func historyCatalog(accountID: String) async throws -> QuotaHistoryCatalog {
        let value = try await historyRequest { try await $0.historyCatalog(accountID: accountID) }
        guard value.hostId == hostSnapshot?.host.id else { throw QuotaHistoryError.invalidResponse }
        return QuotioHistoryMapper.catalog(value)
    }
    public func historyChart(accountID: String, metricID: String, range: QuotaHistoryRange) async throws -> QuotaHistoryChart {
        let value = try await historyRequest { try await $0.historyChart(accountID: accountID, metricID: metricID, range: QuotioHostHistoryRange(rawValue: range.rawValue)!) }
        guard value.hostId == hostSnapshot?.host.id else { throw QuotaHistoryError.invalidResponse }
        return QuotioHistoryMapper.chart(value)
    }
    public func historyEvents(accountID: String, metricID: String, range: QuotaHistoryRange, cursor: String) async throws -> QuotaHistoryEventsPage {
        let value = try await historyRequest { try await $0.historyEvents(accountID: accountID, metricID: metricID, range: QuotioHostHistoryRange(rawValue: range.rawValue)!, cursor: cursor) }
        guard value.hostId == hostSnapshot?.host.id else { throw QuotaHistoryError.invalidResponse }
        return .init(hostID: value.hostId, accountID: value.accountId, metricID: value.metricId, revision: value.historyRevision, events: value.events.map(QuotioHistoryMapper.event), nextCursor: value.nextCursor)
    }
    public func clearHistory(accountID: String?) async throws {
        try await historyRequest(write: true) { try await $0.clearHistory(accountID: accountID) }
        publish()
    }
    public func historyRecordingEnabled() async throws -> Bool {
        let value: QuotioHostSettings = try await historyRequest { try await $0.request("v2/settings") }
        return value.quotaHistoryEnabled ?? true
    }
    public func setHistoryRecording(enabled: Bool) async throws -> Bool {
        let value: QuotioHostSettings = try await historyRequest(write: true) { client in
            let settings: QuotioHostSettings = try await client.request("v2/settings")
            let body = try JSONSerialization.data(withJSONObject: ["revision": settings.revision, "quota_history_enabled": enabled])
            return try await client.request("v2/settings", method: "PATCH", body: body)
        }
        return value.quotaHistoryEnabled ?? true
    }

    private func cancelHistoryRequests() {
        for cancel in historyRequests.values { cancel() }
        historyRequests.removeAll()
    }

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
        cancelHistoryRequests()
        connectionID = UUID()
        hostSnapshot = nil
        refreshFailures = []
        discoveryState = nil
        storageProblem = nil
        reportedAccounts = []
        snapshot = QuotaSnapshot()
        client = QuotioHostHTTPClient(connection: connection, session: session)
        publish()
    }

    public func disconnect() {
        cancelHistoryRequests()
        connectionID = UUID()
        client = nil
        snapshot.canRefresh = false
        snapshot.historyAvailability = historyAvailability()
        publish()
        markFailure(for: knownProviders, hostFailure: true)
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
                markFailure(for: [request.provider], accountKeys: [accountKey])
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
        // After a failed first read the refresh capability is unknown, so retry the read instead.
        guard hostSnapshot != nil || snapshot.hostIssue == nil else {
            await loadSnapshot(mode: mode)
            return snapshot
        }
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
        cancelHistoryRequests()
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
            if let problem = Self.storageProblem(error) { storageProblem = problem }
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
        let body = try JSONEncoder.quotioCLI.encode(NativeSourceBody(kind: source.kind, location: source.location,
            entryKey: source.keychainAccount, configDir: source.configDirectory))
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
            if let problem = Self.storageProblem(error) { storageProblem = problem }
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

    public func addLocalAccount(provider: QuotaProvider, kind: String, configDirectory: String, entryKey: String?, label: String?) async throws {
        guard let client else { throw LocalAccountFailure.unknown }
        // Claude Code NFC-normalizes CLAUDE_CONFIG_DIR before hashing it into its Keychain service.
        let directory = kind == "claude_native" ? configDirectory.precomposedStringWithCanonicalMapping : configDirectory
        let body = try JSONEncoder.quotioCLI.encode(LocalSourceBody(kind: kind, configDir: directory, entryKey: entryKey, label: label))
        do {
            do {
                try await mutate(client: client, path: "v2/sources", method: "POST", body: body)
            } catch QuotioHostClientError.response(_, "permission_required") {
                try await mutate(
                    client: client,
                    path: "v2/sources/authorize",
                    method: "POST",
                    body: body,
                    idempotencyKey: "quotio-native-permission-" + UUID().uuidString,
                    timeout: .seconds(300)
                )
            }
        } catch QuotioHostClientError.response(_, "entry_required") {
            let body = try JSONEncoder.quotioCLI.encode(
                LocalEntryDiscoveryBody(provider: provider.rawValue, kind: kind, configDir: directory))
            let discovery: LocalEntryDiscovery
            do {
                discovery = try await client.request("v2/sources/discover", method: "POST", body: body)
            } catch {
                throw Self.localAccountFailure(error)
            }
            throw LocalAccountFailure.entryRequired(discovery.candidates.map {
                LocalAccountEntry(entryKey: $0.source.entryKey, label: $0.label)
            })
        } catch {
            if let problem = Self.storageProblem(error) { storageProblem = problem }
            throw Self.localAccountFailure(error)
        }
    }

    private static func localAccountFailure(_ error: Error) -> LocalAccountFailure {
        guard case let QuotioHostClientError.response(_, code) = error else { return .unknown }
        switch code {
        case "invalid_request": return .invalidInput
        case "native_login_required", "account_not_found": return .notSignedIn
        case "duplicate_account": return .duplicateAccount
        case "native_keychain_access_failed", "quotio_vault_access_failed": return .keychainAccess
        case "native_credential_invalid", "credential_validation_failed", "invalid_credential": return .invalidCredential
        default: return .unknown
        }
    }

    public func accountStorageProblem() async -> AccountStorageProblem? { storageProblem }

    public func authorizeAccountStorage() async throws {
        guard let client else { throw NativeSourceAuthorizationFailure.unknown }
        do {
            try await mutate(client: client, path: "v2/account-vault/authorize", method: "POST", body: Data("{}".utf8), timeout: .seconds(300))
            storageProblem = nil
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

    func beginOAuth(provider: String, githubHost: String? = nil) async throws -> QuotioCLIOAuthSession {
        guard let client else { throw QuotioHostClientError.disconnected }
        let body = try JSONEncoder.quotioCLI.encode(OAuthSessionBody(provider: provider, host: githubHost))
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
            let configDirectory = value.capabilities.sourceReferences?.lazy.compactMap { reference in
                reference.configDirEnv.map { MonitoringProvider.ConfigDirectorySource(kind: reference.kind, environmentVariable: $0) }
            }.first
            return MonitoringProvider(id: id, displayName: value.displayName,
                actions: Set(value.actions.filter(\.available).map(\.kind)),
                inputs: value.capabilities.settings.map { .init(name: $0.name, fieldPath: $0.fieldPath, required: $0.required, values: $0.values) },
                configDirectorySource: configDirectory)
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
            "quota_history_enabled": settings.quotaHistoryEnabled,
        ])
        let value: QuotioHostSettings = try await client.request("v2/settings", method: "PATCH", body: body)
        guard epoch == connectionID else { throw QuotioHostClientError.disconnected }
        return Self.monitoringSettings(value)
    }

    public func nextRefreshAt() async throws -> Date? {
        guard let client else { throw QuotioHostClientError.disconnected }
        return try await client.status().nextRefreshAt
    }

    private static func monitoringSettings(_ value: QuotioHostSettings) -> MonitoringSettings {
        return MonitoringSettings(
            revision: value.revision,
            enabledProviders: Set(value.enabledProviders),
            disabledProviders: Set(value.disabledProviders),
            automaticallyDiscoverLogins: value.automaticallyDiscoverLogins,
            refreshInterval: value.refreshInterval,
            quotaHistoryEnabled: value.quotaHistoryEnabled ?? true
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
        let domainProviders = providers.isEmpty
            ? knownProviders.union(snapshot.providerNames.keys)
            : Set(providers.compactMap(QuotaProvider.init(rawValue:)))
        guard domainProviders.isDisjoint(with: snapshot.refreshingProviders) else { return }
        let requestConnection = connectionID
        let retryScope = accountID.map { Set([$0]) } ?? importedAccounts
        refreshFailures = refreshFailures.compactMap { $0.retiring(domainProviders, accountKeys: retryScope) }
        snapshot.refreshingProviders.formUnion(domainProviders)
        publish()
        defer {
            if connectionID == requestConnection, activeMode == mode {
                snapshot.refreshingProviders.subtract(domainProviders)
                publish()
            }
        }
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
            guard activeMode == mode, connectionID == requestConnection else { return }
            while operation.status == "running" {
                guard ContinuousClock.now < deadline else { throw QuotioHostClientError.timeout }
                try await Task.sleep(for: .milliseconds(300))
                guard activeMode == mode, connectionID == requestConnection else { return }
                operation = try await client.request("v2/operations/\(operation.id)")
                guard activeMode == mode, connectionID == requestConnection else { return }
            }
            guard operation.status == "completed" else {
                throw QuotioHostClientError.response(500, operation.error ?? operation.status)
            }
            await loadSnapshot(mode: mode, refreshedProviders: domainProviders, importedAccounts: importedAccounts)
        } catch {
            guard activeMode == mode, connectionID == requestConnection else { return }
            if let problem = Self.storageProblem(error) { storageProblem = problem }
            let failure = QuotaFailure(
                revision: hostSnapshot?.revision,
                providers: providers.isEmpty ? knownProviders : domainProviders,
                accountKeys: retryScope,
                reason: Self.refreshFailureReason(error),
                hostFailure: providers.isEmpty,
                occurredAt: Date()
            )
            refreshFailures.append(failure)
            if apply(failure) { publish() }
            await logger?.write(.warning, message: "Quota refresh failed=\(Self.failureCategory(error))")
        }
    }

    private func loadSnapshot(
        mode: QuotaOperatingMode,
        refreshedProviders: Set<QuotaProvider>? = nil,
        importedAccounts: Set<String>? = nil
    ) async {
        guard let client else {
            markFailure(for: knownProviders.union(refreshedProviders ?? []), hostFailure: true)
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
            let previous = snapshot
            snapshot = next
            hostSnapshot = frame
            snapshot.historyAvailability = historyAvailability()
            refreshFailures.removeAll { $0.revision != frame.revision }
            for failure in refreshFailures { apply(failure) }
            let changed = snapshot != previous || reportedAccounts != accounts
            reportedAccounts = accounts
            storageProblem = nil
            if changed { publish() }
        } catch {
            guard activeMode == mode, connectionID == requestConnection, snapshotRequestID == requestID else { return }
            if let problem = Self.storageProblem(error) { storageProblem = problem }
            if hostSnapshot == nil { snapshot.canRefresh = true }
            markFailure(
                for: knownProviders.union(refreshedProviders ?? []),
                reason: Self.refreshFailureReason(error),
                hostFailure: true
            )
            await logger?.write(.warning, message: "Quota snapshot failed=\(Self.failureCategory(error))")
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
                    status: status(source.state), location: source.location, enabled: source.enabled, actions: Set(source.actions.filter(\.available).map(\.kind)), keychainAccount: source.keychainAccount,
                    directory: source.directory)
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

    private func markFailure(
        for providers: Set<QuotaProvider>,
        accountKeys: Set<String>? = nil,
        reason: QuotaRefreshFailureReason = .unavailable,
        hostFailure: Bool = false
    ) {
        let failure = QuotaFailure(
            revision: nil, providers: providers, accountKeys: accountKeys,
            reason: reason, hostFailure: hostFailure, occurredAt: Date()
        )
        if apply(failure) { publish() }
    }

    @discardableResult
    private func apply(_ failure: QuotaFailure) -> Bool {
        let (providers, accountKeys, reason, hostFailure, now) = (
            failure.providers, failure.accountKeys, failure.reason, failure.hostFailure, failure.occurredAt
        )
        var changed = !snapshot.refreshingProviders.isDisjoint(with: providers)
        snapshot.refreshingProviders.subtract(providers)
        if hostFailure, snapshot.hostIssue?.kind != .failed || snapshot.hostIssue?.reason != reason {
            snapshot.hostIssue = QuotaRefreshIssue(kind: .failed, occurredAt: now, reason: reason)
            changed = true
        }
        let activeAccounts = knownAccounts.filter { snapshot.accountStates[$0]?.connection != .disabled }
        for account in activeAccounts where providers.contains(account.provider) {
            guard accountKeys?.contains(account.accountKey) ?? true else { continue }
            let previous = snapshot.accountStates[account]
            let state = AccountMonitoringState(
                connection: previous?.connection ?? .notConnected,
                quota: snapshot.quotas[account.provider]?[account.accountKey] == nil ? .failed(reason) : .stale
            )
            if previous != state {
                snapshot.accountStates[account] = state
                changed = true
            }
            if snapshot.accountIssues[account]?.kind != .failed || snapshot.accountIssues[account]?.reason != reason {
                snapshot.accountIssues[account] = QuotaRefreshIssue(kind: .failed, occurredAt: now, reason: reason)
                changed = true
            }
        }
        if accountKeys == nil {
            let disabledOnly = Set(knownAccounts.map(\.provider)).subtracting(activeAccounts.map(\.provider))
            for provider in providers.subtracting(disabledOnly) where snapshot.issues[provider]?.kind != .failed || snapshot.issues[provider]?.reason != reason {
                snapshot.issues[provider] = QuotaRefreshIssue(kind: .failed, occurredAt: now, reason: reason)
                changed = true
            }
        }
        return changed
    }

    private func publish() {
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func storageProblem(_ error: Error) -> AccountStorageProblem? {
        switch error {
        case QuotioHostClientError.response(_, "credential_storage_unavailable"),
             QuotioHostClientError.response(_, "account_storage_unavailable"),
             QuotioHostClientError.response(_, "account_storage_disabled"):
            .requiresAuthorization
        case QuotioHostClientError.response(_, "credential_storage_corrupt"): .unreadable
        case QuotioHostClientError.response(_, "credential_storage_newer_version"): .newerVersion
        default: nil
        }
    }

    private static func refreshFailureReason(_ error: Error) -> QuotaRefreshFailureReason {
        if storageProblem(error) != nil { return .credentialStorage }
        switch error {
        case QuotioHostClientError.timeout: return .timeout
        case QuotioHostClientError.disconnected: return .unavailable
        case QuotioHostClientError.incompatible, is DecodingError: return .invalidData
        case QuotioHostClientError.response(let status, let code):
            if let reason = QuotaRefreshFailureReason(rawValue: code) { return reason }
            switch status {
            case 429: return .rateLimited
            case 401, 403: return .authentication
            case 500...: return .transient
            default: return .unavailable
            }
        case let error as URLError: return error.code == .timedOut ? .timeout : .transient
        default: return .unavailable
        }
    }

    private static func failureCategory(_ error: Error) -> String {
        switch error {
        case QuotioHostClientError.response(_, let code) where storageProblem(error) != nil: code
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

    private var knownAccounts: Set<QuotaAccountID> {
        Set(snapshot.accountStates.keys).union(snapshot.quotas.flatMap { provider, quotas in
            quotas.keys.map { QuotaAccountID(provider: provider, accountKey: $0) }
        })
    }

    private var knownProviders: Set<QuotaProvider> {
        Set(snapshot.issues.keys).union(knownAccounts.map(\.provider))
    }

}

private struct QuotaFailure {
    let revision: UInt64?
    var providers: Set<QuotaProvider>
    var accountKeys: Set<String>?
    let reason: QuotaRefreshFailureReason
    let hostFailure: Bool
    let occurredAt: Date

    /// What remains once a new refresh of `providers`, limited to `accountKeys` when set, retries part of it.
    func retiring(_ providers: Set<QuotaProvider>, accountKeys retried: Set<String>?) -> Self? {
        guard !self.providers.isDisjoint(with: providers) else { return self }
        var rest = self
        if let retried {
            guard let keys = accountKeys else { return self }
            rest.accountKeys = keys.subtracting(retried)
            return rest.accountKeys?.isEmpty == true ? nil : rest
        }
        rest.providers.subtract(providers)
        return rest.providers.isEmpty ? nil : rest
    }
}

private extension JSONEncoder {
    static var quotioCLI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
