import Foundation
import QuotioApplication
import QuotioDomain
@testable import QuotioInfrastructure
import XCTest

final class OpenCodeConfigEditorTests: XCTestCase {
    private let provider: [String: Any] = [
        "name": "Quotio",
        "options": ["apiKey": "quotio-test", "baseURL": "http://127.0.0.1:8317/v1"],
    ]

    private let userConfig = """
    {
      // keep this comment
      "plugin": ["custom-plugin"],
      "unknown": { "enabled": true },
      "provider": {
        /* user provider */
        "custom": { "npm": "custom-package" }
      }
    }
    """

    func testMergeThenRemoveRestoresOriginalBytes() throws {
        let merged = try OpenCodeConfigEditor.merging(
            existing: Data(userConfig.utf8),
            providers: ["quotio": provider]
        )
        let removed = try XCTUnwrap(OpenCodeConfigEditor.removingProviders(
            existing: merged,
            keys: ["quotio"]
        ))
        XCTAssertEqual(removed, Data(userConfig.utf8))
    }

    func testMergePreservesCommentsAndUnknownKeysAndIsIdempotent() throws {
        let once = try OpenCodeConfigEditor.merging(
            existing: Data(userConfig.utf8),
            providers: ["quotio": provider]
        )
        let twice = try OpenCodeConfigEditor.merging(existing: once, providers: ["quotio": provider])
        XCTAssertEqual(twice, once)
        let text = String(decoding: once, as: UTF8.self)
        XCTAssertTrue(text.contains("// keep this comment"))
        XCTAssertTrue(text.contains("/* user provider */"))
        XCTAssertTrue(text.contains("\"unknown\": { \"enabled\": true }"))
    }

    func testMergePreservesCRLFAndBOM() throws {
        let source = Data("\u{FEFF}{\r\n  // keep\r\n  \"theme\": \"system\"\r\n}".utf8)
        let merged = try OpenCodeConfigEditor.merging(existing: source, providers: ["quotio": provider])
        XCTAssertTrue(merged.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = String(decoding: merged, as: UTF8.self)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertTrue(text.contains("// keep"))
    }

    func testMalformedDocumentsAreRefused() {
        for source in [
            "{\"value\": 1/* x */2}",
            "{ /* never closed",
            "{\"value\": \"never closed}",
            "{\"a\": 1 \"b\": 2}",
            "{} {}",
        ] {
            XCTAssertThrowsError(try OpenCodeConfigEditor.merging(
                existing: Data(source.utf8),
                providers: ["quotio": provider]
            ))
        }
    }

    func testDuplicateAddressedKeysAndNonObjectProviderAreRefused() {
        XCTAssertThrowsError(try OpenCodeConfigEditor.merging(
            existing: Data("{\"provider\":{},\"provider\":{}}".utf8),
            providers: ["quotio": provider]
        )) { XCTAssertEqual($0 as? OpenCodeConfigError, .duplicateKey("provider")) }
        XCTAssertThrowsError(try OpenCodeConfigEditor.merging(
            existing: Data("{\"provider\":null}".utf8),
            providers: ["quotio": provider]
        )) { XCTAssertEqual($0 as? OpenCodeConfigError, .providerNotObject) }
    }

    func testDuplicateManagedProviderKeyIsRefused() {
        let source = "{\"provider\":{\"quotio\":{},\"quotio\":{}}}"
        XCTAssertThrowsError(try OpenCodeConfigEditor.merging(
            existing: Data(source.utf8),
            providers: ["quotio": provider]
        )) { XCTAssertEqual($0 as? OpenCodeConfigError, .duplicateKey("quotio")) }
    }

    func testCommentRemovalPreservesTokenBoundary() throws {
        XCTAssertEqual(
            try OpenCodeConfigEditor.strippingJSONCSyntax(from: "{\"value\":1/*x*/2}"),
            "{\"value\":1 2}"
        )
        XCTAssertThrowsError(try OpenCodeConfigEditor.parseObject(Data("{\"value\":1/*x*/2}".utf8)))
    }

    func testNonUTF8IsRefused() {
        XCTAssertThrowsError(try OpenCodeConfigEditor.merging(
            existing: Data([0x7B, 0xFF, 0x7D]),
            providers: ["quotio": provider]
        )) { XCTAssertEqual($0 as? OpenCodeConfigError, .notUTF8) }
    }
}

final class OpenCodeAgentConfigurationAdapterTests: XCTestCase {
    private var home: URL!
    private var configURL: URL!
    private var adapter: OpenCodeAgentConfigurationAdapter!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configURL = home.appendingPathComponent(".config/opencode/opencode.json")
        adapter = OpenCodeAgentConfigurationAdapter(
            fileStore: AgentFileStore(homeDirectory: home.path, now: { Date(timeIntervalSince1970: 1234) }),
            localize: { key in key == "agents.opencode.notConfigured" ? "Not configured" : "Cannot parse %@: %@" }
        )
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    func testPreviewMalformedFileProducesManagedOnlyContentWithoutWriting() async throws {
        try write(Data("malformed".utf8))
        let before = try Data(contentsOf: configURL)
        let result = try await adapter.preview(request(mode: .manual))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.mode, .manual)
        XCTAssertNotNil(result.rawConfigs.first?.content.range(of: "\"quotio\""))
        XCTAssertEqual(try Data(contentsOf: configURL), before)
    }

