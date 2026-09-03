import CryptoKit
import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class FactoryDroidQuotaFetcherTests: XCTestCase {
  func testLocalCredentialStoreReadsFactorySchemaAndPreservesUnknownFieldsOnRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 7, count: 32)
    let cleartext = Data(
      #"{"access_token":"old","refresh_token":"refresh","active_organization_id":"org-123","unknown":"keep"}"#
        .utf8)
    let sealed = try AES.GCM.seal(cleartext, using: SymmetricKey(data: key))
    let encrypted = [
      Data(sealed.nonce).base64EncodedString(), sealed.tag.base64EncodedString(),
      sealed.ciphertext.base64EncodedString(),
    ].joined(separator: ":")
    let credentialURL = directory.appendingPathComponent("auth.v2.file")
    try Data(encrypted.utf8).write(to: credentialURL)
    try Data(key.base64EncodedString().utf8).write(
      to: directory.appendingPathComponent("auth.v2.key"))
    let store = LocalFactoryDroidCredentialStore(
      directory: directory, externalCredentials: DroidExternalCredentials())

    let loadedValue = await store.load()
    let loaded = try XCTUnwrap(loadedValue)
    XCTAssertEqual(loaded.accountKey, "org-123")
    XCTAssertEqual(loaded.sourcePath, credentialURL.path)
    let canPersist = await store.canPersist(loaded)
    XCTAssertTrue(canPersist)
    let updated = FactoryDroidCredential(
      accessToken: "new", refreshToken: "rotated",
      activeOrganizationID: loaded.activeOrganizationID, sourcePath: loaded.sourcePath)
    let didPersist = try await store.persist(updated, replacingRefreshToken: "refresh")
    XCTAssertTrue(didPersist)

    let reloadedValue = await store.load()
    let reloaded = try XCTUnwrap(reloadedValue)
    XCTAssertEqual(reloaded.accessToken, "new")
    XCTAssertEqual(reloaded.refreshToken, "rotated")
    let persisted = try String(contentsOf: credentialURL, encoding: .utf8)
    let parts = persisted.split(separator: ":")
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: XCTUnwrap(Data(base64Encoded: String(parts[0])))),
      ciphertext: XCTUnwrap(Data(base64Encoded: String(parts[2]))),
      tag: XCTUnwrap(Data(base64Encoded: String(parts[1])))
    )
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: AES.GCM.open(box, using: SymmetricKey(data: key)))
        as? [String: String])
    XCTAssertEqual(json["unknown"], "keep")
    let replacedStaleCredential = try await store.persist(updated, replacingRefreshToken: "stale")
    XCTAssertFalse(replacedStaleCredential)
  }

  func testLocalCredentialStoreLoadsNewestCredentialAcrossFormats() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileKey = Data(repeating: 7, count: 32)
    try Data(fileKey.base64EncodedString().utf8).write(
      to: directory.appendingPathComponent("auth.v2.key"))
    let fileURL = directory.appendingPathComponent("auth.v2.file")
    try Self.encryptedCredential(
      #"{"access_token":"stale-token","refresh_token":"stale-refresh","active_organization_id":"org-123"}"#,
      key: fileKey,
      nonce: Data(repeating: 1, count: 16)
    ).write(to: fileURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: fileURL.path)

    let keychainKey = Data(repeating: 9, count: 32)
    let keychainURL = directory.appendingPathComponent("auth.v2.loginkeychain")
    try Self.encryptedCredential(
      #"{"access_token":"live-token","refresh_token":"live-refresh","active_organization_id":"org-123"}"#,
      key: keychainKey,
      nonce: Data(repeating: 2, count: 16)
    ).write(to: keychainURL)
    let external = DroidExternalCredentials(
      record: ExternalCredentialRecord(
        data: Data(keychainKey.base64EncodedString().utf8),
        account: "auth-encryption-key-security-cli"))
    let store = LocalFactoryDroidCredentialStore(
      directory: directory, externalCredentials: external)

    let loaded = await store.load()
    let credential = try XCTUnwrap(loaded)

    XCTAssertEqual(credential.accessToken, "live-token")
    XCTAssertEqual(credential.refreshToken, "live-refresh")
    XCTAssertEqual(credential.sourcePath, keychainURL.path)
  }

  func testLocalCredentialStoreCoordinatesReplacementWithFactoryWriteLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentialURL = directory.appendingPathComponent("auth.encrypted")
    let lockURL = directory.appendingPathComponent("auth.v2.write.lock")
    try Data(#"{"access_token":"old-token","refresh_token":"old-refresh"}"#.utf8).write(
      to: credentialURL)
    try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
    try JSONSerialization.data(withJSONObject: [
      "token": "factory-writer",
      "pid": ProcessInfo.processInfo.processIdentifier,
    ]).write(to: lockURL.appendingPathComponent("owner.json"))
    let writer = Task.detached {
      try await Task.sleep(for: .milliseconds(50))
      try Data(#"{"access_token":"factory-token","refresh_token":"factory-refresh"}"#.utf8)
        .write(to: credentialURL)
      try FileManager.default.removeItem(at: lockURL)
    }
    let store = LocalFactoryDroidCredentialStore(
      directory: directory, externalCredentials: DroidExternalCredentials())
    let replacement = FactoryDroidCredential(
      accessToken: "quotio-token", refreshToken: "quotio-refresh",
      activeOrganizationID: nil, sourcePath: credentialURL.path)

    let persisted = try await store.persist(replacement, replacingRefreshToken: "old-refresh")
    try await writer.value

    XCTAssertFalse(persisted)
    let stored = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: credentialURL)) as? [String: String])
    XCTAssertEqual(stored["access_token"], "factory-token")
    XCTAssertEqual(stored["refresh_token"], "factory-refresh")
  }

  func testLocalCredentialStoreRequiresWritableDirectoryAndRefusesSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let target = directory.appendingPathComponent("target.json")
    let link = directory.appendingPathComponent("auth.encrypted")
    try Data(#"{"access_token":"old-token","refresh_token":"old-refresh"}"#.utf8).write(
      to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = LocalFactoryDroidCredentialStore(
      directory: directory, externalCredentials: DroidExternalCredentials())
    let linkedCredential = FactoryDroidCredential(
      accessToken: "new-token", refreshToken: "new-refresh", activeOrganizationID: nil,
      sourcePath: link.path)

    let canPersistLink = await store.canPersist(linkedCredential)
    XCTAssertFalse(canPersistLink)
    do {
      _ = try await store.persist(linkedCredential, replacingRefreshToken: "old-refresh")
      XCTFail("Expected symbolic-link destination to be refused")
    } catch {}

    try FileManager.default.removeItem(at: link)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    let targetCredential = FactoryDroidCredential(
      accessToken: "new-token", refreshToken: "old-refresh", activeOrganizationID: nil,
      sourcePath: target.path)
    let canPersistReadOnly = await store.canPersist(targetCredential)
    XCTAssertFalse(canPersistReadOnly)
  }

  func testLocalCredentialStoreReclaimsWriteLockFromTerminatedOwner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentialURL = directory.appendingPathComponent("auth.encrypted")
    let lockURL = directory.appendingPathComponent("auth.v2.write.lock")
    try Data(#"{"access_token":"old-token","refresh_token":"old-refresh"}"#.utf8).write(
      to: credentialURL)
    try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
    try JSONSerialization.data(withJSONObject: [
      "token": "abandoned-writer",
      "pid": Int32.max,
    ]).write(to: lockURL.appendingPathComponent("owner.json"))
    let store = LocalFactoryDroidCredentialStore(
      directory: directory, externalCredentials: DroidExternalCredentials())
    let replacement = FactoryDroidCredential(
      accessToken: "new-token", refreshToken: "new-refresh", activeOrganizationID: nil,
      sourcePath: credentialURL.path)

    let persisted = try await store.persist(replacement, replacingRefreshToken: "old-refresh")
    XCTAssertTrue(persisted)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    let stored = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: credentialURL)) as? [String: String])
    XCTAssertEqual(stored["access_token"], "new-token")
    XCTAssertEqual(stored["refresh_token"], "new-refresh")
  }

  func testFetchesScopedLocalAccountInBothModesWithFactoryMappingsAndHeaders() async throws
  {
    let local = FactoryDroidCredential(
      accessToken: Self.validToken, refreshToken: nil, activeOrganizationID: "org-local",
      sourcePath: "/tmp/auth.v2.file")
    let session = DroidSession { request in
      if request.url?.path == "/api/app/auth/me" {
        return (#"{"userProfile":{"email":" factory@example.com "}}"#, 200)
      }
      return (Self.limitsBody, 200)
    }
    let fetcher = FactoryDroidQuotaFetcher(
      vault: DroidVault(), metadata: DroidMetadata(),
      localCredentials: DroidCredentialSource(local), credentialWriter: DroidCredentialWriter(),
      session: session,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .factoryDroid, scope: .account("org-local"), mode: mode))
      XCTAssertEqual(Set(output.quotas.keys), ["org-local"])
      XCTAssertEqual(output.credentialAvailability, .present)
      let quota = try XCTUnwrap(output.quotas["org-local"])
      XCTAssertEqual(quota.accountDisplayName, "factory@example.com")
      XCTAssertEqual(quota.models.first { $0.name == "factory-standard-weekly" }?.percentage, 37)
      XCTAssertEqual(quota.models.first { $0.name == "factory-core-five-hour" }?.percentage, 0)
      XCTAssertEqual(
        quota.models.first { $0.name == "factory-extra-balance" }?.presentation,
        .amount(value: 1.25, unit: .usd, semantics: .balance))
    }
    let requests = await session.requests()
    XCTAssertEqual(requests.count, 4)
    XCTAssertTrue(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.validToken)"
      })
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
  }

  func testRefreshesLocalCredentialOnceOnlyForUnauthorizedAndMapsForbidden() async throws {
    let local = FactoryDroidCredential(
      accessToken: Self.validToken, refreshToken: "refresh + token",
      activeOrganizationID: "org-123", sourcePath: "/tmp/auth.v2.file")
    let session = DroidSession { request in
      if request.url?.host == "api.workos.com" {
        return (#"{"access_token":"new-token","refresh_token":"new-refresh"}"#, 200)
      }
      if request.url?.path == "/api/app/auth/me" { return ("{}", 500) }
      return request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token"
        ? (Self.limitsBody, 200) : ("denied", 401)
    }
    let writer = DroidCredentialWriter()
    let fetcher = FactoryDroidQuotaFetcher(
      vault: DroidVault(), metadata: DroidMetadata(),
      localCredentials: DroidCredentialSource(local),
      credentialWriter: writer, session: session,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    let output = try await fetcher.fetch(.init(provider: .factoryDroid, mode: .monitor))
    XCTAssertNotNil(output.quotas["org-123"])
    let persisted = await writer.persisted()
    XCTAssertEqual(persisted.first?.accessToken, "new-token")
    let recorded = await session.requests()
    let refresh = try XCTUnwrap(recorded.first { $0.url?.host == "api.workos.com" })
    XCTAssertEqual(refresh.httpMethod, "POST")
    XCTAssertEqual(
      refresh.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    XCTAssertTrue(
      String(decoding: try XCTUnwrap(refresh.httpBody), as: UTF8.self).contains(
        "refresh_token=refresh%20%2B%20token"))

    let account = Account.make(
      providerID: .init(rawValue: QuotaProvider.factoryDroid.rawValue), accountKey: "vault",
      source: .quotioKeychain)
    let forbidden = FactoryDroidQuotaFetcher(
      vault: DroidVault(accounts: [account], tokens: [account.id: "token"]),
      metadata: DroidMetadata(),
      localCredentials: DroidCredentialSource(nil), credentialWriter: writer,
      session: DroidSession { request in
        request.url?.path == "/api/billing/limits" ? ("denied", 403) : ("{}", 500)
      }
    )
    let localOutput = try await forbidden.fetch(
      .init(provider: .factoryDroid, mode: .localProxy))
    let forbiddenOutput = try await forbidden.fetch(
      .init(provider: .factoryDroid, mode: .monitor))
    XCTAssertTrue(localOutput.quotas.isEmpty)
    XCTAssertEqual(localOutput.credentialAvailability, .missing)
    XCTAssertEqual(forbiddenOutput.quotas["vault"]?.isForbidden, true)
    XCTAssertTrue(FactoryDroidQuotaFetcher.shouldRefresh(statusCode: 401, didRefresh: false))
    XCTAssertFalse(FactoryDroidQuotaFetcher.shouldRefresh(statusCode: 403, didRefresh: false))
    XCTAssertFalse(FactoryDroidQuotaFetcher.shouldRefresh(statusCode: 401, didRefresh: true))
  }

  func testMapsAllFactoryWindowsExtraBalanceAndLegacyBilling() throws {
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-20T18:30:00Z"))
    let payload = Data(
      #"{"usesTokenRateLimitsBilling":true,"limits":{"standard":{"fiveHour":{"usedPercent":100,"windowEnd":"2026-07-20T17:59:00.865Z"},"weekly":{"usedPercent":63,"windowEnd":"2026-07-25T16:37:06.931Z"},"monthly":{"usedPercent":16,"windowEnd":"2026-08-17T16:37:06.931Z"}},"core":{"fiveHour":{"usedPercent":100,"windowEnd":"2026-07-20T19:01:10.798Z"},"weekly":{"usedPercent":51,"windowEnd":"2026-07-27T14:01:10.798Z"},"monthly":{"usedPercent":19,"windowEnd":"2026-08-19T14:01:10.798Z"}}},"extraUsageBalanceCents":0}"#
        .utf8)

    let quota = try XCTUnwrap(FactoryDroidQuotaFetcher.map(payload, now: now))

    XCTAssertEqual(quota.models.map(\.name), [
      "factory-standard-five-hour", "factory-standard-weekly", "factory-standard-monthly",
      "factory-core-five-hour", "factory-core-weekly", "factory-core-monthly",
      "factory-extra-balance",
    ])
    XCTAssertEqual(quota.models.map(\.percentage), [100, 37, 84, 0, 49, 81, -1])
    XCTAssertEqual(
      quota.models.last?.presentation, .amount(value: 0, unit: .usd, semantics: .balance))

    let legacy = try XCTUnwrap(
      FactoryDroidQuotaFetcher.map(
        Data(#"{"usesTokenRateLimitsBilling":false}"#.utf8), now: now))
    XCTAssertEqual(legacy.models.first?.name, "factory-billing-mode")
    XCTAssertEqual(legacy.models.first?.presentation, .status(text: "legacy-billing"))
  }

  private static func encryptedCredential(_ json: String, key: Data, nonce: Data) throws -> Data {
    let sealed = try AES.GCM.seal(
      Data(json.utf8), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
    return Data(
      [
        Data(sealed.nonce).base64EncodedString(), sealed.tag.base64EncodedString(),
        sealed.ciphertext.base64EncodedString(),
      ].joined(separator: ":").utf8)
  }

  private static let validToken =
    "x." + Data(#"{"exp":4102444800}"#.utf8).base64EncodedString() + ".x"
  private static let limitsBody =
    #"{"usesTokenRateLimitsBilling":true,"limits":{"standard":{"weekly":{"usedPercent":63,"windowEnd":"2099-07-25T16:37:06.931Z"}},"core":{"fiveHour":{"usedPercent":100,"windowEnd":"2099-07-20T19:01:10.798Z"}}},"extraUsageBalanceCents":125}"#
}

private actor DroidSession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  private let handler: Handler
  private var recorded: [URLRequest] = []
  init(_ handler: @escaping Handler) { self.handler = handler }
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.append(request)
    let result = handler(request)
    return (
      Data(result.0.utf8),
      HTTPURLResponse(url: request.url!, statusCode: result.1, httpVersion: nil, headerFields: nil)!
    )
  }
  func requests() -> [URLRequest] { recorded }
}

private struct DroidCredentialSource: FactoryDroidCredentialLoading {
  let credential: FactoryDroidCredential?
  init(_ credential: FactoryDroidCredential?) { self.credential = credential }
  func load() async -> FactoryDroidCredential? { credential }
}

private actor DroidCredentialWriter: FactoryDroidCredentialPersisting {
  private var values: [FactoryDroidCredential] = []
  func canPersist(_ credential: FactoryDroidCredential) -> Bool { true }
  func persist(_ credential: FactoryDroidCredential, replacingRefreshToken: String) throws -> Bool {
    values.append(credential)
    return true
  }
  func persisted() -> [FactoryDroidCredential] { values }
}

private actor DroidExternalCredentials: ExternalCredentialReading {
  private let record: ExternalCredentialRecord?
  init(record: ExternalCredentialRecord? = nil) { self.record = record }
  func read(service: String, account: String?) -> ExternalCredentialRecord? { record }
  func compareAndSwap(service: String, account: String, expectedData: Data, newData: Data) -> Bool {
    false
  }
}

private actor DroidVault: CredentialVault {
  let storedAccounts: [Account]
  let tokens: [String: String]
  init(accounts: [Account] = [], tokens: [String: String] = [:]) {
    storedAccounts = accounts
    self.tokens = tokens
  }
  func accounts() -> [Account] { storedAccounts }
  func credential(for accountID: String) -> StoredCredential? {
    tokens[accountID].map {
      .init(
        accessToken: $0, refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil, extra: [:]
      )
    }
  }
  func reloadLatest(accountID: String) -> StoredCredential? { credential(for: accountID) }
  func save(_ credential: StoredCredential, metadata: Account) throws {}
  func delete(accountID: String) {}
}

private actor DroidMetadata: AccountMetadataRepository {
  func accounts() -> [Account] { [] }
  func disabledAccountIDs() -> Set<String> { [] }
  func saveAccount(_ account: Account) throws {}
  func deleteAccount(_ accountID: String) throws {}
  func setDisabled(_ disabled: Bool, accountID: String) throws {}
}
