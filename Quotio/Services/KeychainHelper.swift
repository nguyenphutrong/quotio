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
    private static let remoteService = "com.quotio.remote-management"
    private static let localService = "com.quotio.local-management"
    private static let warpService = "com.quotio.warp"
    private static let localManagementAccount = "local-management-key"
    private static let warpTokensAccount = "warp-tokens"
    private static let localManagementDefaultsKey = "managementKey"
    private static let warpTokensDefaultsKey = "warpTokens"
    
    static func saveManagementKey(_ key: String, for configId: String) {
        let account = "management-key-\(configId)"
        guard let data = key.data(using: .utf8) else { return }
        if !saveData(data, service: remoteService, account: account) {
            Log.keychain("Failed to save management key for config \(configId)")
        }
    }
    
    static func getManagementKey(for configId: String) -> String? {
        let account = "management-key-\(configId)"
        return readString(service: remoteService, account: account)
    }
    
    static func deleteManagementKey(for configId: String) {
        let account = "management-key-\(configId)"
        deleteData(service: remoteService, account: account)
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
        UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
    }
    
    private static func saveData(_ data: Data, service: String, account: String) -> Bool {
        deleteData(service: service, account: account)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }
        
        Log.keychain("Keychain save failed (service: \(service), account: \(account)): \(status)")
        return false
    }
    
    private static func readData(service: String, account: String) -> Data? {
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
    
    private static func deleteData(service: String, account: String) {
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
