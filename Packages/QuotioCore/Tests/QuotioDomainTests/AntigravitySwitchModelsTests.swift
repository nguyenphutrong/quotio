import XCTest
@testable import QuotioDomain

final class AntigravitySwitchModelsTests: XCTestCase {
    func testActiveAccountMatchingIgnoresEmailCase() {
        let account = AntigravityActiveAccount(email: "Person@Example.com", detectedAt: .distantPast)
        XCTAssertTrue(account.matches(email: "person@example.com"))
        XCTAssertFalse(account.matches(email: "other@example.com"))
    }

    func testDeviceProfileKeepsLegacyJSONKeys() throws {
        let profile = AntigravityDeviceProfile(
            machineID: "machine", macMachineID: "mac", deviceID: "device", sqmID: "sqm")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: String])
        XCTAssertEqual(object["machineId"], "machine")
        XCTAssertEqual(object["macMachineId"], "mac")
        XCTAssertEqual(object["devDeviceId"], "device")
        XCTAssertEqual(object["sqmId"], "sqm")
    }
}
