import XCTest
@testable import QuotioInfrastructure

final class QuotioInfrastructureModuleTests: XCTestCase {
    func testModuleDependsOnApplicationAndDomain() {
        XCTAssertEqual(
            QuotioInfrastructureModule.dependencyNames,
            ["QuotioApplication", "QuotioDomain"]
        )
    }
}
