import QuotioApplication
import SQLite3
import XCTest
@testable import QuotioInfrastructure

final class AntigravitySwitchInfrastructureTests: XCTestCase {
    func testMissingAuthFilePublishesSemanticFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let switcher = AntigravityAccountSwitcher(logger: RecordingAntigravityLogger())

        await switcher.switchAccount(
            email: "person@example.com",
            authDirectory: directory.path,
            restartIDE: false
        )

        let snapshot = await switcher.snapshot()
        XCTAssertEqual(
            snapshot.state,
            .failed(.authFileNotFound(accountEmail: "person@example.com"))
        )
    }

    func testUnreadableAuthFilePublishesSemanticFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authFile = directory.appendingPathComponent("antigravity-person.json")
        try Data("not-json".utf8).write(to: authFile)
        let switcher = AntigravityAccountSwitcher(logger: RecordingAntigravityLogger())

        await switcher.switchAccount(authFilePath: authFile.path, restartIDE: false)

        let snapshot = await switcher.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.authFileUnreadable))
    }

    func testMachineIdentitySyncFailureIsLoggedAsNonfatalWarning() async {
        let logger = RecordingAntigravityLogger()
        let switcher = AntigravityAccountSwitcher(
            logger: logger,
            machineIdentitySync: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        await switcher.synchronizeMachineIdentity(for: "person@example.com")

        let warnings = await logger.warnings
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("machine identity synchronization failed"))
    }

    func testTokenExpirySupportsFractionalDatesAndRefreshesUnknownExpiry() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))

        XCTAssertTrue(
            AntigravityAccountSwitcher.isExpired("2029-12-31T23:59:59.500Z", now: now))
        XCTAssertFalse(
            AntigravityAccountSwitcher.isExpired("2030-01-01T00:00:00.500Z", now: now))
        XCTAssertTrue(AntigravityAccountSwitcher.isExpired(nil, now: now))
        XCTAssertTrue(AntigravityAccountSwitcher.isExpired("not-a-date", now: now))
    }

    func testVersionComponentsSupportThresholdAndShortVersions() {
        XCTAssertEqual(AntigravityVersionDetection.components("1.16.5"), [1, 16, 5])
        XCTAssertEqual(AntigravityVersionDetection.components("2"), [2, 0, 0])
    }

    func testDatabaseRetriesOnlyBusyAndLockedResults() {
        XCTAssertTrue(AntigravitySwitchDatabase.isRetryableSQLiteResult(SQLITE_BUSY))
        XCTAssertTrue(AntigravitySwitchDatabase.isRetryableSQLiteResult(SQLITE_LOCKED))
        XCTAssertFalse(AntigravitySwitchDatabase.isRetryableSQLiteResult(SQLITE_ERROR))
        XCTAssertFalse(AntigravitySwitchDatabase.isRetryableSQLiteResult(SQLITE_CONSTRAINT))
    }

    func testLegacyInjectionReplacesIdentityAndTokenFieldsButPreservesOthers() throws {
        var original = AntigravityProtobuf.stringField(1, "old-user")
        original.append(AntigravityProtobuf.stringField(2, "old@example.com"))
        original.append(AntigravityProtobuf.stringField(5, "preserved"))
        original.append(AntigravityProtobuf.field(6, AntigravityProtobuf.oauth("old", "old-r", 1)))

        let encoded = try AntigravityProtobuf.injectLegacy(
            original.base64EncodedString(), "new", "new-r", 42, "new@example.com")
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))

        XCTAssertTrue(decoded.contains(AntigravityProtobuf.stringField(5, "preserved")))
        XCTAssertTrue(decoded.contains(AntigravityProtobuf.stringField(2, "new@example.com")))
        XCTAssertFalse(decoded.contains(Data("old@example.com".utf8)))
    }

    func testUnifiedPayloadIsBase64EncodedProtobuf() throws {
        let payload = AntigravityProtobuf.createUnified("token", "refresh", 123)
        XCTAssertFalse(try XCTUnwrap(Data(base64Encoded: payload)).isEmpty)
    }
}

private actor RecordingAntigravityLogger: ApplicationLogging {
    private(set) var warnings: [String] = []

    func write(_ level: ApplicationLogLevel, message: String) {
        guard case .warning = level else { return }
        warnings.append(message)
    }
}
