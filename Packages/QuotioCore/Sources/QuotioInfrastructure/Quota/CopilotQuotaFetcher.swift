import Foundation
import QuotioApplication
import QuotioDomain

public struct CopilotQuotaCredential: Equatable, Sendable {
  public let accessToken: String
  public let canonicalKey: String
  public let aliases: Set<String>

  public init(accessToken: String, canonicalKey: String, aliases: Set<String> = []) {
    self.accessToken = accessToken
    self.canonicalKey = canonicalKey
    self.aliases = aliases
  }
}

public protocol CopilotQuotaCredentialSourcing: Sendable {
  func credentials() async -> [CopilotQuotaCredential]
}

public struct LocalCopilotQuotaCredentialSource: CopilotQuotaCredentialSourcing {
  private let homeDirectory: String

  public init(homeDirectory: String = NSHomeDirectory()) {
    self.homeDirectory = homeDirectory
  }

  public func credentials() async -> [CopilotQuotaCredential] {
    var result = nativeCredentials()
    let directory = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".cli-proxy-api")
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    for file in files
    where file.lastPathComponent.hasPrefix("github-copilot-") && file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let token = Self.string(object["access_token"])
      else { continue }
      let filename = file.lastPathComponent
      let stem = file.deletingPathExtension().lastPathComponent
      let suffix = String(stem.dropFirst("github-copilot-".count))
      let key = Self.string(object["username"]) ?? Self.string(object["login"]) ?? suffix
      result.append(
        .init(accessToken: token, canonicalKey: key, aliases: [filename, stem, suffix]))
    }
    return result
  }

  private func nativeCredentials() -> [CopilotQuotaCredential] {
    var tokens = Set<String>()
    let config = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config")
    for relativePath in ["github-copilot/apps.json", "github-copilot/hosts.json"] {
      let url = config.appendingPathComponent(relativePath)
      guard let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      Self.collectTokens(object, into: &tokens)
    }
    let hosts = config.appendingPathComponent("gh/hosts.yml")
    if let yaml = try? String(contentsOf: hosts, encoding: .utf8) {
      for line in yaml.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "oauth_token",
          let token = Self.string(parts[1])
        else { continue }
        tokens.insert(token)
      }
    }
    return tokens.map { .init(accessToken: $0, canonicalKey: CopilotQuotaFetcher.nativeAccountKey) }
  }

  private static func collectTokens(_ value: Any, into tokens: inout Set<String>) {
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        if ["oauth_token", "oauthToken", "access_token"].contains(key), let token = string(child) {
          tokens.insert(token)
        } else {
          collectTokens(child, into: &tokens)
        }
      }
    } else if let array = value as? [Any] {
      for child in array { collectTokens(child, into: &tokens) }
    }
  }

  private static func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public actor CopilotQuotaFetcher: QuotaFetching {
  public static let nativeAccountKey = "GitHub Copilot"
  public nonisolated let provider = QuotaProvider.copilot

  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let credentials: any CopilotQuotaCredentialSourcing
  private let session: any QuotaHTTPSession
  private let entitlementURL: URL
  private let userURL: URL
  private let now: @Sendable () -> Date

  public init(
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    credentials: any CopilotQuotaCredentialSourcing = LocalCopilotQuotaCredentialSource(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    entitlementURL: URL = URL(string: "https://api.github.com/copilot_internal/user")!,
    userURL: URL = URL(string: "https://api.github.com/user")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.vault = vault
    self.metadata = metadata
    self.credentials = credentials
    self.session = session
    self.entitlementURL = entitlementURL
    self.userURL = userURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    var candidates: [CopilotQuotaCredential] = []
    if request.mode == .monitor {
      let disabled = await metadata.disabledAccountIDs()
      for account in await vault.accounts()
      where account.providerID.rawValue == provider.rawValue && !disabled.contains(account.id) {
        guard let credential = await vault.credential(for: account.id),
          !credential.accessToken.isEmpty
        else { continue }
        candidates.append(
          .init(accessToken: credential.accessToken, canonicalKey: account.accountKey))
      }
    }
    candidates.append(contentsOf: await credentials.credentials())

    var quotas: [String: ProviderQuota] = [:]
    var seenTokens = Set<String>()
    var hasApplicableCredential = false
    var canonicalKeys = Set<String>()
    var canonicalKeysByAlias: [String: Set<String>] = [:]
    for candidate in candidates where seenTokens.insert(candidate.accessToken).inserted {
      var key = candidate.canonicalKey
      if key == Self.nativeAccountKey, let login = await githubLogin(token: candidate.accessToken) {
        key = login
      }
      guard Self.includes(key: key, aliases: candidate.aliases, scope: request.scope) else { continue }
      canonicalKeys.insert(key)
      for alias in candidate.aliases where alias != key {
        canonicalKeysByAlias[alias, default: []].insert(key)
      }
      guard quotas[key] == nil else { continue }
      hasApplicableCredential = true
      let result = await entitlement(token: candidate.accessToken)
      if result.status == 401 || result.status == 403 {
        quotas[key] = ProviderQuota(lastUpdated: now(), isForbidden: true)
      } else if result.status.map({ 200...299 ~= $0 }) == true,
        let data = result.data,
        let entitlement = try? JSONDecoder().decode(Entitlement.self, from: data)
      {
        quotas[key] = Self.map(entitlement, now: now())
      }
    }
    let aliases = canonicalKeysByAlias.compactMapValues { candidates in
      candidates.count == 1 ? candidates.first : nil
    }.filter { alias, _ in
      !canonicalKeys.contains(alias)
    }
    return QuotaProviderOutput(
      quotas: quotas,
      credentialAvailability: hasApplicableCredential ? .present : .missing,
      credentialAccountKeys: canonicalKeys,
      accountAliases: aliases
    )
  }

  private func entitlement(token: String) async -> (data: Data?, status: Int?) {
    var request = URLRequest(url: entitlementURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse
    else { return (nil, nil) }
    return (data, http.statusCode)
  }

  private func githubLogin(token: String) async -> String? {
    var request = URLRequest(url: userURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await session.data(for: request),
      (response as? HTTPURLResponse).map({ 200...299 ~= $0.statusCode }) == true,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["login"] as? String
  }

  private nonisolated static func includes(
    key: String, aliases: Set<String>, scope: QuotaFetchScope
  ) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): key == value || aliases.contains(value)
    case .importedAccounts(let values): values.contains(key) || !aliases.isDisjoint(with: values)
    }
  }

  private nonisolated static func map(_ value: Entitlement, now: Date) -> ProviderQuota {
    let reset = value.resetDate?.ISO8601Format() ?? ""
    var metrics: [QuotaMetric] = []
    if let snapshots = value.quotaSnapshots {
      for (name, snapshot, fallback) in [
        ("copilot-chat", snapshots.chat, 50), ("copilot-completions", snapshots.completions, 2_000),
        ("copilot-premium", snapshots.premiumInteractions, 50),
      ] where snapshot?.unlimited != true {
        guard let snapshot else { continue }
        metrics.append(
          .init(
            name: name, percentage: snapshot.percentage(defaultTotal: fallback), resetTime: reset))
      }
    }
    if metrics.isEmpty, let remaining = value.limitedUserQuotas, let total = value.monthlyQuotas {
      for (name, left, limit) in [
        ("copilot-chat", remaining.chat, total.chat),
        ("copilot-completions", remaining.completions, total.completions),
      ] {
        guard let left, let limit, limit > 0 else { continue }
        metrics.append(
          .init(
            name: name, percentage: min(100, max(0, Double(left) / Double(limit) * 100)),
            resetTime: reset))
      }
    }
    return ProviderQuota(models: metrics, lastUpdated: now, planType: value.planName)
  }
}

