import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class PresentationErrorTextTests: XCTestCase {
    func testAgentCatalogErrorMapsToExistingMessage() {
        XCTAssertEqual(
            agentConfigurationErrorMessage(ModelCatalogError.proxyUnavailable),
            "The proxy is not available."
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

    func testOpenCodeConfigIssuesMapToExistingMessages() {
        XCTAssertEqual(
            OpenCodeConfigIssue.notUTF8.localizedText,
            "The OpenCode configuration is not valid UTF-8."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.unterminatedBlockComment.localizedText,
            "The OpenCode configuration contains an unterminated block comment."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.unterminatedString.localizedText,
            "The OpenCode configuration contains an unterminated string."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.invalidSyntax(line: 4, column: 9).localizedText,
            "The OpenCode configuration has invalid syntax at line 4, column 9."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.rootNotObject.localizedText,
            "The OpenCode configuration root must be a JSON object."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.duplicateKey("provider").localizedText,
            "The OpenCode configuration contains the duplicate key 'provider'."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.providerNotObject.localizedText,
            "The OpenCode provider value must be a JSON object."
        )
        XCTAssertEqual(
            OpenCodeConfigIssue.verificationFailed.localizedText,
            "The updated OpenCode configuration could not be verified."
        )
    }
}
