//
//  DirectAuthFileService.swift
//  CKota - CLIProxyAPI GUI Wrapper
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
        case ccsClipProxy = "~/.ccs/cliproxy/auth"
        case cliProxyApi = "~/.cli-proxy-api"
        case claudeCode = "~/.claude"

        var displayName: String {
            switch self {
            case .ccsClipProxy: "CLI Proxy API"
            case .cliProxyApi: "CLI Proxy API"
            case .claudeCode: "Claude Code"
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

        // 1. Scan ~/.ccs/cliproxy/auth (CCS managed - preferred)
        let ccsFiles = await scanAuthDirectory("~/.ccs/cliproxy/auth", source: .ccsClipProxy)
        allFiles.append(contentsOf: ccsFiles)

        // 2. Scan ~/.cli-proxy-api (legacy CLIProxyAPI path)
        let cliProxyFiles = await scanAuthDirectory("~/.cli-proxy-api", source: .cliProxyApi)
        // Only add if not already found (avoid duplicates)
        for file in cliProxyFiles {
            if !allFiles.contains(where: { $0.provider == file.provider && $0.email == file.email }) {
                allFiles.append(file)
            }
        }

        // 3. Scan native CLI auth locations (optional)
        if let claudeAuth = await scanClaudeCodeAuth() {
            // Only add if not already in CLI proxy files
            if !allFiles.contains(where: { $0.provider == .claude && $0.email == claudeAuth.email }) {
                allFiles.append(claudeAuth)
            }
        }

        return allFiles
    }

    // MARK: - Auth Directory Scanning

    /// Scan a directory for managed auth files
    private func scanAuthDirectory(_ directoryPath: String,
                                   source: DirectAuthFile.AuthFileSource) async -> [DirectAuthFile]
    {
        let path = expandPath(directoryPath)
        guard let files = try? fileManager.contentsOfDirectory(atPath: path) else {
            print("[DEBUG] DirectAuthFileService: No files found in \(directoryPath)")
            return []
        }

        var authFiles: [DirectAuthFile] = []
        let jsonFiles = files.filter { $0.hasSuffix(".json") }
        print("[DEBUG] DirectAuthFileService: Found \(jsonFiles.count) JSON files in \(directoryPath)")

        for file in jsonFiles {
            let filePath = (path as NSString).appendingPathComponent(file)

            guard let (provider, email) = parseAuthFileName(file) else {
                continue
            }

            print(
                "[DEBUG] DirectAuthFileService: Parsed '\(file)' -> provider: \(provider.rawValue), email: '\(email ?? "nil")'"
            )

            authFiles.append(DirectAuthFile(
                id: filePath,
                provider: provider,
                email: email,
                filePath: filePath,
                source: source,
                filename: file
            ))
        }

        return authFiles
    }

    /// Parse auth file name to extract provider and email
    private func parseAuthFileName(_ filename: String) -> (AIProvider, String?)? {
        let prefixes: [(String, AIProvider)] = [
            ("antigravity-", .antigravity),
            ("claude-", .claude),
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
                let userPart = String(name.dropLast(underscoreDomain.count + 1))
                // Convert underscores to dots in username (e.g., congsynh_vo -> congsynh.vo)
                let userEmail = userPart.replacingOccurrences(of: "_", with: ".")
                return "\(userEmail)@\(domain)"
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

    /// Scan Claude Code native auth (~/.claude/)
    private func scanClaudeCodeAuth() async -> DirectAuthFile? {
        // Claude Code stores credentials in ~/.claude/.credentials.json
        let credPath = expandPath("~/.claude/.credentials.json")
        guard fileManager.fileExists(atPath: credPath) else { return nil }

        var email: String? = nil

        if let data = fileManager.contents(atPath: credPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
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

    // MARK: - Auth File Reading

    /// Read auth token from file for quota fetching
    func readAuthToken(from file: DirectAuthFile) async -> AuthTokenData? {
        guard let data = fileManager.contents(atPath: file.filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        // Different providers store tokens differently
        switch file.provider {
        case .antigravity:
            // Google OAuth format
            if let accessToken = json["access_token"] as? String {
                let refreshToken = json["refresh_token"] as? String
                let expiresAt = json["expiry"] as? String ?? json["expires_at"] as? String
                return AuthTokenData(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
            }

        case .claude:
            // Anthropic OAuth
            if let sessionKey = json["session_key"] as? String ?? json["access_token"] as? String {
                return AuthTokenData(accessToken: sessionKey, refreshToken: nil, expiresAt: nil)
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
        guard let expiresAt else { return false }

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
