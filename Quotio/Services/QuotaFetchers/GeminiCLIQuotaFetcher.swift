//
//  GeminiCLIQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches Gemini CLI quota through CLIProxyAPI's management proxy when available,
//  and falls back to account detection from ~/.gemini/oauth_creds.json.
//

import Foundation

/// Auth file structure for Gemini CLI (~/.gemini/oauth_creds.json)
nonisolated struct GeminiCLIAuthFile: Codable, Sendable {
    let idToken: String?
    let accessToken: String?
    let scope: String?
    let refreshToken: String?
    let tokenType: String?
    let expiryDate: Double?
    
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case scope
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiryDate = "expiry_date"
    }
}

/// Google accounts file structure (~/.gemini/google_accounts.json)
nonisolated struct GeminiAccountsFile: Codable, Sendable {
    let active: String?
    let old: [String]?
}

/// Decoded JWT claims from Gemini id_token
nonisolated struct GeminiJWTClaims: Sendable {
    let email: String?
    let emailVerified: Bool
    let name: String?
    let givenName: String?
    let familyName: String?
    let subject: String?
}

/// Account info from Gemini CLI
nonisolated struct GeminiCLIAccountInfo: Sendable {
    let email: String
    let name: String?
    let isActive: Bool
    let expiryDate: Date?
}

