import XCTest
@testable import QuotioInfrastructure

final class LocalProxyOAuthStatusPollTests: XCTestCase {
    func testBrowserFlowKeepsTheTwoMinuteWait() {
        XCTAssertEqual(LocalProxyOAuthAuthorizer.statusPollCount(expiresIn: nil), 60)
    }

    func testDeviceFlowWaitsAsLongAsTheProxyDoes() {
        // CLIProxyAPI reports Meta's device-code lifetime, 15 minutes by default.
        XCTAssertEqual(LocalProxyOAuthAuthorizer.statusPollCount(expiresIn: 900), 450)
        XCTAssertEqual(LocalProxyOAuthAuthorizer.statusPollCount(expiresIn: 600), 300)
    }

    func testWaitStaysWithinTwoAndFifteenMinutes() {
        XCTAssertEqual(LocalProxyOAuthAuthorizer.statusPollCount(expiresIn: 30), 60)
        XCTAssertEqual(LocalProxyOAuthAuthorizer.statusPollCount(expiresIn: 0), 60)
        XCTAssertEqual(LocalProxyOAuthAuthorizer.statusPollCount(expiresIn: 86_400), 450)
    }
}
