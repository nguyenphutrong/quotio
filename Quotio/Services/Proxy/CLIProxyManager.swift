//
//  CLIProxyManager.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import AppKit

@MainActor
@Observable
final class CLIProxyManager {
    static let shared = CLIProxyManager()

    private enum AuthDirConfigurationError: LocalizedError {
        case emptyPath
        case notDirectory(String)
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .emptyPath:
                return "settings.authDir.error.empty".localizedStatic()
            case .notDirectory(let path):
                return String(format: "settings.authDir.error.notDirectory".localizedStatic(), path)
            case .notWritable(let path):
                return String(format: "settings.authDir.error.notWritable".localizedStatic(), path)
            }
        }
    }
    
    /// Whether to allow network access to the proxy (bind to 0.0.0.0)
    var allowNetworkAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "allowNetworkAccess") }
        set {
            guard newValue != UserDefaults.standard.bool(forKey: "allowNetworkAccess") else { return }
            UserDefaults.standard.set(newValue, forKey: "allowNetworkAccess")
            ensureConfigExists()
            if newValue {
                ensureApiKeyExistsInConfig()
            }
            updateConfigHost(newValue ? "0.0.0.0" : "127.0.0.1")

            // Restart proxy if running to apply changes
            restartProxyIfRunning()
        }
    }
    
    nonisolated static func terminateProxyOnShutdown() {
        let savedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        let port = (savedPort > 0 && savedPort < 65536) ? UInt16(savedPort) : 8080
        killProcessOnPort(port)
    }
    
    @discardableResult
    nonisolated private static func killProcessOnPort(_ port: UInt16) -> Int {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        // Get own PID to avoid killing ourselves.
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var killedCount = 0

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return killedCount }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    if pid == ownPid {
                        NSLog("[CLIProxyManager] Skipping kill of own PID \(pid) on port \(port) during shutdown")
                        continue
                    }
                    if kill(pid, SIGKILL) == 0 {
                        killedCount += 1
                    }
                }
            }
        } catch {
        }

        return killedCount
    }
    
    private var process: Process?
    private(set) var proxyStatus = ProxyStatus()
    private(set) var isStarting = false
    private(set) var isRegeneratingKey = false
    private(set) var lastError: String?
    
    /// Health monitor task for auto-recovery
    private var healthMonitorTask: Task<Void, Never>?

    /// PIDs that Quotio intentionally terminates during stop/restart/upgrade flows.
    private var expectedTerminationPIDs = Set<Int32>()

    /// Pending restart after an unexpected proxy process exit.
    private var crashRestartTask: Task<Void, Never>?

    /// Consecutive restart attempts after unexpected process exits.
    private var crashRestartAttempts: Int = 0
    
    /// Consecutive health check failures
    private var healthCheckFailures: Int = 0
    
    /// Max failures before auto-restart
    private let maxHealthCheckFailures = 3

    /// Max crash restarts before giving up and leaving the proxy stopped.
    private let maxCrashRestartAttempts = 3
    
    /// Health check interval in seconds
    private let healthCheckIntervalSeconds: UInt64 = 30

    /// Initial delay before restarting after an unexpected process exit.
    private let crashRestartBaseDelaySeconds: UInt64 = 2

    /// Maximum restart delay after repeated unexpected process exits.
    private let maxCrashRestartDelaySeconds: UInt64 = 30
    
    /// Compatibility checker instance.
    private let compatibilityChecker = CompatibilityChecker()

    private static let authDirDefaultsKey = "localAuthDir"

    let binaryPath: String
    let configPath: String
    private(set) var authDir: String
    private(set) var managementKey: String
    let defaultAuthDir: String
    
    var port: UInt16 {
        get { proxyStatus.port }
        set {
            guard newValue != proxyStatus.port else { return }
            proxyStatus.port = newValue
            UserDefaults.standard.set(Int(newValue), forKey: "proxyPort")
            updateConfigPort(newValue)
            restartProxyIfRunning()
        }
    }
    
    private static let binaryName = ProxyBinarySource.binaryName
    
    /// Base URL for the proxy API.
    var baseURL: String {
        "http://127.0.0.1:\(proxyStatus.port)"
    }
    
    var managementURL: String {
        "\(baseURL)/v0/management"
    }
    
    /// The endpoint URL that clients should use (user-facing port)
    var clientEndpoint: String {
        "http://127.0.0.1:\(proxyStatus.port)"
    }
    
    init() {
        let quotioDir = AppRuntimeIdentity.applicationSupportDirectoryURL()
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        
        try? FileManager.default.createDirectory(at: quotioDir, withIntermediateDirectories: true)
        
        self.binaryPath = quotioDir.appendingPathComponent(Self.binaryName).path
        self.configPath = quotioDir.appendingPathComponent("config.yaml").path
        self.defaultAuthDir = homeDir.appendingPathComponent(".cli-proxy-api").path
        self.authDir = Self.resolveInitialAuthDir(configPath: quotioDir.appendingPathComponent("config.yaml").path, defaultAuthDir: defaultAuthDir)
        
        // Always use key from Keychain, generate new if not exists
        // Never read from config because CLIProxyAPI hashes the key on startup
        if let savedKey = KeychainHelper.getLocalManagementKey(), !savedKey.hasPrefix("$2a$") {
            self.managementKey = savedKey
        } else {
            let newKey = UUID().uuidString
            self.managementKey = newKey
            if !KeychainHelper.saveLocalManagementKey(newKey) {
                Log.keychain("Failed to persist local management key, using in-memory value")
            }
        }
        
        let savedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        if savedPort > 0 && savedPort < 65536 {
            self.proxyStatus.port = UInt16(savedPort)
        }

        try? FileManager.default.createDirectory(atPath: authDir, withIntermediateDirectories: true)

        migrateLegacyVersionedStorageIfNeeded()
        initializeSelectedBinarySourceIfNeeded()
        ensureConfigExists()
        syncAuthDirInConfig()
    }

    /// Restart the proxy if it is currently running.
    /// This is used to apply configuration changes that require a restart.
    private func restartProxyIfRunning() {
        guard proxyStatus.running else { return }

        Task {
            NSLog("[CLIProxyManager] Restarting proxy to apply configuration changes...")
            stop()
            // Wait 0.5s for ports to clear
            try? await Task.sleep(nanoseconds: 500_000_000)

            do {
                try await start()
                NSLog("[CLIProxyManager] Proxy restarted successfully")
            } catch {
                NSLog("[CLIProxyManager] Failed to restart proxy: \(error)")
                lastError = "Failed to restart: \(error.localizedDescription)"
            }
        }
    }

    private func updateConfigValue(pattern: String, replacement: String) {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            NSLog("[CLIProxyManager] ERROR: Failed to read config file at \(configPath)")
            return
        }
        
        guard let range = content.range(of: pattern, options: .regularExpression) else {
            NSLog("[CLIProxyManager] ERROR: Pattern '\(pattern)' not found in config")
            return
        }
        
        do {
            content.replaceSubrange(range, with: replacement)
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[CLIProxyManager] ERROR: Failed to write config file: \(error)")
        }
    }

    private func updateConfigPort(_ newPort: UInt16) {
        updateConfigValue(pattern: #"port:\s*\d+"#, replacement: "port: \(newPort)")
    }

    private func updateConfigHost(_ host: String) {
        updateConfigValue(pattern: #"host:\s*"[^"]*""#, replacement: "host: \"\(host)\"")
    }

    private func updateConfigAuthDir(_ path: String) {
        updateConfigValue(pattern: #"auth-dir:\s*"[^"]*""#, replacement: "auth-dir: \"\(path)\"")
    }

    private static func resolveInitialAuthDir(configPath: String, defaultAuthDir: String) -> String {
        if let savedPath = UserDefaults.standard.string(forKey: authDirDefaultsKey),
           !savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizePath(savedPath)
        }

        if let configPathValue = readAuthDirFromConfig(at: configPath) {
            let normalized = normalizePath(configPathValue)
            UserDefaults.standard.set(normalized, forKey: authDirDefaultsKey)
            return normalized
        }

        return defaultAuthDir
    }

    private static func readAuthDirFromConfig(at configPath: String) -> String? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8),
              let match = content.range(of: #"auth-dir:\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }

        let line = String(content[match])
        guard let quotedRange = line.range(of: #""([^"]+)""#, options: .regularExpression) else {
            return nil
        }

        return String(line[quotedRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func normalizePath(_ rawValue: String) -> String {
        NSString(string: rawValue).expandingTildeInPath
    }

    private func syncAuthDirInConfig() {
        updateConfigAuthDir(authDir)
    }

    func setAuthDir(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuthDirConfigurationError.emptyPath
        }

        let normalizedPath = Self.normalizePath(trimmed)
        var isDirectory: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory)

        if fileExists && !isDirectory.boolValue {
            throw AuthDirConfigurationError.notDirectory(normalizedPath)
        }

        if !fileExists {
            try FileManager.default.createDirectory(atPath: normalizedPath, withIntermediateDirectories: true)
        }

        guard FileManager.default.isWritableFile(atPath: normalizedPath) else {
            throw AuthDirConfigurationError.notWritable(normalizedPath)
        }

        guard normalizedPath != authDir else { return }

        authDir = normalizedPath
        UserDefaults.standard.set(normalizedPath, forKey: Self.authDirDefaultsKey)
        updateConfigAuthDir(normalizedPath)
        restartProxyIfRunning()
    }

    func resetAuthDir() throws {
        try setAuthDir(defaultAuthDir)
    }

    private func ensureApiKeyExistsInConfig() {
        guard FileManager.default.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return
        }

        var lines = content.components(separatedBy: "\n")
        if let apiKeysIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "api-keys:" }) {
            var hasKey = false
            var scanIndex = apiKeysIndex + 1

            while scanIndex < lines.count {
                let line = lines[scanIndex]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    break
                }

                if trimmed.hasPrefix("-") {
                    let value = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { hasKey = true }
                    scanIndex += 1
                    continue
                }

                if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    break
                }

                scanIndex += 1
            }

            if !hasKey {
                let newKey = "quotio-local-\(UUID().uuidString)"
                lines.insert("  - \"\(newKey)\"", at: apiKeysIndex + 1)
                try? lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
            }
            return
        }

        let newKey = "quotio-local-\(UUID().uuidString)"
        lines.append("")
        lines.append("api-keys:")
        lines.append("  - \"\(newKey)\"")
        lines.append("")
        try? lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
    }
    
    func updateConfigAllowRemote(_ enabled: Bool) {
        updateConfigValue(pattern: #"allow-remote:\s*(true|false)"#, replacement: "allow-remote: \(enabled)")
    }

    // MARK: - Workarounds

    /// Applies a workaround to force the primary Google API URL in all auth files.
    /// This prevents fallback to the slow "sandbox" environment.
    /// Backs up original files before modification.
    func applyBaseURLWorkaround() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDir) else { return }

        for file in files where file.hasSuffix(".json") && file.starts(with: "antigravity-") {
            let path = (authDir as NSString).appendingPathComponent(file)
            let backupPath = path + ".bak"

            // Create backup if it doesn't exist
            if !fileManager.fileExists(atPath: backupPath) {
                try? fileManager.copyItem(atPath: path, toPath: backupPath)
            }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { continue }

            var metadata = json["metadata"] as? [String: Any] ?? [:]
            metadata["base_url"] = "https://daily-cloudcode-pa.googleapis.com"
            json["metadata"] = metadata

            if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? newData.write(to: URL(fileURLWithPath: path))
            }
        }

        restartProxyIfRunning()
    }

    /// Restores the original auth files from backup, effectively reverting the URL workaround.
    func removeBaseURLWorkaround() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDir) else { return }

        var restoredCount = 0

        for file in files where file.hasSuffix(".json.bak") {
            let backupPath = (authDir as NSString).appendingPathComponent(file)
            let originalPath = backupPath.replacingOccurrences(of: ".bak", with: "")

            // Restore from backup
            do {
                if fileManager.fileExists(atPath: originalPath) {
                    try fileManager.removeItem(atPath: originalPath)
                }
                try fileManager.moveItem(atPath: backupPath, toPath: originalPath)
                restoredCount += 1
            } catch {
                NSLog("[CLIProxyManager] Failed to restore backup for \(file): \(error)")
            }
        }

        // Fallback: If no backups found, try to just remove the key from current files
        if restoredCount == 0 {
            for file in files where file.hasSuffix(".json") && file.starts(with: "antigravity-") {
                let path = (authDir as NSString).appendingPathComponent(file)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { continue }

                if var metadata = json["metadata"] as? [String: Any] {
                    metadata.removeValue(forKey: "base_url")
                    json["metadata"] = metadata

                    if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                        try? newData.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }

        restartProxyIfRunning()
    }

    private func ensureConfigExists() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let defaultConfig = """
        host: "\(allowNetworkAccess ? "0.0.0.0" : "127.0.0.1")"
        port: \(proxyStatus.port)
        auth-dir: "\(authDir)"
        proxy-url: ""

        api-keys:
          - "quotio-local-\(UUID().uuidString)"

        remote-management:
          allow-remote: false
          secret-key: "\(managementKey)"

        debug: false
        logging-to-file: false
        usage-statistics-enabled: true

        routing:
          strategy: "round-robin"

        quota-exceeded:
          switch-project: true
          switch-preview-model: true

        request-retry: 3
        max-retry-interval: 30
        """

        try? defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
    
    private func syncSecretKeyInConfig() {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        
        if let range = content.range(of: #"secret-key:\s*\".*\""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(managementKey)\"")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        } else if let range = content.range(of: #"secret-key:\s*[^\n]+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(managementKey)\"")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }
    
    /// Regenerates the management key with staged persistence and rollback on failure.
    /// - Throws: `ProxyError` if proxy restart fails
    func regenerateManagementKey() async throws {
        guard !isRegeneratingKey else {
            throw ProxyError.operationInProgress
        }
        
        isRegeneratingKey = true
        defer { isRegeneratingKey = false }
        
        let previousKey = managementKey
        let newKey = UUID().uuidString
        managementKey = newKey
        syncSecretKeyInConfig()
        
        guard proxyStatus.running else {
            if !KeychainHelper.saveLocalManagementKey(newKey) {
                Log.keychain("Failed to persist regenerated management key while stopped")
            }
            return
        }
        
        do {
            stop()
            try await Task.sleep(for: .milliseconds(500))
            try await start()
            if !KeychainHelper.saveLocalManagementKey(newKey) {
                Log.keychain("Failed to persist regenerated management key after restart")
            }
        } catch {
            managementKey = previousKey
            syncSecretKeyInConfig()
            try? await Task.sleep(for: .milliseconds(300))
            try? await start()
            throw error
        }
    }
    
    
    var isBinaryInstalled: Bool {
        effectiveBinaryPath != nil
    }

    var legacyCLIProxyAPIPath: String {
        URL(fileURLWithPath: binaryPath)
            .deletingLastPathComponent()
            .appendingPathComponent(ProxyBinarySource.legacyBinaryName)
            .path
    }

    var hasLegacyCLIProxyAPIInstall: Bool {
        FileManager.default.fileExists(atPath: legacyCLIProxyAPIPath)
    }

    var legacyMigrationPrompt: String? {
        guard !isBinaryInstalled, hasLegacyCLIProxyAPIInstall else { return nil }
        return "A legacy CLIProxyAPI install was found. Install cpa++ to continue local mode. Existing auth files will be preserved."
    }

    var cpaPlusPlusDevBinaryPath: String? {
        resolveDevCPAPlusPlusBinaryPath()
    }

    var bundledCPAPlusPlusBinaryPath: String? {
        resolveBundledCPAPlusPlusBinaryPath()
    }

    var activeBinaryPathDescription: String {
        effectiveBinaryPath ?? "Missing bundled cpa++"
    }

    var activeBinarySourceDescription: String {
        if cpaPlusPlusDevBinaryPath != nil {
            return "Dev override"
        }
        if bundledCPAPlusPlusBinaryPath != nil {
            return "Bundled"
        }
        return "Missing"
    }

    var bundledCPAPlusPlusVersion: String? {
        guard let url = Bundle.main.url(forResource: "CPAPlusPlusBundle", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CPAPlusPlusBundleManifest.self, from: data) else {
            return nil
        }

        return manifest.tag.hasPrefix("v") ? String(manifest.tag.dropFirst()) : manifest.tag
    }

    private struct CPAPlusPlusBundleManifest: Decodable {
        let tag: String
    }
    
    func start(resetCrashRecoveryState: Bool = true) async throws {
        guard let activeBinaryPath = effectiveBinaryPath else {
            throw ProxyError.networkError("Bundled cpa++ is missing. Rebuild Quotio or set CPA_PLUSPLUS_BINARY_PATH for local development.")
        }
        
        guard !proxyStatus.running else { return }

        if resetCrashRecoveryState {
            cancelCrashRestart()
            crashRestartAttempts = 0
        }
        
        isStarting = true
        lastError = nil
        
        defer { isStarting = false }

        NSLog("[CLIProxyManager] Starting proxy on port \(proxyStatus.port) using \(activeBinaryPath)")
        
        // Clean up any orphan processes from previous runs
        await cleanupOrphanProcesses()
        
        syncSecretKeyInConfig()
        updateConfigPort(proxyStatus.port)
        
        if activeBinaryPath == resolveDevCPAPlusPlusBinaryPath() {
            try await validateDevBinaryBeforeStart(activeBinaryPath)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: activeBinaryPath)
        process.arguments = ["-config", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: activeBinaryPath).deletingLastPathComponent()
        
        // CRITICAL FIX: Drain stdout/stderr to prevent pipe buffer deadlock
        // macOS pipe buffer is ~64KB. If CLIProxyAPI writes more without being read,
        // the process blocks on write and becomes unresponsive (port open but no response).
        // Solution: Use readabilityHandler to continuously drain the buffers.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Drain stdout buffer to prevent blocking
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Discard data to prevent memory accumulation
            // If debug logging needed: NSLog("[CLIProxyAPI] \(String(data: data, encoding: .utf8) ?? "")")
            _ = data.count
        }
        
        // Drain stderr buffer to prevent blocking
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Discard data - errors are typically reported via exit code
            _ = data.count
        }
        
        // Important: Don't inherit environment that might cause issues
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        
        process.terminationHandler = { terminatedProcess in
            let status = terminatedProcess.terminationStatus
            let pid = terminatedProcess.processIdentifier
            
            // Clear readability handlers to release closures and prevent resource leaks
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            // Close file handles to release resources
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let wasExpected = self.expectedTerminationPIDs.remove(pid) != nil

                guard self.process?.processIdentifier == pid else {
                    return
                }

                self.proxyStatus.running = false
                self.process = nil
                
                if !wasExpected && !self.isStarting {
                    self.lastError = "Process exited with code: \(status)"
                    if status != 0 {
                        NotificationManager.shared.notifyProxyCrashed(exitCode: status)
                    }
                    self.scheduleCrashRestart(exitCode: status)
                }
            }
        }
        
        do {
            try process.run()
            self.process = process
            
            try await Task.sleep(nanoseconds: 1_500_000_000)
            
            guard process.isRunning else {
                throw ProxyError.startupFailed
            }
            
            NSLog("[CLIProxyManager] Proxy started on port \(proxyStatus.port)")
            
            proxyStatus.running = true
            
            startHealthMonitor()

        } catch {
            lastError = error.localizedDescription
            NSLog("[CLIProxyManager] Failed to start proxy on port \(proxyStatus.port): \(error.localizedDescription)")
            throw error
        }
    }
    
    func stop() {
        stopHealthMonitor()
        cancelCrashRestart()
        
        // Run blocking operations in background to avoid freezing MainActor.
        //
        // Trade-off note: If start() is called immediately after stop(), there is a small
        // window where the detached task could kill the newly started process (since
        // killProcessOnPortSync kills by PORT, not PID). This is an acceptable trade-off
        // because UI responsiveness is more important than this rare edge case.
        // A 150ms buffer is added below to reduce (but not eliminate) this race window.
        let currentProcess = process
        let userPort = proxyStatus.port
        markExpectedTermination(currentProcess)
        
        Task.detached(priority: .userInitiated) {
            // Force terminate the main proxy process
            if let proc = currentProcess, proc.isRunning {
                let pid = proc.processIdentifier
                proc.terminate()
                
                let deadline = Date().addingTimeInterval(2.0)
                while proc.isRunning && Date() < deadline {
                    usleep(100_000)  // 100ms, avoid Thread.sleep in async context
                }
                
                if proc.isRunning {
                    kill(pid, SIGKILL)
                }
            }
            
            Self.killProcessOnPortSync(userPort)
        }
        
        process = nil
        proxyStatus.running = false
    }

    /// Stop the proxy and wait for process/port cleanup to complete.
    /// Used by recovery paths that immediately restart, so the detached cleanup in stop()
    /// cannot race with and kill the newly started process by port.
    func stopAndWait() async {
        stopHealthMonitor()
        cancelCrashRestart()

        let currentProcess = process
        let userPort = proxyStatus.port
        markExpectedTermination(currentProcess)

        process = nil
        proxyStatus.running = false

        await Task.detached(priority: .userInitiated) {
            if let proc = currentProcess, proc.isRunning {
                let pid = proc.processIdentifier
                proc.terminate()

                let deadline = Date().addingTimeInterval(2.0)
                while proc.isRunning && Date() < deadline {
                    usleep(100_000)
                }

                if proc.isRunning {
                    kill(pid, SIGKILL)
                }
            }

            Self.killProcessOnPortSync(userPort)
        }.value
    }
    
    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Health Monitoring
    // ════════════════════════════════════════════════════════════════════════
    
    private func startHealthMonitor() {
        stopHealthMonitor()
        healthCheckFailures = 0
        
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.healthCheckIntervalSeconds ?? 30) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                
                await self?.performHealthCheck()
            }
        }
    }
    
    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func markExpectedTermination(_ process: Process?) {
        guard let process else { return }
        expectedTerminationPIDs.insert(process.processIdentifier)
    }

    private func cancelCrashRestart() {
        crashRestartTask?.cancel()
        crashRestartTask = nil
    }

    private func scheduleCrashRestart(exitCode: Int32) {
        guard crashRestartTask == nil else { return }

        guard crashRestartAttempts < maxCrashRestartAttempts else {
            NSLog("[CLIProxyManager] Max crash restart attempts reached after exit code \(exitCode)")
            return
        }

        crashRestartAttempts += 1
        let attempt = crashRestartAttempts
        let multiplier = UInt64(1 << max(0, attempt - 1))
        let delay = min(crashRestartBaseDelaySeconds * multiplier, maxCrashRestartDelaySeconds)

        NSLog("[CLIProxyManager] Scheduling proxy restart in \(delay)s after unexpected exit code \(exitCode) (attempt \(attempt)/\(maxCrashRestartAttempts))")

        crashRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }

            self.crashRestartTask = nil

            guard !self.proxyStatus.running else { return }

            do {
                try await self.start(resetCrashRecoveryState: false)
                NSLog("[CLIProxyManager] Crash auto-restart successful")
            } catch {
                self.lastError = "Auto-restart failed: \(error.localizedDescription)"
                NSLog("[CLIProxyManager] Crash auto-restart failed: \(error)")
                self.scheduleCrashRestart(exitCode: -1)
            }
        }
    }
    
    private func performHealthCheck() async {
        guard proxyStatus.running else {
            healthCheckFailures = 0
            return
        }

        let isHealthy = await compatibilityChecker.isHealthy(
            port: proxyStatus.port,
            managementKey: managementKey
        )
        
        // Re-check state after await - proxy may have been stopped.
        guard proxyStatus.running else {
            healthCheckFailures = 0
            return
        }

        if isHealthy {
            healthCheckFailures = 0
            crashRestartAttempts = 0
        } else {
            healthCheckFailures += 1
            NSLog("[CLIProxyManager] Health check failed (\(healthCheckFailures)/\(maxHealthCheckFailures))")
            
            if healthCheckFailures >= maxHealthCheckFailures {
                NSLog("[CLIProxyManager] Max failures reached, auto-restarting proxy...")
                healthCheckFailures = 0
                
                stop()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                
                do {
                    try await start()
                    NSLog("[CLIProxyManager] Auto-restart successful")
                } catch {
                    NSLog("[CLIProxyManager] Auto-restart failed: \(error)")
                    NotificationManager.shared.notifyProxyCrashed(exitCode: -1)
                }
            }
        }
    }
    
    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Process Cleanup
    // ════════════════════════════════════════════════════════════════════════
    
    /// Clean up any orphan proxy processes from previous runs.
    /// Executes blocking operations on background thread to avoid blocking MainActor.
    private func cleanupOrphanProcesses() async {
        let userPort = proxyStatus.port
        
        // Execute blocking operations on background thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .userInitiated) {
                let killedCount = Self.killProcessOnPortSync(userPort)
                if killedCount > 0 {
                    NSLog("[CLIProxyManager] Cleaned up \(killedCount) orphan proxy process(es) on port \(userPort)")
                }
                
                // Small delay to ensure ports are released
                usleep(200_000)  // 200ms, avoid Thread.sleep in async context
                continuation.resume()
            }
        }
    }
    
    /// Synchronous port cleanup for use in detached tasks.
    /// This method is `nonisolated` to allow calling from background threads.
    /// IMPORTANT: Excludes own PID to prevent killing Quotio itself.
    @discardableResult
    nonisolated private static func killProcessOnPortSync(_ port: UInt16) -> Int {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        // Get own PID to avoid killing ourselves.
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var killedCount = 0

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return killedCount }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    // Never kill our own process.
                    if pid == ownPid {
                        NSLog("[CLIProxyManager] Skipping kill of own PID \(pid) on port \(port)")
                        continue
                    }
                    if kill(pid, SIGKILL) == 0 {
                        killedCount += 1
                    }
                }
            }
        } catch {
            // Silent failure - process may not exist
        }

        return killedCount
    }
    
    func toggle() async throws {
        if proxyStatus.running {
            stop()
        } else {
            try await start()
        }
    }
    
    func copyEndpointToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proxyStatus.endpoint, forType: .string)
    }
    
    func revealInFinder() {
        guard let path = effectiveBinaryPath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }
}

