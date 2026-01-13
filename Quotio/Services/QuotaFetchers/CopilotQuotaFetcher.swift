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

/// Quota structure for limited users (free/individual plans)
nonisolated struct CopilotLimitedUserQuotas: Codable, Sendable {
    let chat: Int?
    let completions: Int?
}

/// Monthly quota limits
nonisolated struct CopilotMonthlyQuotas: Codable, Sendable {
    let chat: Int?
    let completions: Int?
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
    // New fields for limited/individual users
    let limitedUserQuotas: CopilotLimitedUserQuotas?
    let monthlyQuotas: CopilotMonthlyQuotas?

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
        case limitedUserQuotas = "limited_user_quotas"
        case monthlyQuotas = "monthly_quotas"
    }
    
    nonisolated var planDisplayName: String {
        let sku = accessTypeSku?.lowercased() ?? ""
        let plan = copilotPlan?.lowercased() ?? ""

        // Enterprise/Business check first (highest tiers)
        if sku.contains("enterprise") || plan == "enterprise" {
            return "Enterprise"
        }
        if sku.contains("business") || plan == "business" {
            return "Business"
        }
        
        // Educational quota is treated as Pro (unlimited chat/completions)
        if sku.contains("educational") {
            return "Pro"
        }
        
        // Pro checks
        if sku.contains("pro") || plan.contains("pro") {
            return "Pro"
        }
        
        // Individual plan without "free_limited" sku means paid Pro
        if plan == "individual" && !sku.contains("free_limited") {
            return "Pro"
        }
        
        // Free tier: only "free_limited_user" or explicit free plan
        if sku.contains("free_limited") || sku == "free" {
            return "Free"
        }
        if plan.contains("free") {
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

// MARK: - Copilot API Token Response

nonisolated struct CopilotAPITokenResponse: Codable, Sendable {
    let token: String
    let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

// MARK: - Copilot Model Info

nonisolated struct CopilotModelInfo: Codable, Sendable {
    let id: String
    let name: String?
    let modelPickerEnabled: Bool?
    let modelPickerCategory: String?
    let vendor: String?
    let preview: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case modelPickerEnabled = "model_picker_enabled"
        case modelPickerCategory = "model_picker_category"
        case vendor
        case preview
    }

    /// Whether this model is available for the user
    var isAvailable: Bool {
        modelPickerEnabled == true
    }
}

nonisolated struct CopilotModelsResponse: Codable, Sendable {
    let data: [CopilotModelInfo]
}

actor CopilotQuotaFetcher {
    private let entitlementURL = "https://api.github.com/copilot_internal/user"
    private let tokenURL = "https://api.github.com/copilot_internal/v2/token"
    private let modelsURL = "https://api.githubcopilot.com/models"
    private var session: URLSession

    // Cache for available models (per access token)
    private var modelsCache: [String: (models: [CopilotModelInfo], expiry: Date)] = [:]
    private let modelsCacheTTL: TimeInterval = 300 // 5 minutes

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
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

        // Method 1: Parse quota_snapshots (used by some plans)
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

        // Method 2: Parse limited_user_quotas + monthly_quotas (used by free/individual plans)
        if models.isEmpty,
           let remaining = entitlement.limitedUserQuotas,
           let total = entitlement.monthlyQuotas {
            // Chat quota
            if let chatRemaining = remaining.chat, let chatTotal = total.chat, chatTotal > 0 {
                let percentage = (Double(chatRemaining) / Double(chatTotal)) * 100.0
                models.append(ModelQuota(
                    name: "copilot-chat",
                    percentage: percentage,
                    resetTime: resetTimeString
                ))
            }

            // Completions quota
            if let compRemaining = remaining.completions, let compTotal = total.completions, compTotal > 0 {
                let percentage = (Double(compRemaining) / Double(compTotal)) * 100.0
                models.append(ModelQuota(
                    name: "copilot-completions",
                    percentage: percentage,
                    resetTime: resetTimeString
                ))
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

    // MARK: - Copilot Available Models

    /// Fetch available models for a Copilot account
    /// This calls the GitHub Copilot API to get the list of models the user can actually use
    func fetchAvailableModels(authFilePath: String) async -> [CopilotModelInfo] {
        guard let authFile = loadAuthFile(from: authFilePath) else {
            return []
        }

        // Check cache first
        if let cached = modelsCache[authFile.accessToken],
           cached.expiry > Date() {
            return cached.models
        }

        do {
            // Step 1: Get Copilot API token from GitHub OAuth token
            let apiToken = try await fetchCopilotAPIToken(accessToken: authFile.accessToken)

            // Step 2: Fetch models from Copilot API
            let models = try await fetchModelsFromCopilotAPI(apiToken: apiToken)

            // Cache the result
            modelsCache[authFile.accessToken] = (
                models: models,
                expiry: Date().addingTimeInterval(modelsCacheTTL)
            )

            return models
        } catch {
            print("CopilotQuotaFetcher fetchAvailableModels error: \(error)")
            return []
        }
    }

    /// Fetch available models for all Copilot accounts
    func fetchAllAvailableModels(authDir: String = "~/.cli-proxy-api") async -> [CopilotModelInfo] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return []
        }

        let copilotFiles = files.filter { $0.hasPrefix("github-copilot-") && $0.hasSuffix(".json") }

        // Get models from the first valid account (they should be the same for all accounts with same plan)
        for file in copilotFiles {
            let filePath = (expandedPath as NSString).appendingPathComponent(file)
            let models = await fetchAvailableModels(authFilePath: filePath)
            if !models.isEmpty {
                return models
            }
        }

        return []
    }

    /// Get only the models that are available for the user (model_picker_enabled == true)
    func fetchUserAvailableModelIds(authDir: String = "~/.cli-proxy-api") async -> Set<String> {
        let models = await fetchAllAvailableModels(authDir: authDir)
        return Set(models.filter { $0.isAvailable }.map { $0.id })
    }

    private func fetchCopilotAPIToken(accessToken: String) async throws -> String {
        guard let url = URL(string: tokenURL) else {
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

        guard 200...299 ~= httpResponse.statusCode else {
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }

        let tokenResponse = try JSONDecoder().decode(CopilotAPITokenResponse.self, from: data)
        return tokenResponse.token
    }

    private func fetchModelsFromCopilotAPI(apiToken: String) async throws -> [CopilotModelInfo] {
        guard let url = URL(string: modelsURL) else {
            throw QuotaFetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("GithubCopilot/1.0", forHTTPHeaderField: "User-Agent")
        request.addValue("vscode/1.100.0", forHTTPHeaderField: "Editor-Version")
        request.addValue("copilot/1.300.0", forHTTPHeaderField: "Editor-Plugin-Version")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }

        let modelsResponse = try JSONDecoder().decode(CopilotModelsResponse.self, from: data)
        return modelsResponse.data
    }
}
