import XCTest
@testable import QuotioApplication

final class QuotioApplicationModuleTests: XCTestCase {
    func testModuleDependsOnDomain() {
        XCTAssertEqual(QuotioApplicationModule.dependencyName, "QuotioDomain")
    }
}
