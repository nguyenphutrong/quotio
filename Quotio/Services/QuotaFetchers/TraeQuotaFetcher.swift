//
//  TraeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Trae (ByteDance) using stored auth tokens
//  Reads auth from Trae's storage.json file
//  Supports both the international edition (Trae) and the China edition (Trae CN),
//  which is a separate app with its own Application Support directory and API host.
//

import Foundation

/// Describes an installable Trae edition (international or China).
/// Both editions share the same storage.json auth blob format;
/// the install/storage paths, API host fallback, quota endpoints and web origin differ.
nonisolated struct TraeVariantDescriptor: Sendable, Equatable {
    /// Provider identity used for quota bookkeeping and persistence keys
    let provider: AIProvider
    /// User-facing name, e.g. "Trae" / "Trae CN"
    let displayName: String
    /// App bundle name inside /Applications, e.g. "Trae CN.app"
    let appBundleName: String
    /// Directory name under ~/Library/Application Support, e.g. "Trae CN"
    let applicationSupportDirectory: String
    /// API host used when the auth blob does not carry a "host" field.
    ///
    /// `nil` means "no verified fallback exists": the edition is only queried when the
    /// blob names its own host, rather than guessing one.
    let defaultAPIHost: String?
    /// Quota endpoints to try, in order. The first one that returns a parsable
    /// entitlement response wins.
    let quotaEndpointPaths: [String]
    /// Web origin sent as Origin/Referer headers
    let webOrigin: String

    /// storage.json location holding the iCubeAuthInfo auth blob
    var storageJsonPath: String {
        "~/Library/Application Support/\(applicationSupportDirectory)/User/globalStorage/storage.json"
    }

    /// Candidate install locations for the app bundle
    var appPaths: [String] {
        [
            "/Applications/\(appBundleName)",
            NSString(string: "~/Applications/\(appBundleName)").expandingTildeInPath
        ]
    }

    /// Account key used when the auth blob has no email/username/userId
    var fallbackAccountKey: String { "\(displayName) User" }

    /// International edition (trae.ai)
    static let international = TraeVariantDescriptor(
        provider: .trae,
        displayName: "Trae",
        appBundleName: "Trae.app",
        applicationSupportDirectory: "Trae",
        defaultAPIHost: "https://api-sg-central.trae.ai",
        quotaEndpointPaths: ["trae/api/v1/pay/user_current_entitlement_list"],
        webOrigin: "https://www.trae.ai"
    )

    /// China edition — ships as "Trae CN.app" (bundle id `cn.trae.app`) with its own
    /// "~/Library/Application Support/Trae CN" directory and homepage www.trae.com.cn
    /// (Homebrew cask `trae-cn`).
    ///
    /// `defaultAPIHost` is deliberately `nil`. No public source confirms which API host a
    /// Trae CN install talks to (`api.trae.cn` and `api.trae.com.cn` both appear in
    /// third-party host allow-lists), so the host is taken from the auth blob's `host`
    /// field — which is what both reference implementations do — instead of being guessed.
    ///
    /// The endpoint order is likewise taken from public CN integrations rather than
    /// inherited from the international edition: koi128bit/WorkBuddy-Switch calls
    /// `trae/api/v2/pay/ide_user_ent_usage` with a v1 fallback. The international v1
    /// entitlement endpoint is kept last so an install that only answers there still works.
    static let cn = TraeVariantDescriptor(
        provider: .traeCn,
        displayName: "Trae CN",
        appBundleName: "Trae CN.app",
        applicationSupportDirectory: "Trae CN",
        defaultAPIHost: nil,
        quotaEndpointPaths: [
            "trae/api/v2/pay/ide_user_ent_usage",
            "trae/api/v1/pay/ide_user_ent_usage",
            "trae/api/v1/pay/user_current_entitlement_list"
        ],
        webOrigin: "https://www.trae.com.cn"
    )
}

/// Overrides the on-disk locations a `TraeQuotaFetcher` inspects.
///
/// Only used by tests, so the real scan (storage read → envelope decode → account
/// extraction) can run against a fixture instead of requiring a Trae install.
nonisolated struct TraeScanPathOverrides: Sendable {
    let storageJSONPath: String
    let appPaths: [String]

    init(storageJSONPath: String, appPaths: [String]) {
        self.storageJSONPath = storageJSONPath
        self.appPaths = appPaths
    }
}

/// Auth data from Trae's storage.json
nonisolated struct TraeAuthData: Sendable {
    let accessToken: String?
    let refreshToken: String?
    let email: String?
    let userId: String?
    let apiHost: String?
    let username: String?
}

