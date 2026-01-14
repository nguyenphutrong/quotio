//
//  DaemonConfigService.swift
//  Quotio
//

import Foundation

@MainActor @Observable
final class DaemonConfigService {
    static let shared = DaemonConfigService()
    
    private(set) var isLoading = false
    private(set) var lastError: String?
    
    private(set) var routingStrategy: String?
    private(set) var debugMode: Bool?
    private(set) var proxyUrl: String?
    
    private let ipcClient = DaemonIPCClient.shared
    private let daemonManager = DaemonManager.shared
    
    private init() {}
    
    private var isDaemonReady: Bool {
        get async {
            if daemonManager.isRunning { return true }
            return await daemonManager.checkHealth()
        }
    }
    
    func getRoutingStrategy() async -> String? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        do {
            let result = try await ipcClient.getRoutingStrategy()
            routingStrategy = result.strategy
            return result.strategy
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func setRoutingStrategy(_ strategy: String) async throws {
        guard await isDaemonReady else {
            throw DaemonConfigError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.setRoutingStrategy(strategy)
            routingStrategy = result.strategy
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func getDebugMode() async -> Bool? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        do {
            let result = try await ipcClient.getDebugMode()
            debugMode = result.debug
            return result.debug
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func setDebugMode(_ enabled: Bool) async throws {
        guard await isDaemonReady else {
            throw DaemonConfigError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.setDebugMode(enabled)
            debugMode = result.debug
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func getProxyUrl() async -> String? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        do {
            let result = try await ipcClient.getProxyUrl()
            proxyUrl = result.proxyUrl
            return result.proxyUrl
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func setProxyUrl(_ url: String?) async throws {
        guard await isDaemonReady else {
            throw DaemonConfigError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.setProxyUrl(url)
            proxyUrl = result.proxyUrl
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func refreshAll() async {
        _ = await getRoutingStrategy()
        _ = await getDebugMode()
        _ = await getProxyUrl()
    }
}

enum DaemonConfigError: LocalizedError {
    case daemonNotRunning
    case updateFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .updateFailed(let key):
            return "Failed to update config: \(key)"
        }
    }
}
