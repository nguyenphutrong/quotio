import Foundation
import XCTest
@testable import QuotioApplication
import QuotioDomain

final class OAuthFlowControllerTests: XCTestCase {
    func testStartingNewAttemptCancelsOldAttemptAndIgnoresItsCompletion() async {
        let authorizer = ControllableOAuthAuthorizer()
        let controller = OAuthFlowController(authorizer: authorizer)
        let firstProvider = AccountProviderID(rawValue: "codex")
        let secondProvider = AccountProviderID(rawValue: "claude")

        await controller.start(OAuthAuthorizationRequest(providerID: firstProvider))
        let firstAttempt = await authorizer.waitForAttempt(providerID: firstProvider)
        await controller.start(OAuthAuthorizationRequest(providerID: secondProvider))
        let secondAttempt = await authorizer.waitForAttempt(providerID: secondProvider)

        await authorizer.succeed(attemptID: firstAttempt, providerID: firstProvider)
        try? await Task.sleep(for: .milliseconds(10))
        let stateAfterStaleCompletion = await controller.state
        XCTAssertEqual(stateAfterStaleCompletion, .authorizing(providerID: secondProvider))

        await authorizer.succeed(attemptID: secondAttempt, providerID: secondProvider)
        await waitUntil {
            await controller.state == .succeeded(
                providerID: secondProvider,
                accountID: AccountIdentity.make(
                    providerID: secondProvider,
                    accountKey: "person@example.com"
                ).id
            )
        }
        let cancelledFirstAttempt = await authorizer.wasCancelled(firstAttempt)
        XCTAssertTrue(cancelledFirstAttempt)
    }

    func testCancelClearsStateAndRejectsLateProgress() async {
        let authorizer = ControllableOAuthAuthorizer()
        let controller = OAuthFlowController(authorizer: authorizer)
        let providerID = AccountProviderID(rawValue: "github-copilot")

        await controller.start(OAuthAuthorizationRequest(providerID: providerID))
        let attempt = await authorizer.waitForAttempt(providerID: providerID)
        await controller.cancel()
        await authorizer.reportPrompt(attemptID: attempt)

        try? await Task.sleep(for: .milliseconds(10))
        let stateAfterLateProgress = await controller.state
        let cancelledAttempt = await authorizer.wasCancelled(attempt)
        XCTAssertEqual(stateAfterLateProgress, .idle)
        XCTAssertTrue(cancelledAttempt)
    }

    func testFailedAttemptIsCancelledBeforePublishingFailure() async {
        let authorizer = ControllableOAuthAuthorizer()
        let controller = OAuthFlowController(authorizer: authorizer)
        let providerID = AccountProviderID(rawValue: "codex")

        await controller.start(OAuthAuthorizationRequest(providerID: providerID))
        let attempt = await authorizer.waitForAttempt(providerID: providerID)
        await authorizer.fail(attemptID: attempt, failure: .expired)

        await waitUntil {
            await controller.state == .failed(providerID: providerID, failure: .expired)
        }
        let cancelledAttempt = await authorizer.wasCancelled(attempt)
        XCTAssertTrue(cancelledAttempt)
    }

    func testManualCompletionBelongsToCurrentAttempt() async {
        let authorizer = ControllableOAuthAuthorizer(manualProvider: "claude")
        let controller = OAuthFlowController(authorizer: authorizer)
        let providerID = AccountProviderID(rawValue: "claude")

        await controller.start(OAuthAuthorizationRequest(providerID: providerID))
        await waitUntil {
            if case .awaitingManualCode = await controller.state { return true }
            return false
        }
        await controller.completeManualCode("code#state")

        await waitUntil {
            if case .succeeded(providerID, _) = await controller.state {
                return providerID == AccountProviderID(rawValue: "claude")
            }
            return false
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor ControllableOAuthAuthorizer: OAuthAuthorizing {
    private struct Pending {
        let providerID: AccountProviderID
        let progress: @Sendable (OAuthPrompt) async -> Void
        let continuation: CheckedContinuation<OAuthAuthorizationOutcome, Error>
    }

    private let manualProvider: String?
    private var pending: [OAuthAttemptID: Pending] = [:]
    private var cancelled: Set<OAuthAttemptID> = []

    init(manualProvider: String? = nil) {
        self.manualProvider = manualProvider
    }

    func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        let providerID = request.providerID
        if providerID.rawValue == manualProvider {
            return .awaitingManualCode(
                prompt: OAuthPrompt(authorizationURL: URL(string: "https://example.com")!),
                state: "state"
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[attemptID] = Pending(
                providerID: providerID,
                progress: progress,
                continuation: continuation
            )
        }
    }

    func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) -> Account {
        Account.make(
            providerID: providerID,
            accountKey: "person@example.com",
            source: .quotioKeychain,
            capabilities: [.disable, .delete]
        )
    }

    func cancel(attemptID: OAuthAttemptID) {
        cancelled.insert(attemptID)
        pending.removeValue(forKey: attemptID)?.continuation.resume(throwing: CancellationError())
    }

    func waitForAttempt(providerID: AccountProviderID) async -> OAuthAttemptID {
        while true {
            if let attempt = pending.first(where: { $0.value.providerID == providerID })?.key {
                return attempt
            }
            await Task.yield()
        }
    }

    func succeed(attemptID: OAuthAttemptID, providerID: AccountProviderID) {
        pending.removeValue(forKey: attemptID)?.continuation.resume(returning: .completed(
            Account.make(
                providerID: providerID,
                accountKey: "person@example.com",
                source: .quotioKeychain,
                capabilities: [.disable, .delete]
            )
        ))
    }

    func fail(attemptID: OAuthAttemptID, failure: OAuthFlowFailure) {
        pending.removeValue(forKey: attemptID)?.continuation.resume(throwing: failure)
    }

    func reportPrompt(attemptID: OAuthAttemptID) async {
        guard let progress = pending[attemptID]?.progress else { return }
        await progress(OAuthPrompt(authorizationURL: URL(string: "https://example.com")!, userCode: "CODE"))
    }

    func wasCancelled(_ attemptID: OAuthAttemptID) -> Bool {
        cancelled.contains(attemptID)
    }
}
