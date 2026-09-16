import Foundation
import QuotioApplication
import QuotioDomain

struct QuotioCLIUsageReport: Decodable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let providers: [QuotioCLIProviderUsage]
    let failures: [QuotioCLIUsageFailure]
}

struct QuotioCLIProviderUsage: Decodable, Sendable {
    struct Identity: Decodable, Sendable {
        let id: String
        let label: String
        let plan: String?
    }

    let provider: String
    let account: Identity
    let accountRef: QuotioCLIAccountReference?
    let windows: [QuotioCLIUsageWindow]
    let antigravitySubscription: QuotioCLISubscription?
}

struct QuotioCLIAccountReference: Decodable, Sendable {
    let origin: String?
    let id: String
    let label: String
}

struct QuotioCLIUsageWindow: Decodable, Sendable {
    struct Quota: Decodable, Sendable {
        let state: String
        let remainingPercent: Double?
        let amount: Double?
        let unit: String?
    }

    struct Amounts: Decodable, Sendable {
        let remaining: Double
        let limit: Double?
        let unit: String
    }

    struct Consumption: Decodable, Sendable {
        let used: Double
        let unit: String
    }

    let label: String
    let metricId: String?
    let quota: Quota
    let amounts: Amounts?
    let consumption: Consumption?
    let resetsAt: Date?
    let resetDescription: String?
    let fetchedAt: Date
    let note: String?
}

struct QuotioCLIUsageFailure: Decodable, Sendable {
    let provider: String
    let accountRef: QuotioCLIAccountReference?
    let code: String
}

struct QuotioCLISubscription: Decodable, Sendable {
    struct Tier: Decodable, Sendable {
        let id: String?
        let name: String?
        let description: String?
    }

    let currentTier: Tier?
    let paidTier: Tier?
}

struct QuotioCLIAccountList: Decodable, Sendable {
    let schemaVersion: Int
    let accounts: [QuotioCLIAccount]
}

struct QuotioCLIAccount: Decodable, Sendable {
    let id: String
    let provider: String
    let label: String
    let origin: String
    let enabled: Bool
    let sourceKind: String?
}

struct QuotioCLIOperation: Decodable, Sendable {
    let id: String
    let status: String
    let error: String?
}

struct QuotioCLIOAuthSession: Decodable, Sendable {
    let provider: String
    let workflow: String
    let userCode: String?
    let id: String
    let url: String
    let status: String
    let accountId: String?
    let errorCode: String?
}

enum QuotioCLIProviderMap {
    static func domain(_ id: String) -> QuotaProvider? {
        switch id {
        case "copilot": .copilot
        case "factory": .factoryDroid
        case "zai": .glm
        case "vertexai": .vertex
        case "devin-desktop": .devin
        default: QuotaProvider(rawValue: id)
        }
    }

    static func cli(_ provider: QuotaProvider) -> String? {
        switch provider {
        case .copilot: "copilot"
        case .factoryDroid: "factory"
        case .glm: "zai"
        case .vertex: "vertexai"
        case .devin: "devin-desktop"
        case .qwen, .iflow, .trae: nil
        default: provider.rawValue
        }
    }
}

