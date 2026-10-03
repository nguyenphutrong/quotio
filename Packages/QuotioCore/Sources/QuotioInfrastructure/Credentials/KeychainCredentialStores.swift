import CryptoKit
import Foundation
import LocalAuthentication
import QuotioApplication
@preconcurrency import Security

private enum ProcessKeychainLock {
    nonisolated static let value = NSRecursiveLock()
}

public enum ProtectedCredentialReadResult: Equatable, Sendable {
    case absent
    case unreadable
    case success(Data)
}

public protocol LegacyProtectedCredentialReading: Sendable {
    func read(service: String, account: String) async -> ProtectedCredentialReadResult
}

public actor KeychainCredentialDataStore: CredentialDataStoring {
    private let service: String
    private let legacyServices: [String]
    private let canMigrateLegacy: Bool
    private let legacyProtectedStore: (any LegacyProtectedCredentialReading)?
    private let defaults: UserDefaults

    public init(
        service: String,
        legacyServices: [String] = [],
        canMigrateLegacy: Bool,
        legacyProtectedStore: (any LegacyProtectedCredentialReading)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.legacyServices = legacyServices
        self.canMigrateLegacy = canMigrateLegacy
        self.legacyProtectedStore = legacyProtectedStore
        self.defaults = defaults
    }

    public func read(accountID: String) async -> CredentialDataRecord? {
        guard let data = await readData(accountID: accountID) else { return nil }
        return CredentialDataRecord(data: data, generation: Self.generation(for: data))
    }

    public func save(_ data: Data, accountID: String) async -> CredentialDataRecord? {
        if !defaults.bool(forKey: migrationKey(accountID)), let legacyProtectedStore {
            for candidate in [service] + (canMigrateLegacy ? legacyServices : []) {
                if await legacyProtectedStore.read(service: candidate, account: accountID) == .unreadable { return nil }
            }
        }
        guard Self.saveKeychainData(data, service: service, account: accountID) else { return nil }
        defaults.set(true, forKey: migrationKey(accountID))
        return CredentialDataRecord(data: data, generation: Self.generation(for: data))
    }

    public func compareAndSwap(_ data: Data, accountID: String, expectedGeneration: String) async -> CredentialDataRecord? {
        guard let current = await readData(accountID: accountID),
              Self.generation(for: current) == expectedGeneration,
              Self.updateKeychainData(data, service: service, account: accountID) else { return nil }
        defaults.set(true, forKey: migrationKey(accountID))
        return CredentialDataRecord(data: data, generation: Self.generation(for: data))
    }

    public func delete(accountID: String) async {
        // Keep deprecated envelopes untouched, but never resurrect a deleted credential.
        defaults.set(true, forKey: migrationKey(accountID))
        Self.deleteKeychainData(service: service, account: accountID)
        if canMigrateLegacy {
            for legacyService in legacyServices {
                Self.deleteKeychainData(service: legacyService, account: accountID)
            }
        }
    }

    private func migrationKey(_ accountID: String) -> String {
        "legacyYubiKeyMigrated." + Self.generation(for: Data((service + "\u{0}" + accountID).utf8))
    }

    private func readData(accountID: String) async -> Data? {
        if let data = Self.readKeychainData(service: service, account: accountID) { return data }
        guard !defaults.bool(forKey: migrationKey(accountID)) else { return nil }
        for candidate in [service] + (canMigrateLegacy ? legacyServices : []) {
            var data: Data?
            if let legacyProtectedStore {
                switch await legacyProtectedStore.read(service: candidate, account: accountID) {
                case .unreadable: return nil
                case .success(let value): data = value
                case .absent: break
                }
            }
            if data == nil, candidate != service {
                data = Self.readKeychainData(service: candidate, account: accountID)
            }
            guard let data else { continue }
            // The hardware read suspends this actor. Never replace a newer write
            // that completed while the key was being unlocked.
            if let current = Self.readKeychainData(service: service, account: accountID) { return current }
            var query = Self.identity(service: service, account: accountID)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                return status == errSecDuplicateItem ? Self.readKeychainData(service: service, account: accountID) : nil
            }
            guard Self.readKeychainData(service: service, account: accountID) == data else { return nil }
            defaults.set(true, forKey: migrationKey(accountID))
            return data
        }
        return nil
    }

    private nonisolated static func generation(for data: Data) -> String {
        SHA256.hash(data: Data(data.base64EncodedString().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(20)
            .description
    }

    private nonisolated static func identity(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private nonisolated static func saveKeychainData(
        _ data: Data,
        service: String,
        account: String
    ) -> Bool {
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        let identity = identity(service: service, account: account)
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var query = identity
        query.merge([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private nonisolated static func updateKeychainData(
        _ data: Data,
        service: String,
        account: String
    ) -> Bool {
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        return SecItemUpdate(
            identity(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        ) == errSecSuccess
    }

    private nonisolated static func readKeychainData(service: String, account: String) -> Data? {
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        var query = identity(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private nonisolated static func deleteKeychainData(service: String, account: String) {
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        SecItemDelete(identity(service: service, account: account) as CFDictionary)
    }
}

public actor ExternalKeychainCredentialReader: ExternalCredentialReading {
    public init() {}

    public func read(service: String, account: String?) -> ExternalCredentialRecord? {
        var result: AnyObject?
        let status = Self.performWithoutInteraction {
            SecItemCopyMatching(Self.readQuery(service: service, account: account) as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let resolvedAccount = item[kSecAttrAccount as String] as? String else { return nil }
        return ExternalCredentialRecord(data: data, account: resolvedAccount)
    }

    public func compareAndSwap(
        service: String,
        account: String,
        expectedData: Data,
        newData: Data
    ) async -> Bool {
        guard read(service: service, account: account)?.data == expectedData else { return false }
        return Self.performWithoutInteraction {
            SecItemUpdate(
                Self.updateQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: newData] as CFDictionary
            )
        } == errSecSuccess
    }

    public nonisolated static func readQuery(
        service: String,
        account: String? = nil
    ) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    public nonisolated static func updateQuery(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private nonisolated static func performWithoutInteraction(
        _ operation: () -> OSStatus
    ) -> OSStatus {
        ProcessKeychainLock.value.lock()
        defer { ProcessKeychainLock.value.unlock() }
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }
}
