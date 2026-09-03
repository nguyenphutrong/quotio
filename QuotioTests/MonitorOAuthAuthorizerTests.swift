import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import Quotio

final class MonitorOAuthAuthorizerTests: XCTestCase {
    func testCancellationDuringCredentialWriteRestoresPreviousCredential() async throws {
        let providerID = AccountProviderID(rawValue: AIProvider.claude.rawValue)
        let attemptID = OAuthAttemptID()
        let account = Account.make(
            providerID: providerID,
            accountKey: "person@example.com",
            source: .quotioKeychain,
            capabilities: [.disable, .delete]
        )
        let previousCredential = StoredCredential(
            accessToken: "previous-access-token",
            refreshToken: "previous-refresh-token",
            idToken: nil,
            accountID: "previous-account-id",
            expiresAt: nil,
            extra: [:]
        )
        let vault = SuspendingOAuthCredentialVault()
        await vault.seed(previousCredential, account: account)
        let callbackTransport = RecordingOAuthCallbackTransport()
        let authorizer = MonitorOAuthAuthorizer(
            vault: vault,
            urlOpener: SuccessfulOAuthURLOpener(),
            callbackTransport: callbackTransport,
            httpTransport: ClaudeTokenHTTPTransport()
        ) { _, _, _, _, _ in nil }

        let outcome = try await authorizer.begin(
            request: OAuthAuthorizationRequest(providerID: providerID),
            attemptID: attemptID,
            progress: { _ in }
        )
        guard case .awaitingManualCode(_, let state) = outcome else {
            return XCTFail("Expected manual authorization code state")
        }

        let completion = Task {
            try await authorizer.completeManualCode(
                "authorization-code#\(state)",
                providerID: providerID,
                attemptID: attemptID
            )
        }
        await vault.waitUntilSaveStarts()
        let cancellation = Task {
            await authorizer.cancel(attemptID: attemptID)
        }
        await callbackTransport.waitUntilStopped()
        await vault.resumeSave()
        await cancellation.value

        do {
            _ = try await completion.value
            XCTFail("Expected the cancelled authorization attempt to fail")
        } catch is CancellationError {
            // Expected.
        }
        let restoredCredential = await vault.credential(for: account.id)
        let restoredAccounts = await vault.accounts()
        XCTAssertEqual(restoredCredential, previousCredential)
        XCTAssertEqual(restoredAccounts, [account])
    }
}

@MainActor
private final class SuccessfulOAuthURLOpener: URLOpening {
    func open(_ url: URL) -> Bool { true }
}

private actor ClaudeTokenHTTPTransport: OAuthHTTPTransport {
    func send(_ request: OAuthHTTPRequest) throws -> OAuthHTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": "replacement-access-token",
            "refresh_token": "replacement-refresh-token",
            "account": [
                "email_address": "person@example.com",
                "uuid": "replacement-account-id",
            ],
        ])
        return OAuthHTTPResponse(statusCode: 200, body: body)
    }
}

private actor RecordingOAuthCallbackTransport: OAuthCallbackTransport {
    private var isStopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func start(preferredPort: UInt16?) -> UInt16 { preferredPort ?? 0 }

    func waitForCallback(timeout: Duration) throws -> URL {
        throw OAuthFlowFailure.expired
    }

    func stop() {
        isStopped = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStopped() async {
        guard !isStopped else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }
}

private actor SuspendingOAuthCredentialVault: CredentialVault {
    private var storedAccounts: [Account] = []
    private var storedCredentials: [String: StoredCredential] = [:]
    private var shouldSuspendNextSave = true
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []

    func seed(_ credential: StoredCredential, account: Account) {
        storedAccounts = [account]
        storedCredentials[account.id] = credential
    }

    func accounts() -> [Account] { storedAccounts }

    func credential(for accountID: String) -> StoredCredential? {
        storedCredentials[accountID]
    }

    func reloadLatest(accountID: String) -> StoredCredential? {
        storedCredentials[accountID]
    }

    func save(_ credential: StoredCredential, metadata account: Account) async {
        if shouldSuspendNextSave {
            shouldSuspendNextSave = false
            let waiters = saveStartWaiters
            saveStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                saveContinuation = continuation
            }
        }
        storedAccounts.removeAll { $0.id == account.id }
        storedAccounts.append(account)
        storedCredentials[account.id] = credential
    }

    func delete(accountID: String) {
        storedAccounts.removeAll { $0.id == accountID }
        storedCredentials.removeValue(forKey: accountID)
    }

    func waitUntilSaveStarts() async {
        guard shouldSuspendNextSave else { return }
        await withCheckedContinuation { continuation in
            saveStartWaiters.append(continuation)
        }
    }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}