enum QuotioCLIUsageMapper {
    static func snapshot(_ report: QuotioCLIUsageReport) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(lastUpdated: report.generatedAt)
        for usage in report.providers {
            guard let provider = QuotioCLIProviderMap.domain(usage.provider) else { continue }
            let key = usage.account.label.isEmpty ? usage.account.id : usage.account.label
            snapshot.quotas[provider, default: [:]][key] = quota(usage)
            if let reference = usage.accountRef {
                snapshot.accountAliases[provider, default: [:]][reference.id] = key
                snapshot.accountAliases[provider, default: [:]][reference.label] = key
            }
            if let subscription = subscription(usage) {
                snapshot.subscriptions[provider, default: [:]][key] = subscription
            }
        }
        for failure in report.failures {
            guard let provider = QuotioCLIProviderMap.domain(failure.provider) else { continue }
            let issue = QuotaRefreshIssue(kind: .failed, occurredAt: report.generatedAt)
            if let account = failure.accountRef {
                snapshot.accountIssues[QuotaAccountID(provider: provider, accountKey: account.label)] = issue
            } else {
                snapshot.issues[provider] = issue
            }
        }
        return snapshot
    }

    private static func quota(_ usage: QuotioCLIProviderUsage) -> ProviderQuota {
        ProviderQuota(
            models: usage.windows.map { metric($0, provider: usage.provider) },
            lastUpdated: usage.windows.map(\.fetchedAt).min() ?? .distantPast,
            planType: usage.account.plan,
            accountDisplayName: usage.account.label
        )
    }

    private static func metric(_ window: QuotioCLIUsageWindow, provider: String) -> QuotaMetric {
        let percentage = switch window.quota.state {
        case "available", "exhausted":
            window.quota.remainingPercent.flatMap {
                $0.isFinite && (0...100).contains($0) ? $0 : nil
            } ?? -1.0
        default: -1.0
        }
        var presentation: QuotaMetricPresentation?
        switch window.quota.state {
        case "unlimited": presentation = .status(text: "Unlimited")
        case "disabled": presentation = .status(text: "Disabled")
        case "limit":
            if let amount = window.quota.amount {
                presentation = .status(text: "\(amount.formatted()) \(window.quota.unit ?? "") cap")
            }
        default: break
        }
        if presentation == nil,
           let amounts = window.amounts,
           let unit = QuotaMetricUnit(rawValue: amounts.unit.lowercased()) {
            if let limit = amounts.limit, limit > 0, percentage >= 0 {
                presentation = .progress(
                    used: max(0, limit - amounts.remaining),
                    limit: limit,
                    unit: unit
                )
            } else {
                presentation = .amount(value: amounts.remaining, unit: unit, semantics: .balance)
            }
        } else if presentation == nil,
                  let consumption = window.consumption,
                  let unit = QuotaMetricUnit(rawValue: consumption.unit.lowercased()) {
            presentation = .amount(value: consumption.used, unit: unit, semantics: .spent)
        }
        let reset = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return QuotaMetric(
            name: metricName(window, provider: provider),
            percentage: percentage,
            resetTime: reset,
            presentation: presentation,
            tooltip: [window.note, window.resetDescription]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
    }

    private static func metricName(_ window: QuotioCLIUsageWindow, provider: String) -> String {
        if provider == "codex" {
            let labels = [
                "Session": "codex-session",
                "Weekly": "codex-weekly",
                "Codex Spark Session": "codex-spark",
                "Codex Spark Weekly": "codex-spark-weekly",
            ]
            if let name = labels[window.label] { return name }
            let metrics = [
                "gpt-reserve-session": "codex-base-model-session",
                "gpt-reserve-weekly": "codex-base-model-limit",
            ]
            if let id = window.metricId, let name = metrics[id] { return name }
        }
        return window.metricId ?? window.label
    }

    private static func subscription(_ usage: QuotioCLIProviderUsage) -> QuotaSubscriptionInfo? {
        guard let subscription = usage.antigravitySubscription else { return nil }
        func tier(_ value: QuotioCLISubscription.Tier?) -> QuotaSubscriptionTier? {
            value.map {
                QuotaSubscriptionTier(
                    id: $0.id ?? "unknown",
                    name: $0.name ?? "Unknown",
                    description: $0.description ?? "",
                    privacyNotice: nil,
                    isDefault: nil,
                    upgradeSubscriptionUri: nil,
                    upgradeSubscriptionText: nil,
                    upgradeSubscriptionType: nil,
                    userDefinedCloudaicompanionProject: nil
                )
            }
        }
        return QuotaSubscriptionInfo(
            currentTier: tier(subscription.currentTier),
            allowedTiers: nil,
            cloudaicompanionProject: nil,
            gcpManaged: nil,
            upgradeSubscriptionUri: nil,
            paidTier: tier(subscription.paidTier)
        )
    }
}

func makeQuotioCLIDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid RFC3339 timestamp")
            )
        }
        return date
    }
    return decoder
}
