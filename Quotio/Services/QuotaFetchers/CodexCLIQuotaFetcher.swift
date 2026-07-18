//
//  CodexCLIQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Codex CLI by reading ~/.codex/auth.json and calling ChatGPT usage API
//  Used in Quota-Only mode for direct quota tracking without proxy
//

import Foundation

/// Auth file structure for Codex CLI (~/.codex/auth.json)
nonisolated struct CodexCLIAuthFile: Codable, Sendable {
    var OPENAI_API_KEY: String?
    var tokens: CodexCLITokens?
    var lastRefresh: String?
    
    enum CodingKeys: String, CodingKey {
        case OPENAI_API_KEY
        case tokens
        case lastRefresh = "last_refresh"
    }
}

nonisolated struct CodexCLITokens: Codable, Sendable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var accountId: String?
    
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}

/// Decoded JWT claims from Codex id_token
nonisolated struct CodexJWTClaims: Sendable {
    let email: String?
    let emailVerified: Bool
    let planType: String?
    let accountId: String?
    let userId: String?
    let organizationName: String?
    let subscriptionActiveUntil: Date?
}

/// Fetches quota from Codex CLI auth file
actor CodexCLIQuotaFetcher {
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let refreshURL = "https://auth.openai.com/oauth/token"
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    
    private var session: URLSession
    
    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

#if DEBUG
    private func debugMask(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<nil>" }
        if value.count <= 8 { return "\(value) (len=\(value.count))" }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)…\(suffix) (len=\(value.count))"
    }
