import Foundation
import LocalAuthentication
import QuotioApplication
import QuotioDomain
import Security
import XCTest
@testable import QuotioInfrastructure

final class AccountPersistenceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testAuthFileUploadValidatesNameAndJSONObject() async throws {
        let repository = FileAuthFileRepository(authDirectory: temporaryDirectory)

        for name in [
            "", " ", ".", "..", "../credentials.json", "nested/credentials.json",
            #"nested\credentials.json"#, "credentials.txt", " credentials.json",
            "credentials.json ",
        ] {
            await XCTAssertThrowsErrorAsync(
                try await repository.uploadAuthFile(name: name, content: Data("{}".utf8))
            ) { error in
                XCTAssertEqual(error as? AuthFileRepositoryError, .invalidFileName)
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await repository.uploadAuthFile(name: "codex.json", content: Data("[]".utf8))
        ) { error in
            guard case .invalidJSON = error as? AuthFileRepositoryError else {
                return XCTFail("Expected invalid JSON error")
            }
        }

        let importURL = temporaryDirectory.appendingPathComponent("credentials.json")
        try Data("[]".utf8).write(to: importURL)
        await XCTAssertThrowsErrorAsync(
            try await repository.readAuthFileForImport(from: importURL)
        ) { error in
            guard case .invalidJSON = error as? AuthFileRepositoryError else {
                return XCTFail("Expected invalid JSON error")
            }
        }
    }

    func testAuthFileUploadIsPrivateAndRefusesSymbolicLinkDestination() async throws {
        let authDirectory = temporaryDirectory.appendingPathComponent("auth", isDirectory: true)
        let repository = FileAuthFileRepository(authDirectory: authDirectory)
        let content = Data(#"{"type":"codex","access_token":"secret"}"#.utf8)

        try await repository.uploadAuthFile(name: "codex-user.json", content: content)

        let fileURL = authDirectory.appendingPathComponent("codex-user.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: authDirectory.path
        )
        let downloaded = try await repository.downloadAuthFile(name: "codex-user.json")
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(downloaded, content)

        try FileManager.default.removeItem(at: fileURL)
        let targetURL = authDirectory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: targetURL)

        await XCTAssertThrowsErrorAsync(
            try await repository.uploadAuthFile(name: "codex-user.json", content: content)
        ) { error in
            XCTAssertEqual(error as? AuthFileRepositoryError, .symbolicLinkRefused)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("{}".utf8))
    }

    func testCopilotScanUsesUsernameBeforeLegacyLoginAndRetainsAlias() async throws {
        let repository = FileAuthFileRepository(authDirectory: temporaryDirectory)
        let content = Data(
            #"{"type":"github-copilot","username":"canonical","login":"legacy","access_token":"secret"}"#.utf8
        )
        try content.write(to: temporaryDirectory.appendingPathComponent("github-copilot-file.json"))

        let scanned = await repository.scanAllAuthFiles()
        let file = try XCTUnwrap(scanned.first)

        XCTAssertEqual(file.providerID.rawValue, "github-copilot")
        XCTAssertEqual(file.login, "canonical")
        XCTAssertEqual(file.menuBarAccountKey, "canonical")
        XCTAssertEqual(file.legacyIdentityKeys, ["legacy"])
    }

