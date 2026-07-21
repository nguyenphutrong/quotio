import CryptoKit
import Foundation

nonisolated enum MonitorAccountSource: String, Codable, Sendable, CaseIterable {
    case quotioKeychain
    case nativeCredential
    case legacyCLIProxy
    case localIDE
    case apiKey

    var priority: Int {
        switch self {
        case .quotioKeychain: 300
        case .nativeCredential, .localIDE, .apiKey: 200
        case .legacyCLIProxy: 100
        }
    }

    var displayName: String {
        localizationKey.localizedStatic()
    }

    var localizationKey: String {
        switch self {
        case .quotioKeychain: "monitor.source.quotio"
        case .nativeCredential: "monitor.source.localLogin"
        case .legacyCLIProxy: "monitor.source.cliProxyFile"
        case .localIDE: "monitor.source.localIDE"
        case .apiKey: "monitor.source.apiKey"
        }
    }
}

nonisolated struct MonitorAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: AIProvider
    let accountKey: String
    let displayName: String
    let source: MonitorAccountSource
    let credentialReference: String?
    let canDelete: Bool
    var isDisabled: Bool

    var deduplicationKey: String {
        let identity = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(provider.rawValue):\(identity)"
    }

    static func make(
        provider: AIProvider,
        accountKey: String,
        displayName: String? = nil,
        source: MonitorAccountSource,
        credentialReference: String? = nil,
        canDelete: Bool = false,
        isDisabled: Bool = false
    ) -> MonitorAccount {
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let idSeed = "\(provider.rawValue)|\(normalized.lowercased())"
        return MonitorAccount(
            id: "monitor-" + MonitorIdentity.fingerprint(idSeed),
            provider: provider,
            accountKey: normalized,
            displayName: displayName?.nilIfBlank ?? normalized,
            source: source,
            credentialReference: credentialReference,
            canDelete: canDelete,
            isDisabled: isDisabled
        )
    }

    static func makeLegacy(_ file: DirectAuthFile) -> MonitorAccount {
        let accountKey: String
        if file.provider == .codex || file.provider == .copilot {
            accountKey = file.menuBarAccountKey
        } else if let email = file.email, !email.isEmpty {
            accountKey = email
        } else {
            accountKey = file.filename.replacingOccurrences(of: ".json", with: "")
        }
        let displayName = file.email?.nilIfBlank ?? file.login?.nilIfBlank ?? file.filename
        return make(
            provider: file.provider,
            accountKey: accountKey,
            displayName: displayName,
            source: .legacyCLIProxy,
            credentialReference: file.filePath
        )
    }
}

nonisolated struct MonitorRefreshIssue: Codable, Hashable, Sendable {
    let message: String
    let occurredAt: Date
}

nonisolated struct MonitorRefreshBatch: Sendable {
    var accounts: [MonitorAccount]
    var quotas: [AIProvider: [String: ProviderQuotaData]]
    var issues: [AIProvider: MonitorRefreshIssue]
}

nonisolated protocol MonitorProviderRuntime: Sendable {
    var provider: AIProvider { get }
    func discoverAccounts() async -> [MonitorAccount]
    func refresh(force: Bool) async -> [String: ProviderQuotaData]
}

nonisolated protocol MonitorCredentialStore: Sendable {
    func accounts() async -> [MonitorAccount]
    func credential(for accountID: String) async -> MonitorOAuthCredential?
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential?
    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) async throws
    func delete(accountID: String) async
}

nonisolated struct MonitorOAuthCredential: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var expiresAt: Date?
    var extra: [String: String]
}

