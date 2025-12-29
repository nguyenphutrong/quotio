//
//  DirectAuthFileService.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Service for directly scanning auth files from filesystem
//  Used in Quota-Only mode to read auth without running proxy
//

import Foundation

// MARK: - Direct Auth File

/// Represents an auth file discovered directly from filesystem
struct DirectAuthFile: Identifiable, Sendable, Hashable {
    let id: String
    let provider: AIProvider
    let email: String?
    let filePath: String
    let source: AuthFileSource
    let filename: String
    
    /// Source location of the auth file
    enum AuthFileSource: String, Sendable {
        case cliProxyApi = "~/.cli-proxy-api"
        case claudeCode = "~/.claude"
        case codexCLI = "~/.codex"
        case geminiCLI = "~/.gemini"
        
        var displayName: String {
            switch self {
            case .cliProxyApi: return "CLI Proxy API"
            case .claudeCode: return "Claude Code"
            case .codexCLI: return "Codex CLI"
            case .geminiCLI: return "Gemini CLI"
            }
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: DirectAuthFile, rhs: DirectAuthFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Direct Auth File Service

/// Service for scanning auth files directly from filesystem
/// Used in Quota-Only mode where proxy server is not running
actor DirectAuthFileService {
    private let fileManager = FileManager.default
    
    /// Expand tilde in path
    private func expandPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
    
    /// Scan all known auth file locations
    func scanAllAuthFiles() async -> [DirectAuthFile] {
        var allFiles: [DirectAuthFile] = []
        
        // 1. Scan ~/.cli-proxy-api (CLIProxyAPI managed)
        let cliProxyFiles = await scanCLIProxyAPIDirectory()
        allFiles.append(contentsOf: cliProxyFiles)
        
        // 2. Scan native CLI auth locations (optional - these may also be in ~/.cli-proxy-api)
        if let claudeAuth = await scanClaudeCodeAuth() {
            // Only add if not already in CLI proxy files
            if !allFiles.contains(where: { $0.provider == .claude && $0.email == claudeAuth.email }) {
                allFiles.append(claudeAuth)
            }
        }
        
        if let codexAuth = await scanCodexAuth() {
            if !allFiles.contains(where: { $0.provider == .codex && $0.email == codexAuth.email }) {
                allFiles.append(codexAuth)
            }
        }
        
        if let geminiAuth = await scanGeminiAuth() {
            if !allFiles.contains(where: { $0.provider == .gemini && $0.email == geminiAuth.email }) {
                allFiles.append(geminiAuth)
            }
        }
        
        return allFiles
    }
    
    // MARK: - CLI Proxy API Directory
    
    /// Scan ~/.cli-proxy-api for managed auth files
    private func scanCLIProxyAPIDirectory() async -> [DirectAuthFile] {
        let path = expandPath("~/.cli-proxy-api")
        guard let files = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }
        
        var authFiles: [DirectAuthFile] = []
        
        for file in files where file.hasSuffix(".json") {
            let filePath = (path as NSString).appendingPathComponent(file)
            
            guard let (provider, email) = parseAuthFileName(file) else {
                continue
            }
            
            authFiles.append(DirectAuthFile(
                id: filePath,
                provider: provider,
                email: email,
                filePath: filePath,
                source: .cliProxyApi,
                filename: file
            ))
        }
        
        return authFiles
    }
    
    /// Parse auth file name to extract provider and email
    private func parseAuthFileName(_ filename: String) -> (AIProvider, String?)? {
        let prefixes: [(String, AIProvider)] = [
            ("antigravity-", .antigravity),
            ("codex-", .codex),
            ("github-copilot-", .copilot),
            ("claude-", .claude),
            ("gemini-cli-", .gemini),
            ("qwen-", .qwen),
            ("iflow-", .iflow),
            ("kiro-", .kiro),
            ("vertex-", .vertex)
        ]
        
        for (prefix, provider) in prefixes {
            if filename.hasPrefix(prefix) {
                let email = extractEmail(from: filename, prefix: prefix)
                return (provider, email)
            }
        }
        
        return nil
    }
    
    /// Extract email from filename pattern: prefix-email.json
    private func extractEmail(from filename: String, prefix: String) -> String {
        var name = filename
        name = name.replacingOccurrences(of: prefix, with: "")
        name = name.replacingOccurrences(of: ".json", with: "")
        
        // Handle underscore -> dot conversion for email
        // e.g., user_example_com -> user.example.com
        // But we need to be smart about @ sign
        
        // Check for common email domain patterns
        let emailDomains = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", 
                           "yahoo.com", "icloud.com", "protonmail.com", "proton.me"]
        
        for domain in emailDomains {
            let underscoreDomain = domain.replacingOccurrences(of: ".", with: "_")
            if name.hasSuffix("_\(underscoreDomain)") {
                let prefix = name.dropLast(underscoreDomain.count + 1)
                return "\(prefix)@\(domain)"
            }
        }
        
        // Fallback: try to detect @ pattern
        // Common pattern: user_domain_com -> user@domain.com
        let parts = name.components(separatedBy: "_")
        if parts.count >= 3 {
            // Assume last two parts are domain (e.g., domain_com)
            let user = parts.dropLast(2).joined(separator: ".")
            let domain = parts.suffix(2).joined(separator: ".")
            return "\(user)@\(domain)"
        } else if parts.count == 2 {
            // Could be user_domain or user_com
            return parts.joined(separator: "@")
        }
        
        return name
    }
    
