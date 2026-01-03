//
//  GeminiCLIQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches account info from Gemini CLI by reading ~/.gemini/oauth_creds.json
//  Note: Gemini CLI doesn't have a public quota API yet, so this only provides account info
//  Used in Quota-Only mode for account detection
//

import Foundation

/// Auth file structure for Gemini CLI (~/.gemini/oauth_creds.json)
nonisolated struct GeminiCLIAuthFile: Codable, Sendable {
    let idToken: String?
    let accessToken: String?
    let scope: String?
    let refreshToken: String?
    let tokenType: String?
    let expiryDate: Double?
    
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case scope
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiryDate = "expiry_date"
    }
}

/// Google accounts file structure (~/.gemini/google_accounts.json)
nonisolated struct GeminiAccountsFile: Codable, Sendable {
    let active: String?
    let old: [String]?
}

/// Decoded JWT claims from Gemini id_token
nonisolated struct GeminiJWTClaims: Sendable {
    let email: String?
    let emailVerified: Bool
    let name: String?
    let givenName: String?
    let familyName: String?
    let subject: String?
}

/// Account info from Gemini CLI
nonisolated struct GeminiCLIAccountInfo: Sendable {
    let email: String
    let name: String?
    let isActive: Bool
    let expiryDate: Date?
}

/// Fetches account info from Gemini CLI auth file
actor GeminiCLIQuotaFetcher {
    private let authFilePath = "~/.gemini/oauth_creds.json"
    private let accountsFilePath = "~/.gemini/google_accounts.json"
    private let executor = CLIExecutor.shared
    
    /// Check if Gemini CLI is installed
    func isInstalled() async -> Bool {
        return await executor.isCLIInstalled(name: "gemini")
    }
    
    /// Check if Gemini auth file exists
    func isAuthFilePresent() -> Bool {
        let expandedPath = NSString(string: authFilePath).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expandedPath)
    }
    
    /// Read OAuth credentials from ~/.gemini/oauth_creds.json
    func readAuthFile() -> GeminiCLIAuthFile? {
        let expandedPath = NSString(string: authFilePath).expandingTildeInPath
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        
        return try? JSONDecoder().decode(GeminiCLIAuthFile.self, from: data)
    }
    
    /// Read accounts file from ~/.gemini/google_accounts.json
    func readAccountsFile() -> GeminiAccountsFile? {
        let expandedPath = NSString(string: accountsFilePath).expandingTildeInPath
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        
        return try? JSONDecoder().decode(GeminiAccountsFile.self, from: data)
    }
    
    /// Decode JWT to extract email and name info
    func decodeJWT(token: String) -> GeminiJWTClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        
        var base64 = String(segments[1])
        // Add padding if needed
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        
        // Replace URL-safe characters
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        
        return GeminiJWTClaims(
            email: json["email"] as? String,
            emailVerified: json["email_verified"] as? Bool ?? false,
            name: json["name"] as? String,
            givenName: json["given_name"] as? String,
            familyName: json["family_name"] as? String,
            subject: json["sub"] as? String
        )
    }
    
    /// Get account info from auth files
    func getAccountInfo() -> GeminiCLIAccountInfo? {
        guard let authFile = readAuthFile() else { return nil }
        
        // Try to get email from accounts file first
        var email: String? = readAccountsFile()?.active
        var name: String? = nil
        
        // Fall back to JWT if accounts file doesn't have email
        if email == nil, let idToken = authFile.idToken, let claims = decodeJWT(token: idToken) {
            email = claims.email
            name = claims.name
        }
        
        guard let accountEmail = email else { return nil }
        
        var expiryDate: Date? = nil
        if let expiry = authFile.expiryDate {
            expiryDate = Date(timeIntervalSince1970: expiry / 1000) // Convert from milliseconds
        }
        
        return GeminiCLIAccountInfo(
            email: accountEmail,
            name: name,
            isActive: true,
            expiryDate: expiryDate
        )
    }
    
    /// Fetch quota as ProviderQuotaData
    /// Note: Gemini CLI doesn't have a public quota API, so we return placeholder data
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        guard await isInstalled() else { return [:] }
        guard let accountInfo = getAccountInfo() else { return [:] }
        
        // Since Gemini CLI doesn't have a public quota API, we create a placeholder
        // that shows the account is connected but quota is unknown
        let models: [ModelQuota] = [
            ModelQuota(
                name: "gemini-quota",
                percentage: -1, // -1 indicates unknown/unavailable
                resetTime: ""
            )
        ]
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: "Google Account" // We don't know the actual plan type
        )
        
        return [accountInfo.email: quotaData]
    }
}
