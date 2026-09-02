import XCTest
@testable import QuotioDomain

final class QuotioDomainModuleTests: XCTestCase {
    func testModuleIdentity() {
        XCTAssertEqual(QuotioDomainModule.name, "QuotioDomain")
    }
}
