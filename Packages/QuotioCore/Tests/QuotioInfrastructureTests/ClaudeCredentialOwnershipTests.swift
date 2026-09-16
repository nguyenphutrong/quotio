import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

/// The boundary that keeps Quotio from interfering with the Claude Code CLI:
/// credentials the CLI owns are read, never refreshed or written back.
final class ClaudeCredentialOwnershipTests: XCTestCase {
  private let home = NSString(string: "~").expandingTildeInPath

  // MARK: - Classification

  func testNativeCredentialsFileIsCLIOwnedAndNotRefreshable() {
    let path = "\(home)/.claude/.credentials.json"
    let ownership = ClaudeCredentialOwnership.forAuthFile(at: path, environment: [:])
    XCTAssertEqual(ownership, .externalCLI)
    XCTAssertFalse(
      ownership.allowsRefresh, "Refreshing spends the CLI's single-use refresh token")
  }

  func testProxyAuthFilesRemainRefreshable() {
    for name in ["claude-user.json", "claude-work@example.com.json"] {
      let path = "\(home)/.cli-proxy-api/\(name)"
      let ownership = ClaudeCredentialOwnership.forAuthFile(at: path, environment: [:])
      XCTAssertEqual(ownership, .quotio, "\(name) is owned by Quotio's proxy")
      XCTAssertTrue(ownership.allowsRefresh)
    }
  }

