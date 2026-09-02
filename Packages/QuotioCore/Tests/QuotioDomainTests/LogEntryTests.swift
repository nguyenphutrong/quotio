import Foundation
import XCTest
@testable import QuotioDomain

final class LogEntryTests: XCTestCase {
    func testLevelParsingIsCaseInsensitiveAndUsesSeverityPriority() {
        XCTAssertEqual(LogEntry.Level(message: "request ERROR and warning"), .error)
        XCTAssertEqual(LogEntry.Level(message: "WARN retrying"), .warn)
        XCTAssertEqual(LogEntry.Level(message: "Debug connection"), .debug)
        XCTAssertEqual(LogEntry.Level(message: "request completed"), .info)
    }
}
