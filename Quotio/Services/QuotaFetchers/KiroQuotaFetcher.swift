//
//  KiroQuotaFetcher.swift
//  Quotio
//
//  Kiro (AWS CodeWhisperer) Quota Fetcher
//  Implements logic from kiro2api for quota monitoring


import Foundation

// MARK: - Kiro Response Models

nonisolated struct KiroUsageResponse: Decodable {
    let usageBreakdownList: [KiroUsageBreakdown]?
    let subscriptionInfo: KiroSubscriptionInfo?
    let userInfo: KiroUserInfo?
    let nextDateReset: Double?

    struct KiroUsageBreakdown: Decodable {
        let displayName: String?
        let resourceType: String?
        let currentUsage: Double?
        let currentUsageWithPrecision: Double?
        let usageLimit: Double?
        let usageLimitWithPrecision: Double?
        let nextDateReset: Double?
        let freeTrialInfo: KiroFreeTrialInfo?
    }

    struct KiroFreeTrialInfo: Decodable {
        let currentUsage: Double?
        let currentUsageWithPrecision: Double?
        let usageLimit: Double?
        let usageLimitWithPrecision: Double?
        let freeTrialStatus: String?
        let freeTrialExpiry: Double?
    }

    struct KiroSubscriptionInfo: Decodable {
        let subscriptionTitle: String?
        let type: String?
    }

    struct KiroUserInfo: Decodable {
        let email: String?
        let userId: String?
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

                    let quota = await self.fetchQuota(tokenData: tokenData, filePath: authFile.filePath)
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
    private func fetchQuota(tokenData: AuthTokenData, filePath: String) async -> ProviderQuotaData? {
        var currentToken = tokenData.accessToken

        // 1. Check if token needs refresh
        if isTokenExpired(tokenData) {
            if let refreshed = await refreshToken(tokenData: tokenData, filePath: filePath) {
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
        
        // 2. Fetch Usage - Remove resourceType filter to get all quota types including Bonus Credits
        guard let url = URL(string: "\(usageEndpoint)?isEmailRequired=true&origin=AI_EDITOR") else {
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
            
            // Decode response
            do {
                let usageResponse = try JSONDecoder().decode(KiroUsageResponse.self, from: data)

                // Determine Plan Type from subscription info
                let planType = usageResponse.subscriptionInfo?.subscriptionTitle ?? "Standard"

                return convertToQuotaData(usageResponse, planType: planType)
            } catch {
                // Debug: If decoding failed, show raw keys
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let keys = json.keys.sorted().joined(separator: ",")
                    return ProviderQuotaData(
                        models: [ModelQuota(name: "Debug: Keys: \(keys)", percentage: 0, resetTime: "Decode Error: \(error.localizedDescription)")],
                        lastUpdated: Date(),
                        isForbidden: false,
                        planType: "Error"
                    )
                }

                return ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: error.localizedDescription)],
                    lastUpdated: Date(),
                    isForbidden: false,
                    planType: "Error"
                )
            }
            
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
    
    /// Refresh Kiro token using AWS OIDC and persist to disk
    private func refreshToken(tokenData: AuthTokenData, filePath: String) async -> String? {
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

            // Persist refreshed token to disk for CLIProxyAPI to use
            await persistRefreshedToken(
                filePath: filePath,
                newAccessToken: tokenResponse.accessToken,
                newRefreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn
            )

            return tokenResponse.accessToken
        } catch {
            return nil
        }
    }

    /// Persist refreshed token back to the auth file on disk
    private func persistRefreshedToken(
        filePath: String,
        newAccessToken: String,
        newRefreshToken: String?,
        expiresIn: Int
    ) async {
        // Read existing file to preserve other fields
        guard let existingData = fileManager.contents(atPath: filePath),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            return
        }

        // Update token fields
        json["access_token"] = newAccessToken
        if let newRefresh = newRefreshToken {
            json["refresh_token"] = newRefresh
        }

        // Calculate new expiry time
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        json["expires_at"] = formatter.string(from: newExpiresAt)

        // Update last_refresh timestamp
        json["last_refresh"] = formatter.string(from: Date())

        // Write back to disk
        do {
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            // Silent failure - token refresh still succeeded in memory
        }
    }
    
    /// Convert Kiro response to standard Quota Data
    private func convertToQuotaData(_ response: KiroUsageResponse, planType: String) -> ProviderQuotaData {
        var models: [ModelQuota] = []

        // Calculate reset time from nextDateReset timestamp
        var resetTimeStr = ""
        if let nextReset = response.nextDateReset {
            let resetDate = Date(timeIntervalSince1970: nextReset)
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd"
            resetTimeStr = "resets \(formatter.string(from: resetDate))"
        }

        if let breakdownList = response.usageBreakdownList {
            for breakdown in breakdownList {
                let displayName = breakdown.displayName ?? breakdown.resourceType ?? "Usage"

                // Check for active free trial (Bonus Credits)
                let hasActiveTrial = breakdown.freeTrialInfo?.freeTrialStatus == "ACTIVE"

                if hasActiveTrial, let freeTrialInfo = breakdown.freeTrialInfo {
                    // Show trial/bonus quota
                    let used = freeTrialInfo.currentUsageWithPrecision ?? freeTrialInfo.currentUsage ?? 0
                    let total = freeTrialInfo.usageLimitWithPrecision ?? freeTrialInfo.usageLimit ?? 0

                    var percentage: Double = 0
                    if total > 0 {
                        percentage = max(0, (total - used) / total * 100)
                    }

                    // Calculate free trial expiry time
                    var trialResetStr = resetTimeStr
                    if let expiry = freeTrialInfo.freeTrialExpiry {
                        let expiryDate = Date(timeIntervalSince1970: expiry)
                        let formatter = DateFormatter()
                        formatter.dateFormat = "MM/dd"
                        trialResetStr = "expires \(formatter.string(from: expiryDate))"
                    }

                    models.append(ModelQuota(
                        name: "Bonus \(displayName)",
                        percentage: percentage,
                        resetTime: trialResetStr
                    ))
                }

                // Always check regular/paid quota (root level usage)
                let regularUsed = breakdown.currentUsageWithPrecision ?? breakdown.currentUsage ?? 0
                let regularTotal = breakdown.usageLimitWithPrecision ?? breakdown.usageLimit ?? 0

                // Add regular quota if it has meaningful limits
                // For trial users: this shows the base plan quota (e.g., 50)
                // For paid users: this shows the paid plan quota
                if regularTotal > 0 {
                    var percentage: Double = 0
                    percentage = max(0, (regularTotal - regularUsed) / regularTotal * 100)

                    // Use different name based on whether trial is active
                    let quotaName = hasActiveTrial ? "\(displayName) (Base)" : displayName
                    models.append(ModelQuota(
                        name: quotaName,
                        percentage: percentage,
                        resetTime: resetTimeStr
                    ))
                }
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
