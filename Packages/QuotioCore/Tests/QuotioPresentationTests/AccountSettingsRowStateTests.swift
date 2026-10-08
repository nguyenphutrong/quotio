import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioPresentation

final class AccountSettingsRowStateTests: XCTestCase {
    private let provider = QuotaProvider.claude
    private let now = Date(timeIntervalSince1970: 10_000)

    private func account(_ key: String, sourceIDs: [String], disabled: Bool = false) -> Account {
        Account(identity: .make(providerID: .init(rawValue: provider.rawValue), accountKey: key),
            displayName: key, source: .nativeCredential, enabled: !disabled,
            sources: sourceIDs.map { AccountLoginSource(accountID: $0, source: .nativeCredential,
                credentialReference: "claude_native", status: .ready) })
    }

    private func id(_ account: Account) -> QuotaAccountID {
        QuotaAccountID(provider: provider, accountKey: account.accountKey)
    }

    func testSourceIssueMarksOnlyTheAffectedAccount() {
        let work = account("work", sourceIDs: ["work-code", "work-vault"])
        let personal = account("personal", sourceIDs: ["personal-code"])
        let connected = AccountMonitoringState(connection: .connected, quota: .fresh)
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: now, reason: .authentication, recoveryAction: .signIn)
        let snapshot = QuotaSnapshot(
            accountStates: [id(work): connected, id(personal): connected],
            quotas: [provider: ["work": ProviderQuota(lastUpdated: now), "personal": ProviderQuota(lastUpdated: now)]],
            sourceIssues: [provider: ["work-vault": issue]]
        )

        let workRow = AccountSettingsRowState(account: work, provider: provider, snapshot: snapshot, tracked: true)
        let personalRow = AccountSettingsRowState(account: personal, provider: provider, snapshot: snapshot, tracked: true)

        XCTAssertEqual(workRow.tone, .attention)
        XCTAssertEqual(workRow.issueSourceID, "work-vault")
        XCTAssertEqual(personalRow.tone, .connected)
        XCTAssertNil(personalRow.issue)

        let state = ProviderSettingsState(provider: provider, accounts: [work, personal], permissions: [],
            quota: snapshot, tracking: .init())
        let summary = ProviderAccountsSummary(state: state, snapshot: snapshot, tracked: true)
        XCTAssertEqual(summary.attentionCount, 1)
        XCTAssertNil(summary.providerIssue)
    }

    func testFailedQuotaIssueIsAttributedToTheActiveSource() {
        let work = account("work", sourceIDs: ["work-code", "work-vault"])
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: now, reason: .timeout, recoveryAction: .retry)
        let snapshot = QuotaSnapshot(
            accountStates: [id(work): .init(connection: .connected, quota: .failed(.timeout))],
            accountIDs: [provider: ["work": "work-code"]],
            accountIssues: [id(work): issue]
        )

        let row = AccountSettingsRowState(account: work, provider: provider, snapshot: snapshot, tracked: true)

        XCTAssertEqual(row.tone, .attention)
        XCTAssertEqual(row.issue, issue)
        XCTAssertEqual(row.issueSourceID, "work-code")
        XCTAssertEqual(row.activeSourceID, "work-code")
    }

    func testPausedAccountsAndUntrackedProvidersNeverNeedAttention() {
        let paused = account("paused", sourceIDs: ["paused-code"], disabled: true)
        let active = account("active", sourceIDs: ["active-code"])
        let issue = QuotaRefreshIssue(kind: .failed, occurredAt: now, reason: .authentication)
        let snapshot = QuotaSnapshot(
            accountStates: [id(active): .init(connection: .reauthenticationRequired, quota: .failed(.authentication))],
            accountIssues: [id(active): issue],
            sourceIssues: [provider: ["paused-code": issue]]
        )

        XCTAssertEqual(AccountSettingsRowState(account: paused, provider: provider, snapshot: snapshot, tracked: true).tone, .inactive)
        let untracked = AccountSettingsRowState(account: active, provider: provider, snapshot: snapshot, tracked: false)
        XCTAssertEqual(untracked.tone, .inactive)
        XCTAssertNil(untracked.issue)

        let state = ProviderSettingsState(provider: provider, accounts: [paused, active], permissions: [],
            quota: snapshot, tracking: .init(disabledProviders: [provider]))
        XCTAssertEqual(ProviderAccountsSummary(state: state, snapshot: snapshot, tracked: false).attentionCount, 0)
    }

    func testProviderIssueShowsOnlyUntilAnAccountRefreshesAfterIt() {
        let work = account("work", sourceIDs: ["work-code"])
        let permission = NativeSourcePermission(provider: provider, kind: "claude_native", location: "code_keychain")
        func summary(issueAt: Date) -> ProviderAccountsSummary {
            let snapshot = QuotaSnapshot(
                accountStates: [id(work): .init(connection: .connected, quota: .fresh)],
                quotas: [provider: ["work": ProviderQuota(lastUpdated: now)]],
                issues: [provider: .init(kind: .failed, occurredAt: issueAt, reason: .transient)]
            )
            let state = ProviderSettingsState(provider: provider, accounts: [work], permissions: [permission],
                quota: snapshot, tracking: .init())
            return ProviderAccountsSummary(state: state, snapshot: snapshot, tracked: true)
        }

        let superseded = summary(issueAt: now.addingTimeInterval(-60))
        XCTAssertNil(superseded.providerIssue)
        XCTAssertEqual(superseded.attentionCount, 1, "Only the pending Keychain permission needs attention")

        let current = summary(issueAt: now.addingTimeInterval(60))
        XCTAssertNotNil(current.providerIssue)
        XCTAssertEqual(current.attentionCount, 2)
    }
}
