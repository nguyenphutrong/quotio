//
//  LogsViewModel.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Extracted from QuotaViewModel to reduce memory footprint.
//  This ViewModel is only instantiated when the Logs screen is visible.
//

import Foundation
import Observation

/// Lightweight ViewModel for proxy logs - only loaded when LogsScreen is visible
@MainActor
@Observable
final class LogsViewModel {
    private var apiClient: ManagementAPIClient?
    
    var logs: [LogEntry] = []
    @ObservationIgnored private var lastLogTimestamp: Int?
    
    /// Configure the API client for fetching logs
    func configure(baseURL: String, authKey: String) {
        self.apiClient = ManagementAPIClient(baseURL: baseURL, authKey: authKey)
    }
    
    /// Check if the ViewModel is configured with an API client
    var isConfigured: Bool {
        apiClient != nil
    }
    
    /// Refresh logs from the proxy server
    func refreshLogs() async {
        guard let client = apiClient else { return }
        
        do {
            let response = try await client.fetchLogs(after: lastLogTimestamp)
            if let lines = response.lines {
                let newEntries: [LogEntry] = lines.map { line in
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
                logs.append(contentsOf: newEntries)
                // Keep only last 50 entries to limit memory usage
                if logs.count > 50 {
                    logs = Array(logs.suffix(50))
                }
            }
            lastLogTimestamp = response.latestTimestamp
        } catch {
            // Silently ignore log fetch errors
        }
    }
    
    /// Clear all logs
    func clearLogs() async {
        guard let client = apiClient else { return }
        
        do {
            try await client.clearLogs()
            logs.removeAll()
            lastLogTimestamp = nil
        } catch {
            // Silently ignore clear errors
        }
    }
    
    /// Reset state when disconnecting
    func reset() {
        logs.removeAll()
        lastLogTimestamp = nil
        apiClient = nil
    }
}
