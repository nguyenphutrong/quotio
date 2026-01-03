//
//  TraeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Trae (ByteDance) using stored auth tokens
//  Reads auth from Trae's storage.json file
//

import Foundation

/// Auth data from Trae's storage.json
struct TraeAuthData: Sendable {
    let accessToken: String?
    let refreshToken: String?
    let email: String?
    let userId: String?
    let apiHost: String?
    let username: String?
}

/// Quota info from Trae API
struct TraeQuotaInfo: Sendable {
    let email: String?
    let userId: String?
    let username: String?
    let planType: String?
    
    // Usage limits
    let advancedModelLimit: Int
    let advancedModelUsed: Int
    let autoCompletionLimit: Int
    let autoCompletionUsed: Int
    let premiumFastLimit: Int
    let premiumFastUsed: Int
    let premiumSlowLimit: Int
    let premiumSlowUsed: Int
    
    let resetTime: Date?
}

/// Fetches quota from Trae using stored auth
actor TraeQuotaFetcher {
    private let session: URLSession
    private let storageJsonPath = "~/Library/Application Support/Trae/User/globalStorage/storage.json"
    private let authKey = "iCubeAuthInfo://icube.cloudide"
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }
    
    /// Check if Trae is installed
    func isInstalled() async -> Bool {
        let appPaths = [
            "/Applications/Trae.app",
            NSString(string: "~/Applications/Trae.app").expandingTildeInPath
        ]
        
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if Trae auth exists
    func hasAuth() -> Bool {
        let authData = readAuthFromStorageJson()
        return authData?.accessToken != nil
    }
    
    /// Read auth data from Trae's storage.json
    func readAuthFromStorageJson() -> TraeAuthData? {
        let expandedPath = NSString(string: storageJsonPath).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }
        
        guard let data = FileManager.default.contents(atPath: expandedPath),
              let storageJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Get the auth info string from storage.json
        guard let authInfoString = storageJson[authKey] as? String,
              let authInfoData = authInfoString.data(using: .utf8),
              let authInfo = try? JSONSerialization.jsonObject(with: authInfoData) as? [String: Any] else {
            return nil
        }
        
        // Extract auth info
        let accessToken = authInfo["token"] as? String
        let refreshToken = authInfo["refreshToken"] as? String
        let userId = authInfo["userId"] as? String
        let apiHost = authInfo["host"] as? String
        
        // Email and username are in the nested "account" object
        var email: String? = nil
        var username: String? = nil
        
        if let account = authInfo["account"] as? [String: Any] {
            email = account["email"] as? String
            username = account["username"] as? String
        }
        
        guard accessToken != nil || email != nil else {
            return nil
        }
        
        return TraeAuthData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            userId: userId,
            apiHost: apiHost,
            username: username
        )
    }
    
    /// Fetch quota from Trae API
    func fetchQuota() async -> TraeQuotaInfo? {
        guard let authData = readAuthFromStorageJson(),
              let accessToken = authData.accessToken else {
            return nil
        }
        
        // Use the API host from auth data or default
        let apiHost = authData.apiHost ?? "https://api-sg-central.trae.ai"
        let quotaEndpoint = "\(apiHost)/trae/api/v1/pay/user_current_entitlement_list"
        
        guard let quotaURL = URL(string: quotaEndpoint) else {
            return nil
        }
        
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.setValue("Cloud-IDE-JWT \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.trae.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://www.trae.ai/", forHTTPHeaderField: "Referer")
        
        // Request body
        let body = ["require_usage": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            return parseQuotaResponse(data, authData: authData)
        } catch {
            return nil
        }
    }
    
    /// Parse quota API response
    private func parseQuotaResponse(_ data: Data, authData: TraeAuthData) -> TraeQuotaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entitlementList = json["user_entitlement_pack_list"] as? [[String: Any]] else {
            return nil
        }
        
        // Find the active entitlement (status = 1, typically the free tier)
        var activeEntitlement: [String: Any]? = nil
        var resetTime: Date? = nil
        
        for entitlement in entitlementList {
            let status = entitlement["status"] as? Int ?? 0
            if status == 1 {
                activeEntitlement = entitlement
                
                // Get end time for reset
                if let baseInfo = entitlement["entitlement_base_info"] as? [String: Any],
                   let endTimestamp = baseInfo["end_time"] as? Int {
                    resetTime = Date(timeIntervalSince1970: TimeInterval(endTimestamp))
                }
                break
            }
        }
        
        guard let entitlement = activeEntitlement else {
            // No active entitlement, use first one if available
            if let first = entitlementList.first {
                return parseEntitlement(first, authData: authData, resetTime: nil)
            }
            return nil
        }
        
        return parseEntitlement(entitlement, authData: authData, resetTime: resetTime)
    }
    
    /// Parse a single entitlement object
    private func parseEntitlement(_ entitlement: [String: Any], authData: TraeAuthData, resetTime: Date?) -> TraeQuotaInfo {
        // Get limits from entitlement_base_info.quota
        var advancedModelLimit = 0
        var autoCompletionLimit = 0
        var premiumFastLimit = 0
        var premiumSlowLimit = 0
        var planType: String? = nil
        
        if let baseInfo = entitlement["entitlement_base_info"] as? [String: Any] {
            if let quota = baseInfo["quota"] as? [String: Any] {
                advancedModelLimit = quota["advanced_model_request_limit"] as? Int ?? 0
                autoCompletionLimit = quota["auto_completion_limit"] as? Int ?? 0
                premiumFastLimit = quota["premium_model_fast_request_limit"] as? Int ?? 0
                premiumSlowLimit = quota["premium_model_slow_request_limit"] as? Int ?? 0
            }
            
            // Determine plan type from product_type
            let productType = baseInfo["product_type"] as? Int ?? 0
            switch productType {
            case 0: planType = "Free"
            case 1: planType = "Pro"
            case 2: planType = "Team"
            case 3: planType = "Builder"
            default: planType = nil
            }
        }
        
        // Get usage - use *_amount fields (not *_request_usage)
        var advancedModelUsed = 0
        var autoCompletionUsed = 0
        var premiumFastUsed = 0
        var premiumSlowUsed = 0
        
        if let usage = entitlement["usage"] as? [String: Any] {
            advancedModelUsed = usage["advanced_model_amount"] as? Int ?? 0
            autoCompletionUsed = usage["auto_completion_amount"] as? Int ?? 0
            premiumFastUsed = usage["premium_model_fast_amount"] as? Int ?? 0
            premiumSlowUsed = usage["premium_model_slow_amount"] as? Int ?? 0
        }
        
        return TraeQuotaInfo(
            email: authData.email,
            userId: authData.userId,
            username: authData.username,
            planType: planType,
            advancedModelLimit: advancedModelLimit,
            advancedModelUsed: advancedModelUsed,
            autoCompletionLimit: autoCompletionLimit,
            autoCompletionUsed: autoCompletionUsed,
            premiumFastLimit: premiumFastLimit,
            premiumFastUsed: premiumFastUsed,
            premiumSlowLimit: premiumSlowLimit,
            premiumSlowUsed: premiumSlowUsed,
            resetTime: resetTime
        )
    }
    
    /// Convert to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        guard await isInstalled() else { return [:] }
        guard let info = await fetchQuota() else { return [:] }
        
        var models: [ModelQuota] = []
        
        let resetTimeStr: String
        if let resetTime = info.resetTime {
            resetTimeStr = ISO8601DateFormatter().string(from: resetTime)
        } else {
            resetTimeStr = ""
        }
        
        // Add Premium Fast quota (most important for users)
        if info.premiumFastLimit > 0 {
            let remaining = max(0, info.premiumFastLimit - info.premiumFastUsed)
            let percentage = Double(remaining) / Double(info.premiumFastLimit) * 100
            
            var quotaModel = ModelQuota(
                name: "premium-fast",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.premiumFastUsed
            quotaModel.limit = info.premiumFastLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // Add Premium Slow quota
        if info.premiumSlowLimit > 0 {
            let remaining = max(0, info.premiumSlowLimit - info.premiumSlowUsed)
            let percentage = Double(remaining) / Double(info.premiumSlowLimit) * 100
            
            var quotaModel = ModelQuota(
                name: "premium-slow",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.premiumSlowUsed
            quotaModel.limit = info.premiumSlowLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // Add Advanced Model quota
        if info.advancedModelLimit > 0 {
            let remaining = max(0, info.advancedModelLimit - info.advancedModelUsed)
            let percentage = Double(remaining) / Double(info.advancedModelLimit) * 100
            
            var quotaModel = ModelQuota(
                name: "advanced-model",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.advancedModelUsed
            quotaModel.limit = info.advancedModelLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // Add Auto Completion quota
        if info.autoCompletionLimit > 0 {
            let remaining = max(0, info.autoCompletionLimit - info.autoCompletionUsed)
            let percentage = Double(remaining) / Double(info.autoCompletionLimit) * 100
            
            var quotaModel = ModelQuota(
                name: "auto-completion",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.autoCompletionUsed
            quotaModel.limit = info.autoCompletionLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // If no quota models, add placeholder
        if models.isEmpty {
            models.append(ModelQuota(
                name: "trae-usage",
                percentage: -1,
                resetTime: ""
            ))
        }
        
        let email = info.email ?? info.username ?? info.userId ?? "Trae User"
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: info.planType
        )
        
        return [email: quotaData]
    }
}
