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
    private static let remoteService = "dev.quotio.desktop.remote-management"
    private static let localService = "dev.quotio.desktop.local-management"
    private static let warpService = "dev.quotio.desktop.warp"
    private static let localManagementAccount = "local-management-key"
    private static let warpTokensAccount = "warp-tokens"
    private static let localManagementDefaultsKey = "managementKey"
    private static let warpTokensDefaultsKey = "warpTokens"
    nonisolated private static let monitorAuthService = "dev.quotio.desktop.monitor-auth"

    // Legacy service names for keychain migration (newest first)
    private static let legacyRemoteServices = [
        "proseek.io.vn.Quotio.remote-management",
        "com.quotio.remote-management",
    ]
    private static let legacyLocalServices = [
        "proseek.io.vn.Quotio.local-management",
        "com.quotio.local-management",
    ]
    private static let legacyWarpServices = [
        "proseek.io.vn.Quotio.warp",
        "com.quotio.warp",
    ]

    static func saveManagementKey(_ key: String, for configId: String) {
        let account = "management-key-\(configId)"
        guard let data = key.data(using: .utf8) else { return }
        if !saveData(data, service: remoteService, account: account) {
            Log.keychain("Failed to save management key for config \(configId)")
        }
    }

    static func getManagementKey(for configId: String) -> String? {
        let account = "management-key-\(configId)"
        if let key = readString(service: remoteService, account: account) {
            return key
        }
        return migrateString(from: legacyRemoteServices, to: remoteService, account: account)
    }

    static func deleteManagementKey(for configId: String) {
        let account = "management-key-\(configId)"
        deleteData(service: remoteService, account: account)
        for legacy in legacyRemoteServices {
            deleteData(service: legacy, account: account)
        }
    }

    static func hasManagementKey(for configId: String) -> Bool {
        getManagementKey(for: configId) != nil
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
        if let legacyKey = migrateString(from: legacyLocalServices, to: localService, account: localManagementAccount) {
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
        for legacy in legacyLocalServices {
            deleteData(service: legacy, account: localManagementAccount)
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

        if let legacyData = migrateData(from: legacyWarpServices, to: warpService, account: warpTokensAccount) {
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
        for legacy in legacyWarpServices {
            deleteData(service: legacy, account: warpTokensAccount)
        }
        UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
    }

    // MARK: - Monitor-only credentials

    nonisolated static func saveMonitorCredential(_ data: Data, account: String) -> Bool {
        saveData(data, service: monitorAuthService, account: account)
    }

    nonisolated static func getMonitorCredential(account: String) -> Data? {
        readData(service: monitorAuthService, account: account)
    }

    nonisolated static func deleteMonitorCredential(account: String) {
        deleteData(service: monitorAuthService, account: account)
    }

    nonisolated static func compareAndSwapMonitorCredential(
        _ data: Data,
        account: String,
        expectedFingerprint: String
    ) -> Bool {
        guard let current = getMonitorCredential(account: account),
              MonitorIdentity.fingerprint(current.base64EncodedString()) == expectedFingerprint else {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: monitorAuthService,
            kSecAttrAccount as String: account,
        ]
        return SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        ) == errSecSuccess
    }

    /// Read a credential owned by another local CLI/app without mutating it.
    nonisolated static func readExternalCredential(service: String, account: String? = nil) -> Data? {
        readExternalCredentialRecord(service: service, account: account)?.data
    }

    nonisolated static func readExternalCredentialRecord(
        service: String,
        account: String? = nil
    ) -> (data: Data, account: String)? {
        let query: [String: Any] = {
            var value: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let account, !account.isEmpty {
                value[kSecAttrAccount as String] = account
            }
            return value
        }()

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let item = result as? [String: Any],
           let data = item[kSecValueData as String] as? Data,
           let resolvedAccount = item[kSecAttrAccount as String] as? String {
            return (data, resolvedAccount)
        }
        if status != errSecItemNotFound && status != errSecInteractionNotAllowed {
            Log.keychain("External keychain read failed (service: \(service)): \(status)")
        }
        return nil
    }

    /// Update a known writable credential source after an OAuth refresh.
    nonisolated static func writeExternalCredential(_ data: Data, service: String, account: String) -> Bool {
        saveData(data, service: service, account: account)
    }

    nonisolated static func compareAndSwapExternalCredential(
        service: String,
        account: String,
        expectedData: Data,
        newData: Data
    ) -> Bool {
        guard readExternalCredentialRecord(service: service, account: account)?.data == expectedData else {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: newData] as CFDictionary
        )
        return status == errSecSuccess
    }

    private static func migrateData(from oldServices: [String], to newService: String, account: String) -> Data? {
        for oldService in oldServices {
            guard let data = readData(service: oldService, account: account) else { continue }
            if saveData(data, service: newService, account: account) {
                deleteData(service: oldService, account: account)
            }
            return data
        }
        return nil
    }

    private static func migrateString(from oldServices: [String], to newService: String, account: String) -> String? {
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
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
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

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }

        Log.keychain("Keychain save failed (service: \(service), account: \(account)): \(status)")
        return false
    }

    nonisolated private static func readData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.keychain("Keychain delete failed (service: \(service), account: \(account)): \(status)")
        }
    }
}
