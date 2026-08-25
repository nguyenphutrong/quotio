import XCTest
@testable import Quotio

final class GLMQuotaFetcherTests: XCTestCase {
    func testMapQuotaDataAcceptsCreditLimitWindows() {
        let quota = GLMQuotaFetcher.mapQuotaData(
            GLMQuotaData(limits: [
                GLMLimit(
                    type: "CREDIT_LIMIT",
                    unit: 3,
                    number: 5,
                    percentage: 5,
                    nextResetTime: 1_786_073_946_574
                ),
                GLMLimit(
                    type: "CREDIT_LIMIT",
                    unit: 6,
                    number: 1,
                    percentage: 10,
                    nextResetTime: 1_786_660_488_998
                )
            ]),
            planName: "GLM Coding Max"
        )

        XCTAssertEqual(quota.planType, "GLM Coding Max")
        XCTAssertEqual(quota.models.map(\.name), ["zai-session", "zai-weekly"])
        XCTAssertEqual(quota.models.map(\.percentage), [95, 90])
        XCTAssertTrue(quota.models.allSatisfy { !$0.resetTime.isEmpty })
    }
}
