import QuotioDomain
import XCTest
@testable import QuotioPresentation

final class ManagedAuthFilePresentationTests: XCTestCase {
    func testHumanReadableStatusExtractsNestedAPIErrorMessage() {
        let file = makeAuthFile(
            statusMessage: #"  {"error":{"message":"Retry in 12 minutes"}}  "#
        )

        XCTAssertEqual(file.humanReadableStatus, "Retry in 12 minutes")
    }

    func testHumanReadableStatusPreservesPlainMessage() {
        let file = makeAuthFile(statusMessage: "Cooling down for 2 hours")

        XCTAssertEqual(file.humanReadableStatus, "Cooling down for 2 hours")
    }

    func testHumanReadableStatusPreservesMalformedJSONMessage() {
        let message = #"{"error":"unavailable"}"#
        let file = makeAuthFile(statusMessage: message)

        XCTAssertEqual(file.humanReadableStatus, message)
    }

    func testHumanReadableStatusOmitsMissingAndEmptyMessages() {
        XCTAssertNil(makeAuthFile(statusMessage: nil).humanReadableStatus)
        XCTAssertNil(makeAuthFile(statusMessage: "").humanReadableStatus)
    }

    private func makeAuthFile(statusMessage: String?) -> ManagedAuthFile {
        ManagedAuthFile(
            id: "claude-account",
            name: "claude-account.json",
            provider: "claude",
            status: "cooling",
            statusMessage: statusMessage,
            disabled: false,
            unavailable: false
        )
    }
}
