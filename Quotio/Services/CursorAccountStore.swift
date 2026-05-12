//
//  CursorAccountStore.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Persists multiple Cursor accounts (tokens in Keychain, metadata in UserDefaults).
//  Cursor itself only allows one signed-in account in the IDE at a time; this store
//  lets users snapshot the current Cursor login and keep N saved accounts whose
//  quotas can be queried independently via the Cursor API.
//

import Foundation
import Security

/// Non-secret metadata describing a saved Cursor account.
nonisolated struct CursorSavedAccount: Codable, Sendable, Identifiable, Hashable {
    let email: String
    var membershipType: String?
    var addedAt: Date

    var id: String { email }
}

/// Token bundle for a saved account. Tokens live in the Keychain.
nonisolated struct CursorAccountTokens: Sendable {
    let accessToken: String
    let refreshToken: String?
}

@MainActor
@Observable
final class CursorAccountStore {
    static let shared = CursorAccountStore()

    nonisolated static let keychainService = "dev.quotio.desktop.cursor"
    nonisolated static let metadataKey = "quotio.cursor.savedAccounts"

    /// Currently saved accounts (observable).
    private(set) var accounts: [CursorSavedAccount] = []

    private init() {
        self.accounts = loadMetadata()
    }

    // MARK: - Public API

    func contains(email: String) -> Bool {
        accounts.contains { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    /// Persist a new (or replace existing) account.
    @discardableResult
    func add(
        email: String,
        accessToken: String,
        refreshToken: String?,
        membershipType: String?
    ) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !accessToken.isEmpty else { return false }

        guard saveTokens(email: trimmed, access: accessToken, refresh: refreshToken) else {
            Log.keychain("CursorAccountStore: failed to save tokens for \(Log.maskEmail(trimmed))")
            return false
        }

        if let idx = accounts.firstIndex(where: {
            $0.email.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            accounts[idx].membershipType = membershipType ?? accounts[idx].membershipType
        } else {
            accounts.append(
                CursorSavedAccount(
                    email: trimmed,
                    membershipType: membershipType,
                    addedAt: Date()
                )
            )
        }
        saveMetadata()
        return true
    }

    /// Remove a saved account and its keychain entry.
    func remove(email: String) {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts.removeAll { $0.email.caseInsensitiveCompare(target) == .orderedSame }
        saveMetadata()
        deleteTokens(email: target)
    }

    /// Read tokens for a saved account. nil if the account isn't tracked or
    /// the keychain entry is missing.
    nonisolated static func tokens(for email: String) -> CursorAccountTokens? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = readKeychain(account: trimmed) else { return nil }
        guard let decoded = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return nil
        }
        return CursorAccountTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken
        )
    }

    /// Snapshot of saved accounts callable from non-MainActor contexts (e.g. the
    /// quota fetcher actor). Uses the keychain + UserDefaults directly so callers
    /// don't need to hop to the main actor.
    nonisolated static func snapshotForFetcher() -> [CursorSavedAccount] {
        loadMetadataFromDefaults()
    }

    // MARK: - Metadata Persistence

    private func loadMetadata() -> [CursorSavedAccount] {
        Self.loadMetadataFromDefaults()
    }

    nonisolated static func loadMetadataFromDefaults() -> [CursorSavedAccount] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey) else { return [] }
        return (try? JSONDecoder().decode([CursorSavedAccount].self, from: data)) ?? []
    }

    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: Self.metadataKey)
    }

    // MARK: - Keychain

    nonisolated private struct StoredTokens: Codable, Sendable {
        let accessToken: String
        let refreshToken: String?
    }

    private func saveTokens(email: String, access: String, refresh: String?) -> Bool {
        let stored = StoredTokens(accessToken: access, refreshToken: refresh)
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        deleteTokens(email: email)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: email,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func deleteTokens(email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: email
        ]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated private static func readKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
