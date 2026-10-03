import Foundation
import QuotioApplication
import QuotioDomain

/// Muse Code (Meta) subscription quota.
///
/// The credential comes from the auth file CLIProxyAPI writes after a Meta login
/// (`meta-<email>-<hash>.json`), the same place every other proxy-backed provider keeps
/// its account. That file carries both the Meta account access token and the `LLM|`
/// Model API key the proxy sends to `api.meta.ai/v1`; only the account token is read
/// here, because only it can read subscription usage.
///
/// Reading the file rather than the Muse Code CLI's keychain item is deliberate. Meta's
/// CLI does not list Quotio in that item's access control, so asking macOS for its data
/// is refused with `errSecAuthFailed` unless the user grants access to each signed build
/// by hand. The proxy login sidesteps that entirely: one browser device code, and the
/// credential lands in a file Quotio can read in both operating modes, with no prompt.
///
/// Meta publishes no quota endpoint. The one machine-readable snapshot is the
/// `subs_usage` object returned by the subscription-key endpoint, which makes a refresh
/// an auth-plane POST rather than a metered inference call. That endpoint is rate
/// limited, so successful reads are spaced and failures back off; both bounds hold for a
/// forced refresh, and the previous reading is served while a bound runs.
public actor MuseQuotaFetcher: QuotaFetching {
  /// One Meta account, as the proxy's auth file describes it.
  ///
  /// The token carried here is the Device Client Access token (`dca:…`), which is the
  /// one the subscription-key endpoint accepts. The `access_token` field of that file
  /// holds the `LLM|` Model API key instead — same value as `api_key` — and that key
  /// authenticates model calls, not this endpoint.
  public struct Credential: Sendable, Equatable {
    public let accountKey: String
    public let displayName: String?
    public let dcaToken: String

    public init(accountKey: String, displayName: String?, dcaToken: String) {
      self.accountKey = accountKey
      self.displayName = displayName
      self.dcaToken = dcaToken
    }
  }

  /// The last read and the earliest time the endpoint may be asked again. `quota` is
  /// nil while a backoff is running with nothing to serve yet.
  private struct CachedQuota {
    let quota: ProviderQuota?
    let readyAt: Date
  }

  public static let authDirectory = "~/.cli-proxy-api"
  /// CLIProxyAPI files Muse Code under Meta's own provider id.
  public static let authFilePrefix = "meta-"
  /// Used when the auth file names no account. Meta issues one credential per login.
  public static let localAccountKey = "Muse Code"
  /// Meta's own Muse Code client identifier, as the proxy sends it.
  public static let userAgent = "muse-code/1.0.2"
  /// Matches the spacing the vendor's own client keeps on this endpoint.
  public static let refreshInterval: TimeInterval = 300
  public static let failureBackoff: TimeInterval = 300
  /// Meta's rolling window, identified by its declared duration rather than assumed.
  public static let fiveHourWindowMinutes: Double = 300

  public nonisolated let provider = QuotaProvider.muse
  private let credentials: any MuseCredentialSourcing
  private let session: any QuotaHTTPSession
  private let keyURL: URL
  private let now: @Sendable () -> Date
  private var cache: [String: CachedQuota] = [:]

  public init(
    credentials: any MuseCredentialSourcing = LocalMuseCredentialStore(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    keyURL: URL = URL(string: "https://api.meta.ai/muse-code/key")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.credentials = credentials
    self.session = session
    self.keyURL = keyURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    let all = await credentials.credentials(for: request.mode)
    guard !all.isEmpty else {
      return .init(quotas: [:], credentialAvailability: .missing, credentialAccountKeys: [])
    }
    let keys = Set(all.map(\.accountKey))
    var quotas: [String: ProviderQuota] = [:]
    var failure: (any Error)?
    for credential in all where Self.includes(credential.accountKey, in: request.scope) {
      switch await quota(for: credential) {
      case .success(let quota):
        if let quota { quotas[credential.accountKey] = quota }
      case .failure(let error):
        failure = failure ?? error
      }
    }
    // A read that failed with nothing cached to serve has to be reported. Returning an
    // empty result instead reads as a successful refresh: the account shows neither a
    // quota nor a reason, and the backoff keeps it that way until it elapses. With a
    // reading already in hand — for this account or another one — the failure is the
    // backoff's business, and what was read stays on screen.
    if quotas.isEmpty, let failure {
      throw failure
    }
    return .init(
      quotas: quotas, credentialAvailability: .present, credentialAccountKeys: keys)
  }

  /// Turns Meta's `subs_usage` object into the rolling and weekly windows Quotio renders.
  ///
  /// Always returns both windows, even when Meta's response carries neither: measured
  /// live against a real, active "Muse Code High Usage" subscription, the subscription-key
  /// endpoint answered `is_subs_active: true` with no `subs_usage` object at all — Meta
  /// appears to only attach it around a mint, not on every read. A window with no
  /// readable percentage renders as unavailable (percentage < 0 is this app's existing
  /// "unknown" sentinel); it must not be reported as a fetch failure, since the account
  /// and plan are valid and were read correctly.
  ///
  /// A window whose declared duration is not the five-hour one is carried under its own
  /// name rather than filed as the session window: reporting a longer window as the
  /// five-hour one would understate usage by the ratio between them, and would do it
  /// with full confidence.
  public nonisolated static func mapUsage(
    _ usage: [String: Any],
    plan: String?,
    displayName: String?,
    now: Date
  ) -> ProviderQuota {
    let session = usage["window"] as? [String: Any]
    let minutes = number(session?["window_duration_mins"])
    let sessionName =
      minutes == fiveHourWindowMinutes || minutes == nil
      ? "muse-session" : "muse-window-\(Int(minutes ?? 0))"
    let weekly = usage["weekly"] as? [String: Any]
    let metrics: [QuotaMetric] = [
      .init(
        name: sessionName,
        percentage: remainingPercentage(session?["used_percent"]) ?? -1,
        resetTime: resetTime(session?["resets_at"])),
      .init(
        name: "muse-weekly",
        percentage: remainingPercentage(weekly?["used_percent"]) ?? -1,
        resetTime: resetTime(weekly?["resets_at"])),
    ]
    return ProviderQuota(
      models: metrics, lastUpdated: now, planType: plan, accountDisplayName: displayName)
  }

  private func quota(for credential: Credential) async -> Result<ProviderQuota?, any Error> {
    let at = now()
    if let cached = cache[credential.accountKey], at < cached.readyAt {
      return .success(cached.quota)
    }
    do {
      let quota = try await read(credential)
      cache[credential.accountKey] = CachedQuota(
        quota: quota, readyAt: at.addingTimeInterval(Self.refreshInterval))
      return .success(quota)
    } catch {
      // Every failure backs off, expired credentials included: the account token cannot
      // be refreshed from here, so retrying it on the next poll only spends rate limit.
      // The last good reading keeps being served while the backoff runs; with nothing
      // read yet the failure travels up instead, so it can be shown.
      let previous = cache[credential.accountKey]?.quota
      cache[credential.accountKey] = CachedQuota(
        quota: previous, readyAt: at.addingTimeInterval(Self.failureBackoff))
      return previous.map { Result.success($0) } ?? .failure(error)
    }
  }

  private func read(_ credential: Credential) async throws -> ProviderQuota {
    // Same call CLIProxyAPI makes to mint the key (internal/auth/meta/meta.go,
    // MintAPIKey): the DCA token travels both as the bearer and in the body, under
    // Meta's own client user agent. The response carries the subscription state, so
    // reading quota costs an auth-plane POST rather than an inference turn.
    var request = URLRequest(url: keyURL)
    request.httpMethod = "POST"
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["dca_token": credential.dcaToken])
    request.setValue("Bearer \(credential.dcaToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      return ProviderQuota(
        lastUpdated: now(), isForbidden: true, accountDisplayName: credential.displayName)
    }
    guard 200...299 ~= http.statusCode else {
      throw InfrastructureQuotaFetchError.httpError(http.statusCode)
    }
    // The body of this endpoint carries the Model API key. Only these fields are read.
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    let plan = Self.trimmed(body["subs_tier_name"] as? String)
    let display = Self.trimmed((body["user_email"] as? String)?.lowercased())
      ?? credential.displayName
    if body["is_subs_active"] as? Bool == false {
      return ProviderQuota(
        models: [
          .init(
            name: "muse-subscription", percentage: -1, resetTime: "",
            presentation: .status(text: "muse-inactive"))
        ],
        lastUpdated: now(),
        planType: plan,
        accountDisplayName: display
      )
    }
    let usage = body["subs_usage"] as? [String: Any] ?? [:]
    return Self.mapUsage(usage, plan: plan, displayName: display, now: now())
  }

  private nonisolated static func remainingPercentage(_ value: Any?) -> Double? {
    guard let used = number(value) else { return nil }
    return max(0, min(100, 100 - used))
  }

  private nonisolated static func resetTime(_ value: Any?) -> String {
    guard let seconds = number(value), seconds > 0 else { return "" }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
  }

  private nonisolated static func number(_ value: Any?) -> Double? {
    value is NSNumber ? (value as? NSNumber)?.doubleValue : (value as? String).flatMap(Double.init)
  }

  static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
}

