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
    private(set) var logLines: [String] = []
    private(set) var latestTimestamp: Int?
    
    private let ipcClient = DaemonIPCClient.shared
    private let daemonManager = DaemonManager.shared
    
    private init() {}
    
    private var isDaemonReady: Bool {
        get async {
            if daemonManager.isRunning { return true }
            return await daemonManager.checkHealth()
        }
    }
    
    func fetchLogs(after: Int? = nil) async -> [String] {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return []
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.fetchLogs(after: after)
            
            if let lines = result.lines {
                if after == nil {
                    logLines = lines
                } else {
                    logLines.append(contentsOf: lines)
                }
            }
            
            if let timestamp = result.latestTimestamp {
                latestTimestamp = timestamp
            }
            
            return result.lines ?? []
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
                logLines = []
                latestTimestamp = nil
            } else {
                throw DaemonLogsError.clearFailed
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func refreshLogs() async {
        _ = await fetchLogs(after: latestTimestamp)
    }
    
    func reset() {
        logLines = []
        latestTimestamp = nil
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