enum ProxyError: LocalizedError {
    case startupFailed
    case operationInProgress
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .startupFailed:
            return "Failed to start proxy server."
        case .operationInProgress:
            return "Another operation is already in progress. Please wait."
        case .networkError(let msg):
            return "Network error: \(msg)"
        }
    }
}

// MARK: - Local Binary Resolution

extension CLIProxyManager {
    var selectedBinarySource: ProxyBinarySource {
        get {
            let rawValue = UserDefaults.standard.string(forKey: ProxyBinarySource.userDefaultsKey)
            return ProxyBinarySource(rawValue: rawValue ?? "") ?? defaultBinarySource()
        }
        set {
            let previousSource = selectedBinarySource
            guard previousSource != newValue else { return }

            UserDefaults.standard.set(newValue.rawValue, forKey: ProxyBinarySource.userDefaultsKey)
            lastError = nil

            if proxyStatus.running {
                restartProxyIfRunning()
            }
        }
    }

    func sourceInstallHint(for source: ProxyBinarySource? = nil) -> String {
        (source ?? selectedBinarySource).installHint
    }

    func isSourceInstalled(_ source: ProxyBinarySource) -> Bool {
        if source == .cpaPlusPlus, resolveDevCPAPlusPlusBinaryPath() != nil {
            return true
        }

        return source == .cpaPlusPlus && resolveBundledCPAPlusPlusBinaryPath() != nil
    }
    