    // MARK: - Native CLI Auth Locations

    /// Scan Claude Code native auth from macOS Keychain
    /// Claude Code 2.0+ stores credentials in Keychain instead of ~/.claude/.credentials.json
    private func scanClaudeCodeAuth() async -> DirectAuthFile? {
        // Try multiple credential names (Claude Code may use different names)
        let credentialNames = [
            "Claude Code-credentials",
            "claude-credentials",
            "Claude-credentials",
            "claudecode-credentials"
        ]

        for credName in credentialNames {
            if let authFile = getClaudeAuthFromKeychain(serviceName: credName) {
                return authFile
            }
        }

        // Fallback: check legacy file location for older versions
        let credPath = expandPath("~/.claude/.credentials.json")
        if fileManager.fileExists(atPath: credPath) {
            var email: String? = nil
            if let data = fileManager.contents(atPath: credPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                email = json["email"] as? String ?? json["account_email"] as? String
            }
            return DirectAuthFile(
                id: "claude-code-native",
                provider: .claude,
                email: email,
                filePath: credPath,
                source: .claudeCode,
                filename: ".credentials.json"
            )
        }

        return nil
    }

    /// Get Claude Code auth from macOS Keychain
    private func getClaudeAuthFromKeychain(serviceName: String) -> DirectAuthFile? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty,
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }

            // Extract email from the credential JSON
            var email: String? = nil
            if let claudeAiOauth = json["claudeAiOauth"] as? [String: Any] {
                email = claudeAiOauth["email"] as? String
            }

            return DirectAuthFile(
                id: "claude-code-keychain",
                provider: .claude,
                email: email ?? "Claude Code User",
                filePath: "keychain://\(serviceName)",
                source: .claudeCode,
                filename: serviceName
            )
        } catch {
            return nil
        }
    }

    /// Scan Codex CLI native auth (~/.codex/)
    private func scanCodexAuth() async -> DirectAuthFile? {
        let authPath = expandPath("~/.codex/auth.json")
        guard fileManager.fileExists(atPath: authPath) else { return nil }
        
        var email: String? = nil
        
        if let data = fileManager.contents(atPath: authPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            email = json["email"] as? String ?? json["account_id"] as? String ?? json["user"] as? String
        }
        
        return DirectAuthFile(
            id: "codex-native",
            provider: .codex,
            email: email,
            filePath: authPath,
            source: .codexCLI,
            filename: "auth.json"
        )
    }
    
    /// Scan Gemini CLI native auth (~/.gemini/)
    private func scanGeminiAuth() async -> DirectAuthFile? {
        let settingsPath = expandPath("~/.gemini/settings.json")
        guard fileManager.fileExists(atPath: settingsPath) else { return nil }
        
        // Gemini CLI uses Google OAuth, email might be in different locations
        // Also check for ~/.config/gemini-cli/ or ~/.gemini/credentials.json
        var email: String? = nil
        
        // Try credentials file
        let credPaths = [
            expandPath("~/.gemini/credentials.json"),
            expandPath("~/.config/gemini-cli/credentials.json")
        ]
        
        for credPath in credPaths {
            if let data = fileManager.contents(atPath: credPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                email = json["email"] as? String ?? json["account"] as? String
                if email != nil { break }
            }
        }
        
        return DirectAuthFile(
            id: "gemini-native",
            provider: .gemini,
            email: email,
            filePath: settingsPath,
            source: .geminiCLI,
            filename: "settings.json"
        )
    }
    
    // MARK: - Auth File Reading
    
    /// Read auth token from file for quota fetching
    func readAuthToken(from file: DirectAuthFile) async -> AuthTokenData? {
        guard let data = fileManager.contents(atPath: file.filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Different providers store tokens differently
        switch file.provider {
        case .antigravity, .gemini:
            // Google OAuth format
            if let accessToken = json["access_token"] as? String {
                let refreshToken = json["refresh_token"] as? String
                let expiresAt = json["expiry"] as? String ?? json["expires_at"] as? String
                return AuthTokenData(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
            }
            
        case .codex:
            // OpenAI format - uses bearer token or API key
            if let token = json["access_token"] as? String ?? json["api_key"] as? String {
                return AuthTokenData(accessToken: token, refreshToken: nil, expiresAt: nil)
            }
            
        case .copilot:
            // GitHub OAuth format
            if let accessToken = json["access_token"] as? String ?? json["oauth_token"] as? String {
                return AuthTokenData(accessToken: accessToken, refreshToken: nil, expiresAt: nil)
            }
            
        case .claude:
            // Anthropic OAuth
            if let sessionKey = json["session_key"] as? String ?? json["access_token"] as? String {
                return AuthTokenData(accessToken: sessionKey, refreshToken: nil, expiresAt: nil)
            }
            
        default:
            // Generic token extraction
            if let token = json["access_token"] as? String ?? json["token"] as? String {
                return AuthTokenData(accessToken: token, refreshToken: nil, expiresAt: nil)
            }
        }
        
        return nil
    }
}

// MARK: - Auth Token Data

/// Token data extracted from auth file
struct AuthTokenData: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: String?
    
    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        
        // Try parsing ISO 8601 date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: expiresAt) {
            return date < Date()
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: expiresAt) {
            return date < Date()
        }
        
        return false
    }
}
