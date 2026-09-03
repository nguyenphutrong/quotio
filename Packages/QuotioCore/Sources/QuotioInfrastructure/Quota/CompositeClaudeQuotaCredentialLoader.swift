import Foundation
import QuotioApplication
import QuotioDomain

public protocol ClaudeDesktopCredentialLoading: Sendable {
  func credential() async -> ClaudeQuotaCredential?
}

public struct CompositeClaudeQuotaCredentialLoader: ClaudeQuotaCredentialLoading {
  private let local: any ClaudeQuotaCredentialLoading
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let external: any ExternalCredentialReading
  private let desktop: (any ClaudeDesktopCredentialLoading)?

  public init(
    local: any ClaudeQuotaCredentialLoading = LocalClaudeQuotaCredentialLoader(),
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    external: any ExternalCredentialReading = ExternalKeychainCredentialReader(),
    desktop: (any ClaudeDesktopCredentialLoading)? = ClaudeDesktopCredentialReader()
  ) {
    self.local = local
    self.vault = vault
    self.metadata = metadata
    self.external = external
    self.desktop = desktop
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [ClaudeQuotaCredential] {
    var result: [ClaudeQuotaCredential] = []
    if mode == .monitor {
      let disabled = await metadata.disabledAccountIDs()
      for account in await vault.accounts()
      where account.providerID.rawValue == QuotaProvider.claude.rawValue
        && !account.isDisabled && !disabled.contains(account.id)
      {
        guard let credential = await vault.credential(for: account.id) else { continue }
        result.append(
          .init(
            accountKey: account.accountKey,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt
          ))
      }
    }

    if let record = await external.read(service: "Claude Code-credentials", account: nil),
      let credential = LocalClaudeQuotaCredentialLoader.load(data: record.data)
    {
      result.append(credential)
    }
    result.append(contentsOf: await local.credentials(for: mode))
    if let credential = await desktop?.credential() {
      result.append(credential)
    }

    var seen = Set<String>()
    return result.filter { seen.insert($0.accountKey).inserted }
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    if mode == .monitor,
      let account = await vault.accounts().first(where: {
        $0.providerID.rawValue == QuotaProvider.claude.rawValue
          && $0.accountKey == credential.accountKey
      }),
      var stored = await vault.reloadLatest(accountID: account.id),
      stored.refreshToken == expectedRefreshToken
    {
      stored.accessToken = refresh.accessToken
      stored.refreshToken = refresh.refreshToken ?? expectedRefreshToken
      stored.expiresAt = refresh.expiresAt ?? stored.expiresAt
      try? await vault.save(stored, metadata: account)
      return
    }

    if let record = await external.read(service: "Claude Code-credentials", account: nil),
      LocalClaudeQuotaCredentialLoader.load(data: record.data)?.accountKey == credential.accountKey,
      let updated = LocalClaudeQuotaCredentialLoader.updatedData(
        record.data,
        refresh: refresh,
        replacing: expectedRefreshToken
      )
    {
      _ = await external.compareAndSwap(
        service: "Claude Code-credentials",
        account: record.account,
        expectedData: record.data,
        newData: updated
      )
      return
    }

    await local.persist(
      refresh,
      replacing: expectedRefreshToken,
      for: credential,
      mode: mode
    )
  }
}
