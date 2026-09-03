import Foundation
import QuotioDomain

public struct StoredCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var accountID: String?
    public var expiresAt: Date?
    public var extra: [String: String]

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        accountID: String?,
        expiresAt: Date?,
        extra: [String: String]
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.expiresAt = expiresAt
        self.extra = extra
    }

    public var redactedMetadata: RedactedCredentialMetadata {
        RedactedCredentialMetadata(
            kind: refreshToken == nil && idToken == nil ? .apiKey : .oauth,
            expiresAt: expiresAt,
            hasRefreshToken: refreshToken != nil,
            hasAccountIdentifier: accountID != nil
        )
    }
}

public struct CredentialDataRecord: Equatable, Sendable {
    public let data: Data
    public let generation: String

    public init(data: Data, generation: String) {
        self.data = data
        self.generation = generation
    }
}

public struct ExternalCredentialRecord: Equatable, Sendable {
    public let data: Data
    public let account: String

    public init(data: Data, account: String) {
        self.data = data
        self.account = account
    }
}

public protocol CredentialDataStoring: Sendable {
    func read(accountID: String) async -> CredentialDataRecord?
    func save(_ data: Data, accountID: String) async -> CredentialDataRecord?
    func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration: String
    ) async -> CredentialDataRecord?
    func delete(accountID: String) async
}

public protocol ExternalCredentialReading: Sendable {
    func read(service: String, account: String?) async -> ExternalCredentialRecord?
    func compareAndSwap(
        service: String,
        account: String,
        expectedData: Data,
        newData: Data
    ) async -> Bool
}

public protocol AccountMetadataRepository: Sendable {
    func accounts() async -> [Account]
    func disabledAccountIDs() async -> Set<String>
    func saveAccount(_ account: Account) async throws
    func deleteAccount(_ accountID: String) async throws
    func setDisabled(_ disabled: Bool, accountID: String) async throws
}

public protocol CredentialVault: Sendable {
    func accounts() async -> [Account]
    func credential(for accountID: String) async -> StoredCredential?
    func reloadLatest(accountID: String) async -> StoredCredential?
    func save(_ credential: StoredCredential, metadata: Account) async throws
    func delete(accountID: String) async
}

public enum CredentialVaultError: Error, Equatable, Sendable {
    case writeFailed
}

public actor CredentialVaultService: CredentialVault {
    private let dataStore: any CredentialDataStoring
    private let metadataRepository: any AccountMetadataRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loadedGenerations: [String: String] = [:]

    public init(
        dataStore: any CredentialDataStoring,
        metadataRepository: any AccountMetadataRepository,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.dataStore = dataStore
        self.metadataRepository = metadataRepository
        self.encoder = encoder
        self.decoder = decoder
    }

    public func accounts() async -> [Account] {
        await metadataRepository.accounts()
    }

    public func credential(for accountID: String) async -> StoredCredential? {
        guard let record = await dataStore.read(accountID: accountID) else { return nil }
        loadedGenerations[accountID] = record.generation
        return try? decoder.decode(StoredCredential.self, from: record.data)
    }

    public func reloadLatest(accountID: String) async -> StoredCredential? {
        await credential(for: accountID)
    }

    public func save(_ credential: StoredCredential, metadata account: Account) async throws {
        let data = try encoder.encode(credential)
        let saved: CredentialDataRecord?
        if let expectedGeneration = loadedGenerations[account.id] {
            saved = await dataStore.compareAndSwap(
                data,
                accountID: account.id,
                expectedGeneration: expectedGeneration
            )
        } else {
            saved = await dataStore.save(data, accountID: account.id)
        }
        guard let saved else {
            throw CredentialVaultError.writeFailed
        }
        loadedGenerations[account.id] = saved.generation
        try await metadataRepository.saveAccount(account)
    }

    public func delete(accountID: String) async {
        await dataStore.delete(accountID: accountID)
        loadedGenerations.removeValue(forKey: accountID)
        try? await metadataRepository.deleteAccount(accountID)
    }
}
