import CryptoKit
import Foundation

nonisolated struct FactoryDroidCredential: Sendable, Equatable {
    let accessToken: String
    let activeOrganizationID: String?
    let sourcePath: String

    var accountKey: String {
        activeOrganizationID ?? "Factory Droid"
    }
}

nonisolated enum FactoryDroidCredentialReader {
    static let credentialsDirectory = "~/.factory"

    static func load(directory: URL? = nil) -> FactoryDroidCredential? {
        let directory = directory ?? URL(
            fileURLWithPath: MonitorIdentity.expand(credentialsDirectory),
            isDirectory: true
        )

        let keyFileCredentials = directory.appendingPathComponent("auth.v2.file")
        let keyFileKey = directory.appendingPathComponent("auth.v2.key")
        if let credential = loadEncrypted(
            credentialsURL: keyFileCredentials,
            keyData: try? Data(contentsOf: keyFileKey)
        ) {
            return credential
        }

        let keyringCredentials = directory.appendingPathComponent("auth.v2.keyring")
        let keyringKey = KeychainHelper.readExternalCredential(
            service: "Factory CLI",
            account: "auth-encryption-key"
        )
        if let credential = loadEncrypted(credentialsURL: keyringCredentials, keyData: keyringKey) {
            return credential
        }

        let legacyURL = directory.appendingPathComponent("auth.encrypted")
        guard let legacyData = try? Data(contentsOf: legacyURL) else { return nil }
        if let credential = parseCredential(legacyData, sourcePath: legacyURL.path) {
            return credential
        }
        guard let key = normalizedKey(keyringKey),
              let encrypted = String(data: legacyData, encoding: .utf8),
              let decrypted = decrypt(encrypted, key: key) else { return nil }
        return parseCredential(decrypted, sourcePath: legacyURL.path)
    }

    static func decryptCredential(
        encrypted: String,
        keyData: Data,
        sourcePath: String = "auth.v2.file"
    ) -> FactoryDroidCredential? {
        guard let key = normalizedKey(keyData),
              let decrypted = decrypt(encrypted, key: key) else { return nil }
        return parseCredential(decrypted, sourcePath: sourcePath)
    }

    private static func loadEncrypted(credentialsURL: URL, keyData: Data?) -> FactoryDroidCredential? {
        guard let encrypted = try? String(contentsOf: credentialsURL, encoding: .utf8),
              let keyData else { return nil }
        return decryptCredential(
            encrypted: encrypted.trimmingCharacters(in: .whitespacesAndNewlines),
            keyData: keyData,
            sourcePath: credentialsURL.path
        )
    }

    private static func normalizedKey(_ data: Data?) -> Data? {
        guard let data else { return nil }
        if data.count == 32 { return data }
        guard let string = String(data: data, encoding: .utf8),
              let decoded = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              decoded.count == 32 else { return nil }
        return decoded
    }

    private static func decrypt(_ encrypted: String, key: Data) -> Data? {
        let pieces = encrypted.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let nonceData = Data(base64Encoded: String(pieces[0])),
              let tag = Data(base64Encoded: String(pieces[1])),
              let ciphertext = Data(base64Encoded: String(pieces[2])),
              tag.count == 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
    }

    private static func parseCredential(_ data: Data, sourcePath: String) -> FactoryDroidCredential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = trimmed(json["access_token"] as? String) else { return nil }
        return FactoryDroidCredential(
            accessToken: accessToken,
            activeOrganizationID: trimmed(json["active_organization_id"] as? String),
            sourcePath: sourcePath
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

nonisolated struct FactoryDroidQuotaResponse: Decodable, Sendable {
    let usesTokenRateLimitsBilling: Bool?
    let limits: FactoryDroidLimitPools?
    let extraUsageBalanceCents: Double?
}

nonisolated struct FactoryDroidAuthMeResponse: Decodable, Sendable {
    struct UserProfile: Decodable, Sendable {
        let email: String?
    }

    let userProfile: UserProfile?

    var email: String? {
        guard let email = userProfile?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return email
    }
}

nonisolated struct FactoryDroidLimitPools: Decodable, Sendable {
    let standard: FactoryDroidLimitPool?
    let core: FactoryDroidLimitPool?
}

nonisolated struct FactoryDroidLimitPool: Decodable, Sendable {
    let fiveHour: FactoryDroidLimitWindow?
    let weekly: FactoryDroidLimitWindow?
    let monthly: FactoryDroidLimitWindow?
}

nonisolated struct FactoryDroidLimitWindow: Decodable, Sendable {
    let usedPercent: Double
    let windowEnd: String?
    let secondsRemaining: Double?
}

nonisolated enum FactoryDroidQuotaGroup: String, CaseIterable, Identifiable, Sendable {
    case standard
    case core

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "factory.quota.group.standard".localizedStatic()
        case .core: "factory.quota.group.core".localizedStatic()
        }
    }

    fileprivate var modelPrefix: String { "factory-\(rawValue)-" }
}

