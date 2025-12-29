//
//  CursorQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Cursor using stored auth tokens and cursor.com API
//  Reads auth from Cursor's state.vscdb SQLite database
//

import Foundation
import SQLite3

/// Quota data from Cursor
struct CursorQuotaInfo: Sendable {
    let email: String?
    let membershipType: String? // pro, pro_student, free, etc.
    let subscriptionStatus: String?
    let billingCycleStart: Date?
    let billingCycleEnd: Date?
    let isUnlimited: Bool
    
    /// Plan usage (included in subscription)
    let planUsage: PlanUsage?
    /// On-demand usage (pay-as-you-go)
    let onDemandUsage: OnDemandUsage?
    
    struct PlanUsage: Sendable {
        let enabled: Bool
        let used: Int
        let limit: Int
        let remaining: Int
        let totalPercentUsed: Double
        let autoPercentUsed: Double
        let apiPercentUsed: Double
        
        var remainingPercentage: Double {
            guard limit > 0 else { return 100 }
            return Double(remaining) / Double(limit) * 100
        }
    }
    
    struct OnDemandUsage: Sendable {
        let enabled: Bool
        let used: Int
        let limit: Int?
        let remaining: Int?
    }
}

/// Auth data from Cursor's state.vscdb
struct CursorAuthData: Sendable {
    let accessToken: String?
    let refreshToken: String?
    let email: String?
    let membershipType: String?
    let subscriptionStatus: String?
    let signUpType: String?
}

