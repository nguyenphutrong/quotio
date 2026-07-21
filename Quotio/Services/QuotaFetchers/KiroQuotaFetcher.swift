//
//  KiroQuotaFetcher.swift
//  Quotio
//
//  Kiro (AWS CodeWhisperer) Quota Fetcher
//  Implements logic from kiro2api for quota monitoring


import Foundation
import CommonCrypto
import IOKit

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
    // Default region for usage endpoint (most users are on us-east-1)
    private let defaultRegion = "us-east-1"

    // Token refresh endpoint templates - region is dynamically substituted
    // For Google OAuth (Social auth)
    private func socialTokenEndpoint(region: String) -> String {
        "https://prod.\(region).auth.desktop.kiro.dev/refreshToken"
    }

    // For AWS Builder ID / Enterprise (IdC auth)
    private func idcTokenEndpoint(region: String) -> String {
        "https://oidc.\(region).amazonaws.com/token"
    }

    // Usage endpoint - dynamically resolved region
    private func usageEndpoint(region: String) -> String {
        "https://q.\(region).amazonaws.com/getUsageLimits"
    }

    /// Extract region from profileArn (format: arn:aws:codewhisperer:{region}:...)
    private func extractRegionFromProfileArn(_ profileArn: String?) -> String? {
        guard let arn = profileArn, !arn.isEmpty else { return nil }
        let parts = arn.split(separator: ":")
        guard parts.count >= 6,
              parts[0] == "arn",
              parts[2] == "codewhisperer",
              parts[3].contains("-") else { return nil }
        return String(parts[3])
    }

    // Kiro IDE version for User-Agent — keep in sync with Kiro releases
    private let kiroVersion = "0.10.32"
    /// Generate account-based machine ID using clientId/refreshToken, falling back to hardware UUID
    private var machineIdCache: [String: String] = [:]
    private func machineId(for tokenData: AuthTokenData) -> String {
        if let overrideMid = UserDefaults.standard.string(forKey: "KiroMachineId"), overrideMid.count == 64 {
            return overrideMid
        }
        let seed = tokenData.clientId ?? tokenData.refreshToken ?? hardwareUUID
        if let cached = machineIdCache[seed] { return cached }
        let data = Data(seed.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        let id = hash.map { String(format: "%02x", $0) }.joined()
        machineIdCache[seed] = id
        return id
    }

    /// Hardware UUID stable across app launches
    private lazy var hardwareUUID: String = {
        let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }
        if let uuid = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return uuid
        }
        return UUID().uuidString
    }()

    private lazy var darwinVersion: String = {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }()

    private func kiroUserAgent(for tokenData: AuthTokenData) -> String {
        let mid = machineId(for: tokenData)
        return "aws-sdk-js/1.0.0 ua/2.1 os/darwin#\(darwinVersion) lang/js md/nodejs#22.21.1 api/codewhispererruntime#1.0.0 m/N,E KiroIDE-\(kiroVersion)-\(mid)"
    }

    private func kiroAmzUserAgent(for tokenData: AuthTokenData) -> String {
        let mid = machineId(for: tokenData)
        return "aws-sdk-js/1.0.0 KiroIDE-\(kiroVersion)-\(mid)"
    }

    private var session: URLSession
    private let fileManager = FileManager.default

    /// Path to Kiro IDE auth token file
    private let kiroIDEAuthPath = NSString(string: "~/.aws/sso/cache/kiro-auth-token.json").expandingTildeInPath

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 20)
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 20)
        self.session = URLSession(configuration: config)
    }

    /// Scan and fetch quotas for all Kiro auth files
    func fetchAllQuotas(includeMonitorCredentials: Bool = false) async -> [String: ProviderQuotaData] {
        let authService = DirectAuthFileService()
        let kiroFiles = await kiroAuthFiles(using: authService)
        var results = includeMonitorCredentials ? await fetchOwnedQuotas() : [:]

        for authFile in kiroFiles {
            guard let tokenData = await authService.readAuthToken(from: authFile) else { continue }
            let key = authFile.email
                ?? tokenData.extras?["profileArn"]
                ?? authFile.filename.replacingOccurrences(of: ".json", with: "")
            guard results[key] == nil,
                  let quota = await fetchQuota(tokenData: tokenData, filePath: authFile.filePath) else { continue }
            results[key] = quota
        }
        return results
    }

    /// Fetch quota for exactly one canonical Kiro account.
    func fetchQuota(accountKey: String) async -> ProviderQuotaData? {
        if let account = await MonitorCredentialVault.shared.accounts().first(where: {
            $0.provider == .kiro && !$0.isDisabled && $0.accountKey == accountKey
        }) {
            return await fetchOwnedQuota(account: account)
        }

        let authService = DirectAuthFileService()
        for authFile in await kiroAuthFiles(using: authService) {
            guard let tokenData = await authService.readAuthToken(from: authFile) else { continue }
            let key = authFile.email
                ?? tokenData.extras?["profileArn"]
                ?? authFile.filename.replacingOccurrences(of: ".json", with: "")
            guard key == accountKey else { continue }
            return await fetchQuota(tokenData: tokenData, filePath: authFile.filePath)
        }
        return nil
    }

    private func fetchOwnedQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for account in await MonitorCredentialVault.shared.accounts().filter({ $0.provider == .kiro && !$0.isDisabled }) {
            if let quota = await fetchOwnedQuota(account: account) { results[account.accountKey] = quota }
        }
        return results
    }

    private func fetchOwnedQuota(account: MonitorAccount) async -> ProviderQuotaData? {
            guard var credential = await MonitorCredentialVault.shared.credential(for: account.id) else { return nil }
            if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? false {
                guard await refreshOwnedCredential(&credential, account: account) else { return nil }
            }
            var tokenData = ownedTokenData(credential)
            let region = credential.extra["region"] ?? defaultRegion
            var response = await fetchUsageAPI(
                token: credential.accessToken,
                tokenExpiresAt: credential.expiresAt,
                profileArn: credential.extra["profileArn"],
                region: region,
                tokenData: tokenData
            )
            if (response.statusCode == 401 || response.statusCode == 403),
               await reloadAndRefreshOwnedCredential(&credential, account: account) {
                tokenData = ownedTokenData(credential)
                response = await fetchUsageAPI(
                    token: credential.accessToken,
                    tokenExpiresAt: credential.expiresAt,
                    profileArn: credential.extra["profileArn"],
                    region: region,
                    tokenData: tokenData
                )
            }
            return response.quotaData
    }

    private func reloadAndRefreshOwnedCredential(
        _ credential: inout MonitorOAuthCredential,
        account: MonitorAccount
    ) async -> Bool {
        if let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id) {
            credential = latest
        }
        return await refreshOwnedCredential(&credential, account: account)
    }

    private func ownedTokenData(_ credential: MonitorOAuthCredential) -> AuthTokenData {
        AuthTokenData(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt?.ISO8601Format(),
            clientId: credential.extra["clientId"],
            clientSecret: credential.extra["clientSecret"],
            authMethod: credential.extra["authMethod"] ?? "IdC",
            extras: credential.extra
        )
    }

    private func refreshOwnedCredential(
        _ credential: inout MonitorOAuthCredential,
        account: MonitorAccount
    ) async -> Bool {
        guard let refreshToken = credential.refreshToken,
              let clientID = credential.extra["clientId"],
              let clientSecret = credential.extra["clientSecret"] else { return false }
        let region = credential.extra["region"] ?? defaultRegion
        guard let url = URL(string: idcTokenEndpoint(region: region)) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "clientId": clientID,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken,
        ])
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode,
              let token = try? JSONDecoder().decode(KiroTokenResponse.self, from: data) else { return false }
        credential.accessToken = token.accessToken
        credential.refreshToken = token.refreshToken ?? refreshToken
        credential.expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        do {
            try await MonitorCredentialVault.shared.save(credential, metadata: account)
            return true
        } catch {
            return false
        }
    }

    private let refreshBufferSeconds: TimeInterval = 5 * 60  // Refresh 5 minutes before expiry
    
    func refreshAllTokensIfNeeded() async -> Int {
        let authService = DirectAuthFileService()
        let kiroFiles = await kiroAuthFiles(using: authService)

        guard !kiroFiles.isEmpty else {
            return 0
        }

        var refreshedCount = 0

        for authFile in kiroFiles {
            guard let tokenData = await authService.readAuthToken(from: authFile) else {
                continue
            }

            let (needsRefresh, _) = shouldRefreshToken(tokenData)
            if needsRefresh {
                if let _ = await refreshTokenWithExpiry(tokenData: tokenData, filePath: authFile.filePath) {
                    refreshedCount += 1
                }
            }
        }

        return refreshedCount
    }

    private func kiroAuthFiles(using authService: DirectAuthFileService) async -> [DirectAuthFile] {
        var files = await authService.scanAllAuthFiles().filter { $0.provider == .kiro }
        guard fileManager.fileExists(atPath: kiroIDEAuthPath),
              !files.contains(where: { $0.filePath == kiroIDEAuthPath }) else {
            return files
        }

        var email: String?
        var expiry: Date?
        if let data = fileManager.contents(atPath: kiroIDEAuthPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            email = json["email"] as? String
            let rawExpiry = json["expiresAt"] as? String
                ?? json["expires_at"] as? String
                ?? json["expiry"] as? String
            expiry = parseExpiryDate(rawExpiry)
        }
        files.insert(DirectAuthFile(
            id: kiroIDEAuthPath,
            provider: .kiro,
            email: email,
            login: nil,
            expired: expiry,
            accountType: nil,
            filePath: kiroIDEAuthPath,
            source: .nativeCredential,
            filename: URL(fileURLWithPath: kiroIDEAuthPath).lastPathComponent
        ), at: 0)
        return files
    }
    
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
        var currentToken = tokenData.accessToken
        var hasAttemptedRefresh = false
        var tokenExpiresAt: Date? = parseExpiryDate(tokenData.expiresAt)

        let (needsRefresh, _) = shouldRefreshToken(tokenData)
        if needsRefresh {
            if let (refreshed, newExpiry) = await refreshTokenWithExpiry(tokenData: tokenData, filePath: filePath) {
                currentToken = refreshed
                tokenExpiresAt = newExpiry
                hasAttemptedRefresh = true
            } else {
                return ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Token Refresh Failed")],
                    lastUpdated: Date(),
                    isForbidden: true,
                    planType: "Expired",
                    tokenExpiresAt: tokenExpiresAt
                )
            }
        }

        let region = extractRegionFromProfileArn(tokenData.extras?["profileArn"]) ?? tokenData.extras?["region"] ?? defaultRegion
        let profileArn = tokenData.extras?["profileArn"]
        let result = await fetchUsageAPI(token: currentToken, tokenExpiresAt: tokenExpiresAt, profileArn: profileArn, region: region, tokenData: tokenData)

        // Reactive refresh: If 401/403 and haven't tried refresh yet, refresh and retry
        if (result.statusCode == 401 || result.statusCode == 403) && !hasAttemptedRefresh {
            let latestTokenData = await reloadTokenData(at: filePath) ?? tokenData
            if let (refreshed, newExpiry) = await refreshTokenWithExpiry(tokenData: latestTokenData, filePath: filePath) {
                let latestRegion = extractRegionFromProfileArn(latestTokenData.extras?["profileArn"]) ?? latestTokenData.extras?["region"] ?? defaultRegion
                let retryResult = await fetchUsageAPI(token: refreshed, tokenExpiresAt: newExpiry, profileArn: latestTokenData.extras?["profileArn"], region: latestRegion, tokenData: latestTokenData)
                return retryResult.quotaData ?? ProviderQuotaData(models: [], lastUpdated: Date(), isForbidden: true, planType: "Unauthorized", tokenExpiresAt: newExpiry)
            }
        }

        return result.quotaData
    }

    private func reloadTokenData(at filePath: String) async -> AuthTokenData? {
        let source: DirectAuthFile.AuthFileSource = filePath.contains("/.aws/sso/cache/") ? .nativeCredential : .cliProxyApi
        let file = DirectAuthFile(
            id: filePath,
            provider: .kiro,
            email: nil,
            login: nil,
            expired: nil,
            accountType: nil,
            filePath: filePath,
            source: source,
            filename: URL(fileURLWithPath: filePath).lastPathComponent
        )
        return await DirectAuthFileService().readAuthToken(from: file)
    }

    /// Parse expiry date from ISO8601 string
    private func parseExpiryDate(_ expiresAt: String?) -> Date? {
        guard let expiresAt = expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt)
    }
    
    /// Internal struct for API result
    private struct UsageAPIResult {
        let statusCode: Int
        let quotaData: ProviderQuotaData?
        let accountIdentity: String?

        init(
            statusCode: Int,
            quotaData: ProviderQuotaData?,
            accountIdentity: String? = nil
        ) {
            self.statusCode = statusCode
            self.quotaData = quotaData
            self.accountIdentity = accountIdentity
        }
    }

    func authenticatedAccountIdentity(
        accessToken: String,
        expiresAt: Date,
        clientID: String,
        clientSecret: String,
        region: String
    ) async -> String? {
        let tokenData = AuthTokenData(
            accessToken: accessToken,
            refreshToken: nil,
            expiresAt: expiresAt.ISO8601Format(),
            clientId: clientID,
            clientSecret: clientSecret,
            authMethod: "IdC",
            extras: ["region": region]
        )
        return await fetchUsageAPI(
            token: accessToken,
            tokenExpiresAt: expiresAt,
            profileArn: nil,
            region: region,
            tokenData: tokenData
        ).accountIdentity
    }

    private func fetchUsageAPI(token: String, tokenExpiresAt: Date?, profileArn: String?, region: String, tokenData: AuthTokenData) async -> UsageAPIResult {
        guard var components = URLComponents(string: usageEndpoint(region: region)) else {
            return UsageAPIResult(statusCode: 0, quotaData: ProviderQuotaData(
                models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Invalid URL")],
                lastUpdated: Date(), isForbidden: false, planType: "Error", tokenExpiresAt: tokenExpiresAt
            ))
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "origin", value: "AI_EDITOR"),
            URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")
        ]
        if let profileArn = profileArn, !profileArn.isEmpty {
            queryItems.append(URLQueryItem(name: "profileArn", value: profileArn))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            return UsageAPIResult(statusCode: 0, quotaData: ProviderQuotaData(
                models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Invalid URL")],
                lastUpdated: Date(), isForbidden: false, planType: "Error", tokenExpiresAt: tokenExpiresAt
            ))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Headers matching Kiro IDE requests
        let headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Host": "q.\(region).amazonaws.com",
            "User-Agent": kiroUserAgent(for: tokenData),
            "x-amz-user-agent": kiroAmzUserAgent(for: tokenData),
            "amz-sdk-invocation-id": UUID().uuidString.lowercased(),
            "amz-sdk-request": "attempt=1; max=1"
        ]
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return UsageAPIResult(statusCode: 0, quotaData: ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: "Invalid Response Type")],
                    lastUpdated: Date(), isForbidden: false, planType: "Error", tokenExpiresAt: tokenExpiresAt
                ))
            }

            if httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    return UsageAPIResult(statusCode: httpResponse.statusCode, quotaData: nil)
                }
                let errorMsg = "HTTP \(httpResponse.statusCode)"
                return UsageAPIResult(statusCode: httpResponse.statusCode, quotaData: ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: errorMsg)],
                    lastUpdated: Date(), isForbidden: false, planType: "Error", tokenExpiresAt: tokenExpiresAt
                ))
            }

            // Decode response
            do {
                let usageResponse = try JSONDecoder().decode(KiroUsageResponse.self, from: data)
                let planType = usageResponse.subscriptionInfo?.subscriptionTitle ?? "Standard"
                let accountIdentity = [usageResponse.userInfo?.email, usageResponse.userInfo?.userId]
                    .compactMap { value -> String? in
                        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !value.isEmpty else { return nil }
                        return value
                    }
                    .first
                return UsageAPIResult(
                    statusCode: 200,
                    quotaData: convertToQuotaData(usageResponse, planType: planType, tokenExpiresAt: tokenExpiresAt),
                    accountIdentity: accountIdentity
                )
            } catch {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let keys = json.keys.sorted().joined(separator: ",")
                    return UsageAPIResult(statusCode: 200, quotaData: ProviderQuotaData(
                        models: [ModelQuota(name: "Debug: Keys: \(keys)", percentage: 0, resetTime: "Decode Error: \(error.localizedDescription)")],
                        lastUpdated: Date(), isForbidden: false, planType: "Error", tokenExpiresAt: tokenExpiresAt
                    ))
                }
                return UsageAPIResult(statusCode: 200, quotaData: ProviderQuotaData(
                    models: [ModelQuota(name: "Error", percentage: 0, resetTime: error.localizedDescription)],
                    lastUpdated: Date(), isForbidden: false, planType: "Error", tokenExpiresAt: tokenExpiresAt
                ))
            }
        } catch {
            return UsageAPIResult(statusCode: 0, quotaData: ProviderQuotaData(
                models: [ModelQuota(name: "Error", percentage: 0, resetTime: error.localizedDescription)],
                lastUpdated: Date(), isForbidden: false, planType: "Error", tokenExpiresAt: tokenExpiresAt
            ))
        }
    }

    /// Refresh Kiro token based on auth method and persist to disk
    /// Returns tuple of (newAccessToken, newExpiryDate)
    private func refreshTokenWithExpiry(tokenData: AuthTokenData, filePath: String) async -> (String, Date?)? {
        guard let refreshToken = tokenData.refreshToken else {
            return nil
        }

        // Determine auth method: "Social" (Google) or "IdC" (AWS Builder ID)
        // Use case-insensitive comparison since CLIProxyAPI may store as "idc" or "social" (lowercase)
        let authMethod = (tokenData.authMethod ?? "IdC").lowercased()

        if authMethod == "social" {
            let region = tokenData.extras?["region"] ?? defaultRegion
            return await refreshSocialTokenWithExpiry(refreshToken: refreshToken, region: region, filePath: filePath)
        } else {
            return await refreshIdCTokenWithExpiry(tokenData: tokenData, filePath: filePath)
        }
    }

    private func refreshSocialTokenWithExpiry(refreshToken: String, region: String, filePath: String) async -> (String, Date?)? {
        let endpoint = socialTokenEndpoint(region: region)
        guard let url = URL(string: endpoint) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["refreshToken": refreshToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let tokenResponse = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
            let newExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

            await persistRefreshedToken(
                filePath: filePath,
                expectedRefreshToken: refreshToken,
                newAccessToken: tokenResponse.accessToken,
                newRefreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn
            )
            
            await syncToKiroIDEAuthFile(
                expectedRefreshToken: refreshToken,
                newAccessToken: tokenResponse.accessToken,
                newRefreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn
            )

            return (tokenResponse.accessToken, newExpiry)
        } catch {
            return nil
        }
    }

    /// Refresh token for IdC auth (AWS Builder ID / Enterprise) using AWS OIDC endpoint
    /// Supports dynamic region from token data (e.g., ap-northeast-2 for Enterprise users)
    private func refreshIdCTokenWithExpiry(tokenData: AuthTokenData, filePath: String) async -> (String, Date?)? {
        guard let refreshToken = tokenData.refreshToken,
              let clientId = tokenData.clientId,
              let clientSecret = tokenData.clientSecret else {
            return nil
        }
        
        // Use region from token data, fallback to us-east-1
        let region = tokenData.extras?["region"] ?? defaultRegion
        let endpoint = idcTokenEndpoint(region: region)
        
        guard let url = URL(string: endpoint) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("oidc.\(region).amazonaws.com", forHTTPHeaderField: "Host")
        request.addValue("keep-alive", forHTTPHeaderField: "Connection")
        request.addValue("aws-sdk-js/3.980.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.980.0 m/E KiroIDE", forHTTPHeaderField: "x-amz-user-agent")
        request.addValue("*/*", forHTTPHeaderField: "Accept")
        request.addValue("*", forHTTPHeaderField: "Accept-Language")
        request.addValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.addValue("node", forHTTPHeaderField: "User-Agent")

        let body: [String: String] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let tokenResponse = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
            let newExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

            // Persist to Quotio's auth file
            await persistRefreshedToken(
                filePath: filePath,
                expectedRefreshToken: refreshToken,
                newAccessToken: tokenResponse.accessToken,
                newRefreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn
            )
            
            // Also sync to Kiro IDE auth file if it exists
            await syncToKiroIDEAuthFile(
                expectedRefreshToken: refreshToken,
                newAccessToken: tokenResponse.accessToken,
                newRefreshToken: tokenResponse.refreshToken,
                expiresIn: tokenResponse.expiresIn
            )

            return (tokenResponse.accessToken, newExpiry)
        } catch {
            return nil
        }
    }
    
    /// Sync refreshed token to Kiro IDE auth file (~/.aws/sso/cache/kiro-auth-token.json)
    /// This keeps Kiro IDE in sync when Quotio refreshes the token
    private func syncToKiroIDEAuthFile(
        expectedRefreshToken: String,
        newAccessToken: String,
        newRefreshToken: String?,
        expiresIn: Int
    ) async {
        guard fileManager.fileExists(atPath: kiroIDEAuthPath),
              let existingData = fileManager.contents(atPath: kiroIDEAuthPath),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            return
        }
        let latestRefresh = json["refreshToken"] as? String ?? json["refresh_token"] as? String
        guard latestRefresh == expectedRefreshToken else { return }
        
        // Kiro IDE uses camelCase keys (accessToken, refreshToken, expiresAt)
        json["accessToken"] = newAccessToken
        if let newRefresh = newRefreshToken {
            json["refreshToken"] = newRefresh
        }
        
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        json["expiresAt"] = formatter.string(from: newExpiresAt)
        
        do {
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try SecureAtomicFileWriter.write(updatedData, to: URL(fileURLWithPath: kiroIDEAuthPath))
        } catch {
            // Silent failure - Kiro IDE will refresh on its own if needed
        }
    }

    /// Persist refreshed token back to the auth file on disk
    private func persistRefreshedToken(
        filePath: String,
        expectedRefreshToken: String,
        newAccessToken: String,
        newRefreshToken: String?,
        expiresIn: Int
    ) async {
        guard let existingData = fileManager.contents(atPath: filePath),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            return
        }
        let latestRefresh = json["refresh_token"] as? String ?? json["refreshToken"] as? String
        guard latestRefresh == expectedRefreshToken else { return }

        json["access_token"] = newAccessToken
        if let newRefresh = newRefreshToken {
            json["refresh_token"] = newRefresh
        }

        // Calculate new expiry time - ALWAYS use UTC for consistency
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        json["expires_at"] = formatter.string(from: newExpiresAt)
        json["last_refresh"] = formatter.string(from: Date())

        do {
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try SecureAtomicFileWriter.write(updatedData, to: URL(fileURLWithPath: filePath))
        } catch {
            // Silent failure - token will be refreshed again on next request
        }
    }

    /// Convert Kiro response to standard Quota Data
    private func convertToQuotaData(_ response: KiroUsageResponse, planType: String, tokenExpiresAt: Date?) -> ProviderQuotaData {
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
                        percentage = min(100, max(0, (total - used) / total * 100))
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
                if regularTotal > 0 {
                    var percentage: Double = 0
                    percentage = min(100, max(0, (regularTotal - regularUsed) / regularTotal * 100))

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
            planType: planType,
            tokenExpiresAt: tokenExpiresAt
        )
    }
}
