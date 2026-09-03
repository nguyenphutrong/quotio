import Foundation
import QuotioApplication
import QuotioDomain

public actor LocalAccountDiscovery: AccountDiscovering {
    private let vault: any CredentialVault
    private let authFiles: any AuthFileRepository
    private let metadata: any AccountMetadataRepository
    private let externalCredentials: any ExternalCredentialReading
    private let environment: [String: String]
    private let homeDirectory: URL
    private let factoryCredentials: any FactoryDroidCredentialLoading
    private let kiroCredentials: any KiroQuotaCredentialSourcing
    private let quotaFiles: any QuotaCredentialFileReading
    private let devinDatabase: any DevinCredentialDatabaseReading
    private let claudeDesktop: ClaudeDesktopCredentialReader
    private let antigravityDatabase: AntigravitySwitchDatabase

    public init(
        vault: any CredentialVault,
        authFileRepository: any AuthFileRepository,
        metadataRepository: any AccountMetadataRepository,
        externalCredentials: any ExternalCredentialReading
    ) {
        self.vault = vault
        self.authFiles = authFileRepository
        self.metadata = metadataRepository
        self.externalCredentials = externalCredentials
        environment = ProcessInfo.processInfo.environment
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        factoryCredentials = LocalFactoryDroidCredentialStore(
            externalCredentials: externalCredentials
        )
        kiroCredentials = LocalKiroQuotaCredentialSource()
        quotaFiles = LocalQuotaCredentialFileReader()
        devinDatabase = LocalDevinCredentialDatabaseReader()
        claudeDesktop = ClaudeDesktopCredentialReader(externalCredentials: externalCredentials)
        antigravityDatabase = AntigravitySwitchDatabase()
    }

    init(
        vault: any CredentialVault,
        authFileRepository: any AuthFileRepository,
        metadataRepository: any AccountMetadataRepository,
        externalCredentials: any ExternalCredentialReading,
        environment: [String: String],
        homeDirectory: URL,
        factoryCredentials: any FactoryDroidCredentialLoading,
        kiroCredentials: any KiroQuotaCredentialSourcing,
        quotaFiles: any QuotaCredentialFileReading,
        devinDatabase: any DevinCredentialDatabaseReading,
        claudeDesktop: ClaudeDesktopCredentialReader,
        antigravityDatabase: AntigravitySwitchDatabase
    ) {
        self.vault = vault
        self.authFiles = authFileRepository
        self.metadata = metadataRepository
        self.externalCredentials = externalCredentials
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.factoryCredentials = factoryCredentials
        self.kiroCredentials = kiroCredentials
        self.quotaFiles = quotaFiles
        self.devinDatabase = devinDatabase
        self.claudeDesktop = claudeDesktop
        self.antigravityDatabase = antigravityDatabase
    }

    public func discoverAccounts() async -> [Account] {
        let legacyFiles = await authFiles.scanAllAuthFiles()
        let aliases = Self.codexAliases(from: legacyFiles)
        var candidates = await canonicalizeCodexAccounts(await vault.accounts(), aliases: aliases)
        candidates.append(contentsOf: await discoverNativeFiles(codexAliases: aliases))
        candidates.append(contentsOf: await discoverNativeKeychains(codexAliases: aliases))
        candidates.append(contentsOf: legacyFiles.map(Self.legacyAccount))
        return AccountSelectionPolicy.preferred(
            candidates,
            disabledIDs: await metadata.disabledAccountIDs()
        )
    }

    static func legacyAccount(_ file: AuthFileDescriptor) -> Account {
        let accountKey: String
        switch file.providerID.rawValue {
        case QuotaProvider.codex.rawValue, QuotaProvider.copilot.rawValue, "copilot":
            accountKey = file.menuBarAccountKey
        default:
            accountKey = nonBlank(file.email)
                ?? file.filename.replacingOccurrences(of: ".json", with: "")
        }
        return Account.make(
            providerID: file.providerID,
            accountKey: accountKey,
            displayName: nonBlank(file.email) ?? nonBlank(file.login) ?? file.filename,
            source: .legacyCLIProxy,
            credentialReference: file.filePath
        )
    }

    static func canonicalizeCodexAccount(
        _ account: Account,
        accountID: String?,
        aliases: [String: String]
    ) -> Account {
        guard account.providerID.rawValue == QuotaProvider.codex.rawValue,
              let accountID = nonBlank(accountID),
              let canonicalKey = aliases[accountID] else {
            return account
        }
        return Account(
            identity: AccountIdentity(
                id: account.id,
                providerID: account.providerID,
                accountKey: canonicalKey
            ),
            displayName: account.displayName,
            source: account.source,
            credentialReference: account.credentialReference,
            capabilities: account.capabilities,
            status: account.status,
            credentialMetadata: account.credentialMetadata
        )
    }

    private static func codexAliases(from files: [AuthFileDescriptor]) -> [String: String] {
        var keysByAccountID: [String: Set<String>] = [:]
        for file in files where file.providerID.rawValue == QuotaProvider.codex.rawValue {
            guard let json = json(at: file.filePath) else { continue }
            let accountID = nonBlank(json["account_id"] as? String)
                ?? jwtNestedString(
                    json["id_token"] as? String,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            guard let accountID else { continue }
            keysByAccountID[accountID, default: []].insert(file.menuBarAccountKey)
        }
        return keysByAccountID.reduce(into: [:]) { aliases, entry in
            guard entry.value.count == 1, let key = entry.value.first else { return }
            aliases[entry.key] = key
        }
    }

    private func canonicalizeCodexAccounts(
        _ accounts: [Account],
        aliases: [String: String]
    ) async -> [Account] {
        var result: [Account] = []
        for account in accounts {
            guard account.providerID.rawValue == QuotaProvider.codex.rawValue,
                  let credential = await vault.credential(for: account.id) else {
                result.append(account)
                continue
            }
            let accountID = credential.accountID
                ?? Self.jwtNestedString(
                    credential.idToken,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            result.append(Self.canonicalizeCodexAccount(
                account,
                accountID: accountID,
                aliases: aliases
            ))
        }
        return result
    }

    private func discoverNativeFiles(codexAliases: [String: String]) async -> [Account] {
        var accounts = discoverCodexFiles(aliases: codexAliases)
        accounts.append(contentsOf: discoverClaudeFile())
        if claudeDesktop.hasCredentialMaterial() {
            accounts.append(Self.account(
                provider: .claude,
                accountKey: "Claude Desktop",
                source: .localIDE,
                credentialReference: "claude-desktop"
            ))
        }
        accounts.append(contentsOf: discoverCopilotFiles())
        accounts.append(contentsOf: await discoverKiroFile())
        accounts.append(contentsOf: await discoverFactoryDroidCredential())
        accounts.append(contentsOf: await discoverAmpCredential())
        accounts.append(contentsOf: await discoverDevinCredential())
        accounts.append(contentsOf: await discoverGrokCredentials())
        if await antigravityDatabase.hasCredential() {
            accounts.append(Self.account(
                provider: .antigravity,
                accountKey: "Antigravity",
                source: .localIDE,
                credentialReference: homeDirectory
                    .appendingPathComponent(
                        "Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
                    ).path
            ))
        }
        return accounts
    }

    private func discoverFactoryDroidCredential() async -> [Account] {
        guard let credential = await factoryCredentials.load() else { return [] }
        return [Self.account(
            provider: .factoryDroid,
            accountKey: credential.accountKey,
            source: .nativeCredential,
            credentialReference: credential.sourcePath
        )]
    }

    private func discoverAmpCredential() async -> [Account] {
        let path = homeDirectory.appendingPathComponent(".local/share/amp/secrets.json").path
        guard let data = await quotaFiles.read(path: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"].contains(where: {
                  Self.nonBlank(json[$0] as? String) != nil
              }) else {
            return []
        }
        return [Self.account(
            provider: .amp,
            accountKey: AmpQuotaFetcher.localAccountKey,
            source: .nativeCredential,
            credentialReference: path
        )]
    }

    private func discoverDevinCredential() async -> [Account] {
        let credentialsPath = homeDirectory
            .appendingPathComponent(".local/share/devin/credentials.toml").path
        if let data = await quotaFiles.read(path: credentialsPath),
           let text = String(data: data, encoding: .utf8),
           DevinQuotaFetcher.parseCredentialsTOML(text) != nil {
            return [Self.account(
                provider: .devin,
                accountKey: DevinQuotaFetcher.accountKey,
                source: .nativeCredential,
                credentialReference: credentialsPath
            )]
        }
        let databasePath = homeDirectory.appendingPathComponent(
            "Library/Application Support/Devin/User/globalStorage/state.vscdb"
        ).path
        guard devinDatabase.credential(path: databasePath) != nil else { return [] }
        return [Self.account(
            provider: .devin,
            accountKey: DevinQuotaFetcher.accountKey,
            source: .localIDE,
            credentialReference: databasePath
        )]
    }

    private func discoverGrokCredentials() async -> [Account] {
        let path = homeDirectory.appendingPathComponent(".grok/auth.json").path
        guard let data = await quotaFiles.read(path: path) else { return [] }
        return GrokQuotaFetcher.loadCandidates(data: data).map { candidate in
            Self.account(
                provider: .grok,
                accountKey: candidate.entryKey,
                displayName: candidate.displayName,
                source: .nativeCredential,
                credentialReference: path + "#" + candidate.entryKey
            )
        }
    }

    private func discoverCodexFiles(aliases: [String: String]) -> [Account] {
        var paths: [String] = []
        if let codexHome = Self.nonBlank(environment["CODEX_HOME"]) {
            paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json").path)
        }
        paths.append(homeDirectory.appendingPathComponent(".config/codex/auth.json").path)
        paths.append(homeDirectory.appendingPathComponent(".codex/auth.json").path)
        return paths.compactMap { path in
            guard let credential = LocalCodexQuotaCredentialLoader.loadNative(path: path) else {
                return nil
            }
            let account = Self.account(
                provider: .codex,
                accountKey: credential.accountKey,
                source: .nativeCredential,
                credentialReference: path
            )
            return Self.canonicalizeCodexAccount(
                account,
                accountID: credential.accountID,
                aliases: aliases
            )
        }
    }

    private func discoverClaudeFile() -> [Account] {
        let base = Self.nonBlank(environment["CLAUDE_CONFIG_DIR"])
            .map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".claude")
        let path = base.appendingPathComponent(".credentials.json").path
        guard let credential = LocalClaudeQuotaCredentialLoader.load(path: path) else { return [] }
        return [Self.account(
            provider: .claude,
            accountKey: credential.accountKey,
            source: .nativeCredential,
            credentialReference: path
        )]
    }

    private func discoverCopilotFiles() -> [Account] {
        [
            ".config/github-copilot/apps.json",
            ".config/github-copilot/hosts.json",
            ".config/gh/hosts.yml",
        ].compactMap { relativePath in
            let path = homeDirectory.appendingPathComponent(relativePath).path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Self.account(
                provider: .copilot,
                accountKey: CopilotQuotaFetcher.nativeAccountKey,
                source: .nativeCredential,
                credentialReference: path
            )
        }
    }

    private func discoverKiroFile() async -> [Account] {
        await kiroCredentials.credentials().compactMap { credential in
            guard let path = credential.filePath,
                  path.contains("/.aws/sso/cache/") else { return nil }
            return Self.account(
                provider: .kiro,
                accountKey: credential.accountKey,
                source: .nativeCredential,
                credentialReference: path
            )
        }
    }

    private func discoverNativeKeychains(codexAliases: [String: String]) async -> [Account] {
        var accounts: [Account] = []
        if let record = await externalCredentials.read(service: "Codex Auth", account: nil),
           let credential = LocalCodexQuotaCredentialLoader.loadNative(data: record.data) {
            let account = Self.account(
                provider: .codex,
                accountKey: credential.accountKey == "Codex User" ? "Codex" : credential.accountKey,
                source: .nativeCredential,
                credentialReference: "keychain:Codex Auth"
            )
            accounts.append(Self.canonicalizeCodexAccount(
                account,
                accountID: credential.accountID,
                aliases: codexAliases
            ))
        }
        if let record = await externalCredentials.read(
            service: "Claude Code-credentials",
            account: nil
        ), let credential = LocalClaudeQuotaCredentialLoader.load(data: record.data) {
            accounts.append(Self.account(
                provider: .claude,
                accountKey: credential.accountKey,
                source: .nativeCredential,
                credentialReference: "keychain:Claude Code-credentials"
            ))
        }
        return accounts
    }

    private static func account(
        provider: QuotaProvider,
        accountKey: String,
        displayName: String? = nil,
        source: AccountSource,
        credentialReference: String?
    ) -> Account {
        Account.make(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            accountKey: accountKey,
            displayName: displayName,
            source: source,
            credentialReference: credentialReference
        )
    }

    private static func json(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jwtNestedString(
        _ token: String?,
        namespace: String,
        claim: String
    ) -> String? {
        (jwtPayload(token)?[namespace] as? [String: Any])?[claim] as? String
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
