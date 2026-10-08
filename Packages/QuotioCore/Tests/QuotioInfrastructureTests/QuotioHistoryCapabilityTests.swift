import Foundation
import XCTest
import QuotioDomain
import QuotioHostClient
@testable import QuotioInfrastructure

final class QuotioHistoryCapabilityTests: XCTestCase {
    private func host(readAvailable: Bool, readReason: String?, writeAvailable: Bool = false) throws -> QuotioHostSnapshot.Host {
        var read: [String: Any] = ["available": readAvailable]
        if let readReason { read["reason"] = readReason }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "host", "platform": "macos", "api_versions": [2],
            "capabilities": ["quota_history": read, "quota_history_write": ["available": writeAvailable]]
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(QuotioHostSnapshot.Host.self, from: data)
    }
    func testReadFailuresAreMappedWithoutConflatingStorageAuthorizationAndSupport() throws {
        let cases: [(String?, QuotaHistoryError)] = [
            ("history_storage_unavailable", .storage), ("insufficient_scope", .unauthorized),
            ("unavailable", .unsupported), ("no_saved_accounts", .unsupported), (nil, .unsupported)
        ]
        for (reason, expected) in cases {
            let value = QuotioHistoryMapper.availability(try host(readAvailable: false, readReason: reason), connected: true)
            XCTAssertFalse(value.canRead)
            XCTAssertEqual(value.readFailure, expected)
        }
        XCTAssertEqual(QuotioHistoryMapper.availability(nil, connected: false).readFailure, .unsupported)
    }
    func testReadOnlyCapabilityDoesNotBecomeUnauthorizedBecauseWritesAreDisabled() throws {
        let value = QuotioHistoryMapper.availability(try host(readAvailable: true, readReason: nil), connected: true)
        XCTAssertTrue(value.canRead)
        XCTAssertFalse(value.canWrite)
        XCTAssertNil(value.readFailure)
    }
}
