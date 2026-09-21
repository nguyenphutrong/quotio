import Foundation
import CryptoKit
import QuotioApplication
import QuotioDomain

public enum QuotioCLIBackendError: Error, Equatable, Sendable {
    case disconnected
    case incompatible
    case response(Int, String)
    case timeout
}

private final class QuotioCLINoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct QuotioCLIHTTPClient: Sendable {
    private struct Failure: Decodable { let error: String }

    let connection: QuotioCLIConnection
    let session: URLSession

    init(connection: QuotioCLIConnection, session: URLSession? = nil) {
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        self.session = session ?? URLSession(
            configuration: configuration,
            delegate: QuotioCLINoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func request<T: Decodable & Sendable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        idempotencyKey: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        var request = URLRequest(url: connection.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotioCLIBackendError.disconnected
        }
        guard http.url?.host == "127.0.0.1",
              http.url?.port == connection.baseURL.port else {
            throw QuotioCLIBackendError.incompatible
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "request_failed"
            throw QuotioCLIBackendError.response(http.statusCode, code)
        }
        return try makeQuotioCLIDecoder().decode(T.self, from: data)
    }
}

public actor QuotioCLIBackend: AccountManaging, QuotaCoordinating {
    private struct Empty: Decodable, Sendable {}
    private struct RefreshBody: Encodable {
        let providers: [String]
        let accountId: String?
        let force: Bool
        let includeOwned: Bool
    }
    private struct APIKeyBody: Encodable {
        let provider: String?
        let label: String
        let apiKey: String
    }
    private struct EnabledBody: Encodable { let enabled: Bool }
    private struct LabelBody: Encodable { let label: String }
    private struct CustomProviderSourceBody: Encodable {
        struct Source: Encodable {
            let domain: String
            let recordId: String
        }

        let kind = "quotio_custom_provider"
        let source: Source
    }

    public private(set) var snapshot = QuotaSnapshot()
    private var client: QuotioCLIHTTPClient?
    private var reportedAccounts: [Account] = []
    private var activeMode: QuotaOperatingMode = .monitor
    private var continuations: [UUID: AsyncStream<QuotaSnapshot>.Continuation] = [:]
    private let session: URLSession?
    private let userDefaults: UserDefaults
    private let customProviders: (@Sendable () throws -> [CustomProvider])?
    private let customProviderDomain: String
    private let localization: @MainActor @Sendable () -> (bundle: Bundle, locale: Locale)

    public init(
        session: URLSession? = nil,
        userDefaults: UserDefaults = .standard,
        customProviders: (@Sendable () throws -> [CustomProvider])? = nil,
        customProviderDomain: String = "production",
        localization: @escaping @MainActor @Sendable () -> (bundle: Bundle, locale: Locale) = { (.main, .current) }
    ) {
        self.session = session
        self.userDefaults = userDefaults
        self.customProviders = customProviders
        self.customProviderDomain = customProviderDomain
        self.localization = localization
    }

    public func connect(_ connection: QuotioCLIConnection) {
        client = QuotioCLIHTTPClient(connection: connection, session: session)
    }

    public func disconnect() {
        client = nil
        markFailure(for: Set(Self.supportedProviders))
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
        guard let provider = QuotioCLIProviderMap.cli(request.provider) else { return snapshot }
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
        let selected = (providers ?? Set(Self.supportedProviders)).compactMap(QuotioCLIProviderMap.cli)
        await performRefresh(providers: selected, accountID: nil, mode: mode, force: force)
        return snapshot
    }

    public func replaceQuotas(
        _ quotas: [String: ProviderQuota],
        for provider: QuotaProvider,
        mode: QuotaOperatingMode
    ) {
        snapshot.quotas[provider] = quotas.isEmpty ? nil : quotas
        saveImportedIDEQuotas()
        publish()
    }

    public func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) {
        snapshot.quotas[account.provider]?[account.accountKey] = nil
        snapshot.accountIDs[account.provider]?[account.accountKey] = nil
        snapshot.accountAliases[account.provider]?.filter { $0.value == account.accountKey }
            .forEach { snapshot.accountAliases[account.provider]?[$0.key] = nil }
        snapshot.subscriptions[account.provider]?[account.accountKey] = nil
        snapshot.accountIssues[account] = nil
        saveImportedIDEQuotas()
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

    public func accounts() async -> [Account] {
        guard let client else { return visibleReportedAccounts() }
        do {
            let response: QuotioCLIAccountList = try await client.request("v1/accounts")
            guard response.schemaVersion == 1 else { return [] }
            let accounts = response.accounts
                .filter { activeMode == .monitor || $0.origin != "owned" || $0.provider == "warp" }
                .compactMap(Self.account)
            return AccountSelectionPolicy.preferred(
                accounts + visibleReportedAccounts(),
                disabledIDs: Set(accounts.filter(\.isDisabled).map(\.id))
            )
        } catch {
            return visibleReportedAccounts()
        }
    }

    public func importLegacyAccount(_ account: Account, credential: StoredCredential, disabled: Bool) async throws {
        guard let client else { throw QuotioCLIBackendError.disconnected }
        struct Import: Encodable {
            let legacyId: String
            let provider: String
            let label: String
            let enabled: Bool
            let credential: StoredCredential
        }
        guard let domainProvider = QuotaProvider(rawValue: account.providerID.rawValue),
              let provider = QuotioCLIProviderMap.cli(domainProvider) else {
            throw QuotioCLIBackendError.incompatible
        }
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
                throw QuotioCLIBackendError.incompatible
            }
            var container = encoder.singleValueContainer()
            try container.encode(Int64(seconds))
        }
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Import(
            legacyId: account.id, provider: provider, label: account.accountKey,
            enabled: !disabled, credential: credential
        ))
        try await mutate(client: client, path: "v1/accounts/migrate", method: "POST", body: body,
                         idempotencyKey: "quotio-monitor-v1-" + SHA256.hash(data: Data(account.id.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    public func setDisabled(_ disabled: Bool, accountID: String) async {
        guard let client else { return }
        let body = try? JSONEncoder.quotioCLI.encode(EnabledBody(enabled: !disabled))
        guard let body else { return }
        try? await mutate(
            client: client,
            path: "v1/accounts/\(accountID)",
            method: "PATCH",
            body: body
        )
    }

    public func delete(accountID: String) async throws {
        guard let client else { throw AccountServiceFailure.accountNotFound }
        do {
            try await mutate(
                client: client,
                path: "v1/accounts/\(accountID)",
                method: "DELETE",
                body: nil
            )
        } catch {
            throw Self.accountFailure(error)
        }
    }

    public func synchronizeWarpTokens(_ tokens: [WarpToken]) async throws {
        guard let client else { throw QuotioCLIBackendError.disconnected }
        let response: QuotioCLIAccountList = try await client.request("v1/accounts")
        guard response.schemaVersion == 1 else { throw QuotioCLIBackendError.incompatible }
        let existing = response.accounts.filter(QuotioCLIWarpMirror.isMirror)
        var retained = Set<String>()
        for token in tokens where token.isEnabled {
            let account = existing.first {
                QuotioCLIWarpMirror.displayLabel($0.label, provider: $0.provider)
                    .caseInsensitiveCompare(token.name) == .orderedSame
            }
            let body = try JSONEncoder.quotioCLI.encode(APIKeyBody(
                provider: account == nil ? "warp" : nil,
                label: QuotioCLIWarpMirror.storageLabel(token.name),
                apiKey: token.token
            ))
            try await mutate(
                client: client,
                path: account.map { "v1/accounts/\($0.id)" } ?? "v1/accounts",
                method: account == nil ? "POST" : "PATCH",
                body: body
            )
            if let account { retained.insert(account.id) }
        }
        for account in existing where !retained.contains(account.id) {
            try await mutate(
                client: client,
                path: "v1/accounts/\(account.id)",
                method: "DELETE",
                body: nil
            )
        }
    }

    public func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) async throws {
        guard let client,
              let provider = QuotaProvider(rawValue: providerID.rawValue),
              let cliProvider = QuotioCLIProviderMap.cli(provider) else {
            throw AccountServiceFailure.invalidCredential
        }
        do {
            let body = try JSONEncoder.quotioCLI.encode(APIKeyBody(
                provider: existingAccountID == nil ? cliProvider : nil,
                label: label,
                apiKey: apiKey
            ))
            try await mutate(
                client: client,
                path: existingAccountID.map { "v1/accounts/\($0)" } ?? "v1/accounts",
                method: existingAccountID == nil ? "POST" : "PATCH",
                body: body
            )
        } catch {
            throw Self.accountFailure(error)
        }
    }

    func beginOAuth(provider: String) async throws -> QuotioCLIOAuthSession {
        guard let client else { throw QuotioCLIBackendError.disconnected }
        let body = try JSONSerialization.data(withJSONObject: [
            "provider": provider,
            "callback_mode": "relay",
        ])
        return try await client.request(
            "v1/auth/sessions",
            method: "POST",
            body: body,
            idempotencyKey: UUID().uuidString
        )
    }

    func oauthSession(id: String) async throws -> QuotioCLIOAuthSession {
        guard let client else { throw QuotioCLIBackendError.disconnected }
        return try await client.request("v1/auth/sessions/\(id)")
    }

    func completeOAuth(id: String, callbackURL: String? = nil, code: String? = nil) async throws -> QuotioCLIOAuthSession {
        guard let client else { throw QuotioCLIBackendError.disconnected }
        var value: [String: String] = [:]
        if let callbackURL { value["callback_url"] = callbackURL }
        if let code { value["code"] = code }
        let body = try JSONSerialization.data(withJSONObject: value)
        return try await client.request(
            "v1/auth/sessions/\(id)/callback",
            method: "POST",
            body: body,
            timeout: 60
        )
    }

    func cancelOAuth(id: String) async {
        guard let client else { return }
        let _: QuotioCLIOAuthSession? = try? await client.request(
            "v1/auth/sessions/\(id)",
            method: "DELETE"
        )
    }

    private func performRefresh(
        providers: [String],
        accountID: String?,
        mode: QuotaOperatingMode,
        force: Bool,
        importedAccounts: Set<String>? = nil
    ) async {
        guard let client, !providers.isEmpty, activeMode == mode else { return }
        let domainProviders = Set(providers.compactMap(QuotioCLIProviderMap.domain))
        snapshot.refreshingProviders.formUnion(domainProviders)
        publish()
        do {
            if providers.contains("zai") || providers.contains("clinepass") {
                try await synchronizeCustomProviders(client: client)
            }
            let body = try JSONEncoder.quotioCLI.encode(RefreshBody(
                providers: providers,
                accountId: accountID,
                force: force,
                includeOwned: mode == .monitor
            ))
            var operation: QuotioCLIOperation = try await client.request(
                "v1/refresh",
                method: "POST",
                body: body
            )
            let deadline = ContinuousClock.now + .seconds(180)
            while operation.status == "running" {
                guard ContinuousClock.now < deadline else { throw QuotioCLIBackendError.timeout }
                try await Task.sleep(for: .milliseconds(300))
                operation = try await client.request("v1/operations/\(operation.id)")
            }
            guard operation.status == "completed" else {
                throw QuotioCLIBackendError.response(500, operation.error ?? operation.status)
            }
            await loadSnapshot(mode: mode, refreshedProviders: domainProviders, importedAccounts: importedAccounts)
        } catch {
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
            markFailure(for: refreshedProviders ?? Set(Self.supportedProviders))
            return
        }
        do {
            let report: QuotioCLIUsageReport = try await client.request("v1/usage")
            guard activeMode == mode else { return }
            guard report.schemaVersion == 1 else { throw QuotioCLIBackendError.incompatible }
            let localization = await localization()
            guard activeMode == mode else { return }
            let previous = snapshot
            let retainedAccounts = reportedAccounts.filter { account in
                refreshedProviders.map { providers in
                    !providers.contains { $0.rawValue == account.providerID.rawValue }
                } ?? false
            }
            snapshot = QuotioCLIUsageMapper.snapshot(report, mode: mode, bundle: localization.bundle, locale: localization.locale)
            if let refreshedProviders {
                for provider in QuotaProvider.allCases where !refreshedProviders.contains(provider) {
                    snapshot.quotas[provider] = previous.quotas[provider]
                    snapshot.accountIDs[provider] = previous.accountIDs[provider]
                    snapshot.accountAliases[provider] = previous.accountAliases[provider]
                    snapshot.subscriptions[provider] = previous.subscriptions[provider]
                    snapshot.issues[provider] = previous.issues[provider]
                }
                snapshot.accountIssues = snapshot.accountIssues.filter { refreshedProviders.contains($0.key.provider) }
                for (account, issue) in previous.accountIssues where !refreshedProviders.contains(account.provider) {
                    snapshot.accountIssues[account] = issue
                }
                snapshot.refreshingProviders = previous.refreshingProviders.subtracting(refreshedProviders)
                if refreshedProviders.contains(.cursor), let importedAccounts {
                    snapshot.quotas[.cursor] = snapshot.quotas[.cursor]?.filter { importedAccounts.contains($0.key) }
                }
            } else {
                snapshot.quotas[.cursor] = nil
                mergeImportedIDEQuotas()
            }
            let cursorKeys = Set(snapshot.quotas[.cursor]?.keys.map { $0 } ?? [])
            snapshot.accountIDs[.cursor] = snapshot.accountIDs[.cursor]?.filter { cursorKeys.contains($0.key) }
            snapshot.accountAliases[.cursor] = snapshot.accountAliases[.cursor]?.filter { cursorKeys.contains($0.value) }
            snapshot.accountIssues = snapshot.accountIssues.filter {
                $0.key.provider != .cursor || cursorKeys.contains($0.key.accountKey)
            }
            saveImportedIDEQuotas()
            let references = report.providers.map { ($0.provider, $0.accountRef) }
                + report.failures.map { ($0.provider, $0.accountRef) }
            reportedAccounts = references.compactMap { name, reference in
                guard let reference,
                      let provider = QuotioCLIProviderMap.domain(name),
                      refreshedProviders?.contains(provider) != false,
                      let key = snapshot.accountAliases[provider]?[reference.id] else { return nil }
                return Self.account(reference, provider: provider, accountKey: key)
            } + retainedAccounts
            publish()
        } catch {
            guard activeMode == mode else { return }
            markFailure(for: refreshedProviders ?? Set(Self.supportedProviders))
        }
    }

    private func selectMode(_ mode: QuotaOperatingMode) {
        guard activeMode != mode else { return }
        activeMode = mode
        snapshot = QuotaSnapshot()
        reportedAccounts = []
        publish()
    }

    private func visibleReportedAccounts() -> [Account] {
        reportedAccounts.filter {
            activeMode == .monitor
                || $0.source != .quotioKeychain
                || $0.providerID.rawValue == QuotaProvider.warp.rawValue
        }
    }

    private func accountID(provider: String, accountKey: String) async -> String? {
        guard let client else { return nil }
        if let domainProvider = QuotioCLIProviderMap.domain(provider) {
            let quotaKey = snapshot.accountAliases[domainProvider]?[accountKey] ?? accountKey
            if let id = snapshot.accountIDs[domainProvider]?[quotaKey] { return id }
        }
        if let list: QuotioCLIAccountList = try? await client.request("v1/accounts"),
           let id = list.accounts.first(where: {
            $0.provider == provider
                && ($0.id == accountKey || $0.label.caseInsensitiveCompare(accountKey) == .orderedSame)
           })?.id {
            return id
        }
        return nil
    }

    private func synchronizeCustomProviders(client: QuotioCLIHTTPClient) async throws {
        guard let customProviders else { return }
        let desired = try customProviders().compactMap { provider -> (CustomProvider, String)? in
            guard provider.isEnabled, !provider.apiKeys.isEmpty else { return nil }
            let sourceID = Self.customProviderSourceID(
                domain: customProviderDomain,
                recordID: provider.id
            )
            switch provider.type {
            case .glmCompatibility, .clinePass: return (provider, sourceID)
            default: return nil
            }
        }
        let response: QuotioCLIAccountList = try await client.request("v1/accounts")
        guard response.schemaVersion == 1 else { throw QuotioCLIBackendError.incompatible }
        var existing = response.accounts.filter { $0.sourceKind == "quotio_custom_provider" }
        for account in existing where !desired.contains(where: {
            $0.1 == account.sourceId
        }) {
            try await mutate(client: client, path: "v1/accounts/\(account.id)", method: "DELETE", body: nil)
            existing.removeAll { $0.id == account.id }
        }
        for (provider, sourceID) in desired {
            if let account = existing.first(where: { $0.sourceId == sourceID }) {
                if account.label != provider.name {
                    let body = try JSONEncoder.quotioCLI.encode(LabelBody(label: provider.name))
                    try await mutate(client: client, path: "v1/accounts/\(account.id)", method: "PATCH", body: body)
                }
                continue
            }
            let body = try JSONEncoder.quotioCLI.encode(CustomProviderSourceBody(
                source: .init(domain: customProviderDomain, recordId: provider.id.uuidString)
            ))
            try await mutate(client: client, path: "v1/account-sources", method: "POST", body: body)
        }
    }

    private func mergeImportedIDEQuotas() {
        guard let data = userDefaults.data(forKey: "persisted.ideQuotas"),
              let stored = try? JSONDecoder().decode([String: [String: ProviderQuota]].self, from: data) else {
            return
        }
        for provider in [QuotaProvider.cursor]
            where snapshot.quotas[provider]?.isEmpty != false {
            snapshot.quotas[provider] = stored[provider.rawValue]
        }
    }

    private func saveImportedIDEQuotas() {
        let stored = [QuotaProvider.cursor, .trae].reduce(into: [String: [String: ProviderQuota]]()) {
            if let quotas = snapshot.quotas[$1], !quotas.isEmpty { $0[$1.rawValue] = quotas }
        }
        guard !stored.isEmpty else {
            userDefaults.removeObject(forKey: "persisted.ideQuotas")
            return
        }
        if let data = try? JSONEncoder().encode(stored) {
            userDefaults.set(data, forKey: "persisted.ideQuotas")
        }
    }

    private static func customProviderSourceID(domain: String, recordID: UUID) -> String {
        let identifier = switch domain {
        case "production": "app.bytrong.quotio"
        case "development": "app.bytrong.quotio.dev"
        default: domain
        }
        let parts = ["quotio_custom_provider", identifier, recordID.uuidString.lowercased()]
        var data = Data()
        for part in parts {
            var length = UInt64(part.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: part.utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mutate(
        client: QuotioCLIHTTPClient,
        path: String,
        method: String,
        body: Data?,
        idempotencyKey: String = UUID().uuidString
    ) async throws {
        var operation: QuotioCLIOperation = try await client.request(
            path,
            method: method,
            body: body,
            idempotencyKey: idempotencyKey
        )
        let deadline = ContinuousClock.now + .seconds(60)
        while operation.status == "running" {
            guard ContinuousClock.now < deadline else { throw QuotioCLIBackendError.timeout }
            try await Task.sleep(for: .milliseconds(100))
            operation = try await client.request("v1/operations/\(operation.id)")
        }
        guard operation.status == "completed" else {
            throw QuotioCLIBackendError.response(500, operation.error ?? operation.status)
        }
    }

    private func markFailure(for providers: Set<QuotaProvider>) {
        let now = Date()
        snapshot.refreshingProviders.subtract(providers)
        for provider in providers {
            snapshot.issues[provider] = QuotaRefreshIssue(kind: .failed, occurredAt: now)
        }
        snapshot.lastUpdated = now
        publish()
    }

    private func publish() {
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func account(_ value: QuotioCLIAccount) -> Account? {
        guard let provider = QuotioCLIProviderMap.domain(value.provider) else { return nil }
        let label = QuotioCLIWarpMirror.displayLabel(value.label, provider: value.provider)
        let source: AccountSource = switch value.origin {
        case "borrowed_proxy": .legacyCLIProxy
        case "borrowed_native": .nativeCredential
        default: .quotioKeychain
        }
        var capabilities: Set<AccountCapability> = [.disable]
        if value.origin != "borrowed_proxy" { capabilities.insert(.delete) }
        if value.origin == "owned", provider.usesAPIKeyAuth { capabilities.insert(.edit) }
        if QuotioCLIWarpMirror.isMirror(value) { capabilities = [] }
        return Account(
            identity: AccountIdentity(
                id: value.id,
                providerID: AccountProviderID(rawValue: provider.rawValue),
                accountKey: label
            ),
            displayName: label,
            source: source,
            credentialReference: value.sourceKind,
            capabilities: capabilities,
            status: value.enabled ? .ready : .disabled,
            credentialMetadata: RedactedCredentialMetadata(
                kind: value.origin == "owned" && provider.usesAPIKeyAuth ? .apiKey : .external
            )
        )
    }

    private static func account(
        _ reference: QuotioCLIAccountReference,
        provider: QuotaProvider,
        accountKey: String
    ) -> Account {
        let label = QuotioCLIWarpMirror.displayLabel(reference.label, provider: provider.rawValue)
        let source: AccountSource = switch reference.origin {
        case "borrowed_proxy": .legacyCLIProxy
        case "borrowed_native": .nativeCredential
        default: .quotioKeychain
        }
        return Account(
            identity: AccountIdentity(
                id: reference.id,
                providerID: AccountProviderID(rawValue: provider.rawValue),
                accountKey: accountKey
            ),
            displayName: label,
            source: source,
            credentialReference: nil,
            capabilities: [],
            status: .ready
        )
    }

    private static func accountFailure(_ error: Error) -> AccountServiceFailure {
        guard case let QuotioCLIBackendError.response(_, code) = error else {
            return .invalidCredential
        }
        switch code {
        case "account_not_found": return .accountNotFound
        case "duplicate_account": return .duplicateAccount
        case "unsupported_operation": return .deletionNotAllowed
        default: return .invalidCredential
        }
    }

    private static let supportedProviders: [QuotaProvider] = [
        .claude, .codex, .antigravity, .kiro, .copilot, .cursor, .factoryDroid,
        .devin, .grok, .openRouter, .amp, .glm, .vertex, .warp, .clinePass,
    ]
}

private extension JSONEncoder {
    static var quotioCLI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