private struct Entitlement: Decodable {
  let accessTypeSKU: String?
  let copilotPlan: String?
  let quotaResetDate: String?
  let quotaResetDateUTC: String?
  let limitedUserResetDate: String?
  let quotaSnapshots: Snapshots?
  let limitedUserQuotas: Counts?
  let monthlyQuotas: Counts?

  enum CodingKeys: String, CodingKey {
    case accessTypeSKU = "access_type_sku"
    case copilotPlan = "copilot_plan"
    case quotaResetDate = "quota_reset_date"
    case quotaResetDateUTC = "quota_reset_date_utc"
    case limitedUserResetDate = "limited_user_reset_date"
    case quotaSnapshots = "quota_snapshots"
    case limitedUserQuotas = "limited_user_quotas"
    case monthlyQuotas = "monthly_quotas"
  }

  var resetDate: Date? {
    guard let text = quotaResetDateUTC ?? quotaResetDate ?? limitedUserResetDate else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: text) { return date }
    let dateOnly = DateFormatter()
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.dateFormat = "yyyy-MM-dd"
    return dateOnly.date(from: text)
  }

  var planName: String {
    let sku = accessTypeSKU?.lowercased() ?? ""
    let plan = copilotPlan?.lowercased() ?? ""
    if sku.contains("enterprise") || plan == "enterprise" { return "Enterprise" }
    if sku.contains("business") || plan == "business" { return "Business" }
    if sku.contains("educational") || sku.contains("pro") || plan.contains("pro")
      || (plan == "individual" && !sku.contains("free_limited"))
    {
      return "Pro"
    }
    if sku.contains("free_limited") || sku == "free" || plan.contains("free") { return "Free" }
    return copilotPlan ?? accessTypeSKU ?? "Unknown"
  }
}

private struct Snapshots: Decodable {
  let chat: Snapshot?
  let completions: Snapshot?
  let premiumInteractions: Snapshot?
  enum CodingKeys: String, CodingKey {
    case chat, completions
    case premiumInteractions = "premium_interactions"
  }
}

private struct Snapshot: Decodable {
  let entitlement: Int?
  let remaining: Int?
  let percentRemaining: Double?
  let unlimited: Bool?
  enum CodingKeys: String, CodingKey {
    case entitlement, remaining, unlimited
    case percentRemaining = "percent_remaining"
  }
  func percentage(defaultTotal: Int) -> Double {
    if let percentRemaining { return min(100, max(0, percentRemaining)) }
    let total = entitlement ?? defaultTotal
    return total > 0 ? min(100, max(0, Double(remaining ?? 0) / Double(total) * 100)) : 0
  }
}

private struct Counts: Decodable {
  let chat: Int?
  let completions: Int?
}
