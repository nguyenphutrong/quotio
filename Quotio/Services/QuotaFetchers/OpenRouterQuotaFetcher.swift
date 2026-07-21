import Foundation

nonisolated struct OpenRouterEndpointResult: Sendable {
    let data: Data?
    let statusCode: Int?

    var succeeded: Bool {
        guard let statusCode else { return false }
        return 200...299 ~= statusCode && data != nil
    }

    var isAuthenticationFailure: Bool {
        statusCode == 401 || statusCode == 403
    }
}

nonisolated enum OpenRouterQuotaMapper {
    static func map(
        credits: OpenRouterEndpointResult,
        key: OpenRouterEndpointResult,
        now: Date = Date()
    ) -> ProviderQuotaData? {
        guard credits.succeeded || key.succeeded else {
            if credits.isAuthenticationFailure || key.isAuthenticationFailure {
                return ProviderQuotaData(isForbidden: true)
            }
            return nil
        }

        var models: [ModelQuota] = []
        var plan: String?

        if let data = credits.data, credits.succeeded,
           let body = object(data) {
            let payload = dictionary(body["data"]) ?? body
            let purchased = max(0, number(payload["total_credits"]) ?? 0)
            if let spentValue = number(payload["total_usage"]) {
                let spent = max(0, spentValue)
                if purchased > 0 {
                    models.append(ModelQuota(
                        name: "openrouter-credits",
                        percentage: remainingPercentage(used: spent, limit: purchased),
                        resetTime: "",
                        presentation: .progress(used: spent, limit: purchased, unit: .usd)
                    ))
                }
                models.append(amount("openrouter-balance", value: max(0, purchased - spent), semantics: .balance))
            } else if let balance = number(payload["balance"]) {
                models.append(amount("openrouter-balance", value: balance, semantics: .balance))
            }
        }

        if let data = key.data, key.succeeded,
           let body = object(data) {
            let payload = dictionary(body["data"]) ?? body
            let isFree = bool(payload["is_free_tier"])
            plan = (isFree == true ? "openrouter.plan.freeTier" : "openrouter.plan.payAsYouGo").localizedStatic()
            for (name, field) in [
                ("openrouter-today", "usage_daily"),
                ("openrouter-week", "usage_weekly"),
                ("openrouter-month", "usage_monthly"),
            ] {
                if let value = number(payload[field]) {
                    models.append(amount(name, value: max(0, value), semantics: .spent))
                }
            }
            if let limit = number(payload["limit"]), limit > 0 {
                let used = number(payload["usage"]) ?? max(0, limit - (number(payload["limit_remaining"]) ?? limit))
                models.append(ModelQuota(
                    name: "openrouter-key-limit",
                    percentage: remainingPercentage(used: used, limit: limit),
                    resetTime: "",
                    presentation: .progress(used: used, limit: limit, unit: .usd)
                ))
            }
        }

        guard !models.isEmpty else { return ProviderQuotaData(models: [], lastUpdated: now, planType: plan) }
        return ProviderQuotaData(models: models, lastUpdated: now, planType: plan)
    }

    private static func amount(_ name: String, value: Double, semantics: QuotaAmountSemantics) -> ModelQuota {
        ModelQuota(
            name: name,
            percentage: -1,
            resetTime: "",
            presentation: .amount(value: value, unit: .usd, semantics: semantics)
        )
    }

    private static func remainingPercentage(used: Double, limit: Double) -> Double {
        max(0, min(100, (limit - used) / limit * 100))
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: Bool(value)
        default: nil
        }
    }
}

actor OpenRouterQuotaFetcher {
    private let vault: MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private var session: URLSession
    private let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    private let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared
    ) {
        self.vault = vault
        self.metadata = metadata
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        for account in await vault.accounts()
        where account.provider == .openRouter && !disabledAccountIDs.contains(account.id) {
            guard let credential = await vault.credential(for: account.id) else { continue }
            async let credits = fetch(creditsURL, apiKey: credential.accessToken)
            async let key = fetch(keyURL, apiKey: credential.accessToken)
            if let quota = OpenRouterQuotaMapper.map(credits: await credits, key: await key) {
                results[account.accountKey] = quota
            }
        }
        return results
    }

    private func fetch(_ url: URL, apiKey: String) async -> OpenRouterEndpointResult {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return OpenRouterEndpointResult(data: nil, statusCode: nil)
        }
        return OpenRouterEndpointResult(data: data, statusCode: http.statusCode)
    }
}
