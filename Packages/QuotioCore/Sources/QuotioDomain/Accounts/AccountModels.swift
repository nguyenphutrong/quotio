import CryptoKit
import Foundation

public struct AccountProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ProviderAccountKey {
    public static let ampNative = "amp:native"
}

public enum AccountSource: String, Codable, CaseIterable, Sendable {
    case quotioKeychain
    case nativeCredential
    case legacyCLIProxy
    case localIDE
    case apiKey


}

public enum AccountCapability: String, Codable, Hashable, Sendable {
    case rename
    case delete
    case disable
    case edit
    case exportCredential
    case switchAccount
}

public enum AccountStatus: String, Codable, Hashable, Sendable {
    case unknown
    case ready
    case cooling
    case error
    case unavailable
    case outdated
    case expired
    case disabled
}

public enum CredentialKind: String, Codable, Hashable, Sendable {
    case apiKey
    case oauth
    case external
    case authFile
}

/// Credential facts that are safe to retain in Presentation state.
///
/// Tokens, OAuth codes, client secrets, Keychain payloads, and filesystem contents are
/// intentionally absent from this type.
public struct RedactedCredentialMetadata: Codable, Hashable, Sendable {
    public let kind: CredentialKind
    public let expiresAt: Date?
    public let hasRefreshToken: Bool
    public let hasAccountIdentifier: Bool

    public init(
        kind: CredentialKind,
        expiresAt: Date? = nil,
        hasRefreshToken: Bool = false,
        hasAccountIdentifier: Bool = false
    ) {
        self.kind = kind
        self.expiresAt = expiresAt
        self.hasRefreshToken = hasRefreshToken
        self.hasAccountIdentifier = hasAccountIdentifier
    }
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let providerID: AccountProviderID
    public let accountKey: String

    public init(id: String, providerID: AccountProviderID, accountKey: String) {
        self.id = id
        self.providerID = providerID
        self.accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func make(providerID: AccountProviderID, accountKey: String) -> AccountIdentity {
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = "\(providerID.rawValue)|\(normalized.lowercased())"
        let digest = SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return AccountIdentity(
            id: "monitor-" + digest.prefix(20),
            providerID: providerID,
            accountKey: normalized
        )
    }


}

public struct Account: Identifiable, Codable, Hashable, Sendable {
    public let identity: AccountIdentity
    public let displayName: String
    public let source: AccountSource
    public let credentialReference: String?
    public let capabilities: Set<AccountCapability>
    public var status: AccountStatus
    public var enabled: Bool
    public let credentialMetadata: RedactedCredentialMetadata?
    public var sources: [AccountLoginSource]
    public let isIdentityVerified: Bool?

    public var id: String { identity.id }
    public var providerID: AccountProviderID { identity.providerID }
    public var accountKey: String { identity.accountKey }
    public var canDelete: Bool { capabilities.contains(.delete) }
    public var isDisabled: Bool {
        get { !enabled }
        set {
            enabled = !newValue
            status = newValue ? .disabled : .unknown
        }
    }

    public init(
        identity: AccountIdentity,
        displayName: String,
        source: AccountSource,
        credentialReference: String? = nil,
        capabilities: Set<AccountCapability> = [.disable],
        status: AccountStatus = .unknown,
        enabled: Bool? = nil,
        credentialMetadata: RedactedCredentialMetadata? = nil,
        sources: [AccountLoginSource]? = nil,
        isIdentityVerified: Bool? = nil
    ) {
        self.identity = identity
        self.isIdentityVerified = isIdentityVerified
        self.displayName = displayName
        self.source = source
        self.credentialReference = credentialReference
        self.capabilities = capabilities
        self.status = status
        self.enabled = enabled ?? (status != .disabled)
        self.credentialMetadata = credentialMetadata
        self.sources = sources ?? [AccountLoginSource(
            accountID: identity.id, source: source, credentialReference: credentialReference, status: status
        )]
    }

    public static func make(
        providerID: AccountProviderID,
        accountKey: String,
        displayName: String? = nil,
        source: AccountSource,
        credentialReference: String? = nil,
        capabilities: Set<AccountCapability> = [.disable],
        status: AccountStatus = .unknown,
        credentialMetadata: RedactedCredentialMetadata? = nil
    ) -> Account {
        let identity = AccountIdentity.make(providerID: providerID, accountKey: accountKey)
        let normalizedDisplayName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName: String
        if let normalizedDisplayName, !normalizedDisplayName.isEmpty {
            resolvedDisplayName = normalizedDisplayName
        } else {
            resolvedDisplayName = identity.accountKey
        }
        return Account(
            identity: identity,
            displayName: resolvedDisplayName,
            source: source,
            credentialReference: credentialReference,
            capabilities: capabilities,
            status: status,
            credentialMetadata: credentialMetadata
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerID = "provider"
        case accountKey
        case displayName
        case source
        case credentialReference
        case canDelete
        case isDisabled
        case sources
        case isIdentityVerified
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let providerID = try container.decode(AccountProviderID.self, forKey: .providerID)
        let accountKey = try container.decode(String.self, forKey: .accountKey)
        identity = AccountIdentity(id: id, providerID: providerID, accountKey: accountKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        source = try container.decode(AccountSource.self, forKey: .source)
        credentialReference = try container.decodeIfPresent(String.self, forKey: .credentialReference)
        let canDelete = try container.decodeIfPresent(Bool.self, forKey: .canDelete) ?? false
        capabilities = canDelete ? [.disable, .delete] : [.disable]
        let isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        status = isDisabled ? .disabled : .unknown
        enabled = !isDisabled
        credentialMetadata = nil
        isIdentityVerified = try container.decodeIfPresent(Bool.self, forKey: .isIdentityVerified)
        sources = try container.decodeIfPresent([AccountLoginSource].self, forKey: .sources) ?? [
            AccountLoginSource(accountID: id, source: source, credentialReference: credentialReference, status: status),
        ]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(accountKey, forKey: .accountKey)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(credentialReference, forKey: .credentialReference)
        try container.encode(canDelete, forKey: .canDelete)
        try container.encode(isDisabled, forKey: .isDisabled)
        try container.encode(sources, forKey: .sources)
        try container.encodeIfPresent(isIdentityVerified, forKey: .isIdentityVerified)
    }
}
