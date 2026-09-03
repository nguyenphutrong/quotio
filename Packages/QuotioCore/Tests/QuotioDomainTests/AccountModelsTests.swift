import Foundation
import XCTest
@testable import QuotioDomain

final class AccountModelsTests: XCTestCase {
    func testIdentityPreservesExistingStableMonitorID() {
        let identity = AccountIdentity.make(
            providerID: AccountProviderID(rawValue: "codex"),
            accountKey: " Person@Example.com "
        )

        XCTAssertEqual(identity.id, "monitor-a8110b8da0533693c274")
        XCTAssertEqual(identity.accountKey, "Person@Example.com")
        XCTAssertEqual(identity.deduplicationKey, "codex:person@example.com")
    }

    func testAccountCodingPreservesVersionOneMetadataShape() throws {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: "claude"),
            accountKey: "person@example.com",
            source: .quotioKeychain,
            credentialReference: "keychain",
            capabilities: [.disable, .delete],
            status: .disabled,
            credentialMetadata: RedactedCredentialMetadata(
                kind: .oauth,
                hasRefreshToken: true,
                hasAccountIdentifier: true
            )
        )

        let data = try JSONEncoder().encode(account)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["provider"] as? String, "claude")
        XCTAssertEqual(object["canDelete"] as? Bool, true)
        XCTAssertEqual(object["isDisabled"] as? Bool, true)
        XCTAssertNil(object["credentialMetadata"])
        XCTAssertNil(object["capabilities"])
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(decoded.identity, account.identity)
        XCTAssertEqual(decoded.source, account.source)
        XCTAssertEqual(decoded.capabilities, account.capabilities)
        XCTAssertEqual(decoded.status, account.status)
        XCTAssertNil(decoded.credentialMetadata)
    }

    func testPreferredAccountUsesSourcePriorityAndDisabledMetadata() {
        let providerID = AccountProviderID(rawValue: "codex")
        let legacy = Account.make(
            providerID: providerID,
            accountKey: "person@example.com",
            source: .legacyCLIProxy
        )
        let native = Account.make(
            providerID: providerID,
            accountKey: "PERSON@example.com",
            source: .nativeCredential
        )

        let selected = AccountSelectionPolicy.preferred([legacy, native], disabledIDs: [native.id])

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.source, .nativeCredential)
        XCTAssertEqual(selected.first?.status, .disabled)
    }

    func testMergingQuotaAccountsAddsImportedIDEAccountWithoutDuplicatingCredentialAccount() {
        let codex = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.codex.rawValue),
            accountKey: "person@example.com",
            source: .nativeCredential
        )
        let quota = ProviderQuota(
            models: [],
            accountDisplayName: "Person"
        )

        let merged = AccountSelectionPolicy.mergingQuotaAccounts(
            [codex],
            quotas: [
                .codex: ["person@example.com": quota],
                .cursor: ["cursor@example.com": quota],
            ]
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.filter { $0.providerID.rawValue == QuotaProvider.codex.rawValue }.count, 1)
        let cursor = merged.first { $0.providerID.rawValue == QuotaProvider.cursor.rawValue }
        XCTAssertEqual(cursor?.source, .localIDE)
        XCTAssertEqual(cursor?.displayName, "Person")
        XCTAssertEqual(cursor?.canDelete, true)
    }

    func testMergingQuotaDisplayNameDoesNotChangeExistingAccountIdentity() {
        let account = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.factoryDroid.rawValue),
            accountKey: "org-123",
            displayName: "Factory Droid",
            source: .nativeCredential
        )
        let quota = ProviderQuota(accountDisplayName: "factory@example.com")

        let merged = AccountSelectionPolicy.mergingQuotaAccounts(
            [account],
            quotas: [.factoryDroid: [account.accountKey: quota]]
        )

        XCTAssertEqual(merged.first?.displayName, "factory@example.com")
        XCTAssertEqual(merged.first?.accountKey, account.accountKey)
        XCTAssertEqual(merged.first?.id, account.id)
    }

    func testMergingQuotaAccountsHidesGenericPlaceholderWhenSpecificAccountExists() {
        let specific = Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.claude.rawValue),
            accountKey: "person@example.com",
            source: .nativeCredential
        )

        let merged = AccountSelectionPolicy.mergingQuotaAccounts(
            [specific],
            quotas: [.claude: ["Claude Code": ProviderQuota()]]
        )

        XCTAssertEqual(merged, [specific])
    }
}