nonisolated struct FactoryDroidQuotaSection: Identifiable, Sendable {
    let group: FactoryDroidQuotaGroup
    let models: [ModelQuota]

    var id: FactoryDroidQuotaGroup { group }
    var title: String { group.title }

    static func sections(from models: [ModelQuota]) -> [FactoryDroidQuotaSection] {
        FactoryDroidQuotaGroup.allCases.compactMap { group in
            let groupModels = models.filter { $0.name.hasPrefix(group.modelPrefix) }
            guard !groupModels.isEmpty else { return nil }
            return FactoryDroidQuotaSection(group: group, models: groupModels)
        }
    }
}

nonisolated enum FactoryDroidQuotaMapper {
    static func map(_ response: FactoryDroidQuotaResponse, now: Date = Date()) -> ProviderQuotaData {
        if response.usesTokenRateLimitsBilling == false {
            return ProviderQuotaData(
                models: [ModelQuota(
                    name: "factory-billing-mode",
                    percentage: -1,
                    resetTime: "",
                    presentation: .status(text: "factory.status.legacyBilling".localizedStatic())
                )],
                lastUpdated: now
            )
        }

        var models: [ModelQuota] = []
        append(pool: response.limits?.standard, prefix: "factory-standard", to: &models)
        append(pool: response.limits?.core, prefix: "factory-core", to: &models)

        if let cents = response.extraUsageBalanceCents {
            models.append(ModelQuota(
                name: "factory-extra-balance",
                percentage: -1,
                resetTime: "",
                presentation: .amount(
                    value: max(0, cents) / 100,
                    unit: .usd,
                    semantics: .balance
                )
            ))
        }

        return ProviderQuotaData(models: models, lastUpdated: now)
    }

    private static func append(
        pool: FactoryDroidLimitPool?,
        prefix: String,
        to models: inout [ModelQuota]
    ) {
        guard let pool else { return }
        for (suffix, window) in [
            ("five-hour", pool.fiveHour),
            ("weekly", pool.weekly),
            ("monthly", pool.monthly),
        ] {
            guard let window else { continue }
            models.append(ModelQuota(
                name: prefix + "-" + suffix,
                percentage: max(0, min(100, 100 - window.usedPercent)),
                resetTime: window.windowEnd ?? ""
            ))
        }
    }

}

actor FactoryDroidQuotaFetcher {
    private let vault: MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private var session: URLSession
    private let limitsURL = URL(string: "https://api.factory.ai/api/billing/limits")!
    private let profileURL = URL(string: "https://api.factory.ai/api/app/auth/me")!

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared
    ) {
        self.vault = vault
        self.metadata = metadata
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        let disabledAccountIDs = await metadata.disabledAccountIDs()

        if let localCredential = FactoryDroidCredentialReader.load() {
            let account = Self.localAccount(for: localCredential)
            if !disabledAccountIDs.contains(account.id),
               let quota = await fetch(accessToken: localCredential.accessToken) {
                results[account.accountKey] = quota
            }
        }

        for account in await vault.accounts()
        where account.provider == .factoryDroid && !disabledAccountIDs.contains(account.id) {
            guard let credential = await vault.credential(for: account.id),
                  let quota = await fetch(accessToken: credential.accessToken) else { continue }
            results[account.accountKey] = quota
        }
        return results
    }

    nonisolated static func localAccount(for credential: FactoryDroidCredential) -> MonitorAccount {
        .make(
            provider: .factoryDroid,
            accountKey: credential.accountKey,
            displayName: "Factory Droid",
            source: .nativeCredential,
            credentialReference: credential.sourcePath
        )
    }

    private func fetch(accessToken: String) async -> ProviderQuotaData? {
        async let profile = fetchProfile(accessToken: accessToken)

        var request = URLRequest(url: limitsURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 || http.statusCode == 403 {
            return ProviderQuotaData(isForbidden: true)
        }
        guard 200...299 ~= http.statusCode,
              let decoded = try? JSONDecoder().decode(FactoryDroidQuotaResponse.self, from: data) else {
            return nil
        }
        var quota = FactoryDroidQuotaMapper.map(decoded)
        quota.accountDisplayName = await profile?.email
        return quota
    }

    private func fetchProfile(accessToken: String) async -> FactoryDroidAuthMeResponse? {
        var request = URLRequest(url: profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode else { return nil }
        return try? JSONDecoder().decode(FactoryDroidAuthMeResponse.self, from: data)
    }
}
