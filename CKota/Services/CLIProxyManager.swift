//
//  CLIProxyManager.swift
//  CKota - CLIProxyAPI GUI Wrapper
//

import AppKit
import Foundation

@MainActor
@Observable
final class CLIProxyManager {
    static let shared = CLIProxyManager()

    /// Whether we're using an external proxy (e.g., CCS) instead of our own
    private(set) var isUsingExternalProxy = false

    /// CCS cliproxy directories (preferred over CKota's own)
    private static let ccsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ccs/cliproxy")
    private static let ccsBinaryPath = ccsDir.appendingPathComponent("bin/cli-proxy-api-plus").path
    private static let ccsConfigPath = ccsDir.appendingPathComponent("config.yaml").path
    private static let ccsAuthDir = ccsDir.appendingPathComponent("auth").path
    private static let ccsDefaultPort: UInt16 = 8317

    /// Whether using CCS binary/config instead of CKota's own
    var isUsingCCS: Bool {
        binaryPath.contains(".ccs")
    }

    nonisolated static func terminateProxyOnShutdown() {
        // Keep proxy running on app quit - shared with CCS
        // Proxy will continue serving other clients (Claude Code, etc.)
    }

    private nonisolated static func killProcessOnPort(_ port: UInt16) {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGKILL)
                }
            }
        } catch {}
    }

    private var authProcess: Process?
    private(set) var proxyStatus = ProxyStatus()
    private(set) var isStarting = false
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0
    private(set) var lastError: String?

    let binaryPath: String
    let configPath: String
    let authDir: String
    let managementKey: String

    var port: UInt16 {
        get { proxyStatus.port }
        set {
            proxyStatus.port = newValue
            UserDefaults.standard.set(Int(newValue), forKey: "proxyPort")
            updateConfigPort(newValue)
        }
    }

    private static let githubRepo = "router-for-me/CLIProxyAPIPlus"
    private static let binaryName = "CLIProxyAPI"

    var baseURL: String {
        "http://127.0.0.1:\(proxyStatus.port)"
    }

    var managementURL: String {
        "\(baseURL)/v0/management"
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ckotaDir = appSupport.appendingPathComponent("CKota")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        try? FileManager.default.createDirectory(at: ckotaDir, withIntermediateDirectories: true)

        // Initialize managementKey - hardcoded as 'ccs' for shared proxy compatibility
        self.managementKey = "ccs"

        // Prefer CCS binary/config if exists (for shared proxy support)
        if FileManager.default.fileExists(atPath: Self.ccsBinaryPath) {
            self.binaryPath = Self.ccsBinaryPath
            self.configPath = Self.ccsConfigPath
            self.authDir = Self.ccsAuthDir
            // Use CCS default port
            proxyStatus.port = Self.ccsDefaultPort
        } else {
            self.binaryPath = ckotaDir.appendingPathComponent("CLIProxyAPI").path
            self.configPath = ckotaDir.appendingPathComponent("config.yaml").path
            self.authDir = homeDir.appendingPathComponent(".cli-proxy-api").path
            // Use saved port for CKota's own proxy
            let savedPort = UserDefaults.standard.integer(forKey: "proxyPort")
            if savedPort > 0, savedPort < 65536 {
                proxyStatus.port = UInt16(savedPort)
            }
        }

        try? FileManager.default.createDirectory(atPath: authDir, withIntermediateDirectories: true)

        // Only ensure config exists for CKota's own config (not CCS's)
        if !binaryPath.contains(".ccs") {
            ensureConfigExists()
        }
    }

    private func updateConfigPort(_ newPort: UInt16) {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        if let range = content.range(of: #"port:\s*\d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "port: \(newPort)")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }

    func updateConfigLogging(enabled: Bool) {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        if let range = content.range(of: #"logging-to-file:\s*(true|false)"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "logging-to-file: \(enabled)")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }

    private func ensureConfigExists() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let defaultConfig = """
        host: "127.0.0.1"
        port: \(proxyStatus.port)
        auth-dir: "\(authDir)"

        api-keys:
          - "ccs"

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

    var isBinaryInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
    }

    func downloadAndInstallBinary() async throws {
        isDownloading = true
        downloadProgress = 0
        lastError = nil

        defer { isDownloading = false }

        do {
            let releaseInfo = try await fetchLatestRelease()
            guard let asset = findCompatibleAsset(in: releaseInfo) else {
                throw ProxyError.noCompatibleBinary
            }

            downloadProgress = 0.1

            let binaryData = try await downloadAsset(url: asset.downloadURL)
            downloadProgress = 0.7

            try await extractAndInstall(data: binaryData, assetName: asset.name)
            downloadProgress = 1.0

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

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let urlString = "https://api.github.com/repos/router-for-me/CLIProxyAPIPlus/releases/latest"
        guard let url = URL(string: urlString) else {
            throw ProxyError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.addValue("CKota/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch release info")
        }

        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    private func findCompatibleAsset(in release: ReleaseInfo) -> CompatibleAsset? {
        #if arch(arm64)
            let arch = "arm64"
        #else
            let arch = "amd64"
        #endif

        let platform = "darwin"
        let targetPattern = "\(platform)_\(arch)"
        let skipPatterns = ["windows", "linux", "checksum"]

        for asset in release.assets {
            let lowercaseName = asset.name.lowercased()

            let shouldSkip = skipPatterns.contains { lowercaseName.contains($0) }
            if shouldSkip { continue }

            if lowercaseName.contains(targetPattern) {
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
        request.addValue("CKota/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

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
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey]
        )

        let binaryNames = ["CLIProxyAPI", "cli-proxy-api", "cli-proxy-api-plus", "claude-code-proxy", "proxy"]

        for name in binaryNames {
            if let found = contents.first(where: { $0.lastPathComponent.lowercased() == name.lowercased() }) {
                return found
            }
        }

        for item in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    if let found = try findBinaryInDirectory(item) {
                        return found
                    }
                } else {
                    let resourceValues = try item.resourceValues(forKeys: [.isExecutableKey])
                    if resourceValues.isExecutable == true {
                        let name = item.lastPathComponent.lowercased()
                        if !name.hasSuffix(".sh"), !name.hasSuffix(".txt"), !name.hasSuffix(".md") {
                            return item
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Check if a compatible CLIProxyAPI is already running on the configured port
    private func detectExternalProxy() async -> Bool {
        guard let url = URL(string: baseURL) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Verify it's CLIProxyAPI by checking response content
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["message"] as? String,
                   message.contains("CLI Proxy API")
                {
                    return true
                }
            }
        } catch {}

        return false
    }

    /// Public method to check if external proxy is running (for auto-connect on app launch)
    func hasExternalProxyRunning() async -> Bool {
        await detectExternalProxy()
    }

    func start() async throws {
        // First check if external proxy (e.g., CCS) is already running
        if await detectExternalProxy() {
            isUsingExternalProxy = true
            proxyStatus.running = true
            UserDefaults.standard.set(true, forKey: "isUsingExternalProxy")
            return
        }

        guard isBinaryInstalled else {
            throw ProxyError.binaryNotFound
        }

        guard !proxyStatus.running else { return }

        isStarting = true
        lastError = nil
        isUsingExternalProxy = false
        UserDefaults.standard.set(false, forKey: "isUsingExternalProxy")

        defer { isStarting = false }

        syncSecretKeyInConfig()

        // Launch proxy as detached process via nohup so it survives app quit
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "nohup \"\(binaryPath)\" -config \"\(configPath)\" > /dev/null 2>&1 &",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()

        // Detach from terminal
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit() // Shell exits immediately after spawning background process

            // Wait for proxy to start and verify it's running
            try await Task.sleep(nanoseconds: 1_500_000_000)

            if await detectExternalProxy() {
                proxyStatus.running = true
            } else {
                throw ProxyError.startupFailed
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        // Just disconnect - don't kill proxy (it's shared with CCS/other apps)
        terminateAuthProcess()
        isUsingExternalProxy = false
        proxyStatus.running = false
        UserDefaults.standard.set(false, forKey: "isUsingExternalProxy")
    }

    /// Force stop proxy - actually kills the process (use sparingly)
    func forceStop() {
        terminateAuthProcess()
        killProcessOnPort(proxyStatus.port)
        isUsingExternalProxy = false
        proxyStatus.running = false
    }

    private func killProcessOnPort(_ port: UInt16) {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGKILL)
                }
            }
        } catch {}
    }

    func terminateAuthProcess() {
        guard let authProcess, authProcess.isRunning else { return }
        authProcess.terminate()
        self.authProcess = nil
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
        NSWorkspace.shared.selectFile(
            binaryPath,
            inFileViewerRootedAtPath: (binaryPath as NSString).deletingLastPathComponent
        )
    }
}

enum ProxyError: LocalizedError {
    case binaryNotFound
    case startupFailed
    case networkError(String)
    case noCompatibleBinary
    case extractionFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "CLIProxyAPI binary not found. Click 'Install' to download."
        case .startupFailed:
            "Failed to start proxy server."
        case let .networkError(msg):
            "Network error: \(msg)"
        case .noCompatibleBinary:
            "No compatible binary found for your system."
        case .extractionFailed:
            "Failed to extract binary from archive."
        case .downloadFailed:
            "Failed to download binary."
        }
    }
}
