//
//  RequestTracker.swift
//  Quotio - Request History Tracking Service
//
//  This service tracks API requests through ProxyBridge callbacks.
//  Request history is persisted to disk for session continuity.
//

import Foundation
import AppKit

/// Service for tracking API request history with persistence
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
    
    /// Last error message
    private(set) var lastError: String?
    
    // MARK: - Private Properties
    
    /// Storage container
    private var store: RequestHistoryStore = .empty
    
    /// Queue for file operations
    private let fileQueue = DispatchQueue(label: "io.quotio.request-tracker-file")
    
    /// Storage file URL
    private var storageURL: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found")
        }
        let quotioDir = appSupport.appendingPathComponent("Quotio")
        try? FileManager.default.createDirectory(at: quotioDir, withIntermediateDirectories: true)
        return quotioDir.appendingPathComponent("request-history.json")
    }
    
    // MARK: - Initialization
    
    private init() {
        loadFromDisk()
        setupMemoryWarningObserver()
    }
    
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.trimHistoryForBackground()
            }
        }
    }
    
    private func trimHistoryForBackground() {
        let reducedLimit = 10
        if store.entries.count > reducedLimit {
            store.entries = Array(store.entries.prefix(reducedLimit))
            requestHistory = store.entries
            stats = store.calculateStats()
            saveToDisk()
            NSLog("[RequestTracker] Trimmed to \(reducedLimit) entries for background")
        }
    }
    
    // MARK: - Public Methods
    
    /// Start tracking (called when proxy starts)
    func start() {
        isActive = true
        NSLog("[RequestTracker] Started tracking")
    }
    
    /// Stop tracking (called when proxy stops)
    func stop() {
        isActive = false
        NSLog("[RequestTracker] Stopped tracking")
    }
    
    /// Add a request from ProxyBridge callback
    func addRequest(from metadata: ProxyBridge.RequestMetadata) {
        let attempts = metadata.fallbackAttempts.isEmpty ? nil : metadata.fallbackAttempts
        let entry = RequestLog(
            timestamp: metadata.timestamp,
            method: metadata.method,
            endpoint: metadata.path,
            provider: metadata.provider,
            model: metadata.model,
            resolvedModel: metadata.resolvedModel,
            resolvedProvider: metadata.resolvedProvider,
            inputTokens: nil,
            outputTokens: nil,
            durationMs: metadata.durationMs,
            statusCode: metadata.statusCode,
            requestSize: metadata.requestSize,
            responseSize: metadata.responseSize,
            errorMessage: metadata.responseSnippet,
            fallbackAttempts: attempts,
            fallbackStartedFromCache: metadata.fallbackStartedFromCache
        )

        addEntry(entry)
    }
    
    /// Add a request entry directly
    func addEntry(_ entry: RequestLog) {
        store.addEntry(entry)
        requestHistory = store.entries
        stats = store.calculateStats()
        saveToDisk()
    }
    
    /// Clear all history
    func clearHistory() {
        store = .empty
        requestHistory = []
        stats = .empty
        saveToDisk()
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
    
    // MARK: - Persistence
    
    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            NSLog("[RequestTracker] No history file found, starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601  // Match the encoding strategy
            store = try decoder.decode(RequestHistoryStore.self, from: data)
            requestHistory = store.entries
            stats = store.calculateStats()
            NSLog("[RequestTracker] Loaded \(store.entries.count) entries from disk")
        } catch {
            NSLog("[RequestTracker] Failed to load history: \(error)")
            lastError = error.localizedDescription
            // If decoding fails due to format mismatch, clear the corrupt file
            try? FileManager.default.removeItem(at: storageURL)
            NSLog("[RequestTracker] Removed corrupt history file, starting fresh")
        }
    }
    
    private func saveToDisk() {
        // Capture store snapshot on MainActor to avoid data race
        let storeSnapshot = self.store
        let storageURLSnapshot = self.storageURL

        fileQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .prettyPrinted

                let data = try encoder.encode(storeSnapshot)
                try data.write(to: storageURLSnapshot)
            } catch {
                NSLog("[RequestTracker] Failed to save history: \(error)")
            }
        }
    }
}
