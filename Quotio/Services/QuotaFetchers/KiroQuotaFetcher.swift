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
    let tokenType: String?
    let refreshToken: String?

    // AWS OIDC returns camelCase keys, not snake_case
    // No CodingKeys needed - Swift will match camelCase by default
}

// MARK: - Kiro Quota Fetcher

actor KiroQuotaFetcher {
    private let usageEndpoint = "https://codewhisperer.us-east-1.amazonaws.com/getUsageLimits"

    // Token refresh endpoints for different auth methods
    private let socialTokenEndpoint = "https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken"  // For Google OAuth
    private let idcTokenEndpoint = "https://oidc.us-east-1.amazonaws.com/token"  // For AWS Builder ID

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

    private let refreshBufferSeconds: TimeInterval = 5 * 60  // Refresh 5 minutes before expiry
    
    private func shouldRefreshToken(_ tokenData: AuthTokenData) -> (shouldRefresh: Bool, reason: String) {
        guard let expiresAt = tokenData.expiresAt else { 
            return (false, "no expiry info") 
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var expiryDate: Date?
        
        if let date = formatter.date(from: expiresAt) {
            expiryDate = date
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            expiryDate = formatter.date(from: expiresAt)
        }
        
        guard let date = expiryDate else {
            return (false, "unparseable expiry")
        }
        
        let timeRemaining = date.timeIntervalSinceNow
        
        if timeRemaining <= 0 {
            return (true, "expired \(Int(-timeRemaining))s ago")
        } else if timeRemaining < refreshBufferSeconds {
            return (true, "expiring in \(Int(timeRemaining))s (< 5min buffer)")
        }
        
        return (false, "\(Int(timeRemaining))s remaining")
    }

    /// Fetch quota for a single token
    /// Implements reactive token refresh: if API returns 401/403, refresh token and retry once
    private func fetchQuota(tokenData: AuthTokenData, filePath: String) async -> ProviderQuotaData? {
        let filename = (filePath as NSString).lastPathComponent
        var currentToken = tokenData.accessToken
        var hasAttemptedRefresh = false

        // 1. Proactive refresh: Check if token needs refresh (expired or expiring soon)
        let (needsRefresh, reason) = shouldRefreshToken(tokenData)
        if needsRefresh {
            print("[Kiro] ⚠️ Token needs refresh for \(filename): \(reason)")
            if let expiresAt = tokenData.expiresAt {
                print("[Kiro]    Expired at: \(expiresAt)")
            }
            print("[Kiro]    Auth method: \(tokenData.authMethod ?? "IdC")")
            print("[Kiro]    Has refresh token: \(tokenData.refreshToken != nil)")
            
            if let refreshed = await refreshToken(tokenData: tokenData, filePath: filePath) {
                print("[Kiro] ✅ Proactive token refresh succeeded for \(filename)")
                currentToken = refreshed
                hasAttemptedRefresh = true
            } else {
                print("[Kiro] ❌ Proactive token refresh FAILED for \(filename)")
                return ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Token Refresh Failed")],
                    lastUpdated: Date(),
                    isForbidden: true,
                    planType: "Expired"
                )
            }
        }

        // 2. Fetch Usage (with retry on 401/403)
        let result = await fetchUsageAPI(token: currentToken, filename: filename)
        
        // 3. Reactive refresh: If 401/403 and haven't tried refresh yet, refresh and retry
        if (result.statusCode == 401 || result.statusCode == 403) && !hasAttemptedRefresh {
            print("[Kiro] 🔄 Got HTTP \(result.statusCode) for \(filename), attempting reactive token refresh...")
            
            if let refreshed = await refreshToken(tokenData: tokenData, filePath: filePath) {
                print("[Kiro] ✅ Reactive token refresh succeeded, retrying API call...")
                let retryResult = await fetchUsageAPI(token: refreshed, filename: filename)
                
                if retryResult.quotaData != nil {
                    print("[Kiro] ✅ Retry succeeded for \(filename)")
                } else {
                    print("[Kiro] ❌ Retry still failed with HTTP \(retryResult.statusCode) for \(filename)")
                }
                return retryResult.quotaData ?? ProviderQuotaData(models: [], lastUpdated: Date(), isForbidden: true, planType: "Unauthorized")
            } else {
                print("[Kiro] ❌ Reactive token refresh FAILED for \(filename)")
            }
        }
        
        return result.quotaData
    }
    
    /// Internal struct for API result
    private struct UsageAPIResult {
        let statusCode: Int
        let quotaData: ProviderQuotaData?
    }
    
    /// Fetch usage from API with given token
    private func fetchUsageAPI(token: String, filename: String) async -> UsageAPIResult {
        guard let url = URL(string: "\(usageEndpoint)?isEmailRequired=true&origin=AI_EDITOR") else {
            return UsageAPIResult(statusCode: 0, quotaData: ProviderQuotaData(
                models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Invalid URL")],
                lastUpdated: Date(), isForbidden: false, planType: "Error"
            ))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("aws-sdk-js/3.0.0 KiroIDE-0.1.0 os/macos lang/js md/nodejs/18.0.0", forHTTPHeaderField: "User-Agent")
        request.addValue("aws-sdk-js/3.0.0", forHTTPHeaderField: "x-amz-user-agent")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return UsageAPIResult(statusCode: 0, quotaData: ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Invalid Response Type")],
                    lastUpdated: Date(), isForbidden: false, planType: "Error"
                ))
            }

            print("[Kiro] 📥 API response for \(filename): HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    return UsageAPIResult(statusCode: httpResponse.statusCode, quotaData: nil)
                }
                let errorMsg = "HTTP \(httpResponse.statusCode)"
                return UsageAPIResult(statusCode: httpResponse.statusCode, quotaData: ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: errorMsg)],
                    lastUpdated: Date(), isForbidden: false, planType: "Error"
                ))
            }

            // Decode response
            do {
                let usageResponse = try JSONDecoder().decode(KiroUsageResponse.self, from: data)
                let planType = usageResponse.subscriptionInfo?.subscriptionTitle ?? "Standard"
                return UsageAPIResult(statusCode: 200, quotaData: convertToQuotaData(usageResponse, planType: planType))
            } catch {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let keys = json.keys.sorted().joined(separator: ",")
                    return UsageAPIResult(statusCode: 200, quotaData: ProviderQuotaData(
                        models: [ModelQuota(name: "Debug: Keys: \(keys)", percentage: 0, resetTime: "Decode Error: \(error.localizedDescription)")],
                        lastUpdated: Date(), isForbidden: false, planType: "Error"
                    ))
                }
                return UsageAPIResult(statusCode: 200, quotaData: ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: error.localizedDescription)],
                    lastUpdated: Date(), isForbidden: false, planType: "Error"
                ))
            }
        } catch {
            return UsageAPIResult(statusCode: 0, quotaData: ProviderQuotaData(
                models: [ModelQuota(name: "Error", percentage: 0, resetTime: error.localizedDescription)],
                lastUpdated: Date(), isForbidden: false, planType: "Error"
            ))
        }
    }

    /// Refresh Kiro token based on auth method and persist to disk
    /// - Social auth (Google): Uses Kiro's refreshToken endpoint, only needs refreshToken
    /// - IdC auth (AWS Builder ID): Uses AWS OIDC endpoint, needs clientId + clientSecret
    private func refreshToken(tokenData: AuthTokenData, filePath: String) async -> String? {
        let filename = (filePath as NSString).lastPathComponent
        
        guard let refreshToken = tokenData.refreshToken else {
            print("[Kiro] ❌ No refresh token available for \(filename)")
            return nil
        }

        // Determine auth method: "Social" (Google) or "IdC" (AWS Builder ID)
        // Default to "IdC" for backwards compatibility
        let authMethod = tokenData.authMethod ?? "IdC"
        
        print("[Kiro] 🔄 Starting token refresh for \(filename)")
        print("[Kiro]    Method: \(authMethod)")
        print("[Kiro]    Refresh token: \(refreshToken.prefix(20))...")

        if authMethod == "Social" {
            return await refreshSocialToken(refreshToken: refreshToken, filePath: filePath)
        } else {
            return await refreshIdCToken(tokenData: tokenData, filePath: filePath)
        }
    }

    /// Refresh token for Social auth (Google OAuth) using Kiro's endpoint
    private func refreshSocialToken(refreshToken: String, filePath: String) async -> String? {
        let filename = (filePath as NSString).lastPathComponent
        print("[Kiro] 📡 Refreshing Social (Google) token for \(filename)")
        print("[Kiro]    Endpoint: \(socialTokenEndpoint)")
        
        guard let url = URL(string: socialTokenEndpoint) else {
            print("[Kiro] ❌ Invalid Social token endpoint URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Social auth only needs the refresh token
        let body: [String: String] = ["refreshToken": refreshToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            print("[Kiro] ❌ Failed to serialize request body")
            return nil
        }
        request.httpBody = bodyData

        do {
            print("[Kiro] 🌐 Sending refresh request...")
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Kiro] ❌ Invalid response type")
                return nil
            }
            
            print("[Kiro] 📥 Response status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                print("[Kiro] ❌ HTTP error: \(httpResponse.statusCode)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("[Kiro]    Response body: \(responseString)")
                }
                return nil
            }

            let tokenResponse = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
            print("[Kiro] ✅ Token decoded successfully")
            print("[Kiro]    New access token: \(tokenResponse.accessToken.prefix(20))...")
            print("[Kiro]    Expires in: \(tokenResponse.expiresIn) seconds")
            print("[Kiro]    Has new refresh token: \(tokenResponse.refreshToken != nil)")

            // Persist refreshed token to disk
            await persistRefreshedToken(
                filePath: filePath,
                newAccessToken: tokenResponse.accessToken,
                newRefreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn
            )

            return tokenResponse.accessToken
        } catch let decodingError as DecodingError {
            print("[Kiro] ❌ JSON decoding error: \(decodingError)")
            return nil
        } catch {
            print("[Kiro] ❌ Network error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Refresh token for IdC auth (AWS Builder ID) using AWS OIDC endpoint
    /// Based on kiro2api implementation: uses JSON body format with specific AWS headers
    private func refreshIdCToken(tokenData: AuthTokenData, filePath: String) async -> String? {
        let filename = (filePath as NSString).lastPathComponent
        print("[Kiro] 📡 Refreshing IdC (AWS Builder ID) token for \(filename)")
        print("[Kiro]    Endpoint: \(idcTokenEndpoint)")
        
        guard let refreshToken = tokenData.refreshToken,
              let clientId = tokenData.clientId,
              let clientSecret = tokenData.clientSecret,
              let url = URL(string: idcTokenEndpoint) else {
            print("[Kiro] ❌ Missing required credentials for IdC refresh")
            print("[Kiro]    Has refresh token: \(tokenData.refreshToken != nil)")
            print("[Kiro]    Has clientId: \(tokenData.clientId != nil)")
            print("[Kiro]    Has clientSecret: \(tokenData.clientSecret != nil)")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Headers matching kiro2api implementation
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("oidc.us-east-1.amazonaws.com", forHTTPHeaderField: "Host")
        request.addValue("keep-alive", forHTTPHeaderField: "Connection")
        request.addValue("aws-sdk-js/3.738.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.738.0 m/E KiroIDE", forHTTPHeaderField: "x-amz-user-agent")
        request.addValue("*/*", forHTTPHeaderField: "Accept")
        request.addValue("*", forHTTPHeaderField: "Accept-Language")
        request.addValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.addValue("node", forHTTPHeaderField: "User-Agent")

        // JSON body format (not form-urlencoded)
        let body: [String: String] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            print("[Kiro] ❌ Failed to serialize IdC request body")
            return nil
        }
        request.httpBody = bodyData

        do {
            print("[Kiro] 🌐 Sending IdC refresh request...")
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Kiro] ❌ Invalid response type")
                return nil
            }
            
            print("[Kiro] 📥 Response status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                print("[Kiro] ❌ HTTP error: \(httpResponse.statusCode)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("[Kiro]    Response body: \(responseString)")
                }
                return nil
            }

            let tokenResponse = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
            print("[Kiro] ✅ IdC token decoded successfully")
            print("[Kiro]    New access token: \(tokenResponse.accessToken.prefix(20))...")
            print("[Kiro]    Expires in: \(tokenResponse.expiresIn) seconds")
            print("[Kiro]    Has new refresh token: \(tokenResponse.refreshToken != nil)")

            // Persist refreshed token to disk
            await persistRefreshedToken(
                filePath: filePath,
                newAccessToken: tokenResponse.accessToken,
                newRefreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn
            )

            return tokenResponse.accessToken
        } catch let decodingError as DecodingError {
            print("[Kiro] ❌ JSON decoding error: \(decodingError)")
            return nil
        } catch {
            print("[Kiro] ❌ Network error: \(error.localizedDescription)")
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
        let filename = (filePath as NSString).lastPathComponent
        print("[Kiro] 💾 Persisting refreshed token to \(filename)")
        
        // Read existing file to preserve other fields
        guard let existingData = fileManager.contents(atPath: filePath),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            print("[Kiro] ❌ Failed to read existing auth file")
            return
        }

        // Update token fields
        json["access_token"] = newAccessToken
        if let newRefresh = newRefreshToken {
            json["refresh_token"] = newRefresh
            print("[Kiro]    Updated refresh token")
        }

        // Calculate new expiry time
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        let expiryString = formatter.string(from: newExpiresAt)
        json["expires_at"] = expiryString
        print("[Kiro]    New expiry: \(expiryString)")

        // Update last_refresh timestamp
        let lastRefreshString = formatter.string(from: Date())
        json["last_refresh"] = lastRefreshString
        print("[Kiro]    Last refresh: \(lastRefreshString)")

        // Write back to disk
        do {
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            print("[Kiro] ✅ Token persisted successfully")
        } catch {
            print("[Kiro] ⚠️ Failed to write auth file: \(error.localizedDescription)")
            print("[Kiro]    (Token refresh still succeeded in memory)")
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
