import XCTest
@testable import QuotioPresentation

final class QuotioPresentationModuleTests: XCTestCase {
    func testModuleDependsOnApplicationAndDomain() {
        XCTAssertEqual(
            QuotioPresentationModule.dependencyNames,
            ["QuotioApplication", "QuotioDomain"]
        )
    }
}
