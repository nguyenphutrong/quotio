import XCTest
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class QuotioInfrastructureModuleTests: XCTestCase {
    func testModuleDependsOnApplicationAndDomain() {
        XCTAssertEqual(
            QuotioInfrastructureModule.dependencyNames,
            ["QuotioApplication", "QuotioDomain"]
        )
    }

    func testTelemetrySanitizerAllowsOnlySemanticEventsAndAnonymousIdentify() {
        let properties: [String: Any] = [
            "anonymous_install_id": "00000000-0000-0000-0000-000000000001",
            "app_version": "1.2.3",
            "build_number": "45",
            "bundle_id": "com.example.quotio",
            "macos_version": "Version 26.0",
            "update_channel": "stable",
            "$device_name": "Private Mac",
        ]

        let semantic = PostHogTelemetryAdapter.sanitizedProperties(
            for: "app_started",
            properties: properties
        )
        let identify = PostHogTelemetryAdapter.sanitizedProperties(
            for: "$identify",
            properties: properties
        )

        XCTAssertEqual(Set(semantic?.keys.map { $0 } ?? []), TelemetryPayload.allowedPropertyNames)
        XCTAssertEqual(identify?.count, 0)
        XCTAssertNil(PostHogTelemetryAdapter.sanitizedProperties(
            for: "$screen",
            properties: properties
        ))
    }

    func testTelemetrySanitizerDropsSensitiveValuesEvenWhenPropertyNameIsAllowed() {
        let properties: [String: Any] = [
            "anonymous_install_id": "00000000-0000-0000-0000-000000000001",
            "app_version": "https://example.com/token",
            "build_number": "45",
            "bundle_id": "com.example.quotio",
            "macos_version": "Version 26.0",
            "update_channel": "stable",
        ]

        XCTAssertNil(PostHogTelemetryAdapter.sanitizedProperties(
            for: "app_started",
            properties: properties
        ))
    }
}
