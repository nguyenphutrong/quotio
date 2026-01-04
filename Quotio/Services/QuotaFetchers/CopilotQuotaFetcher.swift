//
//  CopilotQuotaFetcher.swift
//  Quotio
//

import Foundation

nonisolated struct CopilotQuotaSnapshot: Codable, Sendable {
    let entitlement: Int?
    let remaining: Int?
    let percentRemaining: Double?
    let overageCount: Int?
    let overagePermitted: Bool?
    let unlimited: Bool?
    
    enum CodingKeys: String, CodingKey {
        case entitlement
        case remaining
        case percentRemaining = "percent_remaining"
        case overageCount = "overage_count"
        case overagePermitted = "overage_permitted"
        case unlimited
    }
    
    nonisolated func calculatePercent(defaultTotal: Int) -> Double {
        if let percent = percentRemaining {
            return percent
        }
        let remaining = remaining ?? 0
        let total = entitlement ?? defaultTotal
        return total > 0 ? (Double(remaining) / Double(total)) * 100 : 0
    }
}

nonisolated struct CopilotQuotaSnapshots: Codable, Sendable {
    let chat: CopilotQuotaSnapshot?
    let completions: CopilotQuotaSnapshot?
    let premiumInteractions: CopilotQuotaSnapshot?
    
    enum CodingKeys: String, CodingKey {
        case chat
        case completions
        case premiumInteractions = "premium_interactions"
    }
}

nonisolated struct CopilotEntitlement: Codable, Sendable {
    let accessTypeSku: String?
    let copilotPlan: String?
    let chatEnabled: Bool?
    let canSignupForLimited: Bool?
    let organizationLoginList: [String]?
    let quotaResetDate: String?
    let quotaResetDateUtc: String?
    let limitedUserResetDate: String?
    let quotaSnapshots: CopilotQuotaSnapshots?
    
    enum CodingKeys: String, CodingKey {
        case accessTypeSku = "access_type_sku"
        case copilotPlan = "copilot_plan"
        case chatEnabled = "chat_enabled"
        case canSignupForLimited = "can_signup_for_limited"
        case organizationLoginList = "organization_login_list"
        case quotaResetDate = "quota_reset_date"
        case quotaResetDateUtc = "quota_reset_date_utc"
        case limitedUserResetDate = "limited_user_reset_date"
        case quotaSnapshots = "quota_snapshots"
    }
    
    nonisolated var planDisplayName: String {
        let sku = accessTypeSku?.lowercased() ?? ""
        let plan = copilotPlan?.lowercased() ?? ""
        
        if sku.contains("pro") || plan.contains("pro") {
            return "Pro"
        }
        if plan == "individual" || sku.contains("individual") {
            return "Pro"
        }
        if sku.contains("business") || plan == "business" {
            return "Business"
        }
        if sku.contains("enterprise") || plan == "enterprise" {
            return "Enterprise"
        }
        if sku.contains("free") || plan.contains("free") {
            return "Free"
        }
        
        return copilotPlan?.capitalized ?? accessTypeSku?.capitalized ?? "Unknown"
    }
    
    nonisolated var resetDate: Date? {
        let dateString = quotaResetDateUtc ?? quotaResetDate ?? limitedUserResetDate
        guard let dateString = dateString else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        return dateOnlyFormatter.date(from: dateString)
    }
}

nonisolated struct CopilotAuthFile: Codable, Sendable {
    let accessToken: String
    let tokenType: String?
    let scope: String?
    let username: String?
    let type: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case username
        case type
    }
}

actor CopilotQuotaFetcher {
    private let entitlementURL = "https://api.github.com/copilot_internal/user"
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }
    
    func fetchQuota(authFilePath: String) async -> ProviderQuotaData? {
        guard let authFile = loadAuthFile(from: authFilePath) else {
            return nil
        }
        
        do {
            let entitlement = try await fetchEntitlement(accessToken: authFile.accessToken)
            return convertToQuotaData(entitlement: entitlement)
        } catch {
            print("CopilotQuotaFetcher error: \(error)")
            return nil
        }
    }
    
    func fetchAllCopilotQuotas(authDir: String = "~/.cli-proxy-api") async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }
        
        let copilotFiles = files.filter { $0.hasPrefix("github-copilot-") && $0.hasSuffix(".json") }
        
        var results: [String: ProviderQuotaData] = [:]
        
        for file in copilotFiles {
            let filePath = (expandedPath as NSString).appendingPathComponent(file)
            if let authFile = loadAuthFile(from: filePath),
               let quota = await fetchQuota(authFilePath: filePath) {
                let key = authFile.username ?? extractUsername(from: file)
                results[key] = quota
            }
        }
        
        return results
    }
    
    private func loadAuthFile(from path: String) -> CopilotAuthFile? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(CopilotAuthFile.self, from: data)
    }
    
    private func fetchEntitlement(accessToken: String) async throws -> CopilotEntitlement {
        guard let url = URL(string: entitlementURL) else {
            throw QuotaFetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.addValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw QuotaFetchError.forbidden
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(CopilotEntitlement.self, from: data)
    }
    
    private func convertToQuotaData(entitlement: CopilotEntitlement) -> ProviderQuotaData {
        var models: [ModelQuota] = []
        let resetTimeString = entitlement.resetDate?.ISO8601Format() ?? ""
        
        if let snapshots = entitlement.quotaSnapshots {
            if let chat = snapshots.chat, chat.unlimited != true {
                models.append(ModelQuota(
                    name: "copilot-chat",
                    percentage: chat.calculatePercent(defaultTotal: 50),
                    resetTime: resetTimeString
                ))
            }
            
            if let completions = snapshots.completions, completions.unlimited != true {
                models.append(ModelQuota(
                    name: "copilot-completions",
                    percentage: completions.calculatePercent(defaultTotal: 2000),
                    resetTime: resetTimeString
                ))
            }
            
            if let premium = snapshots.premiumInteractions, premium.unlimited != true {
                models.append(ModelQuota(
                    name: "copilot-premium",
                    percentage: premium.calculatePercent(defaultTotal: 50),
                    resetTime: resetTimeString
                ))
            }
        }
        
        if models.isEmpty {
            let isFree = entitlement.accessTypeSku == "free_limited_copilot"
            if isFree {
                models.append(ModelQuota(name: "copilot-chat", percentage: 100.0, resetTime: resetTimeString))
                models.append(ModelQuota(name: "copilot-completions", percentage: 100.0, resetTime: resetTimeString))
            }
        }
        
        return ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: entitlement.planDisplayName
        )
    }
    
    private func extractUsername(from filename: String) -> String {
        var name = filename
        if name.hasPrefix("github-copilot-") {
            name = String(name.dropFirst("github-copilot-".count))
        }
        if name.hasSuffix(".json") {
            name = String(name.dropLast(".json".count))
        }
        return name
    }
}
