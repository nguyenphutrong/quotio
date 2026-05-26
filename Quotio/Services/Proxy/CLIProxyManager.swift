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
    
    // MARK: - Two-Layer Proxy Architecture
    
    /// The ProxyBridge sits between clients and CLIProxyAPI to handle connection management
    /// This solves the stale connection issue by forcing "Connection: close" on all requests
    let proxyBridge = ProxyBridge()
    
    /// When enabled: clients connect to userPort, ProxyBridge forwards to internalPort
    /// When disabled: clients connect directly to userPort where CLIProxyAPI runs
    var useBridgeMode: Bool {
        get { UserDefaults.standard.bool(forKey: "useBridgeMode") }
        set { UserDefaults.standard.set(newValue, forKey: "useBridgeMode") }
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
    
    /// Internal port where CLIProxyAPI runs (when bridge mode is enabled)
    var internalPort: UInt16 {
        ProxyBridge.internalPort(from: proxyStatus.port)
    }
    
    nonisolated static func terminateProxyOnShutdown() {
        let savedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        let port = (savedPort > 0 && savedPort < 65536) ? UInt16(savedPort) : 8080
        let useBridge = UserDefaults.standard.bool(forKey: "useBridgeMode")
        
        // Kill user-facing port
        killProcessOnPort(port)
        
        // Only kill internal port if bridge mode is enabled
        // to avoid accidentally killing unrelated services
        if useBridge {
            killProcessOnPort(ProxyBridge.internalPort(from: port))
        }
    }
    
    /// IMPORTANT: Excludes own PID to prevent killing Quotio itself when ProxyBridge is running.
    nonisolated private static func killProcessOnPort(_ port: UInt16) {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        // Get own PID to avoid killing ourselves (ProxyBridge runs in our process)
        let ownPid = ProcessInfo.processInfo.processIdentifier

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    // Never kill our own process - ProxyBridge uses NWListener in-process
                    if pid == ownPid {
                        NSLog("[CLIProxyManager] Skipping kill of own PID \(pid) on port \(port) during shutdown")
                        continue
                    }
                    kill(pid, SIGKILL)
                }
            }
        } catch {
        }
    }
    
    private var process: Process?
    private var testProcess: Process?
    private(set) var proxyStatus = ProxyStatus()
    private(set) var isStarting = false
    private(set) var isDownloading = false
    private(set) var isRegeneratingKey = false
    private(set) var downloadProgress: Double = 0
    private(set) var lastError: String?
    
    // MARK: - Managed Upgrade State
    
    /// Current state of the proxy manager.
    private(set) var managerState: ProxyManagerState = .idle
    
    /// Version currently being tested (during dry-run).
    private(set) var testingVersion: String?
    
    /// Port used for dry-run testing.
    private(set) var testPort: UInt16?
    
    /// Path to the test config file (for cleanup).
    private var testConfigPath: String?

    /// Raw management key for the current dry-run proxy.
    private var testManagementKey: String?
    
    /// The active proxy version (if using versioned storage).
    private(set) var activeVersion: String?
    
    /// Last upgrade error message.
    private(set) var upgradeError: String?
    
    /// Whether an upgrade is available.
    private(set) var upgradeAvailable: Bool = false
    
    /// Available upgrade version info.
    private(set) var availableUpgrade: ProxyVersionInfo?
    
    /// Last time a proxy update check was performed.
    var lastProxyUpdateCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastProxyUpdateCheckDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastProxyUpdateCheckDate") }
    }
    
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
    
    /// Storage manager for versioned binaries.
    var storageManager: ProxyStorageManager { ProxyStorageManager.shared }
    
    let binaryPath: String
    let configPath: String
    let authDir: String
    private(set) var managementKey: String
    
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
    
    /// Base URL for the proxy API (always points to CLIProxyAPI directly)
    /// When bridge mode is enabled, this uses the internal port
    var baseURL: String {
        let port = useBridgeMode ? internalPort : proxyStatus.port
        return "http://127.0.0.1:\(port)"
    }
    
    var managementURL: String {
        "\(baseURL)/v0/management"
    }
    
    /// The endpoint URL that clients should use (user-facing port)
    var clientEndpoint: String {
        "http://127.0.0.1:\(proxyStatus.port)"
    }
    
    init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found")
        }
        let quotioDir = appSupport.appendingPathComponent("Quotio")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        
        try? FileManager.default.createDirectory(at: quotioDir, withIntermediateDirectories: true)
        
        self.binaryPath = quotioDir.appendingPathComponent(Self.binaryName).path
        self.configPath = quotioDir.appendingPathComponent("config.yaml").path
        self.authDir = homeDir.appendingPathComponent(".cli-proxy-api").path
        
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

        // Note: Bridge mode default is registered in AppDelegate.applicationDidFinishLaunching()
        // using UserDefaults.register(defaults:) which is the preferred approach

        try? FileManager.default.createDirectory(atPath: authDir, withIntermediateDirectories: true)

        migrateLegacyVersionedStorageIfNeeded()
        initializeSelectedBinarySourceIfNeeded()
        ensureConfigExists()
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
        isSourceInstalled(selectedBinarySource)
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
        return "A legacy CLIProxyAPI install was found. Install cpa-plusplus to continue local mode. Existing auth files will be preserved."
    }

    var cpaPlusPlusDevBinaryPath: String? {
        resolveDevCPAPlusPlusBinaryPath()
    }
    
    func downloadAndInstallBinary() async throws {
        lastError = nil

        do {
            let versionInfo: ProxyVersionInfo
            if let localInfo = cpaPlusPlusDevVersionInfo() {
                versionInfo = localInfo
            } else {
                guard let releaseInfo = try await fetchAvailableUpstreamVersions(limit: 30).first else {
                    throw ProxyError.noCompatibleBinary
                }
                versionInfo = releaseInfo
            }

            try await performManagedUpgrade(to: versionInfo)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    private struct ReleaseInfo: Codable {
        let tagName: String
        let assets: [AssetInfo]
        
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }
    
    private struct AssetInfo: Codable {
        let name: String
        let browserDownloadUrl: String
        
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
        
        var downloadURL: String { browserDownloadUrl }
    }
    
    private struct CompatibleAsset {
        let name: String
        let downloadURL: String
    }
    
    private func fetchLatestRelease(source: ProxyBinarySource) async throws -> ReleaseInfo {
        guard let githubRepo = source.githubRepo else {
            throw ProxyError.networkError("Selected source does not provide online releases")
        }

        let urlString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw ProxyError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch release info")
        }

        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }
    
    private func findCompatibleAsset(in release: ReleaseInfo) -> CompatibleAsset? {
        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst()).lowercased()
            : release.tagName.lowercased()
        #if arch(arm64)
        let targetPatterns = ["darwin_aarch64", "darwin_arm64"]
        #else
        let targetPatterns = ["darwin_amd64"]
        #endif
        let skipPatterns = ["windows", "linux", "checksum", "sha256", "license", "readme"]
        
        for asset in release.assets {
            let lowercaseName = asset.name.lowercased()
            
            let shouldSkip = skipPatterns.contains { lowercaseName.contains($0) }
            if shouldSkip { continue }
            
            if lowercaseName.contains("cpa-plusplus_\(version)_"),
               targetPatterns.contains(where: { lowercaseName.contains($0) }) {
                return CompatibleAsset(name: asset.name, downloadURL: asset.browserDownloadUrl)
            }
        }
        
        return nil
    }
    
    private func downloadAsset(url: String) async throws -> Data {
        guard let downloadURL = URL(string: url) else {
            throw ProxyError.networkError("Invalid download URL")
        }

        var request = URLRequest(url: downloadURL)
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 300) // 5 minutes timeout for large downloads
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to download binary")
        }

        return data
    }
    
    private func extractAndInstall(data: Data, assetName: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let downloadedFile = tempDir.appendingPathComponent(assetName)
        try data.write(to: downloadedFile)
        
        let binaryURL = URL(fileURLWithPath: binaryPath)
        
        if assetName.hasSuffix(".tar.gz") || assetName.hasSuffix(".tgz") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", downloadedFile.path, "-C", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            if let binary = try findBinaryInDirectory(tempDir) {
                if FileManager.default.fileExists(atPath: binaryPath) {
                    try FileManager.default.removeItem(atPath: binaryPath)
                }
                try FileManager.default.copyItem(at: binary, to: binaryURL)
            } else {
                throw ProxyError.extractionFailed
            }
            
        } else if assetName.hasSuffix(".zip") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", downloadedFile.path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            if let binary = try findBinaryInDirectory(tempDir) {
                if FileManager.default.fileExists(atPath: binaryPath) {
                    try FileManager.default.removeItem(atPath: binaryPath)
                }
                try FileManager.default.copyItem(at: binary, to: binaryURL)
            } else {
                throw ProxyError.extractionFailed
            }
            
        } else {
            if FileManager.default.fileExists(atPath: binaryPath) {
                try FileManager.default.removeItem(atPath: binaryPath)
            }
            try FileManager.default.copyItem(at: downloadedFile, to: binaryURL)
        }
        
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        
        // Ad-hoc sign the binary to allow execution on macOS
        let signProcess = Process()
        signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProcess.arguments = ["-f", "-s", "-", binaryPath]
        try? signProcess.run()
        signProcess.waitUntilExit()
    }
    
    private func findBinaryInDirectory(_ directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey])
        
        if let found = contents.first(where: { $0.lastPathComponent == ProxyBinarySource.binaryName }) {
            return found
        }
        
        for item in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    if let found = try findBinaryInDirectory(item) {
                        return found
                    }
                }
            }
        }
        
        return nil
    }
    
    func start(resetCrashRecoveryState: Bool = true) async throws {
        guard isBinaryInstalled else {
            throw ProxyError.binaryNotFound
        }
        
        guard !proxyStatus.running else { return }

        if resetCrashRecoveryState {
            cancelCrashRestart()
            crashRestartAttempts = 0
        }
        
        isStarting = true
        lastError = nil
        
        defer { isStarting = false }
        
        // Clean up any orphan processes from previous runs
        await cleanupOrphanProcesses()
        
        syncSecretKeyInConfig()
        
        // Determine which port CLIProxyAPI should listen on
        let cliProxyPort = useBridgeMode ? internalPort : proxyStatus.port
        
        // Update config to use the correct port
        updateConfigPort(cliProxyPort)
        
        // Use effectiveBinaryPath to support versioned storage
        let activeBinaryPath = effectiveBinaryPath

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
        
        let bridgeEnabled = useBridgeMode
        let userPort = proxyStatus.port
        
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

                // Stop ProxyBridge if CLIProxyAPI exits
                if bridgeEnabled {
                    self.proxyBridge.stop()
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
            
            // If bridge mode is enabled, start ProxyBridge
            if bridgeEnabled {
                proxyBridge.configure(listenPort: userPort, targetPort: cliProxyPort)
                proxyBridge.start()
                
                // Wait a bit for ProxyBridge to start
                try await Task.sleep(nanoseconds: 500_000_000)
                
                guard proxyBridge.isRunning else {
                    // ProxyBridge failed to start, stop CLIProxyAPI
                    markExpectedTermination(process)
                    process.terminate()
                    throw ProxyError.startupFailed
                }
                
                NSLog("[CLIProxyManager] Two-layer proxy started: clients → \(userPort) → \(cliProxyPort)")
            } else {
                NSLog("[CLIProxyManager] Direct proxy started on port \(userPort)")
            }
            
            proxyStatus.running = true
            
            startHealthMonitor()
            
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func stop() {
        stopHealthMonitor()
        cancelCrashRestart()
        
        // Stop ProxyBridge first if running
        if proxyBridge.isRunning {
            proxyBridge.stop()
        }
        
        // Run blocking operations in background to avoid freezing MainActor.
        //
        // Trade-off note: If start() is called immediately after stop(), there is a small
        // window where the detached task could kill the newly started process (since
        // killProcessOnPortSync kills by PORT, not PID). This is an acceptable trade-off
        // because UI responsiveness is more important than this rare edge case.
        // A 150ms buffer is added below to reduce (but not eliminate) this race window.
        let currentProcess = process
        let userPort = proxyStatus.port
        let bridgeMode = useBridgeMode
        let intPort = internalPort
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
            
            // Kill processes on both ports
            Self.killProcessOnPortSync(userPort)
            if bridgeMode {
                Self.killProcessOnPortSync(intPort)
            }
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

        if proxyBridge.isRunning {
            proxyBridge.stop()
        }

        let currentProcess = process
        let userPort = proxyStatus.port
        let bridgeMode = useBridgeMode
        let intPort = internalPort
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
            if bridgeMode {
                Self.killProcessOnPortSync(intPort)
            }
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

        switch managerState {
        case .testing, .promoting, .rollingBack:
            return
        case .idle, .active:
            break
        }

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

            switch self.managerState {
            case .testing, .promoting, .rollingBack:
                return
            case .idle, .active:
                break
            }

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
        // Bail out if proxy is not running or manager is in upgrade flow
        guard proxyStatus.running else {
            healthCheckFailures = 0
            return
        }
        
        // Skip health check during managed upgrades to avoid racing with upgrade flow
        switch managerState {
        case .testing, .promoting, .rollingBack:
            NSLog("[CLIProxyManager] Skipping health check during \(managerState) state")
            return
        case .idle, .active:
            break
        }
        
        let isHealthy = await compatibilityChecker.isHealthy(
            port: useBridgeMode ? internalPort : proxyStatus.port,
            managementKey: managementKey
        )
        
        // Re-check state after await - proxy may have been stopped or upgrade may have started
        guard proxyStatus.running else {
            healthCheckFailures = 0
            return
        }
        
        switch managerState {
        case .testing, .promoting, .rollingBack:
            NSLog("[CLIProxyManager] Aborting health check action - manager entered \(managerState) state")
            return
        case .idle, .active:
            break
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
        let bridgeMode = useBridgeMode
        let intPort = internalPort
        
        // Execute blocking operations on background thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .userInitiated) {
                // Kill any process on the user-facing port
                Self.killProcessOnPortSync(userPort)
                
                // Only kill internal port if bridge mode is enabled
                if bridgeMode {
                    Self.killProcessOnPortSync(intPort)
                    NSLog("[CLIProxyManager] Cleaned up orphan processes on ports \(userPort) and \(intPort)")
                } else {
                    NSLog("[CLIProxyManager] Cleaned up orphan processes on port \(userPort)")
                }
                
                // Small delay to ensure ports are released
                usleep(200_000)  // 200ms, avoid Thread.sleep in async context
                continuation.resume()
            }
        }
    }
    
    /// Synchronous port cleanup for use in detached tasks.
    /// This method is `nonisolated` to allow calling from background threads.
    /// IMPORTANT: Excludes own PID to prevent killing Quotio itself when ProxyBridge is running.
    nonisolated private static func killProcessOnPortSync(_ port: UInt16) {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        // Get own PID to avoid killing ourselves (ProxyBridge runs in our process)
        let ownPid = ProcessInfo.processInfo.processIdentifier

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    // Never kill our own process - ProxyBridge uses NWListener in-process
                    if pid == ownPid {
                        NSLog("[CLIProxyManager] Skipping kill of own PID \(pid) on port \(port)")
                        continue
                    }
                    kill(pid, SIGKILL)
                }
            }
        } catch {
            // Silent failure - process may not exist
        }
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
        let path = effectiveBinaryPath
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }
}

