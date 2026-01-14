//
//  DaemonLogsService.swift
//  Quotio
//

import Foundation

@MainActor @Observable
final class DaemonLogsService {
    static let shared = DaemonLogsService()
    
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var logEntries: [IPCLogEntry] = []
    private(set) var lastId: Int?
    
    private let ipcClient = DaemonIPCClient.shared
    private let daemonManager = DaemonManager.shared
    
    private init() {}
    
    private var isDaemonReady: Bool {
        get async {
            if daemonManager.isRunning { return true }
            return await daemonManager.checkHealth()
        }
    }
    
    func fetchLogs(after: Int? = nil) async -> [IPCLogEntry] {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return []
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.fetchLogs(after: after)
            
            guard result.success else {
                lastError = result.error ?? "Failed to fetch logs"
                return []
            }
            
            if let logs = result.logs {
                if after == nil {
                    logEntries = logs
                } else {
                    logEntries.append(contentsOf: logs)
                }
            }
            
            if let fetchedLastId = result.lastId {
                lastId = fetchedLastId
            }
            
            return result.logs ?? []
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }
    
    func clearLogs() async throws {
        guard await isDaemonReady else {
            throw DaemonLogsError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.clearLogs()
            if result.success {
                logEntries = []
                lastId = nil
            } else {
                throw DaemonLogsError.clearFailed
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func refreshLogs() async {
        _ = await fetchLogs(after: lastId)
    }
    
    func reset() {
        logEntries = []
        lastId = nil
        lastError = nil
    }
}

enum DaemonLogsError: LocalizedError {
    case daemonNotRunning
    case clearFailed
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .clearFailed:
            return "Failed to clear logs"
        }
    }
}
