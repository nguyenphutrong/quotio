import Foundation
import XCTest
@testable import Quotio

@MainActor
final class ProxyCharacterizationTests: XCTestCase {
    private let fileManager = FileManager.default

    func testDeleteVersionRefusesCurrentVersion() throws {
        let directory = try makeStorageDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let storage = ProxyStorageManager(proxyDirectory: directory)

        try installFixture(version: "1.2.3", in: directory)
        try storage.setCurrentVersion("1.2.3")

        XCTAssertThrowsError(try storage.deleteVersion("1.2.3")) { error in
            guard case ProxyUpgradeError.cannotDeleteCurrentVersion = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNotNil(storage.getBinaryPath(for: "1.2.3"))
        XCTAssertEqual(storage.currentVersion, "1.2.3")
    }

    func testCleanupKeepsCurrentVersionWhenItIsOlder() throws {
        let directory = try makeStorageDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let storage = ProxyStorageManager(proxyDirectory: directory)

        try installFixture(version: "1.0.0", in: directory)
        try storage.setCurrentVersion("1.0.0")
        try installFixture(version: "2.0.0", in: directory)

        storage.cleanupOldVersions(keepLast: 1)

        XCTAssertNotNil(storage.getBinaryPath(for: "1.0.0"))
        XCTAssertNil(storage.getBinaryPath(for: "2.0.0"))
        XCTAssertEqual(storage.currentVersion, "1.0.0")
    }

    func testManagementBaseURLAlwaysUsesIPv4Loopback() {
        XCTAssertEqual(CLIProxyManager.managementBaseURL(port: 8317), "http://127.0.0.1:8317")
        XCTAssertEqual(CLIProxyManager.managementBaseURL(port: 65_535), "http://127.0.0.1:65535")
    }

    func testPortCleanupExcludesQuotioProcessID() {
        let output = "42\n700\ninvalid\n42\n901\n"

        XCTAssertEqual(
            CLIProxyManager.processIDsToTerminate(from: output, ownPID: 42),
            [700, 901]
        )
    }

    private func makeStorageDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func installFixture(version: String, in directory: URL) throws {
        let versionDirectory = directory
            .appendingPathComponent("upstream", isDirectory: true)
            .appendingPathComponent("v\(version)", isDirectory: true)
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: versionDirectory.appendingPathComponent("CLIProxyAPI"))
    }
}