enum ProxyError: LocalizedError {
    case binaryNotFound
    case startupFailed
    case operationInProgress
    case networkError(String)
    case noCompatibleBinary
    case extractionFailed
    case downloadFailed
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            let rawSource = UserDefaults.standard.string(forKey: ProxyBinarySource.userDefaultsKey)
            let source = ProxyBinarySource(rawValue: rawSource ?? "") ?? .cpaPlusPlus
            return source.installHint
        case .startupFailed:
            return "Failed to start proxy server."
        case .operationInProgress:
            return "Another operation is already in progress. Please wait."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .noCompatibleBinary:
            return "No compatible binary found for your system."
        case .extractionFailed:
            return "Failed to extract binary from archive."
        case .downloadFailed:
            return "Failed to download binary."
        }
    }
}

// MARK: - Managed Proxy Upgrade

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
            UserDefaults.standard.set(true, forKey: ProxyBinarySource.explicitSelectionDefaultsKey)
            upgradeAvailable = false
            availableUpgrade = nil
            lastError = nil

            if proxyStatus.running {
                restartProxyIfRunning()
            }
        }
    }

    var availableBinarySources: [ProxyBinarySource] {
        ProxyBinarySource.allCases
    }

    var shouldPromptForBinarySourceSelection: Bool {
        !UserDefaults.standard.bool(forKey: ProxyBinarySource.explicitSelectionDefaultsKey)
    }

    var selectedBinarySourceWarning: String? {
        selectedBinarySource.legacyAuthWarning
    }

    func isLegacyAuthWarningNeeded(for provider: AIProvider) -> Bool {
        false
    }

    func sourceInstallHint(for source: ProxyBinarySource? = nil) -> String {
        (source ?? selectedBinarySource).installHint
    }

    func confirmBinarySourceSelection(_ source: ProxyBinarySource) {
        let previousSource = selectedBinarySource
        UserDefaults.standard.set(true, forKey: ProxyBinarySource.explicitSelectionDefaultsKey)
        if previousSource != source {
            selectedBinarySource = source
        } else {
            UserDefaults.standard.set(source.rawValue, forKey: ProxyBinarySource.userDefaultsKey)
        }
    }

    func isSourceInstalled(_ source: ProxyBinarySource) -> Bool {
        if source == .cpaPlusPlus, resolveDevCPAPlusPlusBinaryPath() != nil {
            return true
        }

        if storageManager.hasInstalledVersion(for: source) {
            return true
        }

        return FileManager.default.fileExists(atPath: binaryPath)
    }
    
    /// The effective binary path - uses versioned storage if available, otherwise legacy path.
    var effectiveBinaryPath: String {
        if selectedBinarySource == .cpaPlusPlus,
           let devPath = resolveDevCPAPlusPlusBinaryPath() {
            return devPath
        }
        if let path = storageManager.currentBinaryPath(for: selectedBinarySource) {
            return path
        }
        return storageManager.expectedBinaryPath(for: selectedBinarySource)
    }
    
    /// Check if versioned storage is being used.
    var isUsingVersionedStorage: Bool {
        storageManager.hasInstalledVersion(for: selectedBinarySource)
    }
    
    /// Get the currently installed version.
    var currentVersion: String? {
        storageManager.getCurrentVersion(for: selectedBinarySource)
    }
    
    /// List all installed versions.
    var installedVersions: [InstalledProxyVersion] {
        storageManager.listInstalledVersions(for: selectedBinarySource)
    }
    
    // MARK: - Upgrade Flow

    /// Check if an upgrade is available.
    /// Uses Atom feed with ETag caching for efficient polling.
    /// Falls back to GitHub API only when needed for download URLs.
    func checkForUpgrade() async {
        // Record when this check was performed
        lastProxyUpdateCheckDate = Date()

        guard selectedBinarySource == .cpaPlusPlus else {
            upgradeAvailable = false
            availableUpgrade = nil
            return
        }
        
        // Use AtomFeedUpdateService for efficient version checking
        let currentVer = currentVersion ?? installedProxyVersion
        let (latestVersion, isNewer) = await AtomFeedUpdateService.shared.checkForCLIProxyUpdate(source: selectedBinarySource, currentVersion: currentVer)

        guard isNewer, let latestTag = latestVersion else {
            upgradeAvailable = false
            availableUpgrade = nil
            return
        }

        // New version available - fetch release details from GitHub API for download URL
        do {
            let release = try await fetchGitHubRelease(tag: latestTag, source: selectedBinarySource)

            guard let asset = findCompatibleAsset(from: release) else {
                upgradeAvailable = false
                availableUpgrade = nil
                return
            }

            let versionInfo = ProxyVersionInfo(from: release, asset: asset, source: selectedBinarySource)
            guard let info = versionInfo else {
                upgradeAvailable = false
                availableUpgrade = nil
                return
            }

            upgradeAvailable = true
            availableUpgrade = info

            // Note: Notification is handled by AtomFeedUpdateService polling
            let version = latestTag.hasPrefix("v") ? String(latestTag.dropFirst()) : latestTag
            NSLog("[CLIProxyManager] Upgrade available: \(version)")
        } catch {
            NSLog("[CLIProxyManager] Failed to fetch release details: \(error.localizedDescription)")
            upgradeAvailable = false
            availableUpgrade = nil
        }
    }
    
    /// Stored version from UserDefaults (for legacy single-binary installs).
    /// Public accessor for the settings screen.
    var installedProxyVersion: String? {
        UserDefaults.standard.string(forKey: selectedBinarySource.installedVersionDefaultsKey)
    }
    
    /// Save installed version to UserDefaults.
    private func saveInstalledVersion(_ version: String, source: ProxyBinarySource) {
        UserDefaults.standard.set(version, forKey: source.installedVersionDefaultsKey)
    }
    
    // MARK: - Fetch All Releases (for Advanced Mode)
    
    func fetchAvailableVersions(limit: Int = 10) async throws -> [ProxyVersionInfo] {
        var versions = try await fetchAvailableUpstreamVersions(limit: limit)
        if let devVersion = cpaPlusPlusDevVersionInfo() {
            versions.insert(devVersion, at: 0)
        }
        return versions
    }

    /// Fetch all available releases from GitHub.
    /// Used by Advanced Mode to allow users to select a specific version.
    private func fetchAvailableUpstreamVersions(limit: Int) async throws -> [ProxyVersionInfo] {
        guard let githubRepo = selectedBinarySource.githubRepo else {
            return []
        }

        let urlString = "https://api.github.com/repos/\(githubRepo)/releases?per_page=\(limit)"
        guard let url = URL(string: urlString) else {
            throw ProxyError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch releases")
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return releases
            .filter { $0.isCPAPlusPlusRelease }
            .compactMap { versionInfo(from: $0) }
            .sorted {
                guard let lhs = CPAPlusPlusVersion($0.version),
                      let rhs = CPAPlusPlusVersion($1.version) else {
                    return $0.version > $1.version
                }
                return lhs > rhs
            }
    }
    
    /// Convert a GitHubRelease to ProxyVersionInfo for a compatible asset.
    func versionInfo(from release: GitHubRelease) -> ProxyVersionInfo? {
        guard release.isCPAPlusPlusRelease else { return nil }
        guard let asset = findCompatibleAsset(from: release) else { return nil }
        return ProxyVersionInfo(from: release, asset: asset, source: selectedBinarySource)
    }
    
    /// Fetch GitHub release info for a specific tag.
    private func fetchGitHubRelease(tag: String, source: ProxyBinarySource) async throws -> GitHubRelease {
        guard let githubRepo = source.githubRepo else {
            throw ProxyError.networkError("Selected source does not provide online releases")
        }

        let urlString = "https://api.github.com/repos/\(githubRepo)/releases/tags/\(tag)"
        guard let url = URL(string: urlString) else {
            throw ProxyError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch release info")
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
    
    /// Find compatible asset from GitHub release.
    private func findCompatibleAsset(from release: GitHubRelease) -> GitHubAsset? {
        #if arch(arm64)
        let targetPatterns = ["darwin_aarch64", "darwin_arm64"]
        #else
        let targetPatterns = ["darwin_amd64"]
        #endif
        let skipPatterns = ["windows", "linux", "checksum", "sha256", "license", "readme"]
        let version = release.versionString.lowercased()
        
        for asset in release.assets {
            let lowercaseName = asset.name.lowercased()
            
            let shouldSkip = skipPatterns.contains { lowercaseName.contains($0) }
            if shouldSkip { continue }
            
            if lowercaseName.contains("cpa-plusplus_\(version)_"),
               targetPatterns.contains(where: { lowercaseName.contains($0) }) {
                return asset
            }
        }
        
        return nil
    }
    
    /// Perform a managed upgrade with dry-run validation.
    /// This is the main entry point for upgrades.
    /// 
    /// Flow:
    /// 1. Download and verify new version
    /// 2. Start dry-run on test port
    /// 3. Validate compatibility via /meta
    /// 4. If valid: promote to active; if not: rollback
    func performManagedUpgrade(to version: ProxyVersionInfo) async throws {
        guard managerState == .active || managerState == .idle else {
            throw ProxyUpgradeError.dryRunFailed("Cannot upgrade while in \(managerState) state")
        }

        guard version.source == selectedBinarySource else {
            throw ProxyUpgradeError.dryRunFailed("Selected source changed while preparing install")
        }
        
        upgradeError = nil
        
        // Step 1: Download and install to versioned storage
        let installed = try await downloadAndInstallVersion(version)
        
        // Step 2: Perform dry-run
        do {
            try await startDryRun(version: installed.version, source: version.source)
        } catch {
            // Dry-run failed, cleanup
            try? storageManager.deleteVersion(installed.version, source: version.source)
            throw error
        }
        
        // Step 3: Validate compatibility
        guard let testPort = testPort, let testManagementKey = testManagementKey else {
            await stopTestProxy()
            try? storageManager.deleteVersion(installed.version, source: version.source)
            throw ProxyUpgradeError.dryRunFailed("Test port not available")
        }
        
        let compatResult = await compatibilityChecker.fullCheck(port: testPort, managementKey: testManagementKey)
        
        if !compatResult.isCompatible {
            // Compatibility failed, rollback
            await stopTestProxy()
            try? storageManager.deleteVersion(installed.version, source: version.source)
            upgradeError = compatResult.description
            NotificationManager.shared.notifyUpgradeFailed(version: installed.version, reason: compatResult.description)
            throw ProxyUpgradeError.compatibilityCheckFailed(compatResult)
        }
        
        // Step 4: Promote the new version
        try await promote(version: installed.version, source: version.source)
        
        // Cleanup old versions
        storageManager.cleanupOldVersions(source: version.source, keepLast: AppConstants.maxInstalledVersions)
        
        // Reset upgrade state - no longer available since we just installed it
        upgradeAvailable = false
        availableUpgrade = nil
        
        // Save the installed version
        saveInstalledVersion(installed.version, source: version.source)
        
        // Suppress any future upgrade notifications for this version
        // This prevents the bug where a notification is shown immediately after upgrading
        NotificationManager.shared.suppressUpgradeNotification(version: installed.version)
        
        NotificationManager.shared.notifyUpgradeSuccess(version: installed.version)
    }
    
    /// Download and install a specific version.
    private func downloadAndInstallVersion(_ versionInfo: ProxyVersionInfo) async throws -> InstalledProxyVersion {
        isDownloading = true
        downloadProgress = 0
        
        defer { isDownloading = false }
        
        // Determine download URL
        let binaryData: Data
        let assetName: String
        if let localFilePath = versionInfo.localFilePath {
            let fileURL = URL(fileURLWithPath: localFilePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ProxyUpgradeError.downloadFailed("Local binary not found at \(localFilePath)")
            }
            binaryData = try Data(contentsOf: fileURL)
            assetName = fileURL.lastPathComponent
        } else {
            let downloadURL: String
            if let url = versionInfo.downloadURL {
                downloadURL = url
            } else {
                // Fall back to GitHub release
                let release = try await fetchLatestRelease(source: versionInfo.source)
                guard let asset = findCompatibleAsset(in: release) else {
                    throw ProxyUpgradeError.downloadFailed("No compatible binary found")
                }
                downloadURL = asset.downloadURL
            }
            
            downloadProgress = 0.1
            binaryData = try await downloadAsset(url: downloadURL)
            assetName = URL(string: downloadURL)?.lastPathComponent ?? ProxyBinarySource.binaryName
        }
        
        downloadProgress = 0.6
        
        // Verify checksum - fail if no valid checksum is provided
        guard !versionInfo.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProxyUpgradeError.downloadFailed("No valid SHA256 checksum provided for downloaded binary")
        }
        try ChecksumVerifier.verifyOrThrow(data: binaryData, expected: versionInfo.sha256)
        downloadProgress = 0.7
        
        // Install to versioned storage
        let installed = try await storageManager.installVersion(
            source: versionInfo.source,
            version: versionInfo.version,
            binaryData: binaryData,
            assetName: assetName
        )
        downloadProgress = 1.0
        
        return installed
    }
    
    /// Start a dry-run of a specific version on a test port.
    private func startDryRun(version: String, source: ProxyBinarySource) async throws {
        guard let binaryPath = storageManager.getBinaryPath(for: version, source: source) else {
            throw ProxyUpgradeError.dryRunFailed("Version \(version) not installed")
        }
        
        managerState = .testing
        testingVersion = version
        
        // Find an unused port for testing
        let port = try findUnusedPort()
        testPort = port
        
        // Create a temporary config for the test
        let managementKey = UUID().uuidString
        let configPath = createTestConfig(port: port, managementKey: managementKey)
        testConfigPath = configPath
        testManagementKey = managementKey
        
        // Track success to determine cleanup behavior
        var succeeded = false
        defer {
            if !succeeded {
                // Cleanup on any failure path (sync version for defer block)
                stopTestProxySync()
                cleanupTestConfig(configPath)
                testConfigPath = nil
                testManagementKey = nil
                managerState = proxyStatus.running ? .active : .idle
                testingVersion = nil
                testPort = nil
            }
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-config", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        
        do {
            try process.run()
        } catch {
            throw ProxyUpgradeError.dryRunFailed(error.localizedDescription)
        }
        
        testProcess = process
        
        // Wait for startup
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Check if process is still running
        guard process.isRunning else {
            throw ProxyUpgradeError.dryRunFailed("Test proxy exited immediately")
        }
        
        // Verify health
        let isHealthy = await compatibilityChecker.isHealthy(port: port, managementKey: managementKey)
        guard isHealthy else {
            throw ProxyUpgradeError.dryRunFailed("Test proxy health check failed")
        }
        
        // Mark success - defer block will not cleanup
        succeeded = true
    }
    
    /// Promote a tested version to active.
    private func promote(version: String, source: ProxyBinarySource) async throws {
        guard managerState == .testing else {
            throw ProxyUpgradeError.dryRunFailed("Not in testing state")
        }
        
        managerState = .promoting
        
        // Stop the test proxy and clean up test config
        await stopTestProxy()
        if let configPath = testConfigPath {
            cleanupTestConfig(configPath)
            testConfigPath = nil
        }
        testManagementKey = nil
        
        // Stop the current active proxy if running
        let wasRunning = proxyStatus.running
        if wasRunning {
            stop()
        }
        
        // Update the current symlink
        try storageManager.setCurrentVersion(version, source: source)
        activeVersion = version
        
        // Restart proxy if it was running
        if wasRunning {
            try await start()
        }
        
        managerState = proxyStatus.running ? .active : .idle
        testingVersion = nil
        testPort = nil
    }
    
    /// Rollback to the previous version.
    func rollback() async throws {
        guard let previousVersion = findPreviousVersion() else {
            throw ProxyUpgradeError.rollbackFailed("No previous version to rollback to")
        }
        
        managerState = .rollingBack
        
        // Stop current proxy
        let wasRunning = proxyStatus.running
        if wasRunning {
            stop()
        }
        
        // Delete the problematic current version if different from previous
        if let current = currentVersion, current != previousVersion {
            try? storageManager.deleteVersion(current, source: selectedBinarySource)
        }
        
        // Set previous as current
        try storageManager.setCurrentVersion(previousVersion, source: selectedBinarySource)
        activeVersion = previousVersion
        
        // Restart if was running
        if wasRunning {
            try await start()
        }
        
        managerState = proxyStatus.running ? .active : .idle
        
        NotificationManager.shared.notifyRollback(toVersion: previousVersion)
    }
    
    // MARK: - Private Helpers
    
    private func stopTestProxy() async {
        guard let process = testProcess, process.isRunning else {
            testProcess = nil
            testManagementKey = nil
            return
        }
        
        let pid = process.processIdentifier
        process.terminate()
        
        // Wait up to 2 seconds for graceful termination
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        if process.isRunning {
            kill(pid, SIGKILL)
        }
        
        testProcess = nil
        testManagementKey = nil
        
        // Also kill anything on test port
        if let port = testPort {
            Self.killProcessOnPortSync(port)
        }
    }
    
    /// Synchronous version for use in defer blocks.
    private func stopTestProxySync() {
        guard let process = testProcess, process.isRunning else {
            testProcess = nil
            testManagementKey = nil
            return
        }
        
        let pid = process.processIdentifier
        process.terminate()
        
        // Wait up to 2 seconds for graceful termination
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        if process.isRunning {
            kill(pid, SIGKILL)
        }
        
        testProcess = nil
        testManagementKey = nil
        
        // Also kill anything on test port
        if let port = testPort {
            Self.killProcessOnPortSync(port)
        }
    }
    
    private func findUnusedPort() throws -> UInt16 {
        // Try ports in range 18000-18100
        for port in UInt16(18000)...UInt16(18100) {
            if !isPortInUse(port) && port != proxyStatus.port {
                return port
            }
        }
        throw ProxyUpgradeError.dryRunFailed("No available port for testing")
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
            throw ProxyUpgradeError.dryRunFailed("Dev cpa-plusplus exited immediately")
        }

        let result = await compatibilityChecker.fullCheck(port: port, managementKey: managementKey)
        guard result.isCompatible else {
            throw ProxyUpgradeError.compatibilityCheckFailed(result)
        }
    }
    
    private func cleanupTestConfig(_ configPath: String) {
        try? FileManager.default.removeItem(atPath: configPath)
    }
    
    private func isNewerVersion(_ newer: String, than older: String) -> Bool {
        guard let newerVersion = CPAPlusPlusVersion(newer),
              let olderVersion = CPAPlusPlusVersion(older) else {
            return false
        }
        return newerVersion > olderVersion
    }
    
    private func cpaPlusPlusDevVersionInfo() -> ProxyVersionInfo? {
        guard let binaryPath = resolveDevCPAPlusPlusBinaryPath() else {
            return nil
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: binaryPath))) ?? Data()
        let checksum = ChecksumVerifier.sha256(of: data)
        let version = "dev-\(String(checksum.prefix(12)))"

        return ProxyVersionInfo(
            source: .cpaPlusPlus,
            version: version,
            sha256: checksum,
            localFilePath: binaryPath,
            releaseNotes: "Local development binary from \(ProxyBinarySource.devBinaryPathEnvironmentKey)."
        )
    }

    private func installDevCPAPlusPlusBinary() async throws -> InstalledProxyVersion {
        guard let versionInfo = cpaPlusPlusDevVersionInfo() else {
            throw ProxyUpgradeError.downloadFailed("Local cpa-plusplus binary is unavailable")
        }
        return try await downloadAndInstallVersion(versionInfo)
    }

    private func findPreviousVersion() -> String? {
        let versions = installedVersions
        let current = currentVersion
        
        // Find the most recent version that isn't current
        return versions
            .filter { $0.version != current }
            .sorted { $0.installedAt > $1.installedAt }
            .first?.version
    }
    
    /// Legacy CLIProxyAPI binaries are intentionally not migrated into cpa-plusplus storage.
    func migrateToVersionedStorage() async throws {
    }

    private func initializeSelectedBinarySourceIfNeeded() {
        if UserDefaults.standard.string(forKey: ProxyBinarySource.userDefaultsKey) != nil {
            return
        }

        let defaultSource = defaultBinarySource()
        UserDefaults.standard.set(defaultSource.rawValue, forKey: ProxyBinarySource.userDefaultsKey)
        UserDefaults.standard.set(false, forKey: ProxyBinarySource.explicitSelectionDefaultsKey)
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
                   values?.isSymbolicLink != true {
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
}
