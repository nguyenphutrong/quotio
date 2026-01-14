//
//  DaemonProxyConfigService.swift
//  Quotio
//

import Foundation

@MainActor @Observable
final class DaemonProxyConfigService {
    static let shared = DaemonProxyConfigService()
    
    private(set) var isLoading = false
    private(set) var lastError: String?
    
    private(set) var config: IPCProxyConfigData?
    
    private let ipcClient = DaemonIPCClient.shared
    private let daemonManager = DaemonManager.shared
    
    private init() {}
    
    private var isDaemonReady: Bool {
        get async {
            if daemonManager.isRunning { return true }
            return await daemonManager.checkHealth()
        }
    }
    
    func fetchAllConfig() async -> IPCProxyConfigData? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.getProxyConfigAll()
            if result.success, let configData = result.config {
                config = configData
                return configData
            } else {
                lastError = result.error ?? "Failed to fetch config"
                return nil
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func getConfig(key: String) async -> String? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        do {
            let result = try await ipcClient.getProxyConfig(key: key)
            if result.success {
                return result.value?.stringValue
            } else {
                lastError = result.error ?? "Failed to get config"
                return nil
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func setConfig(key: String, value: String) async throws {
        guard await isDaemonReady else {
            throw DaemonProxyConfigError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.setProxyConfig(key: key, value: value)
            if !result.success {
                throw DaemonProxyConfigError.updateFailed(result.error ?? "Unknown error")
            }
        } catch let error as DaemonProxyConfigError {
            lastError = error.localizedDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw DaemonProxyConfigError.updateFailed(error.localizedDescription)
        }
    }
    
    func setPort(_ port: Int) async throws {
        try await setConfig(key: "port", value: String(port))
    }
    
    func setSecretKey(_ key: String) async throws {
        try await setConfig(key: "secret-key", value: key)
    }
    
    func setDebug(_ enabled: Bool) async throws {
        try await setConfig(key: "debug", value: enabled ? "true" : "false")
    }
    
    func setControlPanelDisabled(_ disabled: Bool) async throws {
        try await setConfig(key: "disable-control-panel", value: disabled ? "true" : "false")
    }
    
    func reset() {
        config = nil
        lastError = nil
    }
}

enum DaemonProxyConfigError: LocalizedError {
    case daemonNotRunning
    case updateFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .updateFailed(let reason):
            return "Failed to update proxy config: \(reason)"
        }
    }
}