    /// The effective binary path: dev override first, then bundled app resource.
    var effectiveBinaryPath: String? {
        if selectedBinarySource == .cpaPlusPlus,
           let devPath = resolveDevCPAPlusPlusBinaryPath() {
            return devPath
        }
        return resolveBundledCPAPlusPlusBinaryPath()
    }
    
    /// Get the bundled cpa-plusplus version from the build-time manifest.
    var currentVersion: String? {
        bundledCPAPlusPlusVersion
    }
    
    private func findUnusedPort() throws -> UInt16 {
        // Try ports in range 18000-18100
        for port in UInt16(18000)...UInt16(18100) {
            if !isPortInUse(port) && port != proxyStatus.port {
                return port
            }
        }
        throw ProxyError.networkError("No available port for testing")
    }
    
    private func isPortInUse(_ port: UInt16) -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return true }
        defer { close(socket) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return bindResult != 0
    }
    
    private func createTestConfig(port: UInt16, managementKey: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let testConfigPath = tempDir.appendingPathComponent("quotio-test-config-\(port).yaml").path
        
        let testConfig = """
        host: "127.0.0.1"
        port: \(port)
        auth-dir: "\(authDir)"
        
        api-keys:
          - "quotio-test-\(UUID().uuidString.prefix(8))"
        
        remote-management:
          allow-remote: false
          secret-key: "\(managementKey)"
        
        debug: false
        logging-to-file: false
        usage-statistics-enabled: false
        
        routing:
          strategy: "round-robin"
        """
        
        try? testConfig.write(toFile: testConfigPath, atomically: true, encoding: .utf8)
        return testConfigPath
    }

    private func validateDevBinaryBeforeStart(_ binaryPath: String) async throws {
        let port = try findUnusedPort()
        let managementKey = UUID().uuidString
        let configPath = createTestConfig(port: port, managementKey: managementKey)
        defer {
            cleanupTestConfig(configPath)
            Self.killProcessOnPortSync(port)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-config", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard process.isRunning else {
            throw ProxyError.startupFailed
        }

        let result = await compatibilityChecker.fullCheck(port: port, managementKey: managementKey)
        guard result.isCompatible else {
            throw ProxyError.networkError(result.description)
        }
    }
    
    private func cleanupTestConfig(_ configPath: String) {
        try? FileManager.default.removeItem(atPath: configPath)
    }
    
    private func initializeSelectedBinarySourceIfNeeded() {
        if UserDefaults.standard.string(forKey: ProxyBinarySource.userDefaultsKey) != nil {
            return
        }

        let defaultSource = defaultBinarySource()
        UserDefaults.standard.set(defaultSource.rawValue, forKey: ProxyBinarySource.userDefaultsKey)
    }

    private func defaultBinarySource() -> ProxyBinarySource {
        return .cpaPlusPlus
    }

    private func migrateLegacyVersionedStorageIfNeeded() {
    }

    private func resolveDevCPAPlusPlusBinaryPath() -> String? {
        let fileManager = FileManager.default

        func firstExistingRegularFile(in candidates: [URL?]) -> String? {
            for candidate in candidates.compactMap({ $0 }) {
                guard fileManager.fileExists(atPath: candidate.path) else {
                    continue
                }

                let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true,
                   values?.isSymbolicLink != true,
                   fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
            return nil
        }

        if let override = ProcessInfo.processInfo.environment[ProxyBinarySource.devBinaryPathEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let path = firstExistingRegularFile(in: [URL(fileURLWithPath: override)]) {
            return path
        }

        Log.proxy("No \(ProxyBinarySource.devBinaryPathEnvironmentKey) cpa-plusplus binary override found")
        return nil
    }

    private func resolveBundledCPAPlusPlusBinaryPath() -> String? {
        guard let url = Bundle.main.url(forResource: ProxyBinarySource.binaryName, withExtension: nil) else {
            return nil
        }

        let path = url.path
        guard FileManager.default.fileExists(atPath: path),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }
}
