import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class PresentationErrorTextTests: XCTestCase {
    func testOpaqueAgentDiagnosticsRemainUnchanged() {
        XCTAssertEqual(AgentConfigurationFailure.operationFailed(details: "Disk full").localizedText, "Disk full")
        XCTAssertEqual(
            AgentConnectionMessage.server(details: "Server unavailable").localizedText,
            "Server unavailable"
        )
        XCTAssertEqual(
            AgentConnectionMessage.transport(details: "Network offline").localizedText,
            "Network offline"
        )
    }

    func testCustomProviderRemoteErrorsMapToExistingMessages() {
        XCTAssertEqual(
            customProviderErrorMessage(CustomProviderRemoteError.unauthorized),
            "API key is invalid or unauthorized"
        )
        XCTAssertEqual(
            customProviderErrorMessage(CustomProviderRemoteError.serverError(503, "Unavailable")),
            "Server error (503): Unavailable"
        )
    }

    func testProxyManagementErrorsMapToExistingMessages() {
        XCTAssertEqual(
            proxyManagementErrorMessage(ProxyManagementFailure.invalidResponse),
            "Invalid response"
        )
        XCTAssertEqual(
            proxyManagementErrorMessage(ProxyManagementFailure.connectionError("Offline")),
            "Connection error: Offline"
        )
    }

    func testAntigravitySwitchFailuresMapToPresentationMessages() {
        XCTAssertEqual(
            AntigravitySwitchFailure.authFileNotFound(accountEmail: "person@example.com").displayMessage,
            "Auth file not found for person@example.com"
        )
        XCTAssertEqual(AntigravitySwitchFailure.authFileUnreadable.displayMessage, "Failed to read auth file")
        XCTAssertEqual(
            AntigravitySwitchFailure.credentialRefreshFailed.displayMessage,
            "Failed to refresh the account credential"
        )
        XCTAssertEqual(
            AntigravitySwitchFailure.databaseBackupFailed.displayMessage,
            "Failed to back up the Antigravity database"
        )
        XCTAssertEqual(
            AntigravitySwitchFailure.credentialInjectionFailed.displayMessage,
            "Failed to update the Antigravity credential"
        )
        XCTAssertEqual(
            AntigravitySwitchFailure.ideRestartFailed.displayMessage,
            "Failed to restart Antigravity IDE"
        )
    }
}
