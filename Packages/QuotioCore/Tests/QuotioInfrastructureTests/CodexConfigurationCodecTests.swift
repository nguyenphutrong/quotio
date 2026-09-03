import Foundation
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class CodexConfigurationCodecTests: XCTestCase {
    func testSnapshotReadsOnlyTopLevelValuesAndProviderBaseURL() {
        let content = """
        model = "gpt-5-codex"
        model_provider = "cliproxyapi"
        model_reasoning_effort = "turbo"
        notify = \"\"\"
        model_reasoning_effort = "do-not-read"
        [profiles.fake]
        \"\"\"

        [profiles.work]
        model = "profile-model"
        model_reasoning_effort = "minimal"

        [model_providers.cliproxyapi]
        base_url = "http://127.0.0.1:8317/v1"
        """

        let snapshot = CodexConfigurationCodec.snapshot(from: content)

        XCTAssertEqual(snapshot.model, "gpt-5-codex")
        XCTAssertEqual(snapshot.reasoningEffort, .custom("turbo"))
        XCTAssertEqual(snapshot.baseURL, "http://127.0.0.1:8317/v1")
        XCTAssertTrue(snapshot.isProxyConfigured)
    }

    func testMergePreservesCommentsUnknownSectionsMultilineStringsAndEscapesValues() {
        let existing = """
        # user header
        approval_policy = "never"
        notify = \"\"\"
        model = "not structure"
        [model_providers.cliproxyapi]
        \"\"\"

        [profiles.work]
        model = "profile-model"
        """
        let managed = CodexConfigurationCodec.managedTOML(
            model: "gpt-\"quoted",
            proxyURL: "http://localhost/path\\name",
            reasoningEffort: .custom("x\"high")
        )

        let merged = CodexConfigurationCodec.mergeTOML(existing: existing, managed: managed)

        XCTAssertTrue(merged.contains("# user header"))
        XCTAssertTrue(merged.contains("approval_policy = \"never\""))
        XCTAssertTrue(merged.contains("model = \"not structure\""))
        XCTAssertTrue(merged.contains("[profiles.work]"))
        XCTAssertTrue(merged.contains(#"model = "gpt-\"quoted""#))
        XCTAssertTrue(merged.contains(#"model_reasoning_effort = "x\"high""#))
        XCTAssertTrue(merged.contains(#"base_url = "http://localhost/path\\name""#))
    }

    func testAuthPayloadSeparatesManualContentFromMergedNativeCredentials() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": "native-secret", "refresh_token": "refresh-secret"],
            "last_refresh": "kept",
        ])

        let payloads = CodexConfigurationCodec.authPayloads(existing: existing, apiKey: "quotio-test")
        let managed = try json(payloads.managed)
        let merged = try json(payloads.merged)

        XCTAssertEqual(managed.count, 1)
        XCTAssertEqual(managed["OPENAI_API_KEY"] as? String, "quotio-test")
        XCTAssertFalse(String(decoding: payloads.managed, as: UTF8.self).contains("native-secret"))
        XCTAssertEqual((merged["tokens"] as? [String: Any])?["refresh_token"] as? String, "refresh-secret")
    }

    func testCorruptAuthFallsBackForPayloadButStrictOperationsThrow() throws {
        let corrupt = Data("not-json".utf8)
        let payloads = CodexConfigurationCodec.authPayloads(existing: corrupt, apiKey: "quotio-test")
        XCTAssertEqual(payloads.managed, payloads.merged)
        XCTAssertThrowsError(try CodexConfigurationCodec.mergedAuthJSON(existing: corrupt, apiKey: "key"))
        XCTAssertThrowsError(try CodexConfigurationCodec.removingManagedAuthKey(from: corrupt))
    }

    func testRemovingManagedAuthPreservesNativeFieldsAndUserOwnedKey() throws {
        let managed = try JSONSerialization.data(withJSONObject: [
            "OPENAI_API_KEY": "quotio-test", "access_token": "native",
        ])
        let cleaned = try XCTUnwrap(CodexConfigurationCodec.removingManagedAuthKey(from: managed))
        XCTAssertNil(try json(cleaned)["OPENAI_API_KEY"])
        XCTAssertEqual(try json(cleaned)["access_token"] as? String, "native")

        let userOwned = Data(#"{"OPENAI_API_KEY":"sk-user"}"#.utf8)
        XCTAssertNil(try CodexConfigurationCodec.removingManagedAuthKey(from: userOwned))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
