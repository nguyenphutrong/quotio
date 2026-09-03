import Foundation
import QuotioApplication
import QuotioDomain

public struct CompositeCodexQuotaCredentialLoader: CodexQuotaCredentialLoading {
  private let local: any CodexQuotaCredentialLoading
  private let vault: any CredentialVault
  private let metadata: any AccountMetadataRepository
  private let external: any ExternalCredentialReading

  public init(
    local: any CodexQuotaCredentialLoading = LocalCodexQuotaCredentialLoader(),
    vault: any CredentialVault,
    metadata: any AccountMetadataRepository,
    external: any ExternalCredentialReading = ExternalKeychainCredentialReader()
  ) {
    self.local = local
    self.vault = vault
    self.metadata = metadata
    self.external = external
  }

  public func credentials(for mode: QuotaOperatingMode) async -> [CodexQuotaCredential] {
    var result = await local.credentials(for: mode)
    let aliases = LocalCodexQuotaCredentialLoader.uniqueLegacyAliases(result)

    if mode == .monitor {
      let disabled = await metadata.disabledAccountIDs()
      for account in await vault.accounts()
      where account.providerID.rawValue == QuotaProvider.codex.rawValue
        && !account.isDisabled && !disabled.contains(account.id)
      {
        guard let credential = await vault.credential(for: account.id) else { continue }
        result.insert(
          .init(
            accountKey: account.accountKey,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            idToken: credential.idToken,
            accountID: credential.accountID
          ),
          at: 0
        )
      }
    }

    if let record = await external.read(service: "Codex Auth", account: nil),
      var credential = LocalCodexQuotaCredentialLoader.loadNative(
        data: record.data, fallbackAccountKey: "Codex")
    {
      if let accountID = credential.accountID, let alias = aliases[accountID] {
        credential = .init(
          accountKey: alias,
          accessToken: credential.accessToken,
          refreshToken: credential.refreshToken,
          idToken: credential.idToken,
          accountID: accountID
        )
      }
      result.insert(credential, at: mode == .monitor ? min(result.count, 1) : 0)
    }

    var seen = Set<String>()
    return result.filter { seen.insert($0.accountKey).inserted }
  }

  public func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: CodexQuotaCredential,
    mode: QuotaOperatingMode
  ) async {
    if mode == .monitor,
      let account = await vault.accounts().first(where: {
        $0.providerID.rawValue == QuotaProvider.codex.rawValue
          && $0.accountKey == credential.accountKey
      }),
      var stored = await vault.reloadLatest(accountID: account.id),
      stored.refreshToken == expectedRefreshToken
    {
      stored.accessToken = refresh.accessToken
      stored.refreshToken = refresh.refreshToken ?? expectedRefreshToken
      stored.idToken = refresh.idToken ?? stored.idToken
      stored.expiresAt = refresh.expiresAt ?? stored.expiresAt
      try? await vault.save(stored, metadata: account)
      return
    }

    if let record = await external.read(service: "Codex Auth", account: nil),
      let loaded = LocalCodexQuotaCredentialLoader.loadNative(
        data: record.data,
        fallbackAccountKey: "Codex"
      ),
      loaded.accountKey == credential.accountKey || loaded.accountID == credential.accountID,
      let updated = LocalCodexQuotaCredentialLoader.updatedData(
        record.data,
        isNative: true,
        refresh: refresh,
        replacing: expectedRefreshToken
      )
    {
      _ = await external.compareAndSwap(
        service: "Codex Auth",
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
