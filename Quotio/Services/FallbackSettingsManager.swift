//
//  FallbackSettingsManager.swift
//  Quotio - Model Fallback Configuration Manager
//
//  Reads/writes fallback configuration from ~/.config/quotio/fallback-config.json
//  This allows sharing configuration between CLI (TypeScript) and macOS app (Swift)
//

import Foundation
import Observation

// MARK: - Cached Entry Info

/// Cached entry information with timestamp for expiration
struct CachedEntryInfo: Sendable {
    let entryId: UUID
    let cachedAt: Date
}

// MARK: - Fallback Route State

/// Represents the current routing state for a virtual model
struct FallbackRouteState: Sendable, Equatable {
    let virtualModelName: String
    let currentEntryIndex: Int
    let currentEntry: FallbackEntry
    let lastUpdated: Date
    let totalEntries: Int

    /// Display string for the current route
    var displayString: String {
        "\(currentEntry.provider.displayName) → \(currentEntry.modelId)"
    }

    /// Progress string (e.g., "1/3")
    var progressString: String {
        "\(currentEntryIndex + 1)/\(totalEntries)"
    }
}

// MARK: - File-based Configuration Path

private enum FallbackConfigPath {
    /// Path to ~/.config/quotio/fallback-config.json
    static var configFilePath: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir
            .appendingPathComponent(".config")
            .appendingPathComponent("quotio")
            .appendingPathComponent("fallback-config.json")
    }
    
    /// Ensure ~/.config/quotio directory exists
    static func ensureConfigDirectory() {
        let dirPath = configFilePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
    }
}

@MainActor
@Observable
final class FallbackSettingsManager {
    static let shared = FallbackSettingsManager()

    /// The current fallback configuration
    var configuration: FallbackConfiguration {
        didSet {
            persistToFile()
            onConfigurationChanged?(configuration)
        }
    }

    /// Callback when configuration changes
    var onConfigurationChanged: ((FallbackConfiguration) -> Void)?

    // MARK: - Route State Cache (Runtime only, not persisted)

    /// Current route state for each virtual model (keyed by model name) - for UI display
    private(set) var routeStates: [String: FallbackRouteState] = [:]

    /// Callback when route state changes (for UI updates)
    var onRouteStateChanged: (() -> Void)?

    // Thread-safe cache for entry IDs (accessed from ProxyBridge on background threads)
    // Using entry ID instead of index to handle reordering correctly
    // Marked nonisolated(unsafe) because we handle thread safety manually with NSLock
    @ObservationIgnored nonisolated(unsafe) private var cachedEntryIds: [String: CachedEntryInfo] = [:]
    @ObservationIgnored nonisolated private let cacheLock = NSLock()

    /// Cache expiration time in seconds (60 minutes)
    /// After expiration, fallback will restart from the first entry
    nonisolated static let cacheExpirationSeconds: TimeInterval = 3600
    
    /// File system source for DispatchSource
    @ObservationIgnored private var fileMonitorSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileDescriptor: Int32 = -1

    private init() {
        // Load from file first, fallback to UserDefaults for migration, then default
        if let config = Self.loadFromFile() {
            self.configuration = config
        } else {
            // Check UserDefaults for migration from old format
            let defaults = UserDefaults.standard
            if let data = defaults.data(forKey: "fallbackConfiguration"),
               let decoded = try? JSONDecoder().decode(FallbackConfiguration.self, from: data) {
                self.configuration = decoded
                // Migrate to file-based storage
                persistToFile()
                // Clean up UserDefaults
                defaults.removeObject(forKey: "fallbackConfiguration")
            } else {
                self.configuration = FallbackConfiguration()
            }
        }
        
        // Start watching the config file for external changes (CLI updates)
        startFileWatcher()
    }
    
    // MARK: - File-based Persistence
    
