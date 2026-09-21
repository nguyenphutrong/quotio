import Foundation
import QuotioApplication
import QuotioDomain

public actor QuotioCLILegacyAccountMigration {
    private struct Metadata: Decodable {
        let accounts: [Account]
        let disabledAccountIDs: Set<String>
    }
    private let metadataURL: URL
    private let credentials: any CredentialDataStoring
    private let defaults: UserDefaults
    private let codexKeychain: (any ExternalCredentialReading)?
    private let importAccount: @Sendable (Account, StoredCredential, Bool) async throws -> Void
    private let completedKey = "quotio.cli.migratedMonitorAccounts.v1"

    public init(
        metadataURL: URL? = nil,
        credentials: any CredentialDataStoring,
        defaults: UserDefaults = .standard,
        codexKeychain: (any ExternalCredentialReading)? = nil,
        importAccount: @escaping @Sendable (Account, StoredCredential, Bool) async throws -> Void
    ) {
        self.metadataURL = metadataURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio/Monitor/accounts-v1.json")
        self.credentials = credentials
        self.defaults = defaults
        self.codexKeychain = codexKeychain
        self.importAccount = importAccount
    }

    public func migrate() async -> CredentialMigrationResult {
        let metadata: Metadata
        do {
            let attributes = try metadataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  (attributes.fileSize ?? Int.max) <= 1_048_576 else {
                return CredentialMigrationResult(metadataUnreadable: true)
            }
            metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        } catch CocoaError.fileReadNoSuchFile {
            metadata = Metadata(accounts: [], disabledAccountIDs: [])
        } catch {
            return CredentialMigrationResult(metadataUnreadable: true)
        }
        var completed = Set(defaults.stringArray(forKey: completedKey) ?? [])
        var result = CredentialMigrationResult()
        for account in metadata.accounts where (account.source == .quotioKeychain || account.source == .apiKey)
            && account.credentialReference == "keychain" && account.providerID.rawValue != "gemini-cli" {
            guard !completed.contains(account.id) else { continue }
            do {
                guard let record = await credentials.read(accountID: account.id) else {
                    result.pendingCount += 1
                    continue
                }
                let credential = try JSONDecoder().decode(StoredCredential.self, from: record.data)
                try await importAccount(account, credential, account.isDisabled || metadata.disabledAccountIDs.contains(account.id))
                completed.insert(account.id)
                defaults.set(completed.sorted(), forKey: completedKey)
                result.migratedCount += 1
            } catch {
                result.pendingCount += 1
            }
        }
        let sourceMarker = "codex-auth-keychain.v1"
        if !completed.contains(sourceMarker), let codexKeychain {
            let previousAccount = metadata.accounts.first {
                $0.providerID.rawValue == "codex" && $0.credentialReference == "keychain:Codex Auth"
            }
            guard let record = await codexKeychain.read(service: "Codex Auth", account: nil) else {
                if previousAccount != nil { result.pendingCount += 1 }
                return result
            }
            do {
                let (label, credential) = try Self.codexCredential(record.data)
                let account = previousAccount ?? Account.make(
                    providerID: AccountProviderID(rawValue: "codex"), accountKey: label,
                    source: .nativeCredential, credentialReference: "keychain:Codex Auth"
                )
                if !completed.contains(account.id) {
                    try await importAccount(account, credential, account.isDisabled || metadata.disabledAccountIDs.contains(account.id))
                    completed.insert(account.id)
                    result.migratedCount += 1
                }
                completed.insert(sourceMarker)
                defaults.set(completed.sorted(), forKey: completedKey)
            } catch {
                result.pendingCount += 1
            }
        }
        return result
    }

    private static func codexCredential(_ data: Data) throws -> (String, StoredCredential) {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty,
              let idToken = tokens["id_token"] as? String, !idToken.isEmpty else {
            throw AccountServiceFailure.invalidCredential
        }
        // Claims provide migration labels and routing metadata, not authentication proof.
        let claims = jwtClaims(idToken)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = [tokens["account_id"], auth?["chatgpt_account_id"]]
            .compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
            throw AccountServiceFailure.invalidCredential
        }
        let label = [claims["email"] as? String, accountID].compactMap { $0 }.first { !$0.isEmpty } ?? accountID
        let expiry = (jwtClaims(accessToken)["exp"] as? NSNumber)?.doubleValue
        return (label, StoredCredential(
            accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
            accountID: accountID, expiresAt: expiry.map(Date.init(timeIntervalSince1970:)), extra: [:]
        ))
    }

    private static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return claims
    }
}
