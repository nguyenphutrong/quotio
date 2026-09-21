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
    private let importAccount: @Sendable (Account, StoredCredential, Bool) async throws -> Void
    private let completedKey = "quotio.cli.migratedMonitorAccounts.v1"

    public init(
        metadataURL: URL? = nil,
        credentials: any CredentialDataStoring,
        defaults: UserDefaults = .standard,
        importAccount: @escaping @Sendable (Account, StoredCredential, Bool) async throws -> Void
    ) {
        self.metadataURL = metadataURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio/Monitor/accounts-v1.json")
        self.credentials = credentials
        self.defaults = defaults
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
            return CredentialMigrationResult()
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
        return result
    }
}
