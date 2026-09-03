//
//  KeychainHelper.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Keychain helper for secure credential storage
//

import Foundation
import Security

// MARK: - Keychain Helper

enum KeychainHelper {
    nonisolated private static let securityLock = NSRecursiveLock()
    nonisolated private static var localService: String {
        AppIdentity.keychainService(suffix: "local-management")
    }
    nonisolated private static var warpService: String {
        AppIdentity.keychainService(suffix: "warp")
    }
    private static let localManagementAccount = "local-management-key"
    private static let warpTokensAccount = "warp-tokens"
    private static let localManagementDefaultsKey = "managementKey"
    private static let warpTokensDefaultsKey = "warpTokens"
    // Legacy service names for keychain migration (newest first)
    nonisolated private static var legacyLocalServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "local-management")
    }
    nonisolated private static var legacyWarpServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "warp")
    }
    static func saveLocalManagementKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        let saved = saveData(data, service: localService, account: localManagementAccount)
        if !saved {
            Log.keychain("Failed to save local management key")
        }
        return saved
    }

    static func getLocalManagementKey() -> String? {
        if let key = readString(service: localService, account: localManagementAccount) {
            return key
        }

        // Migrate from legacy keychain service name
        if AppIdentity.isProduction,
           let legacyKey = migrateString(from: legacyLocalServices, to: localService, account: localManagementAccount) {
            return legacyKey
        }

        guard let legacyKey = UserDefaults.standard.string(forKey: localManagementDefaultsKey),
              !legacyKey.hasPrefix("$2a$") else {
            return nil
        }

        if saveLocalManagementKey(legacyKey) {
            UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
        }

        return legacyKey
    }

    static func deleteLocalManagementKey() {
        deleteData(service: localService, account: localManagementAccount)
        if AppIdentity.isProduction {
            for legacy in legacyLocalServices {
                deleteData(service: legacy, account: localManagementAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
    }

    static func saveWarpTokens(_ data: Data) -> Bool {
        let saved = saveData(data, service: warpService, account: warpTokensAccount)
        if !saved {
            Log.keychain("Failed to save Warp tokens")
        }
        return saved
    }

    static func getWarpTokens() -> Data? {
        if let data = readData(service: warpService, account: warpTokensAccount) {
            return data
        }

        if AppIdentity.isProduction,
           let legacyData = migrateData(from: legacyWarpServices, to: warpService, account: warpTokensAccount) {
            return legacyData
        }

        guard let legacyData = UserDefaults.standard.data(forKey: warpTokensDefaultsKey) else {
            return nil
        }

        if saveWarpTokens(legacyData) {
            UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
        }

        return legacyData
    }

    static func deleteWarpTokens() {
        deleteData(service: warpService, account: warpTokensAccount)
        if AppIdentity.isProduction {
            for legacy in legacyWarpServices {
                deleteData(service: legacy, account: warpTokensAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
    }

    nonisolated private static func migrateData(from oldServices: [String], to newService: String, account: String) -> Data? {
        for oldService in oldServices {
            guard let data = readData(service: oldService, account: account) else { continue }
            if saveData(data, service: newService, account: account) {
                deleteData(service: oldService, account: account)
            }
            return data
        }
        return nil
    }

    nonisolated private static func migrateString(from oldServices: [String], to newService: String, account: String) -> String? {
        // Non-destructive read: validate UTF-8 before committing the destructive migration
        for oldService in oldServices {
            guard let data = readData(service: oldService, account: account) else { continue }
            guard let decoded = String(data: data, encoding: .utf8) else { continue }
            _ = migrateData(from: [oldService], to: newService, account: account)
            return decoded
        }
        return nil
    }


    nonisolated private static func saveData(_ data: Data, service: String, account: String) -> Bool {
        if YubiKeySecretVault.isEnabled {
            let existing = YubiKeySecretVault.readResult(service: service, account: account)
            guard allowsVaultOverwrite(existing) else {
                Log.keychain("Refusing to overwrite unreadable vault envelope (service: \(service), account: \(account))")
                return false
            }
            return YubiKeySecretVault.save(data, service: service, account: account)
        }
        return saveKeychainData(data, service: service, account: account)
    }

    /// Whether a vault write may proceed over whatever is already stored.
    ///
    /// A caller that could not read a secret cannot tell "absent" from "hardware
    /// key unavailable", so it may regenerate one and store it -- destroying the
    /// envelope that still holds the real value. Proxy initialization can do this
    /// when no key is returned. Refuse rather than roll a live credential back.
    /// `.absent` costs only a file-existence check, so first writes stay
    /// prompt-free; only an overwrite pays for a decrypt.
    nonisolated static func allowsVaultOverwrite(_ existing: YubiKeySecretVault.ReadResult) -> Bool {
        if case .unreadable = existing { return false }
        return true
    }

    nonisolated private static func saveKeychainData(_ data: Data, service: String, account: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = performSecurityCall {
            SecItemUpdate(
                identity as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ] as CFDictionary
            )
        }
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Log.keychain("Keychain update failed (service: \(service), account: \(account)): \(updateStatus)")
            return false
        }

        var query = identity
        query.merge([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }

        let status = performSecurityCall {
            SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess {
            return true
        }

        Log.keychain("Keychain save failed (service: \(service), account: \(account)): \(status)")
        return false
    }

    nonisolated private static func readData(service: String, account: String) -> Data? {
        if YubiKeySecretVault.isEnabled {
            let result = YubiKeySecretVault.readResult(service: service, account: account)
            if case let .success(data) = result { return data }
            // Only an absent envelope may be filled from a legacy Keychain copy.
            // An unreadable one means the hardware key is unavailable or the
            // envelope is bad, and overwriting it would roll the credential back.
            guard YubiKeySecretVault.shouldMigrateLegacy(result) else { return nil }
            // Move a legacy secret only after a complete encrypted write/read
            // round trip has succeeded.
            guard let legacy = readKeychainData(service: service, account: account),
                  YubiKeySecretVault.save(legacy, service: service, account: account),
                  case let .success(roundTripped) = YubiKeySecretVault.readResult(service: service, account: account),
                  roundTripped == legacy else { return nil }
            deleteKeychainData(service: service, account: account)
            return legacy
        }
        return readKeychainData(service: service, account: account)
    }

    nonisolated private static func readKeychainData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = performSecurityCall {
            SecItemCopyMatching(query as CFDictionary, &result)
        }

        if status == errSecSuccess {
            return result as? Data
        }

        if status != errSecItemNotFound {
            Log.keychain("Keychain read failed (service: \(service), account: \(account)): \(status)")
        }

        return nil
    }

    private static func readString(service: String, account: String) -> String? {
        guard let data = readData(service: service, account: account) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func deleteData(service: String, account: String) {
        if YubiKeySecretVault.isEnabled {
            YubiKeySecretVault.delete(service: service, account: account)
        }
        deleteKeychainData(service: service, account: account)
    }

    nonisolated private static func deleteKeychainData(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = performSecurityCall {
            SecItemDelete(query as CFDictionary)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.keychain("Keychain delete failed (service: \(service), account: \(account)): \(status)")
        }
    }

    nonisolated private static func performSecurityCall(
        _ operation: () -> OSStatus
    ) -> OSStatus {
        securityLock.lock()
        defer { securityLock.unlock() }
        return operation()
    }

}
