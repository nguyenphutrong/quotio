//
//  DaemonAPIKeysService.swift
//  Quotio
//

import Foundation

@MainActor @Observable
final class DaemonAPIKeysService {
    static let shared = DaemonAPIKeysService()
    
    private(set) var isLoading = false
    private(set) var lastError: String?
    
    private(set) var apiKeys: [String] = []
    
    private let ipcClient = DaemonIPCClient.shared
    private let daemonManager = DaemonManager.shared
    
    private init() {}
    
    private var isDaemonReady: Bool {
        get async {
            if daemonManager.isRunning { return true }
            return await daemonManager.checkHealth()
        }
    }
    
    func fetchAPIKeys() async -> [String] {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return []
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.listApiKeys()
            if result.success {
                apiKeys = result.keys ?? []
                return apiKeys
            } else {
                lastError = result.error ?? "Failed to fetch API keys"
                return []
            }
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }
    
    func addAPIKey() async throws -> String? {
        guard await isDaemonReady else {
            throw DaemonAPIKeysError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.addApiKey()
            if result.success, let key = result.key {
                apiKeys.append(key)
                return key
            } else {
                throw DaemonAPIKeysError.addFailed(result.error ?? "Unknown error")
            }
        } catch let error as DaemonAPIKeysError {
            lastError = error.localizedDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw DaemonAPIKeysError.addFailed(error.localizedDescription)
        }
    }
    
    func deleteAPIKey(_ key: String) async throws {
        guard await isDaemonReady else {
            throw DaemonAPIKeysError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.deleteApiKey(key)
            if result.success {
                apiKeys.removeAll { $0 == key }
            } else {
                throw DaemonAPIKeysError.deleteFailed(result.error ?? "Unknown error")
            }
        } catch let error as DaemonAPIKeysError {
            lastError = error.localizedDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw DaemonAPIKeysError.deleteFailed(error.localizedDescription)
        }
    }
    
    func reset() {
        apiKeys = []
        lastError = nil
    }
}

enum DaemonAPIKeysError: LocalizedError {
    case daemonNotRunning
    case addFailed(String)
    case deleteFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .addFailed(let reason):
            return "Failed to add API key: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete API key: \(reason)"
        }
    }
}
