import CryptoKit
import Darwin
import Foundation

nonisolated struct FactoryDroidCredential: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
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

    @discardableResult
    static func persistRefresh(
        sourcePath: String,
        expectedRefreshToken: String,
        accessToken: String,
        refreshToken: String?
    ) throws -> Bool {
        let credentialsURL = URL(fileURLWithPath: sourcePath)
        if let values = try? credentialsURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw MonitorRuntimeError.symbolicLinkRefused
        }
        return try withDroidCredentialWriteLock(directory: credentialsURL.deletingLastPathComponent()) {
            let storedData = try Data(contentsOf: credentialsURL)
            let keyData: Data? = if credentialsURL.lastPathComponent == "auth.v2.file" {
                try? Data(contentsOf: credentialsURL.deletingLastPathComponent().appendingPathComponent("auth.v2.key"))
            } else {
                KeychainHelper.readExternalCredential(service: "Factory CLI", account: "auth-encryption-key")
            }

            let cleartext: Data
            let encryptionKey: Data?
            let encrypted = String(data: storedData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = try? JSONSerialization.jsonObject(with: storedData) as? [String: Any],
               json["access_token"] != nil {
                cleartext = storedData
                encryptionKey = nil
            } else if let encrypted,
                      let key = normalizedKey(keyData),
                      let decrypted = decrypt(encrypted, key: key) {
                cleartext = decrypted
                encryptionKey = key
            } else {
                throw MonitorRuntimeError.invalidCredential
            }

            guard var json = try JSONSerialization.jsonObject(with: cleartext) as? [String: Any],
                  trimmed(json["refresh_token"] as? String) == expectedRefreshToken else { return false }
            json["access_token"] = accessToken
            json["refresh_token"] = refreshToken ?? expectedRefreshToken
            let updated = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            let output = if let key = encryptionKey {
                try encrypt(updated, key: key)
            } else {
                updated
            }

            try SecureAtomicFileWriter.write(output, to: credentialsURL)
            return true
        }
    }

    static func canPersistRefresh(sourcePath: String, expectedRefreshToken: String) -> Bool {
        let credentialsURL = URL(fileURLWithPath: sourcePath)
        let credentialsDirectory = credentialsURL.deletingLastPathComponent()
        if let values = try? credentialsURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return false
        }
        guard FileManager.default.isWritableFile(atPath: credentialsDirectory.path),
              FileManager.default.isWritableFile(atPath: credentialsURL.path),
              let storedData = try? Data(contentsOf: credentialsURL) else { return false }
        if let json = try? JSONSerialization.jsonObject(with: storedData) as? [String: Any] {
            return trimmed(json["refresh_token"] as? String) == expectedRefreshToken
        }

        let keyData: Data? = if credentialsURL.lastPathComponent == "auth.v2.file" {
            try? Data(contentsOf: credentialsURL.deletingLastPathComponent().appendingPathComponent("auth.v2.key"))
        } else {
            KeychainHelper.readExternalCredential(service: "Factory CLI", account: "auth-encryption-key")
        }
        guard let encrypted = String(data: storedData, encoding: .utf8),
              let key = normalizedKey(keyData),
              let cleartext = decrypt(encrypted.trimmingCharacters(in: .whitespacesAndNewlines), key: key),
              let json = try? JSONSerialization.jsonObject(with: cleartext) as? [String: Any] else { return false }
        return trimmed(json["refresh_token"] as? String) == expectedRefreshToken
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

    private static func withDroidCredentialWriteLock<T>(directory: URL, operation: () throws -> T) throws -> T {
        let manager = FileManager.default
        let lockURL = directory.appendingPathComponent("auth.v2.write.lock", isDirectory: true)
        let token = UUID().uuidString
        let pendingURL = directory.appendingPathComponent("auth.v2.write.lock.\(token).pending", isDirectory: true)
        try manager.createDirectory(
            at: pendingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: pendingURL) }
        let ownerData = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ])
        let ownerURL = pendingURL.appendingPathComponent("owner.json")
        try ownerData.write(to: ownerURL, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)

        let deadline = Date().addingTimeInterval(2)
        while rename(pendingURL.path, lockURL.path) != 0 {
            guard [EEXIST, ENOTEMPTY, ENOTDIR, EISDIR].contains(errno), Date() < deadline else {
                throw MonitorRuntimeError.credentialWriteFailed
            }
            if try reclaimAbandonedDroidCredentialWriteLock(at: lockURL, manager: manager) {
                continue
            }
            Thread.sleep(forTimeInterval: 0.015)
        }

        defer {
            if let data = try? Data(contentsOf: lockURL.appendingPathComponent("owner.json")),
               let owner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               owner["token"] as? String == token {
                try? manager.removeItem(at: lockURL)
            }
        }
        return try operation()
    }

    private static func reclaimAbandonedDroidCredentialWriteLock(
        at lockURL: URL,
        manager: FileManager
    ) throws -> Bool {
        guard let initial = droidCredentialWriteLockSnapshot(at: lockURL, manager: manager),
              initial.isAbandoned else { return false }

        let reclaimURL = URL(fileURLWithPath: lockURL.path + ".reclaim", isDirectory: true)
        let token = UUID().uuidString
        let pendingURL = URL(fileURLWithPath: reclaimURL.path + ".\(token).pending", isDirectory: true)
        try manager.createDirectory(
            at: pendingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: pendingURL) }
        let ownerData = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ])
        let ownerURL = pendingURL.appendingPathComponent("owner.json")
        try ownerData.write(to: ownerURL, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)

        guard rename(pendingURL.path, reclaimURL.path) == 0 else {
            if let abandonedReclaim = droidCredentialWriteLockSnapshot(at: reclaimURL, manager: manager),
               abandonedReclaim.isAbandoned,
               droidCredentialWriteLockSnapshot(at: reclaimURL, manager: manager) == abandonedReclaim {
                try? manager.removeItem(at: reclaimURL)
            }
            return false
        }
        defer {
            if droidCredentialWriteLockSnapshot(at: reclaimURL, manager: manager)?.token == token {
                try? manager.removeItem(at: reclaimURL)
            }
        }
        guard droidCredentialWriteLockSnapshot(at: lockURL, manager: manager) == initial else { return false }
        try manager.removeItem(at: lockURL)
        return true
    }

    private static func droidCredentialWriteLockSnapshot(
        at lockURL: URL,
        manager: FileManager
    ) -> DroidCredentialWriteLockSnapshot? {
        guard let attributes = try? manager.attributesOfItem(atPath: lockURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        let ownerData = try? Data(contentsOf: lockURL.appendingPathComponent("owner.json"))
        let owner = ownerData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return DroidCredentialWriteLockSnapshot(
            token: owner?["token"] as? String,
            pid: (owner?["pid"] as? NSNumber)?.int32Value,
            modificationDate: modificationDate
        )
    }

    private struct DroidCredentialWriteLockSnapshot: Equatable {
        let token: String?
        let pid: Int32?
        let modificationDate: Date

        var isAbandoned: Bool {
            if let pid {
                return kill(pid, 0) != 0 && errno == ESRCH
            }
            return Date().timeIntervalSince(modificationDate) >= 10
        }
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

    private static func encrypt(_ cleartext: Data, key: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
        let sealed = try AES.GCM.seal(cleartext, using: SymmetricKey(data: key), nonce: nonce)
        return Data([
            Data(nonce).base64EncodedString(),
            sealed.tag.base64EncodedString(),
            sealed.ciphertext.base64EncodedString(),
        ].joined(separator: ":").utf8)
    }

    private static func parseCredential(_ data: Data, sourcePath: String) -> FactoryDroidCredential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = trimmed(json["access_token"] as? String) else { return nil }
        return FactoryDroidCredential(
            accessToken: accessToken,
            refreshToken: trimmed(json["refresh_token"] as? String),
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

nonisolated struct FactoryDroidTokenRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
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
        append(pool: response.limits?.standard, prefix: "factory-standard", now: now, to: &models)
        append(pool: response.limits?.core, prefix: "factory-core", now: now, to: &models)

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
        now: Date,
        to models: inout [ModelQuota]
    ) {
        guard let pool else { return }
        for (suffix, window) in [
            ("five-hour", pool.fiveHour),
            ("weekly", pool.weekly),
            ("monthly", pool.monthly),
        ] {
            guard let window else { continue }
            let usedPercent = isExpired(window.windowEnd, now: now) ? 0 : window.usedPercent
            models.append(ModelQuota(
                name: prefix + "-" + suffix,
                percentage: max(0, min(100, 100 - usedPercent)),
                resetTime: window.windowEnd ?? ""
            ))
        }
    }

    private static func isExpired(_ windowEnd: String?, now: Date) -> Bool {
        guard let windowEnd else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let endDate = fractional.date(from: windowEnd) ?? ISO8601DateFormatter().date(from: windowEnd)
        return endDate.map { $0 < now } ?? false
    }

}

actor FactoryDroidQuotaFetcher {
    private static let workOSClientID = "client_01HNM792M5G5G1A2THWPXKFMXB"

    private let vault: MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private var session: URLSession
    private var pendingLocalCredentials: [String: (credential: FactoryDroidCredential, replacedRefreshToken: String)] = [:]
    private let limitsURL = URL(string: "https://api.factory.ai/api/billing/limits")!
    private let profileURL = URL(string: "https://api.factory.ai/api/app/auth/me")!
    private let refreshURL = URL(string: "https://api.workos.com/user_management/authenticate")!

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
               let quota = await fetch(localCredential: localCredential) {
                results[account.accountKey] = quota
            }
        }

        for account in await vault.accounts()
        where account.provider == .factoryDroid && !disabledAccountIDs.contains(account.id) {
            guard let credential = await vault.credential(for: account.id),
                  let quota = await fetch(accessToken: credential.accessToken).quota else { continue }
            results[account.accountKey] = quota
        }
        return results
    }

    /// Fetches quota using only the local or vaulted credential matching `accountKey`.
    func fetchQuota(accountKey: String) async -> ProviderQuotaData? {
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        if let localCredential = FactoryDroidCredentialReader.load() {
            let account = Self.localAccount(for: localCredential)
            if account.accountKey == accountKey && !disabledAccountIDs.contains(account.id) {
                return await fetch(localCredential: localCredential)
            }
        }

        guard let account = await vault.accounts().first(where: {
            $0.provider == .factoryDroid
                && $0.accountKey == accountKey
                && !disabledAccountIDs.contains($0.id)
        }), let credential = await vault.credential(for: account.id) else { return nil }
        return await fetch(accessToken: credential.accessToken).quota
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

    nonisolated static func makeRefreshRequest(
        refreshToken: String,
        organizationID: String?,
        url: URL = URL(string: "https://api.workos.com/user_management/authenticate")!
    ) -> URLRequest {
        var items = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: workOSClientID),
        ]
        if let organizationID { items.append(URLQueryItem(name: "organization_id", value: organizationID)) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(items.map {
            formEncoded($0.name) + "=" + formEncoded($0.value ?? "")
        }.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private nonisolated static func formEncoded(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func fetch(localCredential: FactoryDroidCredential) async -> ProviderQuotaData? {
        var credential = localCredential
        if let pending = pendingLocalCredentials[credential.sourcePath] {
            if credential.refreshToken == pending.replacedRefreshToken {
                credential = pending.credential
                if (try? FactoryDroidCredentialReader.persistRefresh(
                    sourcePath: credential.sourcePath,
                    expectedRefreshToken: pending.replacedRefreshToken,
                    accessToken: credential.accessToken,
                    refreshToken: credential.refreshToken
                )) == true {
                    pendingLocalCredentials.removeValue(forKey: credential.sourcePath)
                }
            } else {
                pendingLocalCredentials.removeValue(forKey: credential.sourcePath)
            }
        }
        var didRefresh = false
        if Self.isExpiring(accessToken: credential.accessToken),
           let refreshed = await refresh(credential) {
            credential = refreshed
            didRefresh = true
        }

        var response = await fetch(accessToken: credential.accessToken)
        if Self.shouldRefresh(statusCode: response.statusCode, didRefresh: didRefresh),
           let refreshed = await refresh(credential) {
            response = await fetch(accessToken: refreshed.accessToken)
        }
        return response.quota
    }

    nonisolated static func shouldRefresh(statusCode: Int?, didRefresh: Bool) -> Bool {
        statusCode == 401 && !didRefresh
    }

    private func refresh(_ credential: FactoryDroidCredential) async -> FactoryDroidCredential? {
        guard let refreshToken = credential.refreshToken,
              FactoryDroidCredentialReader.canPersistRefresh(
                sourcePath: credential.sourcePath,
                expectedRefreshToken: refreshToken
              ) else { return nil }
        let request = Self.makeRefreshRequest(
            refreshToken: refreshToken,
            organizationID: credential.activeOrganizationID,
            url: refreshURL
        )
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode,
              let refreshed = try? JSONDecoder().decode(FactoryDroidTokenRefreshResponse.self, from: data) else {
            return nil
        }

        let updatedCredential = FactoryDroidCredential(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            activeOrganizationID: credential.activeOrganizationID,
            sourcePath: credential.sourcePath
        )
        do {
            let persisted = try FactoryDroidCredentialReader.persistRefresh(
                sourcePath: credential.sourcePath,
                expectedRefreshToken: refreshToken,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken
            )
            if !persisted {
                pendingLocalCredentials[credential.sourcePath] = (updatedCredential, refreshToken)
            }
        } catch {
            Log.quota("Failed to persist refreshed Factory Droid credential")
            pendingLocalCredentials[credential.sourcePath] = (updatedCredential, refreshToken)
        }
        return updatedCredential
    }

    private nonisolated static func isExpiring(accessToken: String, leeway: TimeInterval = 60) -> Bool {
        let pieces = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return true }
        var payload = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = json["exp"] as? NSNumber else { return true }
        return Date().addingTimeInterval(leeway).timeIntervalSince1970 >= expiry.doubleValue
    }

    private func fetch(accessToken: String) async -> (quota: ProviderQuotaData?, statusCode: Int?) {
        async let profile = fetchProfile(accessToken: accessToken)

        var request = URLRequest(url: limitsURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return (nil, nil) }
        if http.statusCode == 401 || http.statusCode == 403 {
            return (ProviderQuotaData(isForbidden: true), http.statusCode)
        }
        guard 200...299 ~= http.statusCode,
              let decoded = try? JSONDecoder().decode(FactoryDroidQuotaResponse.self, from: data) else {
            return (nil, http.statusCode)
        }
        var quota = FactoryDroidQuotaMapper.map(decoded)
        quota.accountDisplayName = await profile?.email
        return (quota, http.statusCode)
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