#endif

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }
    
    private var authFilePaths: [String] {
        var paths: [String] = []
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            paths.append((home as NSString).appendingPathComponent("auth.json"))
        }
        paths.append(NSString(string: "~/.config/codex/auth.json").expandingTildeInPath)
        paths.append(NSString(string: "~/.codex/auth.json").expandingTildeInPath)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Check if any supported Codex auth source exists.
    func isAuthFilePresent() -> Bool {
        authFilePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
    
    /// Read auth file from ~/.codex/auth.json
    func readAuthFile() -> CodexCLIAuthFile? {
        for path in authFilePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data),
                  auth.tokens?.accessToken?.isEmpty == false else { continue }
            return auth
        }
        return nil
    }

    private func readAuthSources() -> [(path: String, auth: CodexCLIAuthFile)] {
        authFilePaths.compactMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data),
                  auth.tokens?.accessToken?.isEmpty == false else { return nil }
            return (path, auth)
        }
    }
    
    /// Decode JWT to extract email and plan info
    func decodeJWT(token: String) -> CodexJWTClaims? {
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
        
        // Extract email
        let email = json["email"] as? String
        let emailVerified = json["email_verified"] as? Bool ?? false
        
        // Extract plan info from nested auth object
        var planType: String? = nil
        var accountId: String? = nil
        var userId: String? = nil
        var orgName: String? = nil
        var subscriptionUntil: Date? = nil
        
        if let authInfo = json["https://api.openai.com/auth"] as? [String: Any] {
            planType = authInfo["chatgpt_plan_type"] as? String
            accountId = authInfo["chatgpt_account_id"] as? String
            userId = authInfo["chatgpt_user_id"] as? String
            
            // Parse organizations
            if let orgs = authInfo["organizations"] as? [[String: Any]], let firstOrg = orgs.first {
                orgName = firstOrg["title"] as? String
            }
            
            // Parse subscription end date
            if let untilStr = authInfo["chatgpt_subscription_active_until"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                subscriptionUntil = formatter.date(from: untilStr)
            }
        }
        
        return CodexJWTClaims(
            email: email,
            emailVerified: emailVerified,
            planType: planType,
            accountId: accountId,
            userId: userId,
            organizationName: orgName,
            subscriptionActiveUntil: subscriptionUntil
        )
    }
    
    /// Fetch quota from ChatGPT usage API
    func fetchQuota(accessToken: String, accountId: String?, identity: CodexQuotaIdentity) async throws -> ProviderQuotaData {
        guard let url = URL(string: usageURL) else {
            throw CodexCLIQuotaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.addValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
#if DEBUG
        Log.quota("GET \(usageURL) accountId=\(debugMask(accountId))")
#endif
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexCLIQuotaError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.httpError(httpResponse.statusCode)
        }
        
        var quotaData = try CodexUsageMapper.map(data: data, identity: identity)
#if DEBUG
        Log.quota("plan_type=\(quotaData.planType ?? "<nil>")")
#endif
        if let resetCreditAnalytics = await fetchResetCreditAnalytics(accessToken: accessToken, accountId: accountId) {
            quotaData.analytics = CodexResetCreditInventoryFetcher.merge(
                resetCreditAnalytics,
                into: quotaData.analytics
            )
        }
        if let profileAnalytics = await fetchProfileAnalytics(accessToken: accessToken, accountId: accountId) {
            quotaData.analytics = quotaData.analytics?.merging(profileAnalytics) ?? profileAnalytics
        }
        return quotaData
    }

    private func fetchResetCreditAnalytics(accessToken: String, accountId: String?) async -> QuotaAnalytics? {
        do {
            return try await CodexResetCreditInventoryFetcher(urlSession: session).fetchAnalytics(
                accessToken: accessToken,
                accountID: accountId
            )
        } catch {
            Log.quota("Failed to fetch Codex reset credit inventory: \(error)")
            return nil
        }
    }

    private func fetchProfileAnalytics(accessToken: String, accountId: String?) async -> QuotaAnalytics? {
        do {
            return try await CodexProfileAnalyticsFetcher(urlSession: session).fetch(
                accessToken: accessToken,
                accountID: accountId
            )
        } catch {
            Log.quota("Failed to fetch Codex profile analytics: \(error)")
            return nil
        }
    }
    
    /// Refresh access token using refresh token
    nonisolated struct TokenRefresh: Sendable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Int?
    }

    func refreshAccessToken(refreshToken: String) async throws -> TokenRefresh {
        var request = URLRequest(url: URL(string: refreshURL)!)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "client_id=\(clientID.urlFormEncoded)",
            "refresh_token=\(refreshToken.urlFormEncoded)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.tokenRefreshFailed
        }
        
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Int?
        }
        
        let tokenResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return TokenRefresh(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            idToken: tokenResponse.id_token,
            expiresIn: tokenResponse.expires_in
        )
    }
    
    /// Check if access token is expired by decoding JWT
    func isTokenExpired(accessToken: String) -> Bool {
        let segments = accessToken.split(separator: ".")
        guard segments.count >= 2 else { return true }
        
        var base64 = String(segments[1])
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }
        
        // Refresh five minutes early so scheduled quota checks do not race token expiry.
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(300)
    }
    
    /// Fetch quota and convert to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        var results = await fetchOwnedQuotas()
        for (key, quota) in await fetchNativeKeychainQuotas() where results[key] == nil {
            results[key] = quota
        }
        for source in readAuthSources() {
            guard let tokens = source.auth.tokens, let originalAccessToken = tokens.accessToken else { continue }
            var email = "Codex User"
            var planType: String?
            var accountId = tokens.accountId
            if let idToken = tokens.idToken, let claims = decodeJWT(token: idToken) {
                email = claims.email ?? email
                planType = claims.planType
                accountId = accountId ?? claims.accountId
            }

            var accessToken = originalAccessToken
            var refreshToken = tokens.refreshToken
            if isTokenExpired(accessToken: accessToken), let currentRefresh = refreshToken {
                do {
                    let refreshed = try await refreshAccessToken(refreshToken: currentRefresh)
                    accessToken = refreshed.accessToken
                    refreshToken = refreshed.refreshToken ?? currentRefresh
                    try persistRefresh(refreshed, originalRefreshToken: currentRefresh, path: source.path)
                } catch {
                    Log.quota("Failed to refresh Codex token")
                }
            }

            do {
                let quota: ProviderQuotaData
                do {
                    quota = try await fetchQuota(
                        accessToken: accessToken,
                        accountId: accountId,
                        identity: CodexQuotaIdentity(planType: planType)
                    )
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    let latestTokens = readAuthFile(at: source.path)?.tokens
                    let currentRefresh = latestTokens?.refreshToken ?? refreshToken
                    guard let currentRefresh else { throw CodexCLIQuotaError.tokenRefreshFailed }
                    let latestClaims = latestTokens?.idToken.flatMap(decodeJWT)
                    let refreshed = try await refreshAccessToken(refreshToken: currentRefresh)
                    try persistRefresh(refreshed, originalRefreshToken: currentRefresh, path: source.path)
                    quota = try await fetchQuota(
                        accessToken: refreshed.accessToken,
                        accountId: latestTokens?.accountId ?? latestClaims?.accountId ?? accountId,
                        identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? planType)
                    )
                }
#if DEBUG
                Log.quota("finalPlan=\(quota.planType ?? "<nil>") jwt=\(planType ?? "<nil>")")
#endif
                if results[email] == nil { results[email] = quota }
            } catch {
                Log.quota("Failed to fetch Codex quota for local credential: \(error.localizedDescription)")
            }
        }
        for (key, quota) in await fetchLegacyQuotas() where results[key] == nil {
            results[key] = quota
        }
        return results
    }

    private func fetchLegacyQuotas() async -> [String: ProviderQuotaData] {
        let directory = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var results: [String: ProviderQuotaData] = [:]

        for filename in files where filename.hasPrefix("codex-") && filename.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { continue }
            let claims = auth.idToken.flatMap(decodeJWT)
            let key = nonEmpty(auth.email)
                ?? nonEmpty(claims?.email)
                ?? nonEmpty(auth.accountId)
                ?? filename.codexFilenameKey
            let accountID = auth.accountId ?? claims?.accountId
            let identity = CodexQuotaIdentity(planType: claims?.planType)
            var accessToken = auth.accessToken
            var refreshToken = auth.refreshToken

            if isTokenExpired(accessToken: accessToken), let currentRefreshToken = refreshToken {
                if let refreshed = try? await refreshAccessToken(refreshToken: currentRefreshToken) {
                    accessToken = refreshed.accessToken
                    self.persistLegacyRefresh(refreshed, originalRefreshToken: currentRefreshToken, path: path)
                    refreshToken = refreshed.refreshToken ?? currentRefreshToken
                }
            }

            do {
                do {
                    results[key] = try await fetchQuota(accessToken: accessToken, accountId: accountID, identity: identity)
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    guard let latestData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                          let latest = try? JSONDecoder().decode(CodexAuthFile.self, from: latestData),
                          let latestRefreshToken = latest.refreshToken ?? refreshToken else { continue }
                    let latestClaims = latest.idToken.flatMap(decodeJWT)
                    let refreshed = try await refreshAccessToken(refreshToken: latestRefreshToken)
                    persistLegacyRefresh(refreshed, originalRefreshToken: latestRefreshToken, path: path)
                    results[key] = try await fetchQuota(
                        accessToken: refreshed.accessToken,
                        accountId: latest.accountId ?? latestClaims?.accountId ?? accountID,
                        identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType)
                    )
                }
            } catch {
                Log.quota("Failed to fetch Codex quota for legacy credential: \(error.localizedDescription)")
            }
        }
        return results
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fetchNativeKeychainQuotas() async -> [String: ProviderQuotaData] {
        guard let record = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth"),
              var auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
              var tokens = auth.tokens,
              var accessToken = tokens.accessToken else { return [:] }
        let claims = tokens.idToken.flatMap(decodeJWT)
        let key = claims?.email ?? tokens.accountId ?? "Codex"
        do {
            if isTokenExpired(accessToken: accessToken), let refresh = tokens.refreshToken {
                let refreshed = try await refreshAccessToken(refreshToken: refresh)
                accessToken = refreshed.accessToken
                tokens.accessToken = refreshed.accessToken
                tokens.refreshToken = refreshed.refreshToken ?? refresh
                tokens.idToken = refreshed.idToken ?? tokens.idToken
                auth.tokens = tokens
                if let data = try? JSONEncoder().encode(auth) {
                    _ = KeychainHelper.compareAndSwapExternalCredential(
                        service: "Codex Auth",
                        account: record.account,
                        expectedData: record.data,
                        newData: data
                    )
                }
            }
            do {
                return [key: try await fetchQuota(
                    accessToken: accessToken,
                    accountId: tokens.accountId ?? claims?.accountId,
                    identity: CodexQuotaIdentity(planType: claims?.planType)
                )]
            } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                guard let latest = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth", account: record.account),
                      let latestAuth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: latest.data),
                      let latestTokens = latestAuth.tokens,
                      let refresh = latestTokens.refreshToken else { return [:] }
                let latestClaims = latestTokens.idToken.flatMap(decodeJWT)
                let refreshed = try await refreshAccessToken(refreshToken: refresh)
                persistNativeKeychainRefresh(refreshed, originalRefreshToken: refresh, account: record.account)
                return [key: try await fetchQuota(
                    accessToken: refreshed.accessToken,
                    accountId: latestTokens.accountId ?? latestClaims?.accountId,
                    identity: CodexQuotaIdentity(planType: latestClaims?.planType)
                )]
            }
        } catch {
            return [:]
        }
    }

    private func persistNativeKeychainRefresh(
        _ refreshed: TokenRefresh,
        originalRefreshToken: String,
        account: String
    ) {
        guard let latest = KeychainHelper.readExternalCredentialRecord(service: "Codex Auth", account: account),
              var auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: latest.data),
              var tokens = auth.tokens,
              tokens.refreshToken == originalRefreshToken else { return }
        tokens.accessToken = refreshed.accessToken
        tokens.refreshToken = refreshed.refreshToken ?? originalRefreshToken
        tokens.idToken = refreshed.idToken ?? tokens.idToken
        auth.tokens = tokens
        guard let data = try? JSONEncoder().encode(auth) else { return }
        _ = KeychainHelper.compareAndSwapExternalCredential(
            service: "Codex Auth",
            account: account,
            expectedData: latest.data,
            newData: data
        )
    }

    private func fetchOwnedQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for account in await MonitorCredentialVault.shared.accounts().filter({ $0.provider == .codex && !$0.isDisabled }) {
            guard var credential = await MonitorCredentialVault.shared.credential(for: account.id) else { continue }
            do {
                if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? isTokenExpired(accessToken: credential.accessToken),
                   let refresh = credential.refreshToken {
                    let refreshed = try await refreshAccessToken(refreshToken: refresh)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refresh
                    credential.idToken = refreshed.idToken ?? credential.idToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await MonitorCredentialVault.shared.save(credential, metadata: account)
                }
                let claims = credential.idToken.flatMap(decodeJWT)
                do {
                    results[account.accountKey] = try await fetchQuota(
                        accessToken: credential.accessToken,
                        accountId: credential.accountID ?? claims?.accountId,
                        identity: CodexQuotaIdentity(planType: claims?.planType)
                    )
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    if let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id) {
                        credential = latest
                    }
                    guard let refresh = credential.refreshToken else { throw CodexCLIQuotaError.tokenRefreshFailed }
                    let refreshed = try await refreshAccessToken(refreshToken: refresh)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refresh
                    credential.idToken = refreshed.idToken ?? credential.idToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await MonitorCredentialVault.shared.save(credential, metadata: account)
                    results[account.accountKey] = try await fetchQuota(
                        accessToken: credential.accessToken,
                        accountId: credential.accountID ?? claims?.accountId,
                        identity: CodexQuotaIdentity(planType: claims?.planType)
                    )
                }
            } catch {
                Log.quota("Failed to fetch Codex quota for Quotio credential")
            }
        }
        return results
    }

    private func persistRefresh(_ refreshed: TokenRefresh, originalRefreshToken: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let currentData = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              var tokenJSON = json["tokens"] as? [String: Any],
              tokenJSON["refresh_token"] as? String == originalRefreshToken else {
            return
        }
        tokenJSON["access_token"] = refreshed.accessToken
        tokenJSON["refresh_token"] = refreshed.refreshToken ?? originalRefreshToken
        if let idToken = refreshed.idToken { tokenJSON["id_token"] = idToken }
        json["tokens"] = tokenJSON
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try SecureAtomicFileWriter.write(data, to: url)
    }

    private func persistLegacyRefresh(_ refreshed: TokenRefresh, originalRefreshToken: String, path: String) {
        let url = URL(fileURLWithPath: path)
        guard let currentData = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              json["refresh_token"] as? String == originalRefreshToken else { return }
        json["access_token"] = refreshed.accessToken
        json["refresh_token"] = refreshed.refreshToken ?? originalRefreshToken
        if let idToken = refreshed.idToken { json["id_token"] = idToken }
        let lifetime = TimeInterval(refreshed.expiresIn ?? 3600)
        json["expired"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(lifetime))
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? SecureAtomicFileWriter.write(data, to: url)
    }

    private func readAuthFile(at path: String) -> CodexCLIAuthFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data)
    }
}

private extension String {
    nonisolated var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

// MARK: - Errors

nonisolated enum CodexCLIQuotaError: LocalizedError {
    case invalidResponse
    case invalidURL
    case httpError(Int)
    case noAccessToken
    case tokenRefreshFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from ChatGPT"
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noAccessToken: return "No access token found in Codex auth file"
        case .tokenRefreshFailed: return "Failed to refresh Codex token"
        }
    }
}
