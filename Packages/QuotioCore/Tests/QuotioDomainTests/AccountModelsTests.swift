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
}
