//
//  KeychainService.swift
//  Quotio
//

import Foundation
import Security

actor KeychainService {
    static let shared = KeychainService()
    
    private let serviceName = "com.quotio.api-keys"
    
    private init() {}
    
    // MARK: - CRUD Operations
    
    func store(key: String, for provider: AIProvider, account: String? = nil) throws {
        let accountName = account ?? provider.rawValue
        
        try? delete(for: provider, account: account)
        
        guard let keyData = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }
    
    func retrieve(for provider: AIProvider, account: String? = nil) throws -> String? {
        let accountName = account ?? provider.rawValue
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }
        
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        
        return key
    }
    
    func delete(for provider: AIProvider, account: String? = nil) throws {
        let accountName = account ?? provider.rawValue
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    func exists(for provider: AIProvider, account: String? = nil) -> Bool {
        do {
            return try retrieve(for: provider, account: account) != nil
        } catch {
            return false
        }
    }
    
    // MARK: - Validation
    
    func validate(key: String, for provider: AIProvider) -> ValidationResult {
        guard !key.isEmpty else {
            return .invalid("API key cannot be empty")
        }
        
        switch provider {
        case .codex:
            if !key.hasPrefix("sk-") {
                return .warning("OpenAI keys typically start with 'sk-'")
            }
            if key.count < 20 {
                return .invalid("API key appears too short")
            }
            
        case .claude:
            if !key.hasPrefix("sk-ant-") {
                return .warning("Anthropic keys typically start with 'sk-ant-'")
            }
            
        case .gemini, .vertex:
            if key.count < 10 {
                return .invalid("API key appears too short")
            }
            
        case .copilot:
            if !key.hasPrefix("ghu_") && !key.hasPrefix("ghp_") && !key.hasPrefix("gho_") {
                return .warning("GitHub tokens typically start with 'ghu_', 'ghp_', or 'gho_'")
            }
            
        default:
            if key.count < 8 {
                return .invalid("API key appears too short")
            }
        }
        
        return .valid
    }
    
    func storeValidated(key: String, for provider: AIProvider, account: String? = nil) throws -> ValidationResult {
        let validation = validate(key: key, for: provider)
        
        if case .invalid = validation {
            return validation
        }
        
        try store(key: key, for: provider, account: account)
        return validation
    }
    
    // MARK: - Bulk Operations
    
    func listAccounts(for provider: AIProvider) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return []
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }
        
        guard let items = result as? [[String: Any]] else {
            return []
        }
        
        let providerPrefix = provider.rawValue
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            if account == providerPrefix || account.hasPrefix(providerPrefix + ".") {
                return account
            }
            return nil
        }
    }
    
    func deleteAll(for provider: AIProvider) throws {
        let accounts = try listAccounts(for: provider)
        for account in accounts {
            try delete(for: provider, account: account)
        }
    }
    
    // MARK: - Direct Account Operations (for UniversalProvider)
    
    func storeByAccount(_ account: String, key: String) throws {
        try? deleteByAccount(account)
        
        guard let keyData = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }
    
    func retrieveByAccount(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }
        
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        
        return key
    }
    
    func deleteByAccount(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    func existsByAccount(_ account: String) -> Bool {
        do {
            return try retrieveByAccount(account) != nil
        } catch {
            return false
        }
    }
    
    func listUniversalProviderAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return []
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }
        
        guard let items = result as? [[String: Any]] else {
            return []
        }
        
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            if account.hasPrefix("universal.") {
                return account
            }
            return nil
        }
    }
}

// MARK: - Types

enum KeychainError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode API key"
        case .decodingFailed:
            return "Failed to decode API key"
        case .storeFailed(let status):
            return "Failed to store API key (error \(status))"
        case .retrieveFailed(let status):
            return "Failed to retrieve API key (error \(status))"
        case .deleteFailed(let status):
            return "Failed to delete API key (error \(status))"
        }
    }
}

enum ValidationResult: Equatable {
    case valid
    case warning(String)
    case invalid(String)
    
    var isValid: Bool {
        if case .invalid = self { return false }
        return true
    }
    
    var message: String? {
        switch self {
        case .valid: return nil
        case .warning(let msg), .invalid(let msg): return msg
        }
    }
}
