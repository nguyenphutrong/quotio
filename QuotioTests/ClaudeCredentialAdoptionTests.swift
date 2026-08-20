import XCTest
@testable import Quotio

private actor FakeCredentialStore: MonitorCredentialStore {
    private var storedAccounts: [MonitorAccount] = []
    private var credentials: [String: MonitorOAuthCredential] = [:]
    private(set) var saveCount = 0

    init(seeding account: MonitorAccount? = nil, credential: MonitorOAuthCredential? = nil) {
        if let account {
            storedAccounts = [account]
            credentials[account.id] = credential
        }
    }

    func accounts() async -> [MonitorAccount] { storedAccounts }
    func credential(for accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }

    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) async throws {
        saveCount += 1
        credentials[metadata.id] = credential
        storedAccounts.removeAll { $0.id == metadata.id }
        storedAccounts.append(metadata)
    }

    func delete(accountID: String) async {
        credentials.removeValue(forKey: accountID)
        storedAccounts.removeAll { $0.id == accountID }
    }
}

final class ClaudeCredentialAdoptionTests: XCTestCase {
    private func credentialBlob(_ oauth: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    func testParseReadsTokenEmailAndMillisecondExpiry() throws {
        let expiry = Date().addingTimeInterval(3600)
        let data = credentialBlob([
            "accessToken": "access-abc",
            "refreshToken": "refresh-xyz",
            "email": "me@example.com",
            "subscriptionType": "max",
            "expiresAt": expiry.timeIntervalSince1970 * 1000,
        ])

        let parsed = try XCTUnwrap(ClaudeCredentialAdopter.parse(data))

        XCTAssertEqual(parsed.email, "me@example.com")
        XCTAssertEqual(parsed.credential.accessToken, "access-abc")
        XCTAssertEqual(parsed.credential.extra["subscriptionType"], "max")
        let expiresAt = try XCTUnwrap(parsed.credential.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
    }

    /// Claude Code's refresh tokens are single-use and the CLI treats a spent one
    /// as fatal, so Quotio must not even be able to spend it: the copy keeps the
    /// access token and drops the refresh token on the floor.
    func testParseDiscardsRefreshTokenSoItCanNeverBeSpent() throws {
        let data = credentialBlob([
            "accessToken": "access-abc",
            "refreshToken": "refresh-xyz",
            "email": "me@example.com",
        ])

        let parsed = try XCTUnwrap(ClaudeCredentialAdopter.parse(data))

        XCTAssertNil(parsed.credential.refreshToken)
        XCTAssertEqual(parsed.credential.accessToken, "access-abc")
    }

    func testAdoptedCopyIsDistinguishableFromAQuotioLogin() {
        let adopted = MonitorAccount.make(
            provider: .claude,
            accountKey: "me@example.com",
            source: .quotioKeychain,
            credentialReference: ClaudeCredentialAdopter.credentialReference
        )
        let signedIn = MonitorAccount.make(
            provider: .claude,
            accountKey: "me@example.com",
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )

        XCTAssertTrue(ClaudeCredentialAdopter.isCopyOfCLICredential(adopted))
        XCTAssertFalse(ClaudeCredentialAdopter.isCopyOfCLICredential(signedIn))
    }

    func testParseFallsBackToPlaceholderKeyWhenCredentialCarriesNoEmail() throws {
        let data = credentialBlob(["accessToken": "access-abc"])

        let parsed = try XCTUnwrap(ClaudeCredentialAdopter.parse(data))

        XCTAssertEqual(parsed.email, "Claude Code")
        XCTAssertNil(parsed.credential.refreshToken)
        XCTAssertNil(parsed.credential.expiresAt)
    }

    func testParseRejectsCredentialWithoutAccessToken() {
        XCTAssertNil(ClaudeCredentialAdopter.parse(credentialBlob(["refreshToken": "refresh-xyz"])))
        XCTAssertNil(ClaudeCredentialAdopter.parse(credentialBlob(["accessToken": "   "])))
        XCTAssertNil(ClaudeCredentialAdopter.parse(Data("not json".utf8)))
    }

    /// The whole point of adoption: once Quotio owns a copy, nothing goes back to
    /// the CLI's keychain item. `adopt` is the only path that reads that item and
    /// it always writes on success, so a save-free call proves it was skipped.
    func testAdoptionIsSkippedOnceQuotioOwnsTheCredential() async {
        let owned = MonitorAccount.make(
            provider: .claude,
            accountKey: "me@example.com",
            source: .quotioKeychain,
            credentialReference: ClaudeCredentialAdopter.credentialReference
        )
        let store = FakeCredentialStore(
            seeding: owned,
            credential: MonitorOAuthCredential(
                accessToken: "access-abc",
                refreshToken: nil,
                idToken: nil,
                accountID: nil,
                expiresAt: Date().addingTimeInterval(3600),
                extra: [:]
            )
        )
        let adopter = ClaudeCredentialAdopter(vault: store)

        let resolved = await adopter.adoptIfNeeded()

        XCTAssertEqual(resolved?.id, owned.id)
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 0)
    }

    /// Once the user signs in to Quotio, that credential must win: it is the only
    /// one with an independent refresh lineage, so it can be kept alive.
    func testSignedInCredentialIsPreferredOverAnAdoptedCopy() async {
        let copy = MonitorAccount.make(
            provider: .claude,
            accountKey: "copy@example.com",
            source: .quotioKeychain,
            credentialReference: ClaudeCredentialAdopter.credentialReference
        )
        let signedIn = MonitorAccount.make(
            provider: .claude,
            accountKey: "signed-in@example.com",
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )
        let store = FakeCredentialStore(seeding: copy, credential: nil)
        try? await store.save(
            MonitorOAuthCredential(
                accessToken: "access-def",
                refreshToken: "refresh-uvw",
                idToken: nil,
                accountID: nil,
                expiresAt: Date().addingTimeInterval(3600),
                extra: [:]
            ),
            metadata: signedIn
        )
        let adopter = ClaudeCredentialAdopter(vault: store)

        let resolved = await adopter.ownedAccount()

        XCTAssertEqual(resolved?.id, signedIn.id)
    }

    /// A credential discovered from the CLI must outrank the file- and
    /// keychain-derived candidates for the same login, so the adopted copy is the
    /// one the app actually polls.
    func testAdoptedAccountOutranksNativeCandidatesForSameLogin() {
        let adopted = MonitorAccount.make(
            provider: .claude,
            accountKey: "me@example.com",
            source: .quotioKeychain,
            credentialReference: "keychain"
        )
        let native = MonitorAccount.make(
            provider: .claude,
            accountKey: "me@example.com",
            source: .nativeCredential,
            credentialReference: "~/.claude/.credentials.json"
        )

        let selected = MonitorAccountDiscovery.selectPreferred([native, adopted])

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.source, .quotioKeychain)
    }
}
