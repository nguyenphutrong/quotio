import CryptoKit
import Foundation

nonisolated struct AmpNativeCredential: Sendable, Equatable {
    let apiKey: String
    let sourcePath: String
}

nonisolated enum AmpNativeCredentialReader {
    static let defaultPath = "~/.local/share/amp/secrets.json"

    static func load(path: String = defaultPath) -> AmpNativeCredential? {
        let expandedPath = MonitorIdentity.expand(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        for key in ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"] {
            if let apiKey = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !apiKey.isEmpty {
                return AmpNativeCredential(apiKey: apiKey, sourcePath: expandedPath)
            }
        }
        return nil
    }
}

nonisolated enum AmpQuotaParser {
    static func map(data: Data, statusCode: Int, now: Date = Date()) -> ProviderQuotaData? {
        if statusCode == 401 || statusCode == 403 { return ProviderQuotaData(isForbidden: true) }
        guard 200...299 ~= statusCode,
              let response = try? JSONDecoder().decode(AmpBalanceResponse.self, from: data) else { return nil }
        if response.error?.code == "auth-required" {
            return ProviderQuotaData(isForbidden: true)
        }
        guard response.ok != false, let text = response.result?.displayText else { return nil }
        return parse(displayText: text, now: now)
    }

    static func parse(displayText: String, now: Date = Date()) -> ProviderQuotaData? {
        let text = displayText.replacingOccurrences(
            of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        var models: [ModelQuota] = []

        let identity = captures(
            #"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#,
            in: text
        )

        var freeModel: ModelQuota?
        let freeDollarPattern = #"(?im)^\s*Amp Free:\s*\$?([\d,]+(?:\.\d+)?)\s*/\s*\$?([\d,]+(?:\.\d+)?)\s+remaining(?:\s*\(replenishes\s*\+\$?([\d,]+(?:\.\d+)?)\s*/\s*hour\))?"#
        if let match = captures(freeDollarPattern, in: text),
           let remaining = dollars(match[0]),
           let limit = dollars(match[1]),
           limit > 0,
           remaining >= 0,
           remaining <= limit {
            let used = limit - remaining
            let hourly = dollars(match[2]) ?? 0
            let reset = hourly > 0
                ? ISO8601DateFormatter().string(from: now.addingTimeInterval(used / hourly * 3600))
                : ""
            freeModel = ModelQuota(
                name: "amp-free",
                percentage: remaining / limit * 100,
                resetTime: reset,
                presentation: .progress(used: used, limit: limit, unit: .usd)
            )
        } else if let match = captures(
            #"(?im)^\s*Amp Free:\s*([\d.]+)%\s+remaining(?:\s+today)?(?:\s*\(resets\s+daily\))?"#,
            in: text
        ), let remaining = validPercentage(match[0]) {
            freeModel = ModelQuota(
                name: "amp-free",
                percentage: remaining,
                resetTime: nextMidnightUTC(after: now)
            )
        }

        var plan = identity.flatMap { $0[1].isEmpty ? nil : $0[1] }
        if let subscription = captures(
            #"(?im)^\s*Amp\s+([^:\r\n]+?)\s+Subscription:\s*([\d.]+)%\s+(?:other|agent)\s+usage\s+and\s+([\d.]+)%\s+orb\s+usage\s+remaining\b(?:\s*-\s*resets\s+upon\s+renewal\s+in\s+(\d+)\s+(minutes?|hours?|days?|weeks?|months?|years?))?"#,
            in: text
        ), let agent = validPercentage(subscription[1]),
           let orb = validPercentage(subscription[2]) {
            plan = subscription[0]
            let resetTime = relativeResetTime(value: subscription[3], unit: subscription[4], after: now)
            models.append(ModelQuota(name: "amp-agent-usage", percentage: agent, resetTime: resetTime))
            models.append(ModelQuota(name: "amp-orb-usage", percentage: orb, resetTime: resetTime))
        } else {
            for match in allCaptures(
                #"(?im)^\s*(agent|other|orb)(?:\s+(?:usage|quota))?\s*:\s*([\d.]+)%"#,
                in: text
            ) {
                guard let remaining = validPercentage(match[1]) else { continue }
                let name = match[0].lowercased() == "orb" ? "amp-orb-usage" : "amp-agent-usage"
                if !models.contains(where: { $0.name == name }) {
                    models.append(ModelQuota(name: name, percentage: remaining, resetTime: ""))
                }
            }
        }

        if let freeModel { models.append(freeModel) }

        if let match = captures(
            #"(?im)^\s*Individual credits:\s*\$?([\d,]+(?:\.\d+)?)\s+remaining"#,
            in: text
        ), let value = dollars(match[0]) {
            models.append(amount(name: "amp-individual-credits", value: value))
        }
        for match in allCaptures(
            #"(?im)^\s*Workspace\s+(.+?):\s*\$?([\d,]+(?:\.\d+)?)\s+remaining"#,
            in: text
        ) {
            guard let value = dollars(match[1]) else { continue }
            models.append(ModelQuota(
                name: "amp-workspace-" + stableID(match[0]),
                percentage: -1,
                resetTime: "",
                presentation: .amount(value: value, unit: .usd, semantics: .balance),
                tooltip: match[0]
            ))
        }

        guard !models.isEmpty else { return nil }
        return ProviderQuotaData(models: models, lastUpdated: now, planType: plan, accountDisplayName: identity?.first)
    }

    private static func amount(name: String, value: Double) -> ModelQuota {
        ModelQuota(name: name, percentage: -1, resetTime: "", presentation: .amount(value: value, unit: .usd, semantics: .balance))
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : String(text[Range(range, in: text)!])
        }
    }

    private static func allCaptures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                let capture = match.range(at: index)
                return capture.location == NSNotFound ? "" : String(text[Range(capture, in: text)!])
            }
        }
    }

    private static func dollars(_ value: String) -> Double? { Double(value.replacingOccurrences(of: ",", with: "")) }
    private static func validPercentage(_ value: String) -> Double? {
        guard let percentage = Double(value), 0...100 ~= percentage else { return nil }
        return percentage
    }
    private static func nextMidnightUTC(after date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start)!
        return ISO8601DateFormatter().string(from: next)
    }
    private static func relativeResetTime(value: String, unit: String, after date: Date) -> String {
        guard let value = Int(value) else { return "" }

        let component: Calendar.Component
        switch unit.lowercased() {
        case "minute", "minutes": component = .minute
        case "hour", "hours": component = .hour
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        case "month", "months": component = .month
        case "year", "years": component = .year
        default: return ""
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let resetDate = calendar.date(byAdding: component, value: value, to: date) else { return "" }
        return ISO8601DateFormatter().string(from: resetDate)
    }
    private static func stableID(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated struct AmpBalanceResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable { let displayText: String? }
    struct APIError: Decodable, Sendable {
        let code: String?
        let message: String?
    }
    let ok: Bool?
    let result: Result?
    let error: APIError?
}

final class AmpNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor AmpQuotaFetcher {
    static let localAccountKey = "amp:native"

    private let vault: MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private let nativePath: String
    private let delegate = AmpNoRedirectDelegate()
    private var session: URLSession

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared,
        nativePath: String = AmpNativeCredentialReader.defaultPath
    ) {
        self.vault = vault
        self.metadata = metadata
        self.nativePath = nativePath
        session = Self.makeSession(delegate: delegate)
    }

    func updateProxyConfiguration() { session = Self.makeSession(delegate: delegate) }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var quotas: [String: ProviderQuotaData] = [:]
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        let localAccount = Self.localAccount(provider: .amp, sourcePath: nativePath)
        if !disabledAccountIDs.contains(localAccount.id),
           let native = AmpNativeCredentialReader.load(path: nativePath),
           let quota = await fetch(apiKey: native.apiKey) {
            quotas[Self.localAccountKey] = quota
        }
        for account in await vault.accounts()
        where account.provider == .amp && !disabledAccountIDs.contains(account.id) {
            guard let credential = await vault.credential(for: account.id), let quota = await fetch(apiKey: credential.accessToken) else { continue }
            quotas[account.accountKey] = quota
        }
        return quotas
    }

    func fetchQuota(accountKey: String) async -> ProviderQuotaData? {
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        let localAccount = Self.localAccount(provider: .amp, sourcePath: nativePath)
        if accountKey == Self.localAccountKey,
           !disabledAccountIDs.contains(localAccount.id),
           let native = AmpNativeCredentialReader.load(path: nativePath) {
            return await fetch(apiKey: native.apiKey)
        }
        guard let account = await vault.accounts().first(where: {
            $0.provider == .amp
                && $0.accountKey == accountKey
                && !disabledAccountIDs.contains($0.id)
        }),
              let credential = await vault.credential(for: account.id) else { return nil }
        return await fetch(apiKey: credential.accessToken)
    }

    nonisolated static func localAccount(provider: AIProvider, sourcePath: String = AmpNativeCredentialReader.defaultPath) -> MonitorAccount {
        .make(provider: provider, accountKey: localAccountKey, displayName: "Amp", source: .nativeCredential,
              credentialReference: MonitorIdentity.expand(sourcePath))
    }

    nonisolated static func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        return request
    }

    nonisolated static func sessionConfiguration() -> URLSessionConfiguration {
        let proxied = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = proxied.timeoutIntervalForRequest
        configuration.connectionProxyDictionary = proxied.connectionProxyDictionary
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    private func fetch(apiKey: String) async -> ProviderQuotaData? {
        guard let (data, response) = try? await session.data(for: Self.request(apiKey: apiKey)),
              let http = response as? HTTPURLResponse else { return nil }
        return AmpQuotaParser.map(data: data, statusCode: http.statusCode)
    }

    private nonisolated static func makeSession(delegate: AmpNoRedirectDelegate) -> URLSession {
        URLSession(configuration: sessionConfiguration(), delegate: delegate, delegateQueue: nil)
    }
}
