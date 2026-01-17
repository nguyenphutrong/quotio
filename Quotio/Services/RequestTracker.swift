//
//  RequestTracker.swift
//  Quotio - Request History Tracking Service
//
//  This service wraps DaemonStatsService to provide request history and stats
//  for the UI layer. It fetches data from the daemon via IPC.
//

import Foundation
import AppKit
import Observation

/// Error types for RequestTracker operations
enum RequestTrackerError: LocalizedError {
    case daemonNotRunning
    case fetchFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .fetchFailed(let reason):
            return "Failed to fetch stats: \(reason)"
        }
    }
}

/// Service for tracking API request history via daemon IPC
@MainActor
@Observable
final class RequestTracker {
    
    // MARK: - Singleton
    
    static let shared = RequestTracker()
    
    // MARK: - Properties
    
    /// Current request history (newest first)
    private(set) var requestHistory: [RequestLog] = []
    
    /// Aggregate statistics
    private(set) var stats: RequestStats = .empty
    
    /// Whether the tracker is active
    private(set) var isActive = false
    
    /// Loading state
    private(set) var isLoading = false
    
    /// Last error message
    private(set) var lastError: String?
    
    // MARK: - Private Properties
    
    @ObservationIgnored private let daemonStatsService = DaemonStatsService.shared
    @ObservationIgnored private let daemonManager = DaemonManager.shared
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Start tracking (called when proxy starts)
    func start() {
        isActive = true
        NSLog("[RequestTracker] Started tracking")
        
        // Start periodic refresh
        startPeriodicRefresh()
    }
    
    /// Stop tracking (called when proxy stops)
    func stop() {
        isActive = false
        refreshTask?.cancel()
        refreshTask = nil
        NSLog("[RequestTracker] Stopped tracking")
    }
    
    /// Refresh request history and stats from daemon
    func refresh() async {
        guard isActive else { return }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        // Fetch request logs
        if let logs = await daemonStatsService.fetchRequestLogs() {
            requestHistory = logs
        } else if let error = daemonStatsService.lastError {
            lastError = error
            NSLog("[RequestTracker] Failed to fetch logs: \(error)")
        }
        
        // Fetch aggregated stats
        if let fetchedStats = await daemonStatsService.fetchRequestStats() {
            stats = fetchedStats
        } else if let error = daemonStatsService.lastError {
            lastError = error
            NSLog("[RequestTracker] Failed to fetch stats: \(error)")
        }
    }
    
    /// Clear all history
    func clearHistory() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let success = try await daemonStatsService.clearRequestStats()
            if success {
                requestHistory = []
                stats = .empty
                NSLog("[RequestTracker] Cleared history")
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("[RequestTracker] Failed to clear history: \(error)")
        }
    }
    
    /// Get requests filtered by provider
    func requests(for provider: String) -> [RequestLog] {
        requestHistory.filter { $0.provider == provider }
    }
    
    /// Get requests from last N minutes
    func recentRequests(minutes: Int) -> [RequestLog] {
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        return requestHistory.filter { $0.timestamp >= cutoff }
    }
    
    // MARK: - Private Methods
    
    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
        }
    }
}
