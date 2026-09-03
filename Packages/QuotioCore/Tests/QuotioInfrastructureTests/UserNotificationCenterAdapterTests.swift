import XCTest
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class UserNotificationCenterAdapterTests: XCTestCase {
    func testProxyFailureReasonsPreserveExistingNotificationCopy() {
        XCTAssertEqual(proxyFailureNotificationReason(.binaryNotFound), "Binary not found")
        XCTAssertEqual(proxyFailureNotificationReason(.startupFailed), "Proxy startup failed")
        XCTAssertEqual(
            proxyFailureNotificationReason(.operationInProgress),
            "Another operation is in progress"
        )
        XCTAssertEqual(proxyFailureNotificationReason(.network("Offline")), "Offline")
        XCTAssertEqual(proxyFailureNotificationReason(.noCompatibleBinary), "No compatible binary")
        XCTAssertEqual(proxyFailureNotificationReason(.downloadFailed("Download")), "Download")
        XCTAssertEqual(proxyFailureNotificationReason(.checksumMissing), "No SHA256 checksum provided")
        XCTAssertEqual(
            proxyFailureNotificationReason(.checksumMismatch(expected: "a", actual: "b")),
            "Checksum mismatch"
        )
        XCTAssertEqual(proxyFailureNotificationReason(.extractionFailed("Extract")), "Extract")
        XCTAssertEqual(proxyFailureNotificationReason(.installationFailed("Install")), "Install")
        XCTAssertEqual(
            proxyFailureNotificationReason(.compatibilityCheckFailed(.proxyNotResponding)),
            "Compatibility check failed"
        )
        XCTAssertEqual(proxyFailureNotificationReason(.dryRunFailed("Dry run")), "Dry run")
        XCTAssertEqual(proxyFailureNotificationReason(.rollbackFailed("Rollback")), "Rollback")
        XCTAssertEqual(proxyFailureNotificationReason(.noVersionAvailable), "No version available")
        XCTAssertEqual(
            proxyFailureNotificationReason(.versionAlreadyInstalled("2.0.0")),
            "Version 2.0.0 is already installed"
        )
        XCTAssertEqual(
            proxyFailureNotificationReason(.cannotDeleteCurrentVersion),
            "Cannot delete current version"
        )
        XCTAssertEqual(proxyFailureNotificationReason(.cancelled), "Operation cancelled")
    }
}
