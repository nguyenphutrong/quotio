import Foundation
import SQLite3

nonisolated struct DevinCredential: Sendable, Equatable {
    let apiKey: String
    let apiServerURL: String?
}

nonisolated enum DevinQuotaMapper {
    static func map(_ data: Data) -> ProviderQuotaData? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userStatus = root["userStatus"] as? [String: Any] else { return nil }

        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let hideDaily = bool(planInfo["hideDailyQuota"]) == true
        let dailyRemaining = number(planStatus["dailyQuotaRemainingPercent"])
        let weeklyRemaining = number(planStatus["weeklyQuotaRemainingPercent"])
        let dailyReset = hideDaily ? "" : resetTime(planStatus["dailyQuotaResetAtUnix"])
        let weeklyReset = resetTime(planStatus["weeklyQuotaResetAtUnix"])
        var models: [ModelQuota] = []

        if !hideDaily, let dailyRemaining {
            models.append(ModelQuota(
                name: "devin-daily",
                percentage: clamp(dailyRemaining),
                resetTime: dailyReset
            ))
        }
        if let weeklyRemaining {
            models.append(ModelQuota(
                name: "devin-weekly",
                percentage: clamp(weeklyRemaining),
                resetTime: weeklyReset
            ))
        } else if hideDaily, let dailyRemaining {
            models.append(ModelQuota(
                name: "devin-weekly",
                percentage: clamp(dailyRemaining),
                resetTime: weeklyReset
            ))
        }
        if let micros = number(planStatus["overageBalanceMicros"]) {
            models.append(ModelQuota(
                name: "devin-extra-balance",
                percentage: -1,
                resetTime: "",
                presentation: .amount(
                    value: max(0, micros) / 1_000_000,
                    unit: .usd,
                    semantics: .balance
                )
            ))
        }

        guard !models.isEmpty else { return nil }
        let plan = trimmed(planInfo["planName"] as? String)
        return ProviderQuotaData(models: models, lastUpdated: Date(), planType: plan)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return Bool(value)
        default: return nil
        }
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(100, value)) }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func resetTime(_ value: Any?) -> String {
        guard let seconds = number(value) else { return "" }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }
}

actor DevinQuotaFetcher {
    static let credentialsPath = "~/.local/share/devin/credentials.toml"
    static let stateDBPath = "~/Library/Application Support/Devin/User/globalStorage/state.vscdb"
    static let defaultAPIServerURL = "https://server.codeium.com"

    private var session: URLSession

    init() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        let candidates = [loadCredentialsFile(), Self.loadAppCredential()].compactMap { $0 }
        var rejectedCredential: ProviderQuotaData?
        for credential in candidates {
            if let quota = await fetchQuota(credential: credential) {
                if quota.isForbidden {
                    rejectedCredential = quota
                    continue
                }
                return ["Devin": quota]
            }
        }
        if let rejectedCredential {
            return ["Devin": rejectedCredential]
        }
        return [:]
    }

    nonisolated static func quotaResult(data: Data, statusCode: Int) -> ProviderQuotaData? {
        if statusCode == 401 || statusCode == 403 {
            return ProviderQuotaData(isForbidden: true)
        }
        guard 200...299 ~= statusCode else { return nil }
        return DevinQuotaMapper.map(data)
    }

    private func fetchQuota(credential: DevinCredential) async -> ProviderQuotaData? {
        let server = credential.apiServerURL ?? Self.defaultAPIServerURL
        guard let url = URL(string: server + "/exa.seat_management_pb.SeatManagementService/GetUserStatus") else {
            return nil
        }
        let body: [String: Any] = [
            "metadata": [
                "apiKey": credential.apiKey,
                "ideName": "devin",
                "ideVersion": "1.108.2",
                "extensionName": "devin",
                "extensionVersion": "1.108.2",
                "locale": "en"
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        guard let (responseData, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return Self.quotaResult(data: responseData, statusCode: http.statusCode)
    }

    nonisolated static func parseCredentialsTOML(_ text: String) -> DevinCredential? {
        guard let apiKey = tomlString(text, key: "windsurf_api_key") else { return nil }
        let server = tomlString(text, key: "api_server_url").flatMap(cleanServerURL)
        return DevinCredential(apiKey: apiKey, apiServerURL: server)
    }

    private func loadCredentialsFile() -> DevinCredential? {
        let path = MonitorIdentity.expand(Self.credentialsPath)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Self.parseCredentialsTOML(text)
    }

    nonisolated static func loadAppCredential(path: String = MonitorIdentity.expand(stateDBPath)) -> DevinCredential? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        let text = String(cString: value)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = trimmed(object["apiKey"] as? String) else { return nil }
        return DevinCredential(apiKey: apiKey, apiServerURL: nil)
    }

    private nonisolated static func tomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines) == key else { continue }
            var value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let comment = value.firstIndex(of: "#") { value = value[..<comment].trimmingCharacters(in: .whitespacesAndNewlines) }
            if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private nonisolated static func cleanServerURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://") else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private nonisolated static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
