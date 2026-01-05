//
//  KiroQuotaFetcher.swift
//  Quotio
//
//  Kiro (AWS CodeWhisperer) Quota Fetcher
//  Implements logic from kiro2api for quota monitoring
//

import Foundation

// MARK: - Kiro Response Models

nonisolated struct KiroUsageResponse: Codable {
    let usageLimits: [KiroUsageLimit]?
    
    struct KiroUsageLimit: Codable {
        let name: String
        let description: String?
        let period: String?
        let limit: Int?
        let usage: Int?
        let resourceType: String?
    }
}

nonisolated struct KiroTokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String
    let refreshToken: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
    }
}

// MARK: - Kiro Quota Fetcher

actor KiroQuotaFetcher {
    private let usageEndpoint = "https://codewhisperer.us-east-1.amazonaws.com/getUsageLimits"
    private let tokenEndpoint = "https://oidc.us-east-1.amazonaws.com/token"
    
    private let session: URLSession
    private let fileManager = FileManager.default
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }
    
    /// Scan and fetch quotas for all Kiro auth files
    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        let authService = DirectAuthFileService()
        let allFiles = await authService.scanAllAuthFiles()
        let kiroFiles = allFiles.filter { $0.provider == .kiro }
        
        // Parallel fetching
        return await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for authFile in kiroFiles {
                group.addTask {
                    guard let tokenData = await authService.readAuthToken(from: authFile) else {
                        return ("", nil)
                    }
                    
                    // Use filename as key to match Proxy's behavior (ignoring email inside JSON for key purposes)
                    // This prevents duplicate accounts in the UI
                    let key = authFile.filename.replacingOccurrences(of: ".json", with: "")
                    
                    let quota = await self.fetchQuota(tokenData: tokenData)
                    return (key, quota)
                }
            }
            
            var results: [String: ProviderQuotaData] = [:]
            for await (key, quota) in group {
                if let quota = quota, !key.isEmpty {
                    results[key] = quota
                }
            }
            return results
        }
    }
    
    /// Check if token is expired (local implementation to avoid actor isolation issues)
    private func isTokenExpired(_ tokenData: AuthTokenData) -> Bool {
        guard let expiresAt = tokenData.expiresAt else { return false }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) {
            return date < Date()
        }
        
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: expiresAt) {
            return date < Date()
        }
        
        return false
    }
    
    /// Fetch quota for a single token
    private func fetchQuota(tokenData: AuthTokenData) async -> ProviderQuotaData? {
        var currentToken = tokenData.accessToken
        
        // 1. Check if token needs refresh
        if isTokenExpired(tokenData) {
            if let refreshed = await refreshToken(tokenData: tokenData) {
                currentToken = refreshed
            } else {
                 return ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Token Refresh Failed")],
                    lastUpdated: Date(),
                    isForbidden: true,
                    planType: "Expired"
                )
            }
        }
        
        // 2. Fetch Usage
        guard let url = URL(string: "\(usageEndpoint)?isEmailRequired=true&origin=AI_EDITOR&resourceType=AGENTIC_REQUEST") else { 
            return ProviderQuotaData(models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Invalid URL")], lastUpdated: Date(), isForbidden: false, planType: "Error")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        // Headers mimicking Kiro IDE
        request.addValue("aws-sdk-js/3.0.0 KiroIDE-0.1.0 os/macos lang/js md/nodejs/18.0.0", forHTTPHeaderField: "User-Agent")
        request.addValue("aws-sdk-js/3.0.0", forHTTPHeaderField: "x-amz-user-agent")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else { 
                 return ProviderQuotaData(models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Invalid Response Type")], lastUpdated: Date(), isForbidden: false, planType: "Error")
            }
            
            if httpResponse.statusCode != 200 {
                // If 401/403 despite valid check, access denied
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    return ProviderQuotaData(models: [], lastUpdated: Date(), isForbidden: true, planType: "Unauthorized")
                }
                
                // Return generic error with status code
                let errorMsg = "HTTP \(httpResponse.statusCode)"
                return ProviderQuotaData(models: [ModelQuota(name: "Error", percentage: 0, resetTime: errorMsg)], lastUpdated: Date(), isForbidden: false, planType: "Error")
            }
            
            let usageResponse = try JSONDecoder().decode(KiroUsageResponse.self, from: data)
            
            // Determine Plan Type: Check for Managed/Enterprise via start_url
            // "awsapps.com" or "amazon.com" in start_url usually implies IAM Identity Center (Managed)
            var planType = "Standard"
            if let startUrl = tokenData.extras?["start_url"], 
               (startUrl.contains("awsapps.com") || startUrl.contains("amazon.com")) {
                planType = "Enterprise"
            }
            
            return convertToQuotaData(usageResponse, planType: planType)
            
        } catch {
            // Return error as a quota item for visibility
            return ProviderQuotaData(
                models: [ModelQuota(name: "Error", percentage: 0, resetTime: error.localizedDescription)],
                lastUpdated: Date(),
                isForbidden: false,
                planType: "Error"
            )
        }
    }
    
    /// Refresh Kiro token using AWS OIDC
    private func refreshToken(tokenData: AuthTokenData) async -> String? {
        guard let refreshToken = tokenData.refreshToken,
              let clientId = tokenData.clientId,
              let clientSecret = tokenData.clientSecret,
              let url = URL(string: tokenEndpoint) else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Basic Auth with Client ID & Secret
        let authString = "\(clientId):\(clientSecret)"
        guard let authData = authString.data(using: .utf8) else { return nil }
        let base64Auth = authData.base64EncodedString()
        request.addValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
        
        let bodyComponents = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        
        let bodyString = bodyComponents.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            
            let tokenResponse = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
            // Note: In a full implementation we would write this back to disk. 
            // For now, we use it in-memory for this session.
            return tokenResponse.accessToken
        } catch {
            return nil
        }
    }
    
    /// Convert Kiro response to standard Quota Data
    private func convertToQuotaData(_ response: KiroUsageResponse, planType: String) -> ProviderQuotaData {
        var models: [ModelQuota] = []
        
        if let limits = response.usageLimits {
            for limit in limits {
                 // Create quota items for each limit
                 // Example: "Completions", "Chat", etc.
                let name = limit.name
                let total = limit.limit ?? 0
                let used = limit.usage ?? 0
                
                // Calculate percentage remaining
                // If limit is -1 or 0 (and usage is low), it might mean unlimited or unknown
                // Assuming standard quota: remaining = (total - used) / total
                
                var percentage: Double = 0
                if total > 0 {
                    percentage = max(0, Double(total - used) / Double(total) * 100)
                } else if total == -1 {
                    percentage = 100 // Unlimited (Treat as 100% remaining)
                }
                
                // Construct reset time description if available
                let resetInfo = limit.period ?? "" // e.g., "Monthly"
                
                models.append(ModelQuota(
                    name: "kiro-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    percentage: percentage,
                    resetTime: resetInfo
                ))
            }
        }
        
        // Fallback if no limits found
        if models.isEmpty {
             models.append(ModelQuota(name: "kiro-standard", percentage: 100, resetTime: "Unknown"))
        }

        return ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: planType
        )
    }
}
