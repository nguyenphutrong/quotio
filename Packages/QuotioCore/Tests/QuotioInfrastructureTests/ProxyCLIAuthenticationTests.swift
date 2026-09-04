import Foundation
import QuotioApplication
@testable import QuotioInfrastructure
import XCTest

final class ProxyCLIAuthenticationTests: XCTestCase {
    func testExtractDeviceCodeHandlesInlineAndLineBasedOutput() {
        XCTAssertEqual(
            ProcessProxyCLIAuthenticator.extractDeviceCode(from: "Please enter the code: ABCD-1234\nWaiting"),
            "ABCD-1234"
        )
        XCTAssertEqual(
            ProcessProxyCLIAuthenticator.extractDeviceCode(from: "notice\nenter the code: WXYZ-9876"),
            "WXYZ-9876"
        )
    }

    func testRunReturnsSemanticCompletionStatus() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("auth-success")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let authenticator = ProcessProxyCLIAuthenticator(copyDeviceCode: { _ in })

        let result = await authenticator.run(
            .kiroImport,
            runtime: ProxyCLIAuthRuntime(binaryPath: executable.path, configurationPath: "/tmp/config.yaml")
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.status, .authenticationCompleted)
        XCTAssertNil(result.deviceCode)
    }

    func testRunReturnsSemanticLaunchFailure() async {
        let authenticator = ProcessProxyCLIAuthenticator(copyDeviceCode: { _ in })

        let result = await authenticator.run(
            .kiroImport,
            runtime: ProxyCLIAuthRuntime(
                binaryPath: "/path/that/does/not/exist",
                configurationPath: "/tmp/config.yaml"
            )
        )

        XCTAssertFalse(result.success)
        guard case .failedToStart(let details) = result.status else {
            return XCTFail("Expected a semantic launch failure")
        }
        XCTAssertFalse(details.isEmpty)
        XCTAssertNil(result.deviceCode)
    }

    func testApplyCreatesBackupAndAddsBaseURL() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authFile = directory.appendingPathComponent("antigravity-user.json")
        try Data(#"{"metadata":{"other":"preserved"}}"#.utf8).write(to: authFile)

        let workaround = FileAntigravityAuthWorkaround()
        await workaround.apply(in: directory.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: authFile.path + ".bak"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: authFile)) as? [String: Any]
        )
        let metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["base_url"] as? String, "https://daily-cloudcode-pa.googleapis.com")
        XCTAssertEqual(metadata["other"] as? String, "preserved")
    }

    func testRemoveRestoresOriginalBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authFile = directory.appendingPathComponent("antigravity-user.json")
        let original = Data(#"{"metadata":{"other":"preserved"}}"#.utf8)
        try original.write(to: authFile)

        let workaround = FileAntigravityAuthWorkaround()
        await workaround.apply(in: directory.path)
        await workaround.remove(in: directory.path)

        XCTAssertEqual(try Data(contentsOf: authFile), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authFile.path + ".bak"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