/// Quota info from Trae API
nonisolated struct TraeQuotaInfo: Sendable {
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
    private var session: URLSession
    private let variant: TraeVariantDescriptor
    private let pathOverrides: TraeScanPathOverrides?
    private let authKey = "iCubeAuthInfo://icube.cloudide"

    /// How many times this fetcher has attempted to open the edition's storage.json.
    ///
    /// Exposed so the explicit-scan consent tests (issue #29) can assert that an ordinary
    /// refresh never touches `~/Library/Application Support/Trae CN/...` before opt-in.
    private(set) var storageReadAttemptCount = 0

    init(
        variant: TraeVariantDescriptor = .international,
        pathOverrides: TraeScanPathOverrides? = nil
    ) {
        self.variant = variant
        self.pathOverrides = pathOverrides
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }
    
    /// Check if this Trae edition is installed
    func isInstalled() async -> Bool {
        for path in pathOverrides?.appPaths ?? variant.appPaths {
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

    /// Read auth data from this edition's storage.json
    func readAuthFromStorageJson() -> TraeAuthData? {
        storageReadAttemptCount += 1

        let expandedPath = pathOverrides?.storageJSONPath
            ?? NSString(string: variant.storageJsonPath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }

        guard let data = FileManager.default.contents(atPath: expandedPath),
              let storageJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Get the auth info string from storage.json. Current clients store it as an
        // encrypted envelope; older ones stored plaintext JSON. Both are handled here.
        guard let authInfoString = storageJson[authKey] as? String,
              let authInfo = try? TraeAuthEnvelope.decodeAuthInfo(authInfoString) else {
            return nil
        }

        return Self.makeAuthData(from: authInfo)
    }

    /// Map a decoded `iCubeAuthInfo` object onto `TraeAuthData`.
    ///
    /// Field names are shared by both editions and match the two reference
    /// implementations cited in `TraeAuthEnvelope`.
    nonisolated static func makeAuthData(from authInfo: [String: Any]) -> TraeAuthData? {
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

    /// Resolve the API base URL for a request.
    ///
    /// The auth blob's own `host` field wins — that is how Trae itself routes, and how
    /// both reference implementations resolve the host. `defaultAPIHost` is only a
    /// fallback for editions where a host is actually known; for Trae CN it is `nil`, so a
    /// blob without a host yields `nil` rather than a guessed endpoint.
    ///
    /// The result must be an https URL under a Trae domain, so a tampered storage.json
    /// cannot redirect the bearer token to an arbitrary server.
    nonisolated static func resolveAPIHost(
        authHost: String?,
        variant: TraeVariantDescriptor
    ) -> String? {
        let candidate = authHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (candidate?.isEmpty == false ? candidate : nil) ?? variant.defaultAPIHost
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if !value.contains("://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              Self.allowedAPIHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else {
            return nil
        }
        return value
    }

    /// Domains a Trae auth blob may point the quota request at.
    private static let allowedAPIHostSuffixes = ["trae.ai", "trae.cn", "trae.com.cn"]
    
    /// Fetch quota from Trae API
    func fetchQuota() async -> TraeQuotaInfo? {
        guard let authData = readAuthFromStorageJson(),
              let accessToken = authData.accessToken else {
            return nil
        }

        // Host comes from the auth blob; there is no guessed fallback for editions whose
        // API host has not been verified (Trae CN).
        guard let apiHost = Self.resolveAPIHost(authHost: authData.apiHost, variant: variant) else {
            return nil
        }

        // Try the edition's endpoints in order; the first parsable response wins.
        for path in variant.quotaEndpointPaths {
            guard let quotaURL = URL(string: "\(apiHost)/\(path)") else { continue }

            var request = URLRequest(url: quotaURL)
            request.httpMethod = "POST"
            request.setValue("Cloud-IDE-JWT \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue(variant.webOrigin, forHTTPHeaderField: "Origin")
            request.setValue(variant.webOrigin + "/", forHTTPHeaderField: "Referer")

            // Request body
            let body = ["require_usage": true]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }

                if let info = Self.parseQuotaResponse(data, authData: authData) {
                    return info
                }
            } catch {
                continue
            }
        }

        return nil
    }

    /// Parse quota API response.
    ///
    /// `user_current_entitlement_list` returns the packs under `user_entitlement_pack_list`.
    /// The `ide_user_ent_usage` endpoints return the same pack objects (identified by their
    /// `entitlement_base_info` + `usage` members) but the key that holds them is not
    /// documented, so they are also collected structurally — the same approach
    /// koi128bit/WorkBuddy-Switch takes.
    nonisolated static func parseQuotaResponse(_ data: Data, authData: TraeAuthData) -> TraeQuotaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let entitlementList = (json["user_entitlement_pack_list"] as? [[String: Any]])
            ?? entitlementPacks(in: json)
        guard !entitlementList.isEmpty else {
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
    
    /// Collect entitlement packs from an arbitrary response body by shape.
    ///
    /// A pack is any object carrying both `entitlement_base_info` and `usage`.
    private nonisolated static func entitlementPacks(in value: Any) -> [[String: Any]] {
        var result: [[String: Any]] = []
        collectEntitlementPacks(value, into: &result)
        return result
    }

    private nonisolated static func collectEntitlementPacks(
        _ value: Any,
        into result: inout [[String: Any]]
    ) {
        if let object = value as? [String: Any] {
            if object["entitlement_base_info"] != nil, object["usage"] != nil {
                result.append(object)
                return
            }
            for child in object.values {
                collectEntitlementPacks(child, into: &result)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectEntitlementPacks(child, into: &result)
            }
        }
    }

    /// Parse a single entitlement object
    private nonisolated static func parseEntitlement(_ entitlement: [String: Any], authData: TraeAuthData, resetTime: Date?) -> TraeQuotaInfo {
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
        return Self.makeProviderQuota(info: info, variant: variant)
    }

    /// Map a parsed quota response onto the account-keyed data the UI displays.
    nonisolated static func makeProviderQuota(
        info: TraeQuotaInfo,
        variant: TraeVariantDescriptor
    ) -> [String: ProviderQuotaData] {
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
            let percentage = min(100, max(0, Double(remaining) / Double(info.premiumFastLimit) * 100))
            
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
            let percentage = min(100, max(0, Double(remaining) / Double(info.premiumSlowLimit) * 100))
            
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
            let percentage = min(100, max(0, Double(remaining) / Double(info.advancedModelLimit) * 100))
            
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
            let percentage = min(100, max(0, Double(remaining) / Double(info.autoCompletionLimit) * 100))
            
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
        
        let email = info.email ?? info.username ?? info.userId ?? variant.fallbackAccountKey
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: info.planType
        )
        
        return [email: quotaData]
    }
}