actor MonitorCredentialVault: MonitorCredentialStore {
    static let shared = MonitorCredentialVault()

    private let metadata: MonitorMetadataStore
    private var loadedGenerations: [String: String] = [:]

    init(metadata: MonitorMetadataStore = .shared) {
        self.metadata = metadata
    }

    func accounts() async -> [MonitorAccount] {
        await metadata.accounts()
    }

    func credential(for accountID: String) -> MonitorOAuthCredential? {
        guard let data = KeychainHelper.getMonitorCredential(account: accountID) else { return nil }
        loadedGenerations[accountID] = MonitorIdentity.fingerprint(data.base64EncodedString())
        return try? JSONDecoder().decode(MonitorOAuthCredential.self, from: data)
    }

    func reloadLatest(accountID: String) -> MonitorOAuthCredential? {
        credential(for: accountID)
    }

    func save(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount) async throws {
        let data = try JSONEncoder().encode(credential)
        let saved: Bool
        if let expected = loadedGenerations[account.id] {
            saved = KeychainHelper.compareAndSwapMonitorCredential(
                data,
                account: account.id,
                expectedFingerprint: expected
            )
        } else {
            saved = KeychainHelper.saveMonitorCredential(data, account: account.id)
        }
        guard saved else {
            throw MonitorRuntimeError.credentialWriteFailed
        }
        loadedGenerations[account.id] = MonitorIdentity.fingerprint(data.base64EncodedString())
        try await self.metadata.saveAccount(account)
    }

    func delete(accountID: String) async {
        KeychainHelper.deleteMonitorCredential(account: accountID)
        loadedGenerations.removeValue(forKey: accountID)
        try? await metadata.deleteAccount(accountID)
    }
}

actor MonitorMetadataStore {
    static let shared = MonitorMetadataStore()

    private struct Payload: Codable {
        var accounts: [MonitorAccount] = []
        var disabledAccountIDs: Set<String> = []
    }

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio/Monitor/accounts-v1.json")
    }

    func accounts() -> [MonitorAccount] { load().accounts }
    func disabledAccountIDs() -> Set<String> { load().disabledAccountIDs }

    func saveAccount(_ account: MonitorAccount) throws {
        var payload = load()
        payload.accounts.removeAll { $0.id == account.id }
        payload.accounts.append(account)
        try save(payload)
    }

    func deleteAccount(_ accountID: String) throws {
        var payload = load()
        payload.accounts.removeAll { $0.id == accountID }
        payload.disabledAccountIDs.remove(accountID)
        try save(payload)
    }

    func setDisabled(_ disabled: Bool, accountID: String) throws {
        var payload = load()
        if disabled { payload.disabledAccountIDs.insert(accountID) }
        else { payload.disabledAccountIDs.remove(accountID) }
        try save(payload)
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return Payload() }
        return payload
    }

    private func save(_ payload: Payload) throws {
        try SecureAtomicFileWriter.write(try JSONEncoder().encode(payload), to: url)
    }
}

actor MonitorSnapshotStore {
    private struct Payload: Codable {
        var quotas: [String: [String: ProviderQuotaData]]
    }

    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base
                .appendingPathComponent("Quotio", isDirectory: true)
                .appendingPathComponent("Monitor", isDirectory: true)
                .appendingPathComponent("snapshots-v1.json")
        }
    }

    func load() -> [AIProvider: [String: ProviderQuotaData]] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return [:]
        }
        return payload.quotas.reduce(into: [:]) { result, item in
            if let provider = AIProvider(rawValue: item.key) {
                result[provider] = item.value
            }
        }
    }

    func store(_ quotas: [AIProvider: [String: ProviderQuotaData]]) {
        let encoded = quotas.reduce(into: [String: [String: ProviderQuotaData]]()) {
            $0[$1.key.rawValue] = $1.value
        }
        guard let data = try? JSONEncoder().encode(Payload(quotas: encoded)) else { return }
        do {
            try SecureAtomicFileWriter.write(data, to: url)
        } catch {
            Log.quota("Failed to persist Monitor snapshot: \(error.localizedDescription)")
        }
    }
}

