import CryptoKit
import Foundation

public struct AccountProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum AccountSource: String, Codable, CaseIterable, Sendable {
    case quotioKeychain
    case nativeCredential
    case legacyCLIProxy
    case localIDE
    case apiKey

    public var priority: Int {
        switch self {
        case .quotioKeychain: 300
        case .nativeCredential, .localIDE, .apiKey: 200
        case .legacyCLIProxy: 100
        }
    }
}

public enum AccountCapability: String, Codable, Hashable, Sendable {
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

    public var deduplicationKey: String {
        "\(providerID.rawValue):\(accountKey.lowercased())"
    }
}

public struct Account: Identifiable, Codable, Hashable, Sendable {
    public let identity: AccountIdentity
    public let displayName: String
    public let source: AccountSource
    public let credentialReference: String?
    public let capabilities: Set<AccountCapability>
    public var status: AccountStatus
    public let credentialMetadata: RedactedCredentialMetadata?

    public var id: String { identity.id }
    public var providerID: AccountProviderID { identity.providerID }
    public var accountKey: String { identity.accountKey }
    public var deduplicationKey: String { identity.deduplicationKey }
    public var canDelete: Bool { capabilities.contains(.delete) }
    public var isDisabled: Bool {
        get { status == .disabled }
        set { status = newValue ? .disabled : .unknown }
    }

    public init(
        identity: AccountIdentity,
        displayName: String,
        source: AccountSource,
        credentialReference: String? = nil,
        capabilities: Set<AccountCapability> = [.disable],
        status: AccountStatus = .unknown,
        credentialMetadata: RedactedCredentialMetadata? = nil
    ) {
        self.identity = identity
        self.displayName = displayName
        self.source = source
        self.credentialReference = credentialReference
        self.capabilities = capabilities
        self.status = status
        self.credentialMetadata = credentialMetadata
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
        credentialMetadata = nil
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
    }
}

public enum AccountSelectionPolicy {
    private static let placeholderAccountKeys: [QuotaProvider: Set<String>] = [
        .copilot: ["github copilot"],
        .antigravity: ["antigravity"],
        .claude: ["claude code"],
        .codex: ["codex", "codex user"],
        .kiro: ["kiro"],
    ]

    public static func preferred(
        _ candidates: [Account],
        disabledIDs: Set<String> = []
    ) -> [Account] {
        var selected: [String: Account] = [:]
        for var account in candidates {
            account.isDisabled = disabledIDs.contains(account.id)
            let key = account.deduplicationKey
            if let existing = selected[key], existing.source.priority >= account.source.priority {
                continue
            }
            selected[key] = account
        }
        return selected.values.sorted {
            if $0.providerID == $1.providerID {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.providerID.rawValue < $1.providerID.rawValue
        }
    }

    public static func mergingQuotaAccounts(
        _ accounts: [Account],
        quotas: [QuotaProvider: [String: ProviderQuota]]
    ) -> [Account] {
        var merged = accounts.map { account in
            guard let provider = QuotaProvider(rawValue: account.providerID.rawValue),
                  let displayName = quotas[provider]?[account.accountKey]?.accountDisplayName else {
                return account
            }
            return Account(
                identity: account.identity,
                displayName: displayName,
                source: account.source,
                credentialReference: account.credentialReference,
                capabilities: account.capabilities,
                status: account.status,
                credentialMetadata: account.credentialMetadata
            )
        }
        var keys = Set(merged.map(\.deduplicationKey))

        for (provider, accountQuotas) in quotas {
            for (accountKey, quota) in accountQuotas {
                let source: AccountSource = switch provider {
                case .cursor, .trae: .localIDE
                case .glm, .warp, .clinePass, .factoryDroid, .openRouter, .amp: .apiKey
                default: .nativeCredential
                }
                let account = Account.make(
                    providerID: AccountProviderID(rawValue: provider.rawValue),
                    accountKey: accountKey,
                    displayName: quota.accountDisplayName,
                    source: source,
                    capabilities: provider.isImportedFromLocalIDE ? [.delete] : []
                )
                guard keys.insert(account.deduplicationKey).inserted else { continue }
                merged.append(account)
            }
        }

        merged = preferred(merged)
        return merged.filter { account in
            guard let provider = QuotaProvider(rawValue: account.providerID.rawValue),
                  placeholderAccountKeys[provider]?.contains(account.accountKey.lowercased()) == true else {
                return true
            }
            return !merged.contains {
                $0.providerID == account.providerID
                    && $0.id != account.id
                    && placeholderAccountKeys[provider]?.contains($0.accountKey.lowercased()) != true
                    && $0.source.priority >= account.source.priority
            }
        }
    }
}