    func testManualApplyProducesPreviewWithoutWriting() async throws {
        let original = Data("{\n  // user\n  \"theme\": \"dark\"\n}".utf8)
        try write(original)

        let result = try await adapter.apply(request(mode: .manual))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.mode, .manual)
        XCTAssertEqual(try Data(contentsOf: configURL), original)
        let backups = await adapter.listBackups()
        XCTAssertTrue(backups.isEmpty)
    }

    func testApplyInspectBackupRestoreAndResetContract() async throws {
        let original = Data("{\n  // user\n  \"theme\": \"dark\"\n}".utf8)
        try write(original)

        let applied = try await adapter.apply(request(mode: .automatic))
        XCTAssertTrue(applied.success)
        XCTAssertEqual(applied.backupPath, configURL.path + ".backup.1234")
        let inspectedValue = await adapter.inspect()
        let inspected = try XCTUnwrap(inspectedValue)
        XCTAssertEqual(inspected.baseURL, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(inspected.apiKey, "quotio-key")
        XCTAssertTrue(inspected.isProxyConfigured)
        let appliedBackups = await adapter.listBackups()
        XCTAssertEqual(appliedBackups.count, 1)

        let reset = try await adapter.reset(mode: .automatic)
        XCTAssertTrue(reset.success)
        XCTAssertEqual(try Data(contentsOf: configURL), original)

        let resetBackups = await adapter.listBackups()
        let backup = try XCTUnwrap(resetBackups.first { $0.path.hasSuffix(".backup.1234") })
        try await adapter.restore(backup)
        XCTAssertEqual(try Data(contentsOf: configURL), original)
    }

    func testAutomaticApplyAndResetRefuseMalformedExistingFileWithoutMutation() async throws {
        let malformed = Data("{ not json".utf8)
        try write(malformed)
        let applyResult = try await adapter.apply(request(mode: .automatic))
        XCTAssertFalse(applyResult.success)
        XCTAssertEqual(try Data(contentsOf: configURL), malformed)
        let resetResult = try await adapter.reset(mode: .automatic)
        XCTAssertFalse(resetResult.success)
        XCTAssertEqual(try Data(contentsOf: configURL), malformed)
        let backups = await adapter.listBackups()
        XCTAssertTrue(backups.isEmpty)
    }

    func testManualResetReturnsInstructionsWithoutWriting() async throws {
        let result = try await adapter.reset(mode: .manual)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.mode, .manual)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    private func request(mode: ConfigurationMode) -> AgentConfigurationRequest {
        AgentConfigurationRequest(
            configuration: AgentConfiguration(
                agent: .openCode,
                proxyURL: "http://127.0.0.1:8317/v1",
                apiKey: "quotio-key"
            ),
            mode: mode,
            availableModels: [
                AvailableModel(id: "model", name: "test-model", provider: "test", isDefault: false),
            ]
        )
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: configURL)
    }
}
