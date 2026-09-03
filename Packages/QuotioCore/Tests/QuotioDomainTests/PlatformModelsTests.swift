import XCTest
@testable import QuotioDomain

final class PlatformModelsTests: XCTestCase {
    func testTelemetryPayloadContainsOnlyExplicitlyAllowedProperties() throws {
        let context = try XCTUnwrap(TelemetryRuntimeContext(
            appVersion: "1.2.3",
            buildNumber: "45",
            bundleIdentifier: "com.example.quotio",
            macOSVersion: "Version 26.0 (Build 25A1)",
            updateChannel: .beta
        ))

        let payload = try XCTUnwrap(TelemetryPayload(
            event: .appStarted,
            anonymousInstallID: "00000000-0000-0000-0000-000000000001",
            context: context
        ))

        XCTAssertEqual(Set(payload.properties.keys), TelemetryPayload.allowedPropertyNames)
        XCTAssertEqual(payload.properties["app_version"], "1.2.3")
        XCTAssertEqual(payload.properties["update_channel"], "beta")
        XCTAssertTrue(
            TelemetryPayload.allowedPropertyNames.isDisjoint(with: [
                "account_id", "authorization", "cookie", "file_contents", "path", "token", "url",
            ])
        )
    }

    func testTelemetryContextRejectsSensitiveOrUnstructuredValues() {
        let unsafeValues = [
            "Bearer secret-token",
            "Authorization: secret",
            "https://example.com/callback",
            "file:///Users/person/.config/quotio",
            "/Users/person/.config/quotio",
            #"{"access_token":"secret"}"#,
            "person@example.com",
        ]

        for value in unsafeValues {
            XCTAssertNil(
                TelemetryRuntimeContext(
                    appVersion: "1.2.3",
                    buildNumber: "45",
                    bundleIdentifier: "com.example.quotio",
                    macOSVersion: value,
                    updateChannel: .stable
                ),
                "Expected telemetry context to reject \(value)"
            )
        }
    }

    func testTelemetryPayloadRejectsInvalidAnonymousIdentifier() throws {
        let context = try XCTUnwrap(TelemetryRuntimeContext(
            appVersion: "1.2.3",
            buildNumber: "45",
            bundleIdentifier: "com.example.quotio",
            macOSVersion: "Version 26.0",
            updateChannel: .stable
        ))

        XCTAssertNil(TelemetryPayload(
            event: .appStarted,
            anonymousInstallID: "account@example.com",
            context: context
        ))
    }

    func testTelemetryPropertyValidationRejectsSensitiveValuesBehindAllowedKeys() throws {
        let context = try XCTUnwrap(TelemetryRuntimeContext(
            appVersion: "1.2.3",
            buildNumber: "45",
            bundleIdentifier: "com.example.quotio",
            macOSVersion: "Version 26.0",
            updateChannel: .stable
        ))
        let payload = try XCTUnwrap(TelemetryPayload(
            event: .appStarted,
            anonymousInstallID: "00000000-0000-0000-0000-000000000001",
            context: context
        ))

        var properties = payload.properties
        properties["app_version"] = "Bearer secret-token"

        XCTAssertFalse(TelemetryPayload.allowsProperties(properties))
    }
}