/// Fetches quota from Cursor using stored auth
actor CursorQuotaFetcher {
    private let session: URLSession
    private let cursorAPIBase = "https://api2.cursor.sh"
    private let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }
    
    /// Check if Cursor is installed
    func isInstalled() async -> Bool {
        let appPaths = [
            "/Applications/Cursor.app",
            NSString(string: "~/Applications/Cursor.app").expandingTildeInPath
        ]
        
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if Cursor auth exists
    func hasAuth() -> Bool {
        let authData = readAuthFromStateDB()
        return authData?.accessToken != nil
    }
    
    /// Read auth data from Cursor's state.vscdb
    func readAuthFromStateDB() -> CursorAuthData? {
        let expandedPath = NSString(string: stateDBPath).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }
        
        // Use URI with immutable=1 to avoid WAL file requirement
        // This prevents errors when Cursor is not running and .vscdb-wal doesn't exist
        let uri = "file://\(expandedPath)?mode=ro&immutable=1"
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }
        
        var accessToken: String?
        var refreshToken: String?
        var email: String?
        var membershipType: String?
        var subscriptionStatus: String?
        var signUpType: String?
        
        let query = "SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth/%'"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let keyPtr = sqlite3_column_text(stmt, 0),
                      let valuePtr = sqlite3_column_text(stmt, 1) else {
                    continue
                }
                
                let key = String(cString: keyPtr)
                let value = String(cString: valuePtr)
                
                switch key {
                case "cursorAuth/accessToken":
                    accessToken = value
                case "cursorAuth/refreshToken":
                    refreshToken = value
                case "cursorAuth/cachedEmail":
                    email = value
                case "cursorAuth/stripeMembershipType":
                    membershipType = value
                case "cursorAuth/stripeSubscriptionStatus":
                    subscriptionStatus = value
                case "cursorAuth/cachedSignUpType":
                    signUpType = value
                default:
                    break
                }
            }
            sqlite3_finalize(stmt)
        }
        
        guard accessToken != nil || email != nil else {
            return nil
        }
        
        return CursorAuthData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            membershipType: membershipType,
            subscriptionStatus: subscriptionStatus,
            signUpType: signUpType
        )
    }
    
    /// Fetch quota from Cursor API using usage-summary endpoint
    func fetchQuota() async -> CursorQuotaInfo? {
        guard let authData = readAuthFromStateDB(),
              let accessToken = authData.accessToken else {
            return nil
        }
        
        // Fetch usage-summary endpoint (has both plan and on-demand info)
        guard let usageURL = URL(string: "\(cursorAPIBase)/auth/usage-summary") else { return nil }
        
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            
            // If unauthorized, return basic info from local auth
            if httpResponse.statusCode == 401 {
                return CursorQuotaInfo(
                    email: authData.email,
                    membershipType: authData.membershipType,
                    subscriptionStatus: authData.subscriptionStatus,
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    isUnlimited: false,
                    planUsage: nil,
                    onDemandUsage: nil
                )
            }
            
            guard httpResponse.statusCode == 200 else {
                // Return basic info from local auth if API fails
                return CursorQuotaInfo(
                    email: authData.email,
                    membershipType: authData.membershipType,
                    subscriptionStatus: authData.subscriptionStatus,
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    isUnlimited: false,
                    planUsage: nil,
                    onDemandUsage: nil
                )
            }
            
            return parseUsageSummaryResponse(data, authData: authData)
        } catch {
            // Return basic info from local auth on network error
            return CursorQuotaInfo(
                email: authData.email,
                membershipType: authData.membershipType,
                subscriptionStatus: authData.subscriptionStatus,
                billingCycleStart: nil,
                billingCycleEnd: nil,
                isUnlimited: false,
                planUsage: nil,
                onDemandUsage: nil
            )
        }
    }
    
    /// Parse usage-summary API response
    private func parseUsageSummaryResponse(_ data: Data, authData: CursorAuthData) -> CursorQuotaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CursorQuotaInfo(
                email: authData.email,
                membershipType: authData.membershipType,
                subscriptionStatus: authData.subscriptionStatus,
                billingCycleStart: nil,
                billingCycleEnd: nil,
                isUnlimited: false,
                planUsage: nil,
                onDemandUsage: nil
            )
        }
        
        // Parse membership type
        let membershipType = json["membershipType"] as? String ?? authData.membershipType
        let isUnlimited = json["isUnlimited"] as? Bool ?? false
        
        // Parse billing cycle dates
        var billingCycleStart: Date? = nil
        var billingCycleEnd: Date? = nil
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let startStr = json["billingCycleStart"] as? String {
            billingCycleStart = dateFormatter.date(from: startStr)
        }
        if let endStr = json["billingCycleEnd"] as? String {
            billingCycleEnd = dateFormatter.date(from: endStr)
        }
        
        // Parse individual usage
        var planUsage: CursorQuotaInfo.PlanUsage? = nil
        var onDemandUsage: CursorQuotaInfo.OnDemandUsage? = nil
        
        if let individualUsage = json["individualUsage"] as? [String: Any] {
            // Parse plan usage
            if let plan = individualUsage["plan"] as? [String: Any] {
                let enabled = plan["enabled"] as? Bool ?? false
                let used = plan["used"] as? Int ?? 0
                let limit = plan["limit"] as? Int ?? 0
                let remaining = plan["remaining"] as? Int ?? 0
                let totalPercentUsed = plan["totalPercentUsed"] as? Double ?? 0
                let autoPercentUsed = plan["autoPercentUsed"] as? Double ?? 0
                let apiPercentUsed = plan["apiPercentUsed"] as? Double ?? 0
                
                planUsage = CursorQuotaInfo.PlanUsage(
                    enabled: enabled,
                    used: used,
                    limit: limit,
                    remaining: remaining,
                    totalPercentUsed: totalPercentUsed,
                    autoPercentUsed: autoPercentUsed,
                    apiPercentUsed: apiPercentUsed
                )
            }
            
            // Parse on-demand usage
            if let onDemand = individualUsage["onDemand"] as? [String: Any] {
                let enabled = onDemand["enabled"] as? Bool ?? false
                let used = onDemand["used"] as? Int ?? 0
                let limit = onDemand["limit"] as? Int
                let remaining = onDemand["remaining"] as? Int
                
                onDemandUsage = CursorQuotaInfo.OnDemandUsage(
                    enabled: enabled,
                    used: used,
                    limit: limit,
                    remaining: remaining
                )
            }
        }
        
        return CursorQuotaInfo(
            email: authData.email,
            membershipType: membershipType,
            subscriptionStatus: authData.subscriptionStatus,
            billingCycleStart: billingCycleStart,
            billingCycleEnd: billingCycleEnd,
            isUnlimited: isUnlimited,
            planUsage: planUsage,
            onDemandUsage: onDemandUsage
        )
    }
    
    /// Convert to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        guard await isInstalled() else { return [:] }
        guard let info = await fetchQuota() else { return [:] }
        
        var models: [ModelQuota] = []
        
        // Add plan usage
        if let plan = info.planUsage, plan.enabled {
            let resetTimeStr: String
            if let resetTime = info.billingCycleEnd {
                resetTimeStr = ISO8601DateFormatter().string(from: resetTime)
            } else {
                resetTimeStr = ""
            }
            
            var planModel = ModelQuota(
                name: "plan-usage",
                percentage: plan.remainingPercentage,
                resetTime: resetTimeStr
            )
            planModel.used = plan.used
            planModel.limit = plan.limit
            planModel.remaining = plan.remaining
            models.append(planModel)
        }
        
        // Add on-demand usage if enabled
        if let onDemand = info.onDemandUsage, onDemand.enabled {
            // For on-demand, show used count (no limit typically)
            let percentage: Double
            if let limit = onDemand.limit, limit > 0, let remaining = onDemand.remaining {
                percentage = Double(remaining) / Double(limit) * 100
            } else {
                percentage = 100 // Unlimited or no limit set
            }
            
            var onDemandModel = ModelQuota(
                name: "on-demand",
                percentage: percentage,
                resetTime: ""
            )
            onDemandModel.used = onDemand.used
            onDemandModel.limit = onDemand.limit
            onDemandModel.remaining = onDemand.remaining
            models.append(onDemandModel)
        }
        
        // If no usage data but have account info, create a placeholder
        if models.isEmpty {
            models.append(ModelQuota(
                name: "cursor-usage",
                percentage: info.isUnlimited ? 100 : -1,
                resetTime: ""
            ))
        }
        
        let email = info.email ?? "Cursor User"
        
        // Format plan type for display (e.g., "pro_student" -> "Pro Student")
        var planDisplayName: String? = nil
        if let membership = info.membershipType {
            planDisplayName = membership
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: planDisplayName
        )
        
        return [email: quotaData]
    }
}
