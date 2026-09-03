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
}