/// Fetches account info from Gemini CLI auth file
actor GeminiCLIQuotaFetcher {
    private let authFilePath = "~/.gemini/oauth_creds.json"
    private let accountsFilePath = "~/.gemini/google_accounts.json"
    private let executor = CLIExecutor.shared
    private let quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private let codeAssistURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private let requestHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json"
    ]

    private struct ParsedBucket: Sendable {
        let modelId: String
        let tokenType: String?
        let remainingFraction: Double?
        let remainingAmount: Double?
        let resetTime: String?
    }

    private struct BucketGroupDefinition: Sendable {
        let id: String
        let label: String
        let preferredModelId: String?
        let modelIds: [String]
    }

    private struct BucketGroupState: Sendable {
        var id: String
        var label: String
        var tokenType: String?
        var modelIds: [String]
        var preferredModelId: String?
        var preferredBucket: ParsedBucket?
        var fallbackRemainingFraction: Double?
        var fallbackRemainingAmount: Double?
        var fallbackResetTime: String?
    }

    private let quotaGroups: [BucketGroupDefinition] = [
        BucketGroupDefinition(
            id: "gemini-flash-lite-series",
            label: "Gemini Flash Lite Series",
            preferredModelId: "gemini-2.5-flash-lite",
            modelIds: ["gemini-2.5-flash-lite"]
        ),
        BucketGroupDefinition(
            id: "gemini-flash-series",
            label: "Gemini Flash Series",
            preferredModelId: "gemini-3-flash-preview",
            modelIds: ["gemini-3-flash-preview", "gemini-2.5-flash"]
        ),
        BucketGroupDefinition(
            id: "gemini-pro-series",
            label: "Gemini Pro Series",
            preferredModelId: "gemini-3.1-pro-preview",
            modelIds: ["gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-2.5-pro"]
        )
    ]

    // Note: Gemini CLI interactions are handled by the executor, which spawns processes.
    // The current CLIExecutor implementation does not seem to support explicit proxy configuration
    // for the executed commands.
    // However, if we were making HTTP requests here, we would use ProxyConfigurationService.

    /// Update the URLSession with current proxy settings
    /// (No-op for now as Gemini CLI uses shell commands, but kept for protocol conformance)
    func updateProxyConfiguration() {
        // Future: If GeminiFetcher starts making direct HTTP calls, update session here
    }

    /// Check if Gemini CLI is installed
    func isInstalled() async -> Bool {
        return await executor.isCLIInstalled(name: "gemini")
    }
    
    /// Check if Gemini auth file exists
    func isAuthFilePresent() -> Bool {
        let expandedPath = NSString(string: authFilePath).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expandedPath)
    }
    
    /// Read OAuth credentials from ~/.gemini/oauth_creds.json
    func readAuthFile() -> GeminiCLIAuthFile? {
        let expandedPath = NSString(string: authFilePath).expandingTildeInPath
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        
        return try? JSONDecoder().decode(GeminiCLIAuthFile.self, from: data)
    }
    
    /// Read accounts file from ~/.gemini/google_accounts.json
    func readAccountsFile() -> GeminiAccountsFile? {
        let expandedPath = NSString(string: accountsFilePath).expandingTildeInPath
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        
        return try? JSONDecoder().decode(GeminiAccountsFile.self, from: data)
    }
    
    /// Decode JWT to extract email and name info
    func decodeJWT(token: String) -> GeminiJWTClaims? {
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
        
        return GeminiJWTClaims(
            email: json["email"] as? String,
            emailVerified: json["email_verified"] as? Bool ?? false,
            name: json["name"] as? String,
            givenName: json["given_name"] as? String,
            familyName: json["family_name"] as? String,
            subject: json["sub"] as? String
        )
    }
    
    /// Get account info from auth files
    func getAccountInfo() -> GeminiCLIAccountInfo? {
        guard let authFile = readAuthFile() else { return nil }
        
        // Try to get email from accounts file first
        var email: String? = readAccountsFile()?.active
        var name: String? = nil
        
        // Fall back to JWT if accounts file doesn't have email
        if email == nil, let idToken = authFile.idToken, let claims = decodeJWT(token: idToken) {
            email = claims.email
            name = claims.name
        }
        
        guard let accountEmail = email else { return nil }
        
        var expiryDate: Date? = nil
        if let expiry = authFile.expiryDate {
            expiryDate = Date(timeIntervalSince1970: expiry / 1000) // Convert from milliseconds
        }
        
        return GeminiCLIAccountInfo(
            email: accountEmail,
            name: name,
            isActive: true,
            expiryDate: expiryDate
        )
    }
    
    /// Fetch quota from CLIProxyAPI auth files via the management API.
    func fetchAsProviderQuota(authFiles: [AuthFile], apiClient: ManagementAPIClient?) async -> [String: ProviderQuotaData] {
        guard let apiClient else { return [:] }

        let files = authFiles.filter {
            $0.providerType == .gemini &&
            !$0.disabled &&
            !$0.unavailable &&
            $0.runtimeOnly != true
        }

        guard !files.isEmpty else { return [:] }

        var results: [String: ProviderQuotaData] = [:]
        for file in files {
            guard let authIndex = file.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !authIndex.isEmpty,
                  let projectId = resolveProjectId(from: file) else {
                continue
            }

            do {
                if let quota = try await fetchQuota(authIndex: authIndex, projectId: projectId, apiClient: apiClient) {
                    let accountKey = file.quotaLookupKey.isEmpty ? file.name : file.quotaLookupKey
                    results[accountKey] = quota
                }
            } catch {
                Log.quota("Failed to fetch Gemini CLI quota for \(file.name): \(error.localizedDescription)")
            }
        }

        return results
    }

    /// Fetch account presence as ProviderQuotaData when real quota is unavailable.
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        guard await isInstalled() else { return [:] }
        guard let accountInfo = getAccountInfo() else { return [:] }
        
        // Since Gemini CLI doesn't have a public quota API, we create a placeholder
        // that shows the account is connected but quota is unknown
        let models: [ModelQuota] = [
            ModelQuota(
                name: "gemini-quota",
                percentage: -1, // -1 indicates unknown/unavailable
                resetTime: ""
            )
        ]
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: "Google Account" // We don't know the actual plan type
        )
        
        return [accountInfo.email: quotaData]
    }

    private func fetchQuota(authIndex: String, projectId: String, apiClient: ManagementAPIClient) async throws -> ProviderQuotaData? {
        let requestBody = try jsonString(["project": projectId])
        let response = try await apiClient.apiCall(APICallRequest(
            authIndex: authIndex,
            method: "POST",
            url: quotaURL,
            header: requestHeaders,
            data: requestBody
        ))

        guard 200..<300 ~= response.statusCode,
              let body = response.body,
              let payload = parseJSON(body) else {
            return nil
        }

        let buckets = parseBuckets(from: payload)
        let models = buildModelQuotas(from: buckets)
        guard !models.isEmpty else { return nil }

        let planType = await fetchPlanType(authIndex: authIndex, projectId: projectId, apiClient: apiClient)
        return ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: planType
        )
    }

    private func fetchPlanType(authIndex: String, projectId: String, apiClient: ManagementAPIClient) async -> String? {
        do {
            let body: [String: Any] = [
                "cloudaicompanionProject": projectId,
                "metadata": [
                    "ideType": "IDE_UNSPECIFIED",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI",
                    "duetProject": projectId
                ]
            ]

            let response = try await apiClient.apiCall(APICallRequest(
                authIndex: authIndex,
                method: "POST",
                url: codeAssistURL,
                header: requestHeaders,
                data: try jsonString(body)
            ))

            guard 200..<300 ~= response.statusCode,
                  let responseBody = response.body,
                  let payload = parseJSON(responseBody) else {
                return nil
            }

            return resolveTierLabel(from: payload)
        } catch {
            return nil
        }
    }

    private func parseBuckets(from payload: [String: Any]) -> [ParsedBucket] {
        guard let buckets = payload["buckets"] as? [[String: Any]] else { return [] }

        return buckets.compactMap { bucket in
            guard var modelId = stringValue(bucket["modelId"] ?? bucket["model_id"]) else { return nil }
            if modelId.hasSuffix("_vertex") {
                modelId = String(modelId.dropLast("_vertex".count))
            }

            let remainingFraction = numberValue(bucket["remainingFraction"] ?? bucket["remaining_fraction"])
            let remainingAmount = numberValue(bucket["remainingAmount"] ?? bucket["remaining_amount"])
            let resetTime = stringValue(bucket["resetTime"] ?? bucket["reset_time"])
            let fallbackFraction: Double?
            if remainingFraction == nil {
                if let remainingAmount {
                    fallbackFraction = remainingAmount <= 0 ? 0 : nil
                } else if resetTime != nil {
                    fallbackFraction = 0
                } else {
                    fallbackFraction = nil
                }
            } else {
                fallbackFraction = remainingFraction
            }

            return ParsedBucket(
                modelId: modelId,
                tokenType: stringValue(bucket["tokenType"] ?? bucket["token_type"]),
                remainingFraction: fallbackFraction,
                remainingAmount: remainingAmount,
                resetTime: resetTime
            )
        }
    }

    private func buildModelQuotas(from buckets: [ParsedBucket]) -> [ModelQuota] {
        guard !buckets.isEmpty else { return [] }

        let groupLookup = Dictionary(uniqueKeysWithValues: quotaGroups.flatMap { group in
            group.modelIds.map { ($0, group) }
        })
        let groupOrder = Dictionary(uniqueKeysWithValues: quotaGroups.enumerated().map { ($0.element.id, $0.offset) })
        var grouped: [String: BucketGroupState] = [:]

        for bucket in buckets {
            guard !isIgnoredGeminiModel(bucket.modelId) else { continue }

            let definition = groupLookup[bucket.modelId]
            let groupId = definition?.id ?? bucket.modelId
            let label = definition?.label ?? bucket.modelId
            let tokenType = bucket.tokenType ?? ""
            let mapKey = "\(groupId)::\(tokenType)"

            if grouped[mapKey] == nil {
                grouped[mapKey] = BucketGroupState(
                    id: tokenType.isEmpty ? groupId : "\(groupId)-\(tokenType)",
                    label: label,
                    tokenType: bucket.tokenType,
                    modelIds: [bucket.modelId],
                    preferredModelId: definition?.preferredModelId,
                    preferredBucket: definition?.preferredModelId == bucket.modelId ? bucket : nil,
                    fallbackRemainingFraction: bucket.remainingFraction,
                    fallbackRemainingAmount: bucket.remainingAmount,
                    fallbackResetTime: bucket.resetTime
                )
                continue
            }

            var existing = grouped[mapKey]!
            existing.fallbackRemainingFraction = minNullable(existing.fallbackRemainingFraction, bucket.remainingFraction)
            existing.fallbackRemainingAmount = minNullable(existing.fallbackRemainingAmount, bucket.remainingAmount)
            existing.fallbackResetTime = pickEarlierResetTime(existing.fallbackResetTime, bucket.resetTime)
            if !existing.modelIds.contains(bucket.modelId) {
                existing.modelIds.append(bucket.modelId)
            }
            if existing.preferredModelId == bucket.modelId {
                existing.preferredBucket = bucket
            }
            grouped[mapKey] = existing
        }

        return grouped.values.sorted { lhs, rhs in
            let lhsGroupId = groupId(from: lhs.id, tokenType: lhs.tokenType)
            let rhsGroupId = groupId(from: rhs.id, tokenType: rhs.tokenType)
            let orderDiff = (groupOrder[lhsGroupId] ?? Int.max) - (groupOrder[rhsGroupId] ?? Int.max)
            if orderDiff != 0 { return orderDiff < 0 }
            return (lhs.tokenType ?? "").localizedCaseInsensitiveCompare(rhs.tokenType ?? "") == .orderedAscending
        }.compactMap { group in
            let source = group.preferredBucket
            let remainingFraction = source?.remainingFraction ?? group.fallbackRemainingFraction
            guard let remainingFraction else { return nil }
            let percent = max(0, min(100, remainingFraction * 100))
            let resetTime = source?.resetTime ?? group.fallbackResetTime ?? ""
            return ModelQuota(name: group.label, percentage: percent, resetTime: resetTime)
        }
    }

    private func resolveProjectId(from file: AuthFile) -> String? {
        if let account = file.account,
           let projectId = extractProjectId(from: account) {
            return projectId
        }
        return extractProjectId(from: file.name)
    }

    private func extractProjectId(from value: String) -> String? {
        let pattern = #"\(([^()]+)\)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex.matches(in: value, range: range)
            if let match = matches.last,
               let swiftRange = Range(match.range(at: 1), in: value) {
                let candidate = String(value[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }

        let filenamePattern = #"project-[A-Za-z0-9-]+"#
        if let regex = try? NSRegularExpression(pattern: filenamePattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = regex.firstMatch(in: value, range: range),
               let swiftRange = Range(match.range, in: value) {
                return String(value[swiftRange])
            }
        }

        return nil
    }

    private func resolveTierLabel(from payload: [String: Any]) -> String? {
        let currentTier = payload["currentTier"] as? [String: Any] ?? payload["current_tier"] as? [String: Any]
        let paidTier = payload["paidTier"] as? [String: Any] ?? payload["paid_tier"] as? [String: Any]
        guard let rawId = stringValue(paidTier?["id"] ?? currentTier?["id"]) else { return nil }

        switch rawId.lowercased() {
        case "free-tier": return "Free"
        case "legacy-tier": return "Legacy"
        case "standard-tier": return "Standard"
        case "g1-pro-tier": return "Pro"
        case "g1-ultra-tier": return "Ultra"
        default: return rawId
        }
    }

    private func parseJSON(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("%"), let parsed = Double(trimmed.dropLast()) {
                return parsed / 100
            }
            return Double(trimmed)
        }
        return nil
    }

    private func isIgnoredGeminiModel(_ modelId: String) -> Bool {
        modelId == "gemini-2.0-flash" || modelId.hasPrefix("gemini-2.0-flash-")
    }

    private func minNullable(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }

    private func pickEarlierResetTime(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }

        let formatter = ISO8601DateFormatter()
        let lhsDate = formatter.date(from: lhs)
        let rhsDate = formatter.date(from: rhs)

        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            return lhsDate <= rhsDate ? lhs : rhs
        case (nil, _?):
            return rhs
        default:
            return lhs
        }
    }

    private func groupId(from id: String, tokenType: String?) -> String {
        guard let tokenType, !tokenType.isEmpty else { return id }
        let suffix = "-\(tokenType)"
        return id.hasSuffix(suffix) ? String(id.dropLast(suffix.count)) : id
    }
}