    /// Load configuration from ~/.config/quotio/fallback-config.json
    private static func loadFromFile() -> FallbackConfiguration? {
        let filePath = FallbackConfigPath.configFilePath
        
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: filePath)
            let decoder = JSONDecoder()
            return try decoder.decode(FallbackConfiguration.self, from: data)
        } catch {
            return nil
        }
    }
    
    /// Save configuration to ~/.config/quotio/fallback-config.json
    private func persistToFile() {
        FallbackConfigPath.ensureConfigDirectory()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(configuration)
            try data.write(to: FallbackConfigPath.configFilePath, options: .atomic)
        } catch {
            // Silent failure - logging would be nice but not critical
        }
    }
    
    /// Reload configuration from file (called when file changes externally)
    func reloadFromFile() {
        if let config = Self.loadFromFile() {
            // Only update if different to avoid triggering didSet unnecessarily
            if config != self.configuration {
                self.configuration = config
            }
        }
    }
    
    // MARK: - File Watcher
    
    /// Watch the config file for changes made by CLI
    private func startFileWatcher() {
        let filePath = FallbackConfigPath.configFilePath
        FallbackConfigPath.ensureConfigDirectory()
        
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: filePath.path) {
            persistToFile()
        }
        
        // Open file descriptor for monitoring
        fileDescriptor = open(filePath.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        // Create dispatch source for file system events
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.reloadFromFile()
            }
        }
        
        source.setCancelHandler { [weak self] in
            guard let self = self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        
        source.resume()
        fileMonitorSource = source
    }
    
    /// Stop watching the config file
    private func stopFileWatcher() {
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
    }

    // MARK: - Global Settings

    /// Whether fallback is globally enabled
    var isEnabled: Bool {
        get { configuration.isEnabled }
        set {
            configuration.isEnabled = newValue
        }
    }

    // MARK: - Virtual Model Management

    /// All virtual models
    var virtualModels: [VirtualModel] {
        configuration.virtualModels
    }

    /// Add a new virtual model (returns nil if name already exists)
    func addVirtualModel(name: String) -> VirtualModel? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for duplicate name (case-insensitive)
        guard !configuration.virtualModels.contains(where: {
            $0.name.lowercased() == trimmedName.lowercased()
        }) else {
            return nil
        }

        let model = VirtualModel(name: trimmedName)
        configuration.virtualModels.append(model)
        return model
    }

    /// Remove a virtual model by ID
    func removeVirtualModel(id: UUID) {
        // Clear cached route state before removing
        if let model = configuration.virtualModels.first(where: { $0.id == id }) {
            clearRouteState(for: model.name)
        }
        configuration.virtualModels.removeAll { $0.id == id }
    }

    /// Update a virtual model
    func updateVirtualModel(_ model: VirtualModel) {
        if let index = configuration.virtualModels.firstIndex(where: { $0.id == model.id }) {
            let oldEntries = configuration.virtualModels[index].fallbackEntries
            configuration.virtualModels[index] = model
            
            if oldEntries != model.fallbackEntries {
                clearRouteState(for: model.name)
            }
        }
    }

    /// Find a virtual model by name
    func findVirtualModel(name: String) -> VirtualModel? {
        configuration.findVirtualModel(name: name)
    }

    /// Toggle virtual model enabled state
    func toggleVirtualModel(id: UUID) {
        if let index = configuration.virtualModels.firstIndex(where: { $0.id == id }) {
            let wasEnabled = configuration.virtualModels[index].isEnabled
            configuration.virtualModels[index].isEnabled.toggle()
            
            if wasEnabled {
                clearRouteState(for: configuration.virtualModels[index].name)
            }
        }
    }

    /// Rename a virtual model (returns false if name already exists)
    func renameVirtualModel(id: UUID, newName: String) -> Bool {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for duplicate name (case-insensitive), excluding the current model
        let isDuplicate = configuration.virtualModels.contains {
            $0.id != id && $0.name.lowercased() == trimmedName.lowercased()
        }
        guard !isDuplicate else { return false }

        if let index = configuration.virtualModels.firstIndex(where: { $0.id == id }) {
            let oldName = configuration.virtualModels[index].name
            configuration.virtualModels[index].name = trimmedName

            // Update cached route state key if exists
            if let state = routeStates[oldName] {
                routeStates.removeValue(forKey: oldName)
                routeStates[trimmedName] = FallbackRouteState(
                    virtualModelName: trimmedName,
                    currentEntryIndex: state.currentEntryIndex,
                    currentEntry: state.currentEntry,
                    lastUpdated: state.lastUpdated,
                    totalEntries: state.totalEntries
                )
                onRouteStateChanged?()
            }
        }
        return true
    }

    // MARK: - Fallback Entry Management

    /// Add a fallback entry to a virtual model
    func addFallbackEntry(to modelId: UUID, provider: AIProvider, modelName: String) {
        guard let index = configuration.virtualModels.firstIndex(where: { $0.id == modelId }) else { return }
        configuration.virtualModels[index].addEntry(provider: provider, modelId: modelName)
    }

    /// Remove a fallback entry from a virtual model
    func removeFallbackEntry(from modelId: UUID, entryId: UUID) {
        guard let index = configuration.virtualModels.firstIndex(where: { $0.id == modelId }) else { return }
        let virtualModelName = configuration.virtualModels[index].name
        configuration.virtualModels[index].removeEntry(id: entryId)

        // Clear cached route state when entries change (cached index may be invalid)
        clearRouteState(for: virtualModelName)
    }

    /// Move fallback entry within a virtual model
    func moveFallbackEntry(in modelId: UUID, from source: IndexSet, to destination: Int) {
        guard let index = configuration.virtualModels.firstIndex(where: { $0.id == modelId }) else { return }
        let virtualModelName = configuration.virtualModels[index].name
        configuration.virtualModels[index].moveEntry(from: source, to: destination)

        // Clear cached route state when order changes (cached index may be invalid)
        clearRouteState(for: virtualModelName)
    }

    // MARK: - Persistence

    /// Export configuration as JSON string
    func exportConfiguration() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Import configuration from JSON string
    func importConfiguration(from json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FallbackConfiguration.self, from: data) else {
            return false
        }
        configuration = decoded
        return true
    }

    /// Reset to default configuration
    func resetToDefaults() {
        configuration = FallbackConfiguration()
    }
}

