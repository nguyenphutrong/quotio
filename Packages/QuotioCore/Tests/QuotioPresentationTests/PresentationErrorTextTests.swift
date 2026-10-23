import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class PresentationErrorTextTests: XCTestCase {
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