  func testClaudeConfigDirOverrideIsHonoured() {
    let custom = "\(home)/custom-claude-home"
    let environment = ["CLAUDE_CONFIG_DIR": custom]

    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(
        at: "\(custom)/.credentials.json", environment: environment),
      .externalCLI,
      "A relocated CLI config directory is still CLI-owned"
    )
    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(
        at: "\(home)/.claude/.credentials.json", environment: environment),
      .quotio,
      "With the override set, the default directory is no longer the CLI's"
    )
  }

  func testConfigDirOverrideExpandsTildeAndIgnoresBlankValues() {
    XCTAssertEqual(
      ClaudeCredentialOwnership.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "~/relocated"]),
      "\(home)/relocated"
    )
    XCTAssertEqual(
      ClaudeCredentialOwnership.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "   "]),
      "\(home)/.claude",
      "A blank override falls back to the default, matching the CLI"
    )
    XCTAssertEqual(
      ClaudeCredentialOwnership.configDirectory(environment: [:]), "\(home)/.claude")
  }

  func testSiblingDirectoryIsNotMistakenForCLIDirectory() {
    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(
        at: "\(home)/.claude-backup/.credentials.json", environment: [:]),
      .quotio,
      "Prefix matching must not treat ~/.claude-backup as part of ~/.claude"
    )
  }

  func testUnnormalizedPathsInsideCLIDirectoryAreCLIOwned() {
    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(
        at: "\(home)/.claude/../.claude/.credentials.json", environment: [:]),
      .externalCLI,
      "Path traversal must not smuggle a CLI-owned file into the refreshable branch"
    )
  }

  func testOpenedFileAndConfiguredDirectoryUseTheSameSystemAlias() {
    for alias in ["etc", "tmp", "var"] {
      XCTAssertEqual(
        ClaudeCredentialOwnership.forOpenedAuthFile(
          at: "/private/\(alias)/claude/.credentials.json",
          referenceCount: 1,
          environment: ["CLAUDE_CONFIG_DIR": "/\(alias)/claude"]
        ),
        .externalCLI
      )
    }
  }

  // MARK: - Symlinks

  /// A `claude-*.json` entry under `~/.cli-proxy-api` that links to the CLI's
  /// credentials would otherwise classify as ours, and the refresh would be
  /// spent through the link. AGENTS.md forbids following an auth-file symlink.
  func testSymlinkIntoCLIDirectoryIsNotRefreshable() throws {
    let root = try makeTemporaryDirectory()
    let cliDirectory = root.appendingPathComponent(".claude")
    let proxyDirectory = root.appendingPathComponent(".cli-proxy-api")
    try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)

    let target = cliDirectory.appendingPathComponent(".credentials.json")
    try Data("{}".utf8).write(to: target)
    let link = proxyDirectory.appendingPathComponent("claude-linked.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let environment = ["CLAUDE_CONFIG_DIR": cliDirectory.path]
    let ownership = ClaudeCredentialOwnership.forAuthFile(at: link.path, environment: environment)
    XCTAssertEqual(ownership, .externalCLI)
    XCTAssertFalse(
      ownership.allowsRefresh, "Refreshing through the link spends the CLI's token")
  }

  /// Fail closed: any symlinked auth file is left unrefreshed, even one pointing
  /// somewhere harmless, because we do not follow the destination.
  func testSymlinkWithinProxyDirectoryIsAlsoNotRefreshed() throws {
    let root = try makeTemporaryDirectory()
    let proxyDirectory = root.appendingPathComponent(".cli-proxy-api")
    try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)

    let target = proxyDirectory.appendingPathComponent("claude-real.json")
    try Data("{}".utf8).write(to: target)
    let link = proxyDirectory.appendingPathComponent("claude-alias.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(at: target.path, environment: [:]), .quotio)
    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(at: link.path, environment: [:]), .externalCLI)
  }

  func testCredentialLoaderDoesNotReadSymlinkDestination() throws {
    let root = try makeTemporaryDirectory()
    let target = root.appendingPathComponent("credential.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"linked-access","email":"user@example.com"}}"#.utf8
    ).write(to: target)
    let link = root.appendingPathComponent("claude-linked.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    XCTAssertNil(LocalClaudeQuotaCredentialLoader.load(path: link.path))
  }

  func testCredentialLoaderDoesNotReadThroughSymlinkedDirectory() throws {
    let root = try makeTemporaryDirectory()
    let targetDirectory = root.appendingPathComponent("credentials")
    try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
    let target = targetDirectory.appendingPathComponent("claude-user.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"linked-access","email":"user@example.com"}}"#.utf8
    ).write(to: target)
    let linkedDirectory = root.appendingPathComponent("linked-credentials")
    try FileManager.default.createSymbolicLink(
      at: linkedDirectory, withDestinationURL: targetDirectory)

    XCTAssertNil(
      LocalClaudeQuotaCredentialLoader.load(
        path: linkedDirectory.appendingPathComponent("claude-user.json").path))
  }

  func testOpenedCredentialCannotBeRedirectedByPathSwap() throws {
    let root = try makeTemporaryDirectory()
    let credential = root.appendingPathComponent("claude-user.json")
    let original = Data(
      #"{"access_token":"owned-access","refresh_token":"owned-refresh","email":"user@example.com"}"#
        .utf8)
    try original.write(to: credential)
    let opened = try XCTUnwrap(SecureClaudeCredentialFile(path: credential.path))

    let cliCredential = root.appendingPathComponent("cli-credential.json")
    let cliData = Data(
      #"{"access_token":"cli-access","refresh_token":"cli-refresh","email":"user@example.com"}"#
        .utf8)
    try cliData.write(to: cliCredential)
    try FileManager.default.removeItem(at: credential)
    try FileManager.default.createSymbolicLink(
      at: credential, withDestinationURL: cliCredential)

    XCTAssertEqual(opened.read(), original, "The read remains bound to the opened inode")
    XCTAssertFalse(opened.replaceAtomically(with: Data("updated".utf8)))
    XCTAssertEqual(try Data(contentsOf: cliCredential), cliData)
  }

  // MARK: - Local loader

  func testHardLinkedProxyCredentialRemainsReadOnly() async throws {
    let root = try makeTemporaryDirectory()
    let configDirectory = root.appendingPathComponent(".claude")
    let proxyDirectory = root.appendingPathComponent(".cli-proxy-api")
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
    let nativeFile = configDirectory.appendingPathComponent(".credentials.json")
    let proxyFile = proxyDirectory.appendingPathComponent("claude-linked.json")
    let original = Data(
      #"{"claudeAiOauth":{"accessToken":"cli-access","refreshToken":"cli-refresh","email":"user@example.com","expiresAt":1000}}"#
        .utf8)
    try original.write(to: nativeFile)
    try FileManager.default.linkItem(at: nativeFile, to: proxyFile)
    let environment = ["CLAUDE_CONFIG_DIR": configDirectory.path]
    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(at: proxyFile.path, environment: environment),
      .externalCLI)
    let loader = LocalClaudeQuotaCredentialLoader(
      environment: environment, legacyDirectory: proxyDirectory.path)
    let credentials = await loader.credentials(for: .localProxy)
    XCTAssertEqual(credentials.count, 1)
    let credential = try XCTUnwrap(credentials.first)
    XCTAssertFalse(credential.allowsRefresh)

    let session = RecordingClaudeSession(responses: [("", 401)])
    _ = try await ClaudeQuotaFetcher(credentials: loader, session: session)
      .fetch(.init(provider: .claude, mode: .localProxy, force: true))
    let requests = await session.requests()
    XCTAssertEqual(requests.map(\.url), [ClaudeQuotaFetcher.usageURL])

    await loader.persist(
      QuotaTokenRefresh(accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: nil),
      replacing: "cli-refresh", for: credential, mode: .localProxy)
    XCTAssertEqual(try Data(contentsOf: nativeFile), original)
    XCTAssertEqual(try Data(contentsOf: proxyFile), original)

    // A single-link proxy file remains refreshable after the alias is removed.
    try FileManager.default.removeItem(at: nativeFile)
    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(at: proxyFile.path, environment: environment), .quotio)
  }

  func testLocalLoaderMarksCLIFileReadOnlyAndLeavesItUnchangedOnPersist() async throws {
    let root = try makeTemporaryDirectory()
    let configDirectory = root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    let file = configDirectory.appendingPathComponent(".credentials.json")
    let original = Data(
      #"{"claudeAiOauth":{"accessToken":"cli-access","refreshToken":"cli-refresh","email":"user@example.com"}}"#
        .utf8)
    try original.write(to: file)

    let loader = LocalClaudeQuotaCredentialLoader(
      environment: ["CLAUDE_CONFIG_DIR": configDirectory.path])
    let loaded = await loader.credentials(for: .monitor)
    let credential = try XCTUnwrap(loaded.first { $0.accountKey == "user@example.com" })
    XCTAssertFalse(credential.allowsRefresh)

    await loader.persist(
      QuotaTokenRefresh(accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: nil),
      replacing: "cli-refresh",
      for: credential,
      mode: .monitor
    )
    XCTAssertEqual(
      try Data(contentsOf: file), original,
      "Writing back would replace a refresh token the running CLI still expects")
  }

  func testLocalLoaderPersistsOwnedDuplicateRatherThanCLIFile() async throws {
    let root = try makeTemporaryDirectory()
    let configDirectory = root.appendingPathComponent(".claude")
    let proxyDirectory = root.appendingPathComponent(".cli-proxy-api")
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)

    let nativeFile = configDirectory.appendingPathComponent(".credentials.json")
    let nativeData = Data(
      #"{"claudeAiOauth":{"accessToken":"cli-access","refreshToken":"cli-refresh","email":"user@example.com"}}"#
        .utf8)
    try nativeData.write(to: nativeFile)
    let proxyFile = proxyDirectory.appendingPathComponent("claude-user.json")
    try Data(
      #"{"access_token":"proxy-access","refresh_token":"proxy-refresh","email":"user@example.com"}"#
        .utf8
    ).write(to: proxyFile)

    let loader = LocalClaudeQuotaCredentialLoader(
      environment: ["CLAUDE_CONFIG_DIR": configDirectory.path],
      legacyDirectory: proxyDirectory.path)
    let credentials = await loader.credentials(for: .localProxy)
    let credential = try XCTUnwrap(
      credentials.first { $0.accountKey == "user@example.com" })

    await loader.persist(
      QuotaTokenRefresh(accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: nil),
      replacing: "proxy-refresh",
      for: credential,
      mode: .localProxy
    )

    XCTAssertEqual(try Data(contentsOf: nativeFile), nativeData)
    XCTAssertEqual(LocalClaudeQuotaCredentialLoader.load(path: proxyFile.path)?.accessToken, "rotated")
  }

  // MARK: - Fetcher

  func testReadOnlyCredentialIsNeverRefreshedEvenWhenExpired() async throws {
    let session = RecordingClaudeSession(responses: [
      (#"{"five_hour":{"utilization":25,"resets_at":""}}"#, 200)
    ])
    let expired = Date(timeIntervalSince1970: 1_000)
    let loader = StaticClaudeLoader([
      .init(
        accountKey: "user@example.com", accessToken: "stale", refreshToken: "cli-refresh",
        expiresAt: expired, allowsRefresh: false)
    ])
    let fetcher = ClaudeQuotaFetcher(
      credentials: loader, session: session, now: { expired.addingTimeInterval(3_600) })

    let output = try await fetcher.fetch(.init(provider: .claude, mode: .monitor, force: true))

    XCTAssertEqual(output.quotas["user@example.com"]?.models.first?.percentage, 75)
    let requests = await session.requests()
    XCTAssertEqual(
      requests.map { $0.url?.absoluteString }, [ClaudeQuotaFetcher.usageURL.absoluteString],
      "An expired CLI token yields no fresh quota rather than a refresh Quotio may not make")
    let persisted = await loader.persisted()
    XCTAssertNil(persisted, "A credential Quotio does not own is never written back")
  }

  /// A CLI-owned credential has no re-authentication story in Quotio — the CLI
  /// renews it on its own schedule — so `isForbidden` would wrongly ask the user
  /// to sign in to Quotio for an account Quotio does not manage.
  func testReadOnlyCredentialFallsBackToCacheInsteadOfReportingForbidden() async throws {
    let session = RecordingClaudeSession(responses: [
      (#"{"five_hour":{"utilization":40,"resets_at":""}}"#, 200),
      ("", 401),
    ])
    let loader = StaticClaudeLoader([
      .init(
        accountKey: "user@example.com", accessToken: "token", refreshToken: "cli-refresh",
        allowsRefresh: false)
    ])
    let fetcher = ClaudeQuotaFetcher(credentials: loader, session: session)

    _ = try await fetcher.fetch(.init(provider: .claude, mode: .monitor, force: true))
    let output = try await fetcher.fetch(.init(provider: .claude, mode: .monitor, force: true))

    let quota = try XCTUnwrap(output.quotas["user@example.com"])
    XCTAssertFalse(quota.isForbidden)
    XCTAssertEqual(quota.models.first?.percentage, 60, "The cached reading is kept")
    let requests = await session.requests()
    XCTAssertFalse(
      requests.contains { $0.url == ClaudeQuotaFetcher.tokenURL },
      "A 401 must not trigger a refresh of a token Quotio does not own")
  }

  func testOwnedCredentialStillRefreshesAndReportsForbidden() async throws {
    let session = RecordingClaudeSession(responses: [
      ("", 401),
      (#"{"access_token":"new-token"}"#, 200),
      ("", 403),
    ])
    let loader = StaticClaudeLoader([
      .init(accountKey: "proxy@example.com", accessToken: "old", refreshToken: "refresh")
    ])
    let output = try await ClaudeQuotaFetcher(credentials: loader, session: session)
      .fetch(.init(provider: .claude, mode: .monitor))

    XCTAssertEqual(output.quotas["proxy@example.com"]?.isForbidden, true)
    let requests = await session.requests()
    XCTAssertTrue(requests.contains { $0.url == ClaudeQuotaFetcher.tokenURL })
  }

  // MARK: - Composite loader

  func testCopiedRefreshTokenIsNeverPreferredRegardlessOfOrder() {
    let cli = ClaudeQuotaCredential(
      accountKey: "user@example.com", accessToken: "cli", refreshToken: "shared",
      allowsRefresh: false)
    let copy = ClaudeQuotaCredential(
      accountKey: "different@example.com", accessToken: "copy", refreshToken: "shared")
    let independent = ClaudeQuotaCredential(
      accountKey: "user@example.com", accessToken: "independent", refreshToken: "owned")

    for values in [[cli, copy], [copy, cli]] {
      let result = ClaudeQuotaCredential.uniqueByAccountKey(values)
      XCTAssertEqual(Set(result.map(\.accountKey)), Set([cli.accountKey, copy.accountKey]))
      XCTAssertTrue(result.allSatisfy { !$0.allowsRefresh })
    }
    for values in [
      [cli, copy, independent], [cli, independent, copy],
      [copy, cli, independent], [copy, independent, cli],
      [independent, cli, copy], [independent, copy, cli],
    ] {
      let result = ClaudeQuotaCredential.uniqueByAccountKey(values)
      XCTAssertEqual(result.first { $0.accountKey == independent.accountKey }, independent)
      XCTAssertEqual(result.first { $0.accountKey == copy.accountKey }?.allowsRefresh, false)
    }
  }

  func testCopiedCLIFileNeverRefreshesOrChangesEitherFile() async throws {
    let root = try makeTemporaryDirectory()
    let configDirectory = root.appendingPathComponent(".claude")
    let proxyDirectory = root.appendingPathComponent(".cli-proxy-api")
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
    let nativeFile = configDirectory.appendingPathComponent(".credentials.json")
    let proxyFile = proxyDirectory.appendingPathComponent("claude-copy.json")
    let original = Data(
      #"{"claudeAiOauth":{"accessToken":"cli-access","refreshToken":"shared-refresh","email":"user@example.com","expiresAt":1000}}"#
        .utf8)
    try original.write(to: nativeFile)
    try FileManager.default.copyItem(at: nativeFile, to: proxyFile)
    let environment = ["CLAUDE_CONFIG_DIR": configDirectory.path]
    // This is an ordinary copy, so the hard-link ownership guard does not help.
    XCTAssertEqual(
      ClaudeCredentialOwnership.forAuthFile(at: proxyFile.path, environment: environment), .quotio)
    let loader = LocalClaudeQuotaCredentialLoader(
      environment: environment, legacyDirectory: proxyDirectory.path)
    let credentials = await loader.credentials(for: .localProxy)
    XCTAssertEqual(credentials.count, 1)
    XCTAssertEqual(credentials.first?.allowsRefresh, false)

    let session = RecordingClaudeSession(responses: [("", 401), ("", 403)])
    let fetcher = ClaudeQuotaFetcher(credentials: loader, session: session)
    for _ in 0..<2 {
      let output = try await fetcher.fetch(
        .init(provider: .claude, mode: .localProxy, force: true))
      XCTAssertNil(output.quotas["user@example.com"])
    }
    let requests = await session.requests()
    XCTAssertEqual(requests.map(\.url), [ClaudeQuotaFetcher.usageURL, ClaudeQuotaFetcher.usageURL])
    XCTAssertEqual(try Data(contentsOf: nativeFile), original)
    XCTAssertEqual(try Data(contentsOf: proxyFile), original)
  }

  func testDuplicateWithoutRefreshTokenDoesNotHideCLICredential() {
    let cli = ClaudeQuotaCredential(
      accountKey: "user@example.com", accessToken: "usable-cli", refreshToken: "cli-refresh",
      expiresAt: .distantFuture, allowsRefresh: false)
    let accessOnly = ClaudeQuotaCredential(
      accountKey: "user@example.com", accessToken: "expired-proxy", expiresAt: .distantPast)
    let refreshable = ClaudeQuotaCredential(
      accountKey: "user@example.com", accessToken: "owned", refreshToken: "owned-refresh")

    XCTAssertEqual(ClaudeQuotaCredential.uniqueByAccountKey([cli, accessOnly]), [cli])
    XCTAssertEqual(ClaudeQuotaCredential.uniqueByAccountKey([accessOnly, cli]), [cli])
    XCTAssertEqual(
      ClaudeQuotaCredential.uniqueByAccountKey([cli, accessOnly, refreshable]), [refreshable])
    XCTAssertEqual(
      ClaudeQuotaCredential.uniqueByAccountKey([accessOnly, refreshable, cli]), [refreshable])
    XCTAssertEqual(
      ClaudeQuotaCredential.uniqueByAccountKey([refreshable, accessOnly, cli]), [refreshable])
  }

  func testDuplicateSelectionKeepsTheUsableAccessOnlyCredential() {
    let now = Date(timeIntervalSince1970: 10_000)
    let validAccessOnly = ClaudeQuotaCredential(
      accountKey: "user@example.com", accessToken: "owned-valid",
      expiresAt: now.addingTimeInterval(60))
    let expiredCLI = ClaudeQuotaCredential(
      accountKey: "user@example.com", accessToken: "cli-expired", refreshToken: "cli-refresh",
      expiresAt: now.addingTimeInterval(-60), allowsRefresh: false)

    XCTAssertEqual(
      ClaudeQuotaCredential.uniqueByAccountKey([validAccessOnly, expiredCLI], now: now),
      [validAccessOnly]
    )
  }

  func testCompositeMarksCLIKeychainItemReadOnlyAndNeverSwapsIt() async throws {
    let data = Data(
      #"{"claudeAiOauth":{"accessToken":"cli-access","refreshToken":"cli-refresh","email":"user@example.com"}}"#
        .utf8)
    let external = RecordingExternalCredentials(
      record: ExternalCredentialRecord(data: data, account: "Claude Code"))
    let loader = CompositeClaudeQuotaCredentialLoader(
      local: StaticClaudeLoader([]),
      vault: EmptyVault(),
      metadata: EmptyMetadata(),
      external: external,
      desktop: nil
    )

    let loaded = await loader.credentials(for: .monitor)
    let credential = try XCTUnwrap(loaded.first)
    XCTAssertEqual(credential.accountKey, "user@example.com")
    XCTAssertFalse(credential.allowsRefresh)

    await loader.persist(
      QuotaTokenRefresh(accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: nil),
      replacing: "cli-refresh",
      for: credential,
      mode: .monitor
    )
    let swaps = await external.swaps()
    XCTAssertEqual(swaps, 0, "The CLI's keychain item is read, never written back")
  }

  func testCompositePrefersOwnedCredentialForDuplicateAccountKey() async throws {
    let externalData = Data(
      #"{"claudeAiOauth":{"accessToken":"cli-access","email":"user@example.com"}}"#.utf8)
    let loader = CompositeClaudeQuotaCredentialLoader(
      local: StaticClaudeLoader([
        .init(
          accountKey: "user@example.com", accessToken: "proxy-access", refreshToken: "proxy-refresh")
      ]),
      vault: EmptyVault(),
      metadata: EmptyMetadata(),
      external: RecordingExternalCredentials(
        record: ExternalCredentialRecord(data: externalData, account: "Claude Code")),
      desktop: nil
    )

    let credentials = await loader.credentials(for: .localProxy)

    XCTAssertEqual(credentials.count, 1)
    XCTAssertEqual(credentials.first?.accessToken, "proxy-access")
    XCTAssertEqual(credentials.first?.allowsRefresh, true)
  }

  // MARK: - Helpers

  private func makeTemporaryDirectory() throws -> URL {
    let temporaryDirectory = NSTemporaryDirectory()
    let canonicalDirectory =
      temporaryDirectory.hasPrefix("/var/") ? "/private\(temporaryDirectory)" : temporaryDirectory
    let root = URL(fileURLWithPath: canonicalDirectory)
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

private actor StaticClaudeLoader: ClaudeQuotaCredentialLoading {
  private let values: [ClaudeQuotaCredential]
  private var recorded: QuotaTokenRefresh?

  init(_ values: [ClaudeQuotaCredential]) { self.values = values }

  func credentials(for mode: QuotaOperatingMode) -> [ClaudeQuotaCredential] { values }

  func persist(
    _ refresh: QuotaTokenRefresh,
    replacing expectedRefreshToken: String,
    for credential: ClaudeQuotaCredential,
    mode: QuotaOperatingMode
  ) {
    recorded = refresh
  }

  func persisted() -> QuotaTokenRefresh? { recorded }
}

private actor RecordingClaudeSession: QuotaHTTPSession {
  private var queued: [(String, Int)]
  private var recorded: [URLRequest] = []

  init(responses: [(String, Int)]) { queued = responses }

  func data(for request: URLRequest) throws -> (Data, URLResponse) {
    recorded.append(request)
    let response = queued.isEmpty ? ("", 404) : queued.removeFirst()
    return (
      Data(response.0.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: nil)!
    )
  }

  func requests() -> [URLRequest] { recorded }
}

private actor RecordingExternalCredentials: ExternalCredentialReading {
  private let record: ExternalCredentialRecord?
  private var swapCount = 0

  init(record: ExternalCredentialRecord?) { self.record = record }

  func read(service: String, account: String?) -> ExternalCredentialRecord? { record }

  func compareAndSwap(
    service: String,
    account: String,
    expectedData: Data,
    newData: Data
  ) -> Bool {
    swapCount += 1
    return false
  }

  func swaps() -> Int { swapCount }
}

private actor EmptyVault: CredentialVault {
  func accounts() -> [Account] { [] }
  func credential(for accountID: String) -> StoredCredential? { nil }
  func reloadLatest(accountID: String) -> StoredCredential? { nil }
  func save(_ credential: StoredCredential, metadata: Account) throws {}
  func delete(accountID: String) {}
}

private actor EmptyMetadata: AccountMetadataRepository {
  func accounts() -> [Account] { [] }
  func disabledAccountIDs() -> Set<String> { [] }
  func saveAccount(_ account: Account) throws {}
  func deleteAccount(_ accountID: String) throws {}
  func setDisabled(_ disabled: Bool, accountID: String) throws {}
}
