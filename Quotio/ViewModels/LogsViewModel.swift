//
//  LogsViewModel.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Extracted from QuotaViewModel to reduce memory footprint.
//  This ViewModel is only instantiated when the Logs screen is visible.
//

import Foundation
import Observation

@MainActor
@Observable
final class LogsViewModel {
    private var apiClient: ManagementAPIClient?
    private let daemonManager = DaemonManager.shared
    private let daemonLogsService = DaemonLogsService.shared
    private let modeManager = OperatingModeManager.shared
    
    var logs: [LogEntry] = []
    @ObservationIgnored private var lastLogTimestamp: Int?
    
    func configure(baseURL: String, authKey: String) {
        self.apiClient = ManagementAPIClient(baseURL: baseURL, authKey: authKey)
    }
    
    var isConfigured: Bool {
        apiClient != nil
    }
    
    private func shouldUseDaemon() async -> Bool {
        guard !modeManager.isRemoteProxyMode else { return false }
        return await daemonManager.checkHealth()
    }
    
    func refreshLogs() async {
        if await shouldUseDaemon() {
            await refreshLogsViaDaemon()
        } else {
            await refreshLogsViaAPI()
        }
    }
    
    private func refreshLogsViaDaemon() async {
        let lines = await daemonLogsService.fetchLogs(after: lastLogTimestamp)
        if !lines.isEmpty {
            let newEntries = parseLogLines(lines)
            logs.append(contentsOf: newEntries)
            if logs.count > 50 {
                logs = Array(logs.suffix(50))
            }
        }
        lastLogTimestamp = daemonLogsService.latestTimestamp
    }
    
    private func refreshLogsViaAPI() async {
        guard let client = apiClient else { return }
        
        do {
            let response = try await client.fetchLogs(after: lastLogTimestamp)
            if let lines = response.lines {
                let newEntries = parseLogLines(lines)
                logs.append(contentsOf: newEntries)
                if logs.count > 50 {
                    logs = Array(logs.suffix(50))
                }
            }
            lastLogTimestamp = response.latestTimestamp
        } catch {}
    }
    
    private func parseLogLines(_ lines: [String]) -> [LogEntry] {
        lines.map { line in
            let level: LogEntry.LogLevel
            if line.contains("error") || line.contains("ERROR") {
                level = .error
            } else if line.contains("warn") || line.contains("WARN") {
                level = .warn
            } else if line.contains("debug") || line.contains("DEBUG") {
                level = .debug
            } else {
                level = .info
            }
            return LogEntry(timestamp: Date(), level: level, message: line)
        }
    }
    
    func clearLogs() async {
        if await shouldUseDaemon() {
            try? await daemonLogsService.clearLogs()
            logs.removeAll()
            lastLogTimestamp = nil
        } else {
            guard let client = apiClient else { return }
            do {
                try await client.clearLogs()
                logs.removeAll()
                lastLogTimestamp = nil
            } catch {}
        }
    }
    
    func reset() {
        logs.removeAll()
        lastLogTimestamp = nil
        apiClient = nil
        daemonLogsService.reset()
    }
}
