import XCTest
@testable import Quotio

/// Verifies that auth file structs preserve JSON fields Quotio does not model
/// across a decode → modify → encode cycle (issue #239).
final class AuthFileUnknownFieldsTests: XCTestCase {

    // MARK: - Helpers

    private func jsonObject(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// Unknown fields covering every JSON shape: string, int, double, bool,
    /// null, array, and nested object.
    private let unknownFieldsFragment = """
        "custom_header": "X-Custom: value",
        "retry_count": 3,
        "weight": 0.75,
        "experimental": true,
        "deprecated_field": null,
        "tags": ["alpha", "beta", 42],
        "metadata": {
            "base_url": "https://example.com",
            "nested": {"depth": 2},
            "flags": [true, false]
        }
    """

    private func assertUnknownFieldsPreserved(in output: NSDictionary, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(output["custom_header"] as? String, "X-Custom: value", file: file, line: line)
        XCTAssertEqual(output["retry_count"] as? Int, 3, file: file, line: line)
        XCTAssertEqual(output["weight"] as? Double, 0.75, file: file, line: line)
        XCTAssertEqual(output["experimental"] as? Bool, true, file: file, line: line)
        XCTAssertTrue(output["deprecated_field"] is NSNull, file: file, line: line)
        XCTAssertEqual(output["tags"] as? NSArray, ["alpha", "beta", 42] as NSArray, file: file, line: line)
        let metadata = output["metadata"] as? NSDictionary
        XCTAssertEqual(metadata?["base_url"] as? String, "https://example.com", file: file, line: line)
        XCTAssertEqual(metadata?["nested"] as? NSDictionary, ["depth": 2] as NSDictionary, file: file, line: line)
        XCTAssertEqual(metadata?["flags"] as? NSArray, [true, false] as NSArray, file: file, line: line)
    }

    // MARK: - AntigravityAuthFile

    func testAntigravityAuthFilePreservesUnknownFieldsAcrossRoundTrip() throws {
        let json = """
        {
            "access_token": "old-token",
            "email": "user@example.com",
            "expired": "2026-01-01T00:00:00Z",
            "expires_in": 3599,
            "refresh_token": "refresh-123",
            "timestamp": 1767225600000,
            "type": "antigravity",
            "prefix": "myprefix",
            "project_id": "my-project",
            "proxy_url": "http://127.0.0.1:8080",
            \(unknownFieldsFragment)
        }
        """.data(using: .utf8)!

        var authFile = try JSONDecoder().decode(AntigravityAuthFile.self, from: json)

        // Simulate a token refresh mutating the typed fields.
        authFile.accessToken = "new-token"
        authFile.expired = "2026-06-01T00:00:00Z"

        let output = try jsonObject(try JSONEncoder().encode(authFile))

        // Typed updates applied.
        XCTAssertEqual(output["access_token"] as? String, "new-token")
        XCTAssertEqual(output["expired"] as? String, "2026-06-01T00:00:00Z")

        // Known fields intact (incl. the PR #210 fields).
        XCTAssertEqual(output["email"] as? String, "user@example.com")
        XCTAssertEqual(output["expires_in"] as? Int, 3599)
        XCTAssertEqual(output["refresh_token"] as? String, "refresh-123")
        XCTAssertEqual(output["timestamp"] as? Int, 1_767_225_600_000)
        XCTAssertEqual(output["type"] as? String, "antigravity")
        XCTAssertEqual(output["prefix"] as? String, "myprefix")
        XCTAssertEqual(output["project_id"] as? String, "my-project")
        XCTAssertEqual(output["proxy_url"] as? String, "http://127.0.0.1:8080")

        // Unknown fields survived.
        assertUnknownFieldsPreserved(in: output)
    }

    func testAntigravityAuthFileDecodesKnownFieldsWithoutUnknownFields() throws {
        let json = """
        {"access_token": "token", "email": "user@example.com"}
        """.data(using: .utf8)!

        let authFile = try JSONDecoder().decode(AntigravityAuthFile.self, from: json)
        XCTAssertEqual(authFile.accessToken, "token")
        XCTAssertEqual(authFile.email, "user@example.com")
        XCTAssertTrue(authFile.additionalFields.isEmpty)

        // Encoding without unknown fields emits only the known keys.
        let output = try jsonObject(try JSONEncoder().encode(authFile))
        XCTAssertEqual(output, ["access_token": "token", "email": "user@example.com"] as NSDictionary)
    }

    // MARK: - CodexAuthFile

    func testCodexAuthFilePreservesUnknownFieldsAcrossRoundTrip() throws {
        let json = """
        {
            "access_token": "old-token",
            "account_id": "acct-1",
            "email": "user@example.com",
            "expired": "2026-01-01T00:00:00Z",
            "id_token": "id-token",
            "refresh_token": "refresh-123",
            "type": "codex",
            "prefix": "myprefix",
            "proxy_url": "http://127.0.0.1:8080",
            \(unknownFieldsFragment)
        }
        """.data(using: .utf8)!

        var authFile = try JSONDecoder().decode(CodexAuthFile.self, from: json)
        authFile.accessToken = "new-token"

        let output = try jsonObject(try JSONEncoder().encode(authFile))

        XCTAssertEqual(output["access_token"] as? String, "new-token")
        XCTAssertEqual(output["account_id"] as? String, "acct-1")
        XCTAssertEqual(output["email"] as? String, "user@example.com")
        XCTAssertEqual(output["expired"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(output["id_token"] as? String, "id-token")
        XCTAssertEqual(output["refresh_token"] as? String, "refresh-123")
        XCTAssertEqual(output["type"] as? String, "codex")
        XCTAssertEqual(output["prefix"] as? String, "myprefix")
        XCTAssertEqual(output["proxy_url"] as? String, "http://127.0.0.1:8080")

        assertUnknownFieldsPreserved(in: output)
    }

    // MARK: - CodexCLIAuthFile (native Codex CLI credential)

    func testCodexCLIAuthFilePreservesUnknownFieldsIncludingNestedTokens() throws {
        let json = """
        {
            "OPENAI_API_KEY": "sk-test",
            "last_refresh": "2026-01-01T00:00:00Z",
            "tokens": {
                "id_token": "id-token",
                "access_token": "old-token",
                "refresh_token": "refresh-123",
                "account_id": "acct-1",
                "future_token_field": "keep-me"
            },
            \(unknownFieldsFragment)
        }
        """.data(using: .utf8)!

        var authFile = try JSONDecoder().decode(CodexCLIAuthFile.self, from: json)

        // Simulate the keychain refresh path mutating nested tokens.
        var tokens = try XCTUnwrap(authFile.tokens)
        tokens.accessToken = "new-token"
        tokens.refreshToken = "refresh-456"
        authFile.tokens = tokens

        let output = try jsonObject(try JSONEncoder().encode(authFile))

        XCTAssertEqual(output["OPENAI_API_KEY"] as? String, "sk-test")
        XCTAssertEqual(output["last_refresh"] as? String, "2026-01-01T00:00:00Z")

        let outputTokens = try XCTUnwrap(output["tokens"] as? NSDictionary)
        XCTAssertEqual(outputTokens["access_token"] as? String, "new-token")
        XCTAssertEqual(outputTokens["refresh_token"] as? String, "refresh-456")
        XCTAssertEqual(outputTokens["id_token"] as? String, "id-token")
        XCTAssertEqual(outputTokens["account_id"] as? String, "acct-1")
        XCTAssertEqual(outputTokens["future_token_field"] as? String, "keep-me")

        assertUnknownFieldsPreserved(in: output)
    }

    // MARK: - Full-fidelity round trip

    func testRoundTripWithoutModificationIsLossless() throws {
        let json = """
        {
            "access_token": "token",
            "email": "user@example.com",
            \(unknownFieldsFragment)
        }
        """.data(using: .utf8)!

        let authFile = try JSONDecoder().decode(AntigravityAuthFile.self, from: json)
        let reencoded = try jsonObject(try JSONEncoder().encode(authFile))
        let original = try jsonObject(json)
        XCTAssertEqual(reencoded, original)
    }
}
