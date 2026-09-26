import XCTest
import QuotioDomain
@testable import QuotioApplication

final class ProviderSettingsStateTests: XCTestCase {
    func testUnverifiedExpiredNativeSourcesAreSeparateFromAccountCount() throws {
        let provider = QuotaProvider.factoryDroid
        func account(_ key: String, verified: Bool?) -> Account {
            Account(identity: .make(providerID: .init(rawValue: provider.rawValue), accountKey: key),
                displayName: key, source: .nativeCredential, credentialReference: "factory_native", isIdentityVerified: verified)
        }
        let first = account("keychain", verified: false)
        let second = account("file", verified: false)
        let known = account("known", verified: true)
        let legacy = account("legacy", verified: nil)
        var quota = QuotaSnapshot()
        for account in [first, second, known, legacy] {
            quota.accountStates[.init(provider: provider, accountKey: account.accountKey)] =
                .init(connection: .reauthenticationRequired, quota: .notLoaded)
        }
        let state = ProviderSettingsState(provider: provider, accounts: [first, second, known, legacy],
            permissions: [], quota: quota, tracking: .init())
        XCTAssertEqual(state.accounts, [known, legacy])
        XCTAssertEqual(state.accountsNeedingIdentification, [first, second])
        XCTAssertTrue(state.needsAttention)
        XCTAssertFalse(state.isUnconnected)
        XCTAssertEqual(state.connection, .reauthenticationRequired)
        let onlyPending = ProviderSettingsState(provider: provider, accounts: [first],
            permissions: [], quota: quota, tracking: .init())
        XCTAssertFalse(onlyPending.isUnconnected)
        XCTAssertTrue(onlyPending.accounts.isEmpty)
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded.isIdentityVerified, false)

        quota.accountStates[.init(provider: provider, accountKey: first.accountKey)] =
            .init(connection: .connected, quota: .notLoaded)
        let recovered = ProviderSettingsState(provider: provider, accounts: [first],
            permissions: [], quota: quota, tracking: .init())
        XCTAssertEqual(recovered.accounts, [first])
        XCTAssertTrue(recovered.accountsNeedingIdentification.isEmpty)
        let mixed = ProviderSettingsState(provider: provider, accounts: [first, second],
            permissions: [], quota: quota, tracking: .init())
        XCTAssertEqual(mixed.connection, .connected)
        XCTAssertTrue(mixed.needsAttention)
        XCTAssertEqual(mixed.accountsNeedingIdentification, [second])
    }

    func testConnectionIsIndependentOfProviderQuotaFailureAndDisabledAccountsRemainVisible() {
        let account = Account.make(providerID: .init(rawValue: "claude"), accountKey: "fixture", source: .nativeCredential)
        var quota = QuotaSnapshot(issues: [.claude: .init(kind: .failed, occurredAt: Date(), reason: .timeout)])
        quota.accountStates[.init(provider: .claude, accountKey: account.accountKey)] = .init(connection: .connected, quota: .notLoaded)
        let state = ProviderSettingsState(provider: .claude, accounts: [account], permissions: [], quota: quota,
            tracking: .init())
        XCTAssertEqual(state.connection, .connected)
        XCTAssertEqual(state.accountStates[account.id]?.quota, .notLoaded)
        XCTAssertTrue(state.needsAttention)
        let disabled = ProviderSettingsState(provider: .claude, accounts: [account], permissions: [], quota: quota,
            tracking: .init(disabledProviders: [.claude]))
        XCTAssertEqual(disabled.connection, .disabled)
        XCTAssertEqual(disabled.accounts, [account])
        XCTAssertFalse(disabled.needsAttention)
    }

    func testUnconnectedProviderDoesNotInheritGlobalRefreshFailure() {
        let quota = QuotaSnapshot(issues: [.claude: .init(kind: .failed, occurredAt: Date(), reason: .timeout)])
        let state = ProviderSettingsState(provider: .claude, accounts: [], permissions: [], quota: quota,
            tracking: .init())
        XCTAssertTrue(state.isUnconnected)
        XCTAssertFalse(state.needsAttention)
        XCTAssertNil(state.latestIssue)
    }

    func testPendingSourceDoesNotCountAsAnAccount() {
        let state = ProviderSettingsState(provider: .claude, accounts: [],
            permissions: [.init(provider: .claude, kind: "claude_native", location: "code_keychain")],
            quota: .init(), tracking: .init())
        XCTAssertEqual(state.connection, .permissionRequired)
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertFalse(state.isUnconnected)
    }
}