    func testKiroCredentialAcceptsNumericCamelCaseExpiryAndDeviceRegistration() async throws {
        let awsDirectory = temporaryDirectory.appendingPathComponent("aws", isDirectory: true)
        try FileManager.default.createDirectory(at: awsDirectory, withIntermediateDirectories: true)
        try Data(#"{"clientIdHash":"registration"}"#.utf8)
            .write(to: awsDirectory.appendingPathComponent("kiro-auth-token.json"))
        try Data(#"{"clientId":"client-id","clientSecret":"client-secret"}"#.utf8)
            .write(to: awsDirectory.appendingPathComponent("registration.json"))
        let authURL = temporaryDirectory.appendingPathComponent("kiro-user.json")
        try Data(
            #"{"type":"kiro","accessToken":"secret","expiresAt":2000000000,"authMethod":"IdC"}"#.utf8
        ).write(to: authURL)
        let repository = FileAuthFileRepository(
            authDirectory: temporaryDirectory,
            awsSSOCacheDirectory: awsDirectory
        )
        let scanned = await repository.scanAllAuthFiles()
        let descriptor = try XCTUnwrap(scanned.first)

        let readCredential = await repository.readCredential(from: descriptor)
        let credential = try XCTUnwrap(readCredential)

        XCTAssertEqual(credential.expiresAt, "2033-05-18T03:33:20Z")
        XCTAssertEqual(credential.clientID, "client-id")
        XCTAssertEqual(credential.clientSecret, "client-secret")
        let updated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
        )
        XCTAssertEqual(updated["client_id"] as? String, "client-id")
        XCTAssertEqual(updated["client_secret"] as? String, "client-secret")
    }

    func testAccountMetadataRoundTripsVersionOnePayload() async throws {
        let url = temporaryDirectory.appendingPathComponent("accounts-v1.json")
        let repository = FileAccountMetadataRepository(url: url)
        let account = Account.make(
            providerID: AccountProviderID(rawValue: "codex"),
            accountKey: "person@example.com",
            source: .quotioKeychain,
            capabilities: [.disable, .delete]
        )

        try await repository.saveAccount(account)
        try await repository.setDisabled(true, accountID: account.id)

        let storedAccounts = await repository.accounts()
        let disabledIDs = await repository.disabledAccountIDs()
        XCTAssertEqual(storedAccounts, [account])
        XCTAssertEqual(disabledIDs, [account.id])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertNotNil(object["accounts"])
        XCTAssertNotNil(object["disabledAccountIDs"])
    }

    func testAccountMetadataPrunesLegacyGeminiAccountsAndDisabledIDs() async throws {
        let url = temporaryDirectory.appendingPathComponent("accounts-v1.json")
        let codex = Account.make(
            providerID: AccountProviderID(rawValue: "codex"),
            accountKey: "person@example.com",
            source: .nativeCredential
        )
        let codexObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(codex)) as? [String: Any]
        )
        let legacyID = "monitor-gemini"
        let payload: [String: Any] = [
            "accounts": [
                codexObject,
                [
                    "id": legacyID,
                    "provider": "gemini-cli",
                    "accountKey": "legacy",
                    "displayName": "legacy",
                    "source": "nativeCredential",
                    "canDelete": false,
                    "isDisabled": false,
                ],
            ],
            "disabledAccountIDs": [codex.id, legacyID],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let repository = FileAccountMetadataRepository(url: url)

        let storedAccounts = await repository.accounts()
        let disabledIDs = await repository.disabledAccountIDs()
        XCTAssertEqual(storedAccounts, [codex])
        XCTAssertEqual(disabledIDs, [codex.id])
    }

