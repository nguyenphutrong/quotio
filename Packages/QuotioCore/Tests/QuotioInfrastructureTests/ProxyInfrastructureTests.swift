import Foundation
import XCTest
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class ProxyInfrastructureTests: XCTestCase {
    private let fileManager = FileManager.default

    func testVersionRepositoryRefusesToDeleteCurrentVersion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let repository = FileProxyVersionRepository(proxyDirectory: directory)
        try installFixture(version: "1.2.3", in: directory)
        try await repository.activate(version: "1.2.3")

        do {
            try await repository.delete(version: "1.2.3")
            XCTFail("Expected active version deletion to fail")
        } catch {
            XCTAssertEqual(error as? ProxyFailure, .cannotDeleteCurrentVersion)
        }

        let snapshot = await repository.snapshot()
        let binaryPath = await repository.binaryPath(for: "1.2.3")
        XCTAssertEqual(snapshot.currentVersion, "1.2.3")
        XCTAssertNotNil(binaryPath)
    }

    func testFailedActivationPreservesExistingCurrentEntry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let repository = FileProxyVersionRepository(proxyDirectory: directory)
        try installFixture(version: "2.0.0", in: directory)
        let currentDirectory = directory.appendingPathComponent("upstream/current")
        try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        let sentinel = currentDirectory.appendingPathComponent("user-data")
        try Data("preserve".utf8).write(to: sentinel)

        do {
            try await repository.activate(version: "2.0.0")
            XCTFail("Expected activation over a nonempty current directory to fail")
        } catch {
            XCTAssertTrue(fileManager.fileExists(atPath: sentinel.path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        }
    }

    func testCleanupAlwaysKeepsCurrentVersion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let repository = FileProxyVersionRepository(proxyDirectory: directory)
        try installFixture(version: "1.0.0", in: directory)
        try await repository.activate(version: "1.0.0")
        try installFixture(version: "2.0.0", in: directory)

        await repository.cleanup(keeping: 1)

        let currentBinaryPath = await repository.binaryPath(for: "1.0.0")
        let removedBinaryPath = await repository.binaryPath(for: "2.0.0")
        let snapshot = await repository.snapshot()
        XCTAssertNotNil(currentBinaryPath)
        XCTAssertNil(removedBinaryPath)
        XCTAssertEqual(snapshot.currentVersion, "1.0.0")
    }

    func testVersionsToDeleteMakesRoomWithoutSelectingCurrentVersion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let repository = FileProxyVersionRepository(proxyDirectory: directory)
        try installFixture(version: "1.0.0", in: directory)
        try await repository.activate(version: "1.0.0")
        try installFixture(version: "2.0.0", in: directory)

        let versions = await repository.versionsToDeleteAfterInstalling(keeping: 2)

        XCTAssertEqual(versions, ["2.0.0"])
    }

    func testExistingConfigurationIsPreservedAndTargetedUpdatesKeepUnknownContent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        let original = """
        host: "127.0.0.1"
        port: 8317
        proxy-url: "http://old.example:8080"
        user-owned-setting: keep-me
        remote-management:
          secret-key: "old-key"
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        let paths = ProxyPaths(
            legacyBinaryPath: directory.appendingPathComponent("legacy").path,
            configPath: configURL.path,
            authDirectoryPath: directory.appendingPathComponent("auth").path,
            expectedBinaryPath: directory.appendingPathComponent("current/CLIProxyAPI").path
        )
        let repository = FileProxyConfigurationRepository(paths: paths)

        await repository.ensureExists(
            port: 9000,
            managementKey: "replacement-key",
            allowNetworkAccess: true
        )
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)

        await repository.setPort(9000)
        await repository.setProxyURL("http://new.example:9001")
        await repository.setManagementKey("replacement-key")

        let updated = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("port: 9000"))
        XCTAssertTrue(updated.contains("proxy-url: \"http://new.example:9001\""))
        XCTAssertTrue(updated.contains("secret-key: \"replacement-key\""))
        XCTAssertTrue(updated.contains("user-owned-setting: keep-me"))
    }

    func testProcessControllerUsesConfigArgumentAndExcludesOwnProcessID() {
        let request = ProxyProcessRequest(
            executablePath: "/tmp/CLIProxyAPI",
            configurationPath: "/tmp/config.yaml"
        )

        XCTAssertEqual(
            ProxyProcessController.launchArguments(for: request),
            ["-config", "/tmp/config.yaml"]
        )
        XCTAssertEqual(
            ProxyProcessController.processIDsToTerminate(
                from: "42\n700\ninvalid\n42\n901\n",
                ownPID: 42
            ),
            [700, 901]
        )
    }

    func testRuntimeMetadataUsesExistingKeysAndDefaultPort() throws {
        let suiteName = "ProxyInfrastructureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = UserDefaultsProxyRuntimeMetadataRepository(defaults: defaults)
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(repository.loadPort(), 8317)
        repository.savePort(9000)
        repository.saveLegacyInstalledVersion("1.2.3")
        repository.saveLastUpdateCheckDate(checkedAt)

        XCTAssertEqual(defaults.integer(forKey: "proxyPort"), 9000)
        XCTAssertEqual(defaults.string(forKey: "installedProxyVersion_upstream"), "1.2.3")
        XCTAssertEqual(defaults.object(forKey: "lastProxyUpdateCheckDate") as? Date, checkedAt)
        XCTAssertEqual(repository.loadPort(), 9000)
        XCTAssertEqual(repository.loadLegacyInstalledVersion(), "1.2.3")
        XCTAssertEqual(repository.loadLastUpdateCheckDate(), checkedAt)
    }

    func testReloadableQuotaSessionReplacesItsBackingSession() async throws {
        let factory = SequencedQuotaSessionFactory(responses: ["before", "after"])
        let session = ReloadableQuotaHTTPSession {
            factory.makeSession()
        }
        let request = URLRequest(url: URL(string: "https://example.com")!)

        let before = try await session.data(for: request).0
        await session.reload()
        let after = try await session.data(for: request).0

        XCTAssertEqual(String(decoding: before, as: UTF8.self), "before")
        XCTAssertEqual(String(decoding: after, as: UTF8.self), "after")
    }

    private func makeTemporaryDirectory() throws -> URL {
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
        try Data("fixture".utf8).write(
            to: versionDirectory.appendingPathComponent("CLIProxyAPI")
        )
    }
}

private final class SequencedQuotaSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func makeSession() -> any QuotaHTTPSession {
        let response = lock.withLock { responses.removeFirst() }
        return FixedQuotaSession(response: response)
    }
}

private actor FixedQuotaSession: QuotaHTTPSession {
    private let response: String

    init(response: String) {
        self.response = response
    }

    func data(for request: URLRequest) -> (Data, URLResponse) {
        (
            Data(response.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}
