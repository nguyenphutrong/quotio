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

    // MARK: - Numeric fidelity on the native Codex Keychain refresh path

    /// Mirrors `CodexCLIQuotaFetcher.persistNativeKeychainRefresh`: decode the whole
    /// credential blob, swap the rotated tokens, re-encode the whole blob.
    private func simulateNativeKeychainRefresh(_ record: Data) throws -> Data {
        var auth = try JSONDecoder().decode(CodexCLIAuthFile.self, from: record)
        var tokens = try XCTUnwrap(auth.tokens)
        tokens.accessToken = "new-access"
        tokens.refreshToken = "new-refresh"
        tokens.idToken = "new-id"
        auth.tokens = tokens
        return try JSONEncoder().encode(auth)
    }

    /// An unknown integer larger than `Int64.max` must survive the refresh unchanged.
    /// Narrowing to `Double` would rewrite it as `9.223372036854776e+18`.
    func testNativeKeychainRefreshPreservesIntegerBeyondInt64() throws {
        let json = """
        {
            "OPENAI_API_KEY": "sk-test",
            "last_refresh": "2026-01-01T00:00:00Z",
            "tokens": {
                "id_token": "old-id",
                "access_token": "old-access",
                "refresh_token": "old-refresh",
                "account_id": "acct-1",
                "token_serial": 9223372036854775809
            },
            "install_id": 9223372036854775809,
            "ratio": 0.1
        }
        """.data(using: .utf8)!

        let refreshed = try simulateNativeKeychainRefresh(json)
        let text = String(decoding: refreshed, as: UTF8.self)

        XCTAssertTrue(text.contains("\"install_id\":9223372036854775809"), text)
        XCTAssertTrue(text.contains("\"token_serial\":9223372036854775809"), text)
        XCTAssertFalse(text.contains("9.223372036854776e+18"), text)
        // Base-10 fractions keep their literal form too.
        XCTAssertTrue(text.contains("\"ratio\":0.1"), text)

        // The refresh itself still did its job.
        let output = try jsonObject(refreshed)
        XCTAssertEqual(output["OPENAI_API_KEY"] as? String, "sk-test")
        XCTAssertEqual(output["last_refresh"] as? String, "2026-01-01T00:00:00Z")
        let tokens = try XCTUnwrap(output["tokens"] as? NSDictionary)
        XCTAssertEqual(tokens["access_token"] as? String, "new-access")
        XCTAssertEqual(tokens["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(tokens["id_token"] as? String, "new-id")
        XCTAssertEqual(tokens["account_id"] as? String, "acct-1")
    }

    /// A literal such as `1e400` overflows every numeric type Foundation can build.
    /// It must not abort the decode — token refresh has to keep working, and every
    /// other unknown field has to survive.
    func testNativeKeychainRefreshSurvivesUnrepresentableExponent() throws {
        let json = """
        {
            "OPENAI_API_KEY": "sk-test",
            "last_refresh": "2026-01-01T00:00:00Z",
            "tokens": {
                "id_token": "old-id",
                "access_token": "old-access",
                "refresh_token": "old-refresh",
                "account_id": "acct-1",
                "overflowing_token_field": 1e400,
                "kept_token_field": "keep-me"
            },
            "overflowing": 1e400,
            "underflowing": 1e-400,
            "kept": "still-here",
            "install_id": 9223372036854775809
        }
        """.data(using: .utf8)!

        let refreshed = try simulateNativeKeychainRefresh(json)
        let output = try jsonObject(refreshed)

        // Refresh completed and unrelated fields are untouched.
        XCTAssertEqual(output["OPENAI_API_KEY"] as? String, "sk-test")
        XCTAssertEqual(output["last_refresh"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(output["kept"] as? String, "still-here")
        XCTAssertTrue(
            String(decoding: refreshed, as: UTF8.self).contains("\"install_id\":9223372036854775809"),
            String(decoding: refreshed, as: UTF8.self)
        )

        let tokens = try XCTUnwrap(output["tokens"] as? NSDictionary)
        XCTAssertEqual(tokens["access_token"] as? String, "new-access")
        XCTAssertEqual(tokens["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(tokens["id_token"] as? String, "new-id")
        XCTAssertEqual(tokens["kept_token_field"] as? String, "keep-me")

        // Values Foundation cannot represent are dropped, never fatal.
        XCTAssertNil(output["overflowing"])
        XCTAssertNil(output["underflowing"])
        XCTAssertNil(tokens["overflowing_token_field"])
    }

    // MARK: - JSONValue numeric representation

    func testJSONValueRepresentsNumbersAsDecimalWithoutNarrowing() throws {
        let json = """
        {
            "beyond_int64": 9223372036854775809,
            "beyond_uint64": 18446744073709551616,
            "fraction": 0.1,
            "integral": 3,
            "beyond_decimal_exponent": 1e308,
            "numeric_string": "123",
            "flag": true
        }
        """.data(using: .utf8)!

        let values = try JSONDecoder().decode([String: JSONValue].self, from: json)

        XCTAssertEqual(values["beyond_int64"], .number(Decimal(string: "9223372036854775809")!))
        XCTAssertEqual(values["beyond_uint64"], .number(Decimal(string: "18446744073709551616")!))
        XCTAssertEqual(values["fraction"], .number(Decimal(string: "0.1")!))
        XCTAssertEqual(values["integral"], .number(3))
        // Outside Decimal's exponent range but finite: Double keeps it rather than dropping it.
        XCTAssertEqual(values["beyond_decimal_exponent"], .double(1e308))
        // Numbers must not swallow string/bool literals.
        XCTAssertEqual(values["numeric_string"], .string("123"))
        XCTAssertEqual(values["flag"], .bool(true))
    }

    func testJSONValueReportsUnrepresentableNumbersDistinctly() throws {
        let json = "{\"v\":1e400}".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode([String: JSONValue].self, from: json)) { error in
            XCTAssertTrue(
                error is JSONValue.UnrepresentableNumberError,
                "expected UnrepresentableNumberError, got \(error)"
            )
        }
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
