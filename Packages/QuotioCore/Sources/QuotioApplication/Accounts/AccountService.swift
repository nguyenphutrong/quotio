import Foundation
import QuotioDomain

public protocol AccountDiscovering: Sendable {
    func discoverAccounts() async -> [Account]
}

public enum AccountServiceFailure: Error, Equatable, Sendable {
    case invalidCredential
    case duplicateAccount
    case accountNotFound
    case deletionNotAllowed
}

public protocol AccountManaging: Sendable {
    func accounts() async -> [Account]
    func setDisabled(_ disabled: Bool, accountID: String) async
    func delete(accountID: String) async throws
    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) async throws
}

public actor AccountService: AccountManaging {
    private let discovery: any AccountDiscovering
    private let metadataRepository: any AccountMetadataRepository
    private let credentialVault: any CredentialVault
    private let reservedLabels: [AccountProviderID: Set<String>]

    public init(
        discovery: any AccountDiscovering,
        metadataRepository: any AccountMetadataRepository,
        credentialVault: any CredentialVault,
        reservedLabels: [AccountProviderID: Set<String>] = [:]
    ) {
        self.discovery = discovery
        self.metadataRepository = metadataRepository
        self.credentialVault = credentialVault
        self.reservedLabels = reservedLabels.mapValues { labels in
            Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        }
    }

    public func accounts() async -> [Account] {
        await discovery.discoverAccounts()
    }

    public func setDisabled(_ disabled: Bool, accountID: String) async {
        try? await metadataRepository.setDisabled(disabled, accountID: accountID)
    }

    public func delete(accountID: String) async throws {
        guard let account = await discovery.discoverAccounts().first(where: { $0.id == accountID }) else {
            throw AccountServiceFailure.accountNotFound
        }
        guard account.canDelete else {
            throw AccountServiceFailure.deletionNotAllowed
        }
        await credentialVault.delete(accountID: accountID)
    }

    public func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String? = nil
    ) async throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty,
              !trimmedKey.isEmpty,
              reservedLabels[providerID]?.contains(trimmedLabel.lowercased()) != true else {
            throw AccountServiceFailure.invalidCredential
        }

        let currentAccounts = await discovery.discoverAccounts()
        let account: Account
        if let existingAccountID {
            guard let existing = currentAccounts.first(where: {
                $0.id == existingAccountID && $0.providerID == providerID
            }) else {
                throw AccountServiceFailure.accountNotFound
            }
            guard !currentAccounts.contains(where: {
                $0.id != existing.id
                    && $0.providerID == providerID
                    && $0.accountKey.caseInsensitiveCompare(trimmedLabel) == .orderedSame
            }) else {
                throw AccountServiceFailure.duplicateAccount
            }
            account = Account(
                identity: AccountIdentity(
                    id: existing.id,
                    providerID: existing.providerID,
                    accountKey: trimmedLabel
                ),
                displayName: trimmedLabel,
                source: existing.source,
                credentialReference: existing.credentialReference,
                capabilities: existing.capabilities,
                status: existing.status,
                credentialMetadata: RedactedCredentialMetadata(kind: .apiKey)
            )
            _ = await credentialVault.credential(for: existing.id)
        } else {
            guard !currentAccounts.contains(where: {
                $0.providerID == providerID
                    && $0.accountKey.caseInsensitiveCompare(trimmedLabel) == .orderedSame
            }) else {
                throw AccountServiceFailure.duplicateAccount
            }
            account = Account.make(
                providerID: providerID,
                accountKey: trimmedLabel,
                source: .quotioKeychain,
                credentialReference: "keychain",
                capabilities: [.disable, .delete, .edit],
                credentialMetadata: RedactedCredentialMetadata(kind: .apiKey)
            )
        }

        try await credentialVault.save(
            StoredCredential(
                accessToken: trimmedKey,
                refreshToken: nil,
                idToken: nil,
                accountID: nil,
                expiresAt: nil,
                extra: [:]
            ),
            metadata: account
        )
    }
}
