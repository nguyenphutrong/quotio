import SQLite3
import XCTest
@testable import QuotioInfrastructure

final class AntigravitySwitchInfrastructureTests: XCTestCase {
    func testMissingAuthFilePublishesSemanticFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let switcher = AntigravityAccountSwitcher()

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
        let switcher = AntigravityAccountSwitcher()

        await switcher.switchAccount(authFilePath: authFile.path, restartIDE: false)

        let snapshot = await switcher.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.authFileUnreadable))
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