/// Supplies the Meta accounts Quotio can read.
public protocol MuseCredentialSourcing: Sendable {
  func credentials(for mode: QuotaOperatingMode) async -> [MuseQuotaFetcher.Credential]
}

/// Reads them from the proxy's auth directory, where a Meta login leaves them.
public struct LocalMuseCredentialStore: MuseCredentialSourcing {
  private let authDirectory: String

  public init(authDirectory: String = MuseQuotaFetcher.authDirectory) {
    self.authDirectory = authDirectory
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [MuseQuotaFetcher.Credential] {
    MuseQuotaFetcher.loadCredentials(directory: authDirectory)
  }
}

/// Composes the sources in the same order every other provider uses: accounts Quotio
/// owns in its own keychain vault first — and only in monitor mode, where Quotio is the
/// one holding them — then the accounts the local proxy logged in. Duplicates collapse
/// on the account key, so an account present in both is read once, from the vault.
public struct CompositeMuseCredentialSource: MuseCredentialSourcing {
  private let local: any MuseCredentialSourcing
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository

  public init(
    local: any MuseCredentialSourcing = LocalMuseCredentialStore(),
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository
  ) {
    self.local = local
    self.vault = vault
    self.metadata = metadata
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [MuseQuotaFetcher.Credential] {
    var result: [MuseQuotaFetcher.Credential] = []
    if mode == .monitor {
      let disabled = await metadata.disabledAccountIDs()
      for account in await vault.accounts()
      where account.providerID.rawValue == QuotaProvider.muse.rawValue
        && !account.isDisabled && !disabled.contains(account.id)
      {
        guard let credential = await vault.credential(for: account.id) else { continue }
        result.append(
          .init(
            accountKey: account.accountKey,
            displayName: account.displayName,
            dcaToken: credential.accessToken
          ))
      }
    }
    result.append(contentsOf: await local.credentials(for: mode))
    var seen = Set<String>()
    return result.filter { seen.insert($0.accountKey).inserted }
  }
}

public extension MuseQuotaFetcher {
  /// Parses the proxy's Meta auth files.
  ///
  /// A symlink is never followed: these files are treated as hostile input, like every
  /// other credential this app reads.
  nonisolated static func loadCredentials(directory: String) -> [Credential] {
    let expanded = NSString(string: directory).expandingTildeInPath
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
      return []
    }
    return names.sorted().compactMap { name in
      guard name.hasPrefix(authFilePrefix), name.hasSuffix(".json") else { return nil }
      let path = (expanded as NSString).appendingPathComponent(name)
      let url = URL(fileURLWithPath: path)
      guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
        let data = try? Data(contentsOf: url)
      else { return nil }
      return credential(from: data)
    }
  }

  /// Reads one auth file.
  ///
  /// Only `dca_token` is taken. `api_key` and `access_token` both hold the `LLM|` Model
  /// API key, which authenticates model calls — the proxy's job, not Quotio's — and is
  /// refused by the endpoint read here.
  nonisolated static func credential(from data: Data) -> Credential? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dcaToken = trimmed(json["dca_token"] as? String)
    else { return nil }
    let email = trimmed((json["email"] as? String)?.lowercased())
    return Credential(
      accountKey: email ?? localAccountKey,
      displayName: email,
      dcaToken: dcaToken
    )
  }
}