    func testExternalCredentialQueriesDoNotAllowAuthenticationUI() {
        let readQuery = ExternalKeychainCredentialReader.readQuery(
            service: "fixture.external",
            account: "fixture-account"
        )
        let updateQuery = ExternalKeychainCredentialReader.updateQuery(
            service: "fixture.external",
            account: "fixture-account"
        )

        XCTAssertEqual(readQuery[kSecAttrService as String] as? String, "fixture.external")
        XCTAssertEqual(readQuery[kSecAttrAccount as String] as? String, "fixture-account")
        XCTAssertTrue(
            (readQuery[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        )
        XCTAssertEqual(updateQuery[kSecAttrService as String] as? String, "fixture.external")
        XCTAssertEqual(updateQuery[kSecAttrAccount as String] as? String, "fixture-account")
        XCTAssertTrue(
            (updateQuery[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        )
    }

    func testExternalCredentialReadRestoresProcessInteractionFlag() async {
        var before: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)

        let reader = ExternalKeychainCredentialReader()
        let missingCredential = await reader.read(
            service: "fixture.external.missing.\(UUID().uuidString)",
            account: nil
        )
        let didReplaceMissingCredential = await reader.compareAndSwap(
            service: "fixture.external.missing.\(UUID().uuidString)",
            account: "fixture-account",
            expectedData: Data(),
            newData: Data("unused".utf8)
        )
        XCTAssertNil(missingCredential)
        XCTAssertFalse(didReplaceMissingCredential)

        var after: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(after.boolValue, before.boolValue)
    }

    func testKiroFallbackAccountKeysDoNotCollide() {
        let first = MonitorOAuthAuthorizer.kiroAccountKey(identity: nil, clientID: "client-1")
        let second = MonitorOAuthAuthorizer.kiroAccountKey(identity: nil, clientID: "client-2")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            MonitorOAuthAuthorizer.kiroAccountKey(
                identity: "builder@example.com",
                clientID: "client-1"
            ),
            "builder@example.com"
        )
    }

    func testAtomicWriterRefusesSymbolicLinkDestination() throws {
        let target = temporaryDirectory.appendingPathComponent("target.json")
        let link = temporaryDirectory.appendingPathComponent("link.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try SecureAtomicFileWriter.write(Data("new".utf8), to: link)
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
    }

    func testOAuthCallbackRejectsMismatchedState() throws {
        let callback = URL(string: "http://localhost/callback?code=test&state=unexpected")!

        XCTAssertThrowsError(
            try MonitorOAuthAuthorizer.authorizationCode(from: callback, expectedState: "expected")
        ) { error in
            guard case OAuthFlowFailure.stateMismatch = error else {
                return XCTFail("Expected state mismatch")
            }
        }
    }

    func testProtectedCredentialStoreRefusesUnreadableOverwrite() async {
        let protectedStore = FakeProtectedCredentialStore(readResult: .unreadable)
        let store = KeychainCredentialDataStore(
            service: "test-\(UUID().uuidString)",
            canMigrateLegacy: false,
            protectedStore: protectedStore
        )

        let record = await store.save(Data("new".utf8), accountID: "account")
        let saveCount = await protectedStore.saveCount
        XCTAssertNil(record)
        XCTAssertEqual(saveCount, 0)
    }

    func testProtectedCredentialStoreDoesNotReadBackAfterSuccessfulWrite() async {
        let protectedStore = FakeProtectedCredentialStore(readResult: .absent)
        let store = KeychainCredentialDataStore(
            service: "test-\(UUID().uuidString)",
            canMigrateLegacy: false,
            protectedStore: protectedStore
        )
        let data = Data("new".utf8)

        let record = await store.save(data, accountID: "account")
        let readCount = await protectedStore.readCount
        let saveCount = await protectedStore.saveCount

        XCTAssertEqual(record?.data, data)
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(saveCount, 1)
    }

    func testLoopbackCallbackReturnsCodeAndState() async throws {
        let transport = LoopbackOAuthCallbackTransport()
        let port = try await transport.start()
        async let callback = transport.waitForCallback(timeout: .seconds(2))

        let url = URL(string: "http://127.0.0.1:\(port)/oauth2callback?code=test-code&state=test-state")!
        _ = try await URLSession.shared.data(from: url)
        let result = try await callback
        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems

        XCTAssertEqual(items?.first(where: { $0.name == "code" })?.value, "test-code")
        XCTAssertEqual(items?.first(where: { $0.name == "state" })?.value, "test-state")
    }

    func testLoopbackCallbackTimesOut() async throws {
        let transport = LoopbackOAuthCallbackTransport()
        _ = try await transport.start()

        await XCTAssertThrowsErrorAsync(
            try await transport.waitForCallback(timeout: .milliseconds(30))
        ) { error in
            XCTAssertEqual(error as? OAuthFlowFailure, .expired)
        }
    }
}

private actor FakeProtectedCredentialStore: ProtectedCredentialDataStoring {
    let isEnabled = true
    private let result: ProtectedCredentialReadResult
    private(set) var readCount = 0
    private(set) var saveCount = 0

    init(readResult: ProtectedCredentialReadResult) {
        result = readResult
    }

    func read(service: String, account: String) -> ProtectedCredentialReadResult {
        readCount += 1
        return result
    }

    func save(_ data: Data, service: String, account: String) -> Bool {
        saveCount += 1
        return true
    }

    func delete(service: String, account: String) {}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