// MARK: - Quota Checking Helpers

extension FallbackSettingsManager {
    /// Get all enabled virtual model names for display in Agent configuration
    var enabledVirtualModelNames: [String] {
        configuration.enabledModelNames
    }

    /// Check if a model name is a virtual model
    func isVirtualModel(_ name: String) -> Bool {
        configuration.virtualModels.contains { $0.name == name && $0.isEnabled }
    }
}

// MARK: - Route State Management

extension FallbackSettingsManager {
    /// Get the current cached entry ID for a virtual model (thread-safe, for ProxyBridge)
    /// Returns nil if cache is expired (after 60 minutes)
    nonisolated func getCachedEntryId(for virtualModelName: String) -> UUID? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let cached = cachedEntryIds[virtualModelName] else {
            return nil
        }

        // Check if cache is expired
        let elapsed = Date().timeIntervalSince(cached.cachedAt)
        if elapsed > Self.cacheExpirationSeconds {
            // Cache expired, remove it and return nil to restart from first entry
            cachedEntryIds.removeValue(forKey: virtualModelName)
            return nil
        }

        return cached.entryId
    }

    /// Update cached entry ID (thread-safe, called from ProxyBridge)
    nonisolated func setCachedEntryId(for virtualModelName: String, entryId: UUID) {
        cacheLock.lock()
        cachedEntryIds[virtualModelName] = CachedEntryInfo(entryId: entryId, cachedAt: Date())
        cacheLock.unlock()
    }

    /// Clear cached entry ID (thread-safe)
    nonisolated func clearCachedEntryId(for virtualModelName: String) {
        cacheLock.lock()
        cachedEntryIds.removeValue(forKey: virtualModelName)
        cacheLock.unlock()
    }

    /// Update route state when a fallback is triggered (called from ProxyBridge)
    /// This updates the UI display only, not the cache
    func updateRouteState(virtualModelName: String, entryIndex: Int, entry: FallbackEntry, totalEntries: Int) {
        let state = FallbackRouteState(
            virtualModelName: virtualModelName,
            currentEntryIndex: entryIndex,
            currentEntry: entry,
            lastUpdated: Date(),
            totalEntries: totalEntries
        )
        routeStates[virtualModelName] = state
        onRouteStateChanged?()
    }

    /// Clear route state for a virtual model (e.g., when quota resets or config changes)
    func clearRouteState(for virtualModelName: String) {
        routeStates.removeValue(forKey: virtualModelName)

        // Also clear thread-safe cache
        cacheLock.lock()
        cachedEntryIds.removeValue(forKey: virtualModelName)
        cacheLock.unlock()

        onRouteStateChanged?()
    }

    /// Clear all route states
    func clearAllRouteStates() {
        routeStates.removeAll()

        // Also clear thread-safe cache
        cacheLock.lock()
        cachedEntryIds.removeAll()
        cacheLock.unlock()

        onRouteStateChanged?()
    }

    /// Get all active route states for display
    var activeRouteStates: [FallbackRouteState] {
        Array(routeStates.values).sorted { $0.virtualModelName < $1.virtualModelName }
    }
}
