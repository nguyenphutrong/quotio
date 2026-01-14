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
    @ObservationIgnored private var lastLogId: Int?
    
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
        let ipcEntries = await daemonLogsService.fetchLogs(after: lastLogId)
        if !ipcEntries.isEmpty {
            let newEntries = convertIPCLogEntries(ipcEntries)
            logs.append(contentsOf: newEntries)
            if logs.count > 50 {
                logs = Array(logs.suffix(50))
            }
        }
        lastLogId = daemonLogsService.lastId
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
    
    private func convertIPCLogEntries(_ entries: [IPCLogEntry]) -> [LogEntry] {
        entries.map { entry in
            let level: LogEntry.LogLevel
            if entry.statusCode >= 500 || entry.error != nil {
                level = .error
            } else if entry.statusCode >= 400 {
                level = .warn
            } else {
                level = .info
            }
            
            let message = formatLogMessage(entry)
            let timestamp = parseTimestamp(entry.timestamp) ?? Date()
            
            return LogEntry(timestamp: timestamp, level: level, message: message)
        }
    }
    
    private func formatLogMessage(_ entry: IPCLogEntry) -> String {
        var parts: [String] = []
        parts.append("[\(entry.method)]")
        parts.append(entry.path)
        parts.append("→ \(entry.statusCode)")
        parts.append("(\(entry.duration)ms)")
        
        if let provider = entry.provider {
            parts.append("[\(provider)]")
        }
        if let model = entry.model {
            parts.append(model)
        }
        if let input = entry.inputTokens, let output = entry.outputTokens {
            parts.append("tokens: \(input)/\(output)")
        }
        if let error = entry.error {
            parts.append("error: \(error)")
        }
        
        return parts.joined(separator: " ")
    }
    
    private func parseTimestamp(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
    
    func clearLogs() async {
        if await shouldUseDaemon() {
            try? await daemonLogsService.clearLogs()
            logs.removeAll()
            lastLogId = nil
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
        lastLogId = nil
        apiClient = nil
        daemonLogsService.reset()
    }
}
