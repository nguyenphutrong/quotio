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
    let login: String?          // GitHub username (for Copilot)
    let expired: Date?          // Token expiry date
    let accountType: String?    // pro, free, etc.
    let filePath: String
    let source: AuthFileSource
    let filename: String
    
    /// Source location of the auth file
    enum AuthFileSource: String, Sendable {
        case cliProxyApi = "~/.cli-proxy-api"
        
        var displayName: String {
            switch self {
            case .cliProxyApi: return "CLI Proxy API"
            }
        }
    }
    
    /// Check if token is expired
    var isExpired: Bool {
        guard let expired = expired else { return false }
        return expired < Date()
    }
    
    /// Display name for UI (email > login > filename)
    var displayName: String {
        if let email = email, !email.isEmpty {
            return email
        }
        if let login = login, !login.isEmpty {
            return login
        }
        return filename
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
        // Only scan ~/.cli-proxy-api (CLIProxyAPI managed)
        await scanCLIProxyAPIDirectory()
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
            
            // Try to parse JSON content first
            if let authFile = parseAuthFileJSON(at: filePath, filename: file) {
                authFiles.append(authFile)
                continue
            } else {
                // Parse failed
            }
            
            // Fallback: parse from filename if JSON parsing fails
            guard let (provider, email) = parseAuthFileName(file) else {
                continue
            }
            
            authFiles.append(DirectAuthFile(
                id: filePath,
                provider: provider,
                email: email,
                login: nil,
                expired: nil,
                accountType: nil,
                filePath: filePath,
                source: .cliProxyApi,
                filename: file
            ))
        }
        
        return authFiles
    }
    
    // MARK: - JSON Parsing
    
    /// Parse auth file JSON content to extract provider, email, and metadata
    private func parseAuthFileJSON(at filePath: String, filename: String) -> DirectAuthFile? {
        guard let data = fileManager.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Get provider from "type" field
        guard let typeString = json["type"] as? String,
              let provider = mapTypeToProvider(typeString) else {
            return nil
        }
        
        // Extract metadata
        var email = json["email"] as? String
        let login = json["login"] as? String
        let accountType = json["account_type"] as? String
        
        // For Kiro: if email is empty, try to use provider (e.g., "Google") as identifier
        if provider == .kiro && (email == nil || email?.isEmpty == true) {
            if let authProvider = json["provider"] as? String {
                email = "Kiro (\(authProvider))"
            }
        }
        
        // Parse expired date
        var expiredDate: Date?
        if let expiredString = json["expired"] as? String {
            expiredDate = parseISO8601Date(expiredString)
        } else if let expiredInt = json["expired"] as? Double { // Handle numeric timestamp
            expiredDate = Date(timeIntervalSince1970: expiredInt)
        }
        
        return DirectAuthFile(
            id: filePath,
            provider: provider,
            email: email,
            login: login,
            expired: expiredDate,
            accountType: accountType,
            filePath: filePath,
            source: .cliProxyApi,
            filename: filename
        )
    }
    
    /// Map JSON "type" field to AIProvider
    private func mapTypeToProvider(_ type: String) -> AIProvider? {
        let typeMap: [String: AIProvider] = [
            "antigravity": .antigravity,
            "claude": .claude,
            "codex": .codex,
            "copilot": .copilot,
            "github-copilot": .copilot,
            "gemini": .gemini,
            "gemini-cli": .gemini,
            "qwen": .qwen,
            "iflow": .iflow,
            "kiro": .kiro,
            "vertex": .vertex,
            "cursor": .cursor,
            "trae": .trae
        ]
        return typeMap[type.lowercased()]
    }
    
    /// Parse ISO8601 date string with multiple format support
    private func parseISO8601Date(_ dateString: String) -> Date? {
        // Try with fractional seconds
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: dateString) {
            return date
        }
        
        // Try without fractional seconds
        let formatterStandard = ISO8601DateFormatter()
        formatterStandard.formatOptions = [.withInternetDateTime]
        return formatterStandard.date(from: dateString)
    }
    
    // MARK: - Filename Parsing (Fallback)
    
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
                return AuthTokenData(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, clientId: nil, clientSecret: nil, extras: nil)
            }
            
        case .codex:
            // OpenAI format - uses bearer token or API key
            if let token = json["access_token"] as? String ?? json["api_key"] as? String {
                return AuthTokenData(accessToken: token, refreshToken: nil, expiresAt: nil, clientId: nil, clientSecret: nil, extras: nil)
            }
            
        case .copilot:
            // GitHub OAuth format
            if let accessToken = json["access_token"] as? String ?? json["oauth_token"] as? String {
                return AuthTokenData(accessToken: accessToken, refreshToken: nil, expiresAt: nil, clientId: nil, clientSecret: nil, extras: nil)
            }
            
        case .claude:
            // Anthropic OAuth
            if let sessionKey = json["session_key"] as? String ?? json["access_token"] as? String {
                return AuthTokenData(accessToken: sessionKey, refreshToken: nil, expiresAt: nil, clientId: nil, clientSecret: nil, extras: nil)
            }
            
        case .kiro:
            // Kiro (AWS CodeWhisperer) format
            if let accessToken = json["access_token"] as? String {

                let refreshToken = json["refresh_token"] as? String
                
                // Robust parsing for expires_at (could be string or int/double)
                var expiresAt: String?
                if let expStr = json["expires_at"] as? String ?? json["expiry"] as? String {
                    expiresAt = expStr
                } else if let expNum = json["expires_at"] as? Double ?? json["expiry"] as? Double {
                    // Convert numeric timestamp to ISO string for consistency in AuthTokenData
                    expiresAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: expNum))
                }
                
                let clientId = json["client_id"] as? String
                let clientSecret = json["client_secret"] as? String
                
                var extras: [String: String] = [:]
                if let startUrl = json["start_url"] as? String ?? json["startUrl"] as? String {
                    extras["start_url"] = startUrl
                }
                if let region = json["region"] as? String {
                    extras["region"] = region
                }
                
                return AuthTokenData(
                    accessToken: accessToken, 
                    refreshToken: refreshToken, 
                    expiresAt: expiresAt,
                    clientId: clientId,
                    clientSecret: clientSecret,
                    extras: extras
                )
            }
            
        default:
            // Generic token extraction
            if let token = json["access_token"] as? String ?? json["token"] as? String {
                return AuthTokenData(accessToken: token, refreshToken: nil, expiresAt: nil, clientId: nil, clientSecret: nil, extras: nil)
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
    let clientId: String?
    let clientSecret: String?
    let extras: [String: String]?
    
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