actor MonitorAccountDiscovery {
    private let vault: MonitorCredentialStore
    private let directAuthService: DirectAuthFileService
    private let metadata: MonitorMetadataStore

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        directAuthService: DirectAuthFileService = DirectAuthFileService(),
        metadata: MonitorMetadataStore = .shared
    ) {
        self.vault = vault
        self.directAuthService = directAuthService
        self.metadata = metadata
    }

    func discover() async -> [MonitorAccount] {
        let legacyFiles = await directAuthService.scanAllAuthFiles()
        let codexAliases = Self.codexAliases(from: legacyFiles)
        var candidates = await canonicalizeCodexAccounts(await vault.accounts(), aliases: codexAliases)
        candidates.append(contentsOf: await discoverNativeFiles(codexAliases: codexAliases))
        candidates.append(contentsOf: discoverNativeKeychains(codexAliases: codexAliases))
        let legacy = legacyFiles.map(MonitorAccount.makeLegacy)
        candidates.append(contentsOf: legacy)

        let disabled = await metadata.disabledAccountIDs()
        return Self.selectPreferred(candidates, disabledIDs: disabled)
    }

    nonisolated static func selectPreferred(
        _ candidates: [MonitorAccount],
        disabledIDs: Set<String> = []
    ) -> [MonitorAccount] {
        var selected: [String: MonitorAccount] = [:]
        for var account in candidates {
            account.isDisabled = disabledIDs.contains(account.id)
            let key = account.deduplicationKey
            if let existing = selected[key], existing.source.priority >= account.source.priority {
                continue
            }
            selected[key] = account
        }
        return selected.values.sorted {
            if $0.provider.displayName == $1.provider.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.provider.displayName < $1.provider.displayName
        }
    }

    nonisolated static func canonicalizeCodexAccount(
        _ account: MonitorAccount,
        accountID: String?,
        aliases: [String: String]
    ) -> MonitorAccount {
        guard account.provider == .codex,
              let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let canonicalKey = aliases[accountID] else { return account }
        return MonitorAccount(
            id: account.id,
            provider: account.provider,
            accountKey: canonicalKey,
            displayName: account.displayName,
            source: account.source,
            credentialReference: account.credentialReference,
            canDelete: account.canDelete,
            isDisabled: account.isDisabled
        )
    }

    private nonisolated static func codexAliases(from files: [DirectAuthFile]) -> [String: String] {
        var keysByAccountID: [String: Set<String>] = [:]
        for file in files where file.provider == .codex {
            guard let json = MonitorIdentity.json(at: file.filePath) else { continue }
            let accountID = (json["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(
                    json["id_token"] as? String,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountID.isEmpty else { continue }
            keysByAccountID[accountID, default: []].insert(file.filename.codexFilenameKey)
        }
        return keysByAccountID.reduce(into: [:]) { aliases, entry in
            guard entry.value.count == 1, let key = entry.value.first else { return }
            aliases[entry.key] = key
        }
    }

    private func canonicalizeCodexAccounts(
        _ accounts: [MonitorAccount],
        aliases: [String: String]
    ) async -> [MonitorAccount] {
        var result: [MonitorAccount] = []
        for account in accounts {
            guard account.provider == .codex,
                  let credential = await vault.credential(for: account.id) else {
                result.append(account)
                continue
            }
            let accountID = credential.accountID
                ?? MonitorIdentity.jwtNestedString(
                    credential.idToken,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            result.append(Self.canonicalizeCodexAccount(account, accountID: accountID, aliases: aliases))
        }
        return result
    }

    func setDisabled(_ disabled: Bool, accountID: String) async {
        try? await metadata.setDisabled(disabled, accountID: accountID)
    }

    func disabledAccountIDs() async -> Set<String> {
        await metadata.disabledAccountIDs()
    }

    private func discoverNativeFiles(codexAliases: [String: String]) async -> [MonitorAccount] {
        var accounts: [MonitorAccount] = []
        accounts.append(contentsOf: discoverCodexFiles(aliases: codexAliases))
        accounts.append(contentsOf: discoverClaudeFile())
        if ClaudeDesktopCredentialReader.hasCredentialMaterial() {
            accounts.append(.make(
                provider: .claude,
                accountKey: "Claude Desktop",
                source: .localIDE,
                credentialReference: "claude-desktop"
            ))
        }
        accounts.append(contentsOf: discoverGeminiFile())
        accounts.append(contentsOf: discoverCopilotFiles())
        accounts.append(contentsOf: discoverKiroFile())
        accounts.append(contentsOf: discoverFactoryDroidCredential())
        accounts.append(contentsOf: discoverDevinCredential())
        accounts.append(contentsOf: discoverGrokCredentials())
        let antigravityDatabase = MonitorIdentity.expand("~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        if let token = try? await AntigravityDatabaseService().getCurrentTokenInfo(),
           token.accessToken?.nilIfBlank != nil || token.refreshToken?.nilIfBlank != nil {
            accounts.append(.make(
                provider: .antigravity,
                accountKey: "Antigravity",
                source: .localIDE,
                credentialReference: antigravityDatabase
            ))
        }
        return accounts
    }

    private func discoverFactoryDroidCredential() -> [MonitorAccount] {
        guard let credential = FactoryDroidCredentialReader.load() else { return [] }
        return [FactoryDroidQuotaFetcher.localAccount(for: credential)]
    }

    private func discoverDevinCredential() -> [MonitorAccount] {
        let credentialsPath = MonitorIdentity.expand(DevinQuotaFetcher.credentialsPath)
        if let text = try? String(contentsOfFile: credentialsPath, encoding: .utf8),
           DevinQuotaFetcher.parseCredentialsTOML(text) != nil {
            return [.make(
                provider: .devin,
                accountKey: "Devin",
                source: .nativeCredential,
                credentialReference: credentialsPath
            )]
        }

        let databasePath = MonitorIdentity.expand(DevinQuotaFetcher.stateDBPath)
        guard DevinQuotaFetcher.loadAppCredential(path: databasePath) != nil else { return [] }
        return [.make(
            provider: .devin,
            accountKey: "Devin",
            source: .localIDE,
            credentialReference: databasePath
        )]
    }

    private func discoverGrokCredentials() -> [MonitorAccount] {
        let path = MonitorIdentity.expand(GrokQuotaFetcher.authPath)
        return GrokQuotaFetcher.loadCandidates(path: path).map { candidate in
            .make(
                provider: .grok,
                accountKey: candidate.entryKey,
                displayName: candidate.displayName,
                source: .nativeCredential,
                credentialReference: path + "#" + candidate.entryKey
            )
        }
    }

    private func discoverCodexFiles(aliases: [String: String]) -> [MonitorAccount] {
        var paths: [String] = []
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            paths.append((home as NSString).appendingPathComponent("auth.json"))
        }
        paths.append(contentsOf: ["~/.config/codex/auth.json", "~/.codex/auth.json"].map(MonitorIdentity.expand))
        return paths.compactMap { path in
            guard let json = MonitorIdentity.json(at: path),
                  let tokens = json["tokens"] as? [String: Any],
                  (tokens["access_token"] as? String)?.isEmpty == false else { return nil }
            let email = MonitorIdentity.jwtString(tokens["id_token"] as? String, claim: "email")
            let accountID = (tokens["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(tokens["id_token"] as? String, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
            let key = email ?? accountID ?? "Codex"
            let account = MonitorAccount.make(provider: .codex, accountKey: key, source: .nativeCredential, credentialReference: path)
            return Self.canonicalizeCodexAccount(account, accountID: accountID, aliases: aliases)
        }
    }

    private func discoverClaudeFile() -> [MonitorAccount] {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.nilIfBlank ?? MonitorIdentity.expand("~/.claude")
        let path = (base as NSString).appendingPathComponent(".credentials.json")
        guard let json = MonitorIdentity.json(at: path),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              (oauth["accessToken"] as? String)?.isEmpty == false else { return [] }
        let email = (oauth["email"] as? String) ?? "Claude Code"
        return [.make(provider: .claude, accountKey: email, source: .nativeCredential, credentialReference: path)]
    }

    private func discoverGeminiFile() -> [MonitorAccount] {
        let authPath = MonitorIdentity.expand("~/.gemini/oauth_creds.json")
        guard let auth = MonitorIdentity.json(at: authPath),
              (auth["access_token"] as? String)?.isEmpty == false else { return [] }
        let accountsPath = MonitorIdentity.expand("~/.gemini/google_accounts.json")
        let email = (MonitorIdentity.json(at: accountsPath)?["active"] as? String)
            ?? MonitorIdentity.jwtString(auth["id_token"] as? String, claim: "email")
            ?? "Gemini CLI"
        return [.make(provider: .gemini, accountKey: email, source: .nativeCredential, credentialReference: authPath)]
    }

    private func discoverCopilotFiles() -> [MonitorAccount] {
        let paths = [
            "~/.config/github-copilot/apps.json",
            "~/.config/github-copilot/hosts.json",
            "~/.config/gh/hosts.yml",
        ].map(MonitorIdentity.expand)
        return paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return MonitorAccount.make(provider: .copilot, accountKey: "GitHub Copilot", source: .nativeCredential, credentialReference: path)
        }
    }

    private func discoverKiroFile() -> [MonitorAccount] {
        let path = MonitorIdentity.expand("~/.aws/sso/cache/kiro-auth-token.json")
        guard let json = MonitorIdentity.json(at: path),
              (json["accessToken"] as? String ?? json["access_token"] as? String)?.isEmpty == false else { return [] }
        let key = (json["email"] as? String) ?? (json["profileArn"] as? String) ?? "Kiro"
        return [.make(provider: .kiro, accountKey: key, source: .nativeCredential, credentialReference: path)]
    }

    private func discoverNativeKeychains(codexAliases: [String: String]) -> [MonitorAccount] {
        var accounts: [MonitorAccount] = []
        if let data = KeychainHelper.readExternalCredential(service: "Codex Auth"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = json["tokens"] as? [String: Any],
           (tokens["access_token"] as? String)?.isEmpty == false {
            let idToken = tokens["id_token"] as? String
            let email = MonitorIdentity.jwtString(idToken, claim: "email") ?? "Codex"
            let accountID = (tokens["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(idToken, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
            let account = MonitorAccount.make(provider: .codex, accountKey: email, source: .nativeCredential, credentialReference: "keychain:Codex Auth")
            accounts.append(Self.canonicalizeCodexAccount(account, accountID: accountID, aliases: codexAliases))
        }
        if let data = KeychainHelper.readExternalCredential(service: "Claude Code-credentials"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           (oauth["accessToken"] as? String)?.isEmpty == false {
            accounts.append(.make(provider: .claude, accountKey: (oauth["email"] as? String) ?? "Claude Code", source: .nativeCredential, credentialReference: "keychain:Claude Code-credentials"))
        }
        if KeychainHelper.readExternalCredential(service: "gemini", account: "antigravity") != nil {
            accounts.append(.make(provider: .antigravity, accountKey: "Antigravity", source: .nativeCredential, credentialReference: "keychain:gemini:antigravity"))
        }
        if KeychainHelper.readExternalCredential(service: "gh:github.com") != nil {
            accounts.append(.make(provider: .copilot, accountKey: "GitHub Copilot", source: .nativeCredential, credentialReference: "keychain:gh:github.com"))
        }
        return accounts
    }
}

actor MonitorRefreshCoordinator {
    private let discovery: MonitorAccountDiscovery
    private let snapshots: MonitorSnapshotStore
    private var inFlight: [AIProvider: Task<[String: ProviderQuotaData], Never>] = [:]
    private var retryAfter: [AIProvider: Date] = [:]
    private(set) var issues: [AIProvider: MonitorRefreshIssue] = [:]

    init(
        discovery: MonitorAccountDiscovery = MonitorAccountDiscovery(),
        snapshots: MonitorSnapshotStore = MonitorSnapshotStore()
    ) {
        self.discovery = discovery
        self.snapshots = snapshots
    }

    func bootstrap() async -> MonitorRefreshBatch {
        let quotas = await snapshots.load()
        return MonitorRefreshBatch(
            accounts: await discoverAccounts(merging: quotas),
            quotas: quotas,
            issues: issues
        )
    }

    func discoverAccounts(merging quotas: [AIProvider: [String: ProviderQuotaData]] = [:]) async -> [MonitorAccount] {
        var accounts = await discovery.discover()
        accounts = Self.applyingQuotaDisplayNames(accounts, quotas: quotas)
        let disabledIDs = await discovery.disabledAccountIDs()
        let existingKeys = Set(accounts.map(\.deduplicationKey))
        var appendedKeys = existingKeys

        for (provider, accountQuotas) in quotas {
            let source: MonitorAccountSource
            switch provider {
            case .cursor, .trae: source = .localIDE
            case .glm, .warp, .clinePass, .factoryDroid, .openRouter: source = .apiKey
            default: source = .nativeCredential
            }
            for (accountKey, quota) in accountQuotas {
                let account = Self.makeQuotaDerivedAccount(
                    provider: provider,
                    accountKey: accountKey,
                    displayName: quota.accountDisplayName,
                    source: source,
                    disabledIDs: disabledIDs
                )
                guard appendedKeys.insert(account.deduplicationKey).inserted else { continue }
                accounts.append(account)
            }
        }
        let placeholders: [AIProvider: Set<String>] = [
            .copilot: ["github copilot"],
            .antigravity: ["antigravity"],
            .gemini: ["gemini cli"],
            .claude: ["claude code"],
            .codex: ["codex", "codex user"],
            .kiro: ["kiro"],
        ]
        accounts = accounts.filter { account in
            guard placeholders[account.provider]?.contains(account.accountKey.lowercased()) == true else { return true }
            return !accounts.contains {
                $0.provider == account.provider
                    && $0.id != account.id
                    && placeholders[account.provider]?.contains($0.accountKey.lowercased()) != true
                    && $0.source.priority >= account.source.priority
            }
        }
        return accounts.sorted {
            if $0.provider.displayName == $1.provider.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.provider.displayName < $1.provider.displayName
        }
    }

    nonisolated static func makeQuotaDerivedAccount(
        provider: AIProvider,
        accountKey: String,
        displayName: String? = nil,
        source: MonitorAccountSource,
        disabledIDs: Set<String>
    ) -> MonitorAccount {
        var account = MonitorAccount.make(
            provider: provider,
            accountKey: accountKey,
            displayName: displayName,
            source: source
        )
        account.isDisabled = disabledIDs.contains(account.id)
        return account
    }

    nonisolated static func applyingQuotaDisplayNames(
        _ accounts: [MonitorAccount],
        quotas: [AIProvider: [String: ProviderQuotaData]]
    ) -> [MonitorAccount] {
        accounts.map { account in
            guard let displayName = quotas[account.provider]?[account.accountKey]?.accountDisplayName else {
                return account
            }
            return MonitorAccount(
                id: account.id,
                provider: account.provider,
                accountKey: account.accountKey,
                displayName: displayName,
                source: account.source,
                credentialReference: account.credentialReference,
                canDelete: account.canDelete,
                isDisabled: account.isDisabled
            )
        }
    }

    func refresh(
        provider: AIProvider,
        force: Bool,
        previous: [String: ProviderQuotaData],
        credentialAvailability: MonitorCredentialAvailability = .unknown,
        operation: @escaping @Sendable () async -> [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        if !force, let retry = retryAfter[provider], retry > Date() {
            return previous
        }
        if let task = inFlight[provider] {
            return await task.value
        }

        let task = Task { await operation() }
        inFlight[provider] = task
        let fresh = await task.value
        inFlight[provider] = nil

        if fresh.isEmpty, credentialAvailability == .missing {
            issues.removeValue(forKey: provider)
            retryAfter.removeValue(forKey: provider)
            return [:]
        }

        if fresh.isEmpty, !previous.isEmpty {
            issues[provider] = MonitorRefreshIssue(
                message: "monitor.refresh.failed".localizedStatic(),
                occurredAt: Date()
            )
            retryAfter[provider] = Date().addingTimeInterval(60)
            return previous
        }

        if !fresh.isEmpty {
            var merged = previous
            merged.merge(fresh) { _, new in new }
            if fresh.count < previous.count {
                issues[provider] = MonitorRefreshIssue(
                    message: "monitor.refresh.partial".localizedStatic(),
                    occurredAt: Date()
                )
                retryAfter[provider] = Date().addingTimeInterval(60)
            } else {
                issues.removeValue(forKey: provider)
                retryAfter.removeValue(forKey: provider)
            }
            return merged
        }

        issues.removeValue(forKey: provider)
        retryAfter.removeValue(forKey: provider)
        return fresh
    }

    func finish(quotas: [AIProvider: [String: ProviderQuotaData]]) async {
        await snapshots.store(quotas)
    }

    func currentIssues() -> [AIProvider: MonitorRefreshIssue] {
        issues
    }

    func setDisabled(_ disabled: Bool, accountID: String) async {
        await discovery.setDisabled(disabled, accountID: accountID)
    }

    func deleteOwnedAccount(accountID: String) async {
        await MonitorCredentialVault.shared.delete(accountID: accountID)
    }
}

nonisolated enum MonitorCredentialAvailability: Equatable, Sendable {
    case unknown
    case present
    case missing
}

nonisolated enum SecureAtomicFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw MonitorRuntimeError.symbolicLinkRefused
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

nonisolated enum MonitorIdentity {
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func json(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func jwtString(_ token: String?, claim: String) -> String? {
        jwtPayload(token)?[claim] as? String
    }

    static func jwtNestedString(_ token: String?, namespace: String, claim: String) -> String? {
        (jwtPayload(token)?[namespace] as? [String: Any])?[claim] as? String
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

nonisolated enum MonitorRuntimeError: LocalizedError {
    case credentialWriteFailed
    case invalidCredential
    case symbolicLinkRefused

    var errorDescription: String? {
        switch self {
        case .credentialWriteFailed: "Could not save the Monitor credential in Keychain."
        case .invalidCredential: "The Monitor credential file is invalid."
        case .symbolicLinkRefused: "Refusing to write credentials through a symbolic link."
        }
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
