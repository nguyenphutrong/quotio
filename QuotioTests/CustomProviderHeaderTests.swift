import XCTest
@testable import Quotio

@MainActor
final class CustomProviderHeaderTests: XCTestCase {

    // MARK: - Helpers

    private func makeProvider(
        type: CustomProviderType,
        baseURL: String = "https://llm.internal/v1",
        apiKeys: [CustomAPIKeyEntry] = [CustomAPIKeyEntry(apiKey: "sk-test-1")],
        headers: [CustomHeader]
    ) -> CustomProvider {
        CustomProvider(
            name: "Private LLM",
            type: type,
            baseURL: baseURL,
            apiKeys: apiKeys,
            headers: headers
        )
    }

    private let sampleHeaders = [
        CustomHeader(key: "X-API-Key", value: "secret-token"),
        CustomHeader(key: "X-Tenant-ID", value: "team-a")
    ]

    // MARK: - Type gating

    func testSupportedTypesForCustomHeaders() {
        XCTAssertTrue(CustomProviderType.openaiCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.claudeCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.geminiCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.codexCompatibility.supportsCustomHeaders)
        XCTAssertFalse(CustomProviderType.glmCompatibility.supportsCustomHeaders)
        XCTAssertFalse(CustomProviderType.clinePass.supportsCustomHeaders)
    }

    // MARK: - YAML emission

    func testOpenAICompatibilityEmitsProviderLevelHeaders() {
        let provider = makeProvider(type: .openaiCompatibility, headers: sampleHeaders)
        let yaml = provider.toYAMLBlock()

        let expected = """
          - name: "Private LLM"
            base-url: "https://llm.internal/v1"
            headers:
              "X-API-Key": "secret-token"
              "X-Tenant-ID": "team-a"
            api-key-entries:
              - api-key: "sk-test-1"

        """
        XCTAssertEqual(yaml, expected)
    }

    func testClaudeCompatibilityEmitsPerKeyHeaders() {
        let provider = makeProvider(
            type: .claudeCompatibility,
            baseURL: "https://claude.internal",
            apiKeys: [
                CustomAPIKeyEntry(apiKey: "sk-a"),
                CustomAPIKeyEntry(apiKey: "sk-b")
            ],
            headers: sampleHeaders
        )
        let yaml = provider.toYAMLBlock()

        let expectedKeyBlock = """
            headers:
              "X-API-Key": "secret-token"
              "X-Tenant-ID": "team-a"
        """
        // Headers must be emitted once per API key entry
        XCTAssertEqual(yaml.components(separatedBy: expectedKeyBlock).count - 1, 2)
        XCTAssertTrue(yaml.contains("  - api-key: \"sk-a\"\n"))
        XCTAssertTrue(yaml.contains("  - api-key: \"sk-b\"\n"))
    }

    func testCodexCompatibilityEmitsPerKeyHeaders() {
        let provider = makeProvider(type: .codexCompatibility, headers: sampleHeaders)
        let yaml = provider.toYAMLBlock()

        let expected = """
          - api-key: "sk-test-1"
            base-url: "https://llm.internal/v1"
            headers:
              "X-API-Key": "secret-token"
              "X-Tenant-ID": "team-a"

        """
        XCTAssertEqual(yaml, expected)
    }

    func testGeminiCompatibilityEmitsPerKeyHeaders() {
        let provider = makeProvider(
            type: .geminiCompatibility,
            baseURL: "https://gemini.internal",
            headers: sampleHeaders
        )
        let yaml = provider.toYAMLBlock()

        let expected = """
          - api-key: "sk-test-1"
            base-url: "https://gemini.internal"
            headers:
              "X-API-Key": "secret-token"
              "X-Tenant-ID": "team-a"

        """
        XCTAssertEqual(yaml, expected)
    }

    func testGlmCompatibilityDoesNotEmitHeaders() {
        let provider = makeProvider(type: .glmCompatibility, baseURL: "", headers: sampleHeaders)
        let yaml = provider.toYAMLBlock()

        XCTAssertFalse(yaml.contains("headers:"))
        XCTAssertFalse(yaml.contains("X-API-Key"))
    }

    func testHeaderValuesAreEscapedForYAML() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "X-Quoted", value: "say \"hi\" \\ bye")]
        )
        let yaml = provider.toYAMLBlock()

        XCTAssertTrue(yaml.contains("      \"X-Quoted\": \"say \\\"hi\\\" \\\\ bye\"\n"))
    }

    func testInvalidOrEmptyHeaderNamesAreNotEmitted() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "", value: "ignored"),
                CustomHeader(key: "   ", value: "ignored"),
                CustomHeader(key: "Bad Name", value: "ignored"),
                CustomHeader(key: "X-Valid", value: "kept")
            ]
        )
        let yaml = provider.toYAMLBlock()

        XCTAssertTrue(yaml.contains("      \"X-Valid\": \"kept\"\n"))
        XCTAssertFalse(yaml.contains("ignored"))
        XCTAssertFalse(yaml.contains("Bad Name"))
    }

    func testHeadersOmittedWhenEmpty() {
        let provider = makeProvider(type: .openaiCompatibility, headers: [])
        XCTAssertFalse(provider.toYAMLBlock().contains("headers:"))
    }

    // MARK: - YAML round-trip through a parser

    func testGeneratedYAMLRoundTripsBackToTheCanonicalHeaders() throws {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "  X-Tenant-ID\t", value: "  team-a  "),
                CustomHeader(key: "X-Quoted", value: "say \"hi\" \\ bye"),
                CustomHeader(key: "X-Tabbed", value: "col-a\tcol-b"),
                CustomHeader(key: "X-Colonized", value: "a: b # not-a-comment")
            ]
        )

        let parsed = try YAMLHeaderBlockReader.blocks(in: provider.toYAMLBlock())
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(
            parsed.first.map { $0.map { [$0.name, $0.value] } },
            [
                ["X-Tenant-ID", "team-a"],
                ["X-Quoted", "say \"hi\" \\ bye"],
                ["X-Tabbed", "col-a\tcol-b"],
                ["X-Colonized", "a: b # not-a-comment"]
            ]
        )

        // What a YAML consumer sees must equal the canonical set the app sends on the wire.
        XCTAssertEqual(
            parsed.first.map { $0.map { [$0.name, $0.value] } },
            provider.effectiveHeaders.map { [$0.key, $0.value] }
        )
    }

    func testYAMLEscapingRoundTripsControlAndWhitespaceCharacters() throws {
        // These never survive validation, but the emitter must still be lossless:
        // a bare newline in a quoted scalar is folded to a space by a YAML parser.
        let originals = [
            "line1\nline2",
            "carriage\r\nreturn",
            "null\u{00}byte",
            "delete\u{7F}char",
            "escape\u{1B}[0m",
            "next\u{85}line",
            "nbsp\u{A0}space",
            "sep\u{2028}line",
            "tab\tand \"quotes\" and \\slash"
        ]

        for original in originals {
            let quoted = "\"" + CustomProvider.escapedYAMLString(original) + "\""
            XCTAssertFalse(quoted.contains("\n"), "escaped scalar must stay on one line: \(original.debugDescription)")
            XCTAssertFalse(quoted.contains("\r"), "escaped scalar must stay on one line: \(original.debugDescription)")
            XCTAssertEqual(try YAMLHeaderBlockReader.decodeDoubleQuotedScalar(quoted), original)
        }
    }

    // MARK: - Request-building path (the path the reviewer reproduced against CFNetwork)

    func testConnectionTestRequestSendsNormalizedHeaderName() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: " X-Tenant-ID ", value: " team-a ")]
        )

        var request = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        request.applyCustomHeaders(provider.effectiveHeaders)

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tenant-ID"), "team-a")

        let sentNames = request.allHTTPHeaderFields?.keys.sorted() ?? []
        XCTAssertEqual(sentNames.count, 1)
        for name in sentNames {
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertTrue(CustomHeader.isValidName(name), "request carried a non-token header name: \(name.debugDescription)")
        }
    }

    func testRequestHeadersMatchGeneratedYAMLHeaders() throws {
        let rawFormHeaders = [
            CustomHeader(key: " X-API-Key ", value: "\tsecret-token "),
            CustomHeader(key: "X-Model-Version", value: "2024-12")
        ]

        // Fetch Models canonicalizes the raw form input; save persists the same call.
        let fetchModelsHeaders = CustomHeader.canonicalized(rawFormHeaders)
        XCTAssertTrue(CustomHeader.validationErrors(in: fetchModelsHeaders).isEmpty)

        var fetchRequest = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        fetchRequest.applyCustomHeaders(fetchModelsHeaders)

        let provider = makeProvider(type: .openaiCompatibility, headers: fetchModelsHeaders)
        var testRequest = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        testRequest.applyCustomHeaders(provider.effectiveHeaders)

        XCTAssertEqual(fetchRequest.value(forHTTPHeaderField: "X-API-Key"), "secret-token")
        XCTAssertEqual(testRequest.value(forHTTPHeaderField: "X-API-Key"), "secret-token")

        let emitted = try XCTUnwrap(YAMLHeaderBlockReader.blocks(in: provider.toYAMLBlock()).first)
        for entry in emitted {
            XCTAssertEqual(fetchRequest.value(forHTTPHeaderField: entry.name), entry.value)
            XCTAssertEqual(testRequest.value(forHTTPHeaderField: entry.name), entry.value)
        }
    }

    func testEffectiveHeadersAreEmptyForUnsupportedProviderTypes() {
        for type in [CustomProviderType.glmCompatibility, .clinePass] {
            let provider = makeProvider(type: type, baseURL: "", headers: sampleHeaders)
            XCTAssertTrue(provider.effectiveHeaders.isEmpty, "\(type) must not send custom headers")
        }
    }

    func testEffectiveHeadersDropEntriesThatValidationWouldReject() {
        // Simulates a provider persisted before this validation existed.
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "Bad Name", value: "v"),
                CustomHeader(key: "X-Bad-Value", value: "a\r\nX-Injected: 1"),
                CustomHeader(key: "X-Good", value: "ok")
            ]
        )

        XCTAssertEqual(provider.effectiveHeaders.map(\.key), ["X-Good"])

        var request = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        request.applyCustomHeaders(provider.effectiveHeaders)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Injected"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Bad-Value"))
    }

    // MARK: - Normalization

    func testCanonicalizedTrimsOptionalWhitespaceAndDropsUnnamedEntries() {
        let canonical = CustomHeader.canonicalized([
            CustomHeader(key: " X-Tenant-ID\t", value: "\t team-a "),
            CustomHeader(key: "   ", value: "ignored"),
            CustomHeader(key: "", value: "ignored")
        ])

        XCTAssertEqual(canonical.map { [$0.key, $0.value] }, [["X-Tenant-ID", "team-a"]])
    }

    func testCanonicalizedDoesNotStripNewlinesFromValues() {
        // Stripping would silently change a secret; validation must reject instead.
        let canonical = CustomHeader.canonicalized([CustomHeader(key: "X-Secret", value: " line1\nline2 ")])
        XCTAssertEqual(canonical.first?.value, "line1\nline2")
        XCTAssertFalse(CustomHeader.validationErrors(in: canonical).isEmpty)
    }

    func testHeaderNamesAreNormalizedBeforePersistenceValidation() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: " X-Tenant-ID ", value: " team-a ")]
        )
        XCTAssertTrue(provider.validate().isEmpty)
        XCTAssertEqual(provider.effectiveHeaders.map { [$0.key, $0.value] }, [["X-Tenant-ID", "team-a"]])
    }

    func testNormalizationMakesWhitespacePaddedDuplicatesDetectable() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "X-API-Key", value: "a"),
                CustomHeader(key: "  X-API-Key  ", value: "b")
            ]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    // MARK: - Header value validation

    func testIsValidValueAcceptsWireSafeValues() {
        XCTAssertTrue(CustomHeader.isValidValue(""))
        XCTAssertTrue(CustomHeader.isValidValue("secret-token"))
        XCTAssertTrue(CustomHeader.isValidValue("a: b, c=d; e"))
        XCTAssertTrue(CustomHeader.isValidValue("col-a\tcol-b"))
    }

    func testIsValidValueRejectsControlCharactersAndNonASCII() {
        XCTAssertFalse(CustomHeader.isValidValue("line1\nline2"))
        XCTAssertFalse(CustomHeader.isValidValue("line1\rline2"))
        XCTAssertFalse(CustomHeader.isValidValue("a\r\nX-Injected: 1"))
        XCTAssertFalse(CustomHeader.isValidValue("null\u{00}byte"))
        XCTAssertFalse(CustomHeader.isValidValue("delete\u{7F}"))
        XCTAssertFalse(CustomHeader.isValidValue("token\u{A0}"))
        XCTAssertFalse(CustomHeader.isValidValue("bí-mật"))
    }

    func testValidateRejectsHeaderValueWithLineBreak() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "X-Secret", value: "line1\nline2")]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    func testValidateRejectsCRLFHeaderInjectionAttempt() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "X-Tenant-ID", value: "team-a\r\nAuthorization: Bearer stolen")]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    // MARK: - Header name validation

    func testIsValidNameAcceptsRFC7230Tokens() {
        XCTAssertTrue(CustomHeader.isValidName("X-API-Key"))
        XCTAssertTrue(CustomHeader.isValidName("X-Model-Version"))
        XCTAssertTrue(CustomHeader.isValidName("x_custom.header~1"))
    }

    func testIsValidNameRejectsInvalidCharacters() {
        XCTAssertFalse(CustomHeader.isValidName(""))
        XCTAssertFalse(CustomHeader.isValidName("X API Key"))
        XCTAssertFalse(CustomHeader.isValidName("X-API-Key:"))
        XCTAssertFalse(CustomHeader.isValidName("Ключ"))
    }

    func testValidateRejectsInvalidHeaderName() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "Bad Name", value: "v")]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    func testValidateRejectsDuplicateHeaderNamesCaseInsensitively() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "X-API-Key", value: "a"),
                CustomHeader(key: "x-api-key", value: "b")
            ]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    func testValidateAcceptsWellFormedHeaders() {
        let provider = makeProvider(type: .openaiCompatibility, headers: sampleHeaders)
        XCTAssertTrue(provider.validate().isEmpty)
    }

    // MARK: - Codable round-trip

    func testHeadersSurviveCodableRoundTrip() throws {
        let provider = makeProvider(type: .claudeCompatibility, headers: sampleHeaders)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CustomProvider.self, from: encoder.encode(provider))
        XCTAssertEqual(decoded.headers, provider.headers)
    }

    // MARK: - Config strip/re-append round-trip

    func testConfigStripAndReappendIsIdempotent() {
        let baseConfig = """
        port: 8317
        auth-dir: "~/.cli-proxy-api"
        remote-management:
          allow-remote: false
        """

        let providers = [
            makeProvider(type: .openaiCompatibility, headers: sampleHeaders),
            makeProvider(type: .geminiCompatibility, baseURL: "https://gemini.internal", headers: sampleHeaders)
        ]
        let sections = providers.toYAMLSections()
        XCTAssertTrue(sections.contains("\"X-API-Key\": \"secret-token\""))

        let service = CustomProviderService.shared

        let withSections = baseConfig + "\n\n# Custom Providers (managed by Quotio)\n" + sections
        let strippedOnce = service.removeCustomProviderSections(from: withSections)
        XCTAssertEqual(strippedOnce, baseConfig)

        let reappended = strippedOnce + "\n\n# Custom Providers (managed by Quotio)\n" + sections
        let strippedTwice = service.removeCustomProviderSections(from: reappended)
        XCTAssertEqual(strippedTwice, strippedOnce)
    }
}

// MARK: - YAML reader

/// A minimal reader for the `headers:` blocks emitted by `CustomProvider.toYAMLBlock()`.
///
/// It decodes double-quoted scalars using the YAML 1.2 escape table, so tests can assert
/// what a YAML consumer (CLIProxyAPI) actually parses back rather than matching the
/// generated text with substring checks.
enum YAMLHeaderBlockReader {

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    /// Every `headers:` mapping in the document, in order, as ordered name/value pairs.
    static func blocks(in yaml: String) throws -> [[(name: String, value: String)]] {
        var result: [[(name: String, value: String)]] = []
        let lines = yaml.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.trimmingCharacters(in: .whitespaces) == "headers:" else { continue }

            let blockIndent = line.prefix { $0 == " " }.count
            var entries: [(name: String, value: String)] = []

            while index < lines.count {
                let entryLine = lines[index]
                let entryIndent = entryLine.prefix { $0 == " " }.count
                guard !entryLine.trimmingCharacters(in: .whitespaces).isEmpty, entryIndent > blockIndent else { break }
                entries.append(try parseEntry(entryLine))
                index += 1
            }

            result.append(entries)
        }

        return result
    }

    /// Decode a single double-quoted YAML scalar, quotes included.
    static func decodeDoubleQuotedScalar(_ scalar: String) throws -> String {
        let scalars = Array(scalar.unicodeScalars)
        var cursor = 0
        let decoded = try readDoubleQuotedScalar(scalars, &cursor)
        guard cursor == scalars.count else {
            throw ParseError(description: "trailing content after scalar: \(scalar.debugDescription)")
        }
        return decoded
    }

    private static func parseEntry(_ line: String) throws -> (name: String, value: String) {
        let scalars = Array(line.unicodeScalars)
        var cursor = 0

        func skipSpaces() {
            while cursor < scalars.count, scalars[cursor] == " " { cursor += 1 }
        }

        skipSpaces()
        let name = try readDoubleQuotedScalar(scalars, &cursor)
        skipSpaces()
        guard cursor < scalars.count, scalars[cursor] == ":" else {
            throw ParseError(description: "expected ':' in \(line.debugDescription)")
        }
        cursor += 1
        skipSpaces()
        let value = try readDoubleQuotedScalar(scalars, &cursor)
        skipSpaces()
        guard cursor == scalars.count else {
            throw ParseError(description: "trailing content in \(line.debugDescription)")
        }
        return (name, value)
    }

    private static func readDoubleQuotedScalar(_ scalars: [Unicode.Scalar], _ cursor: inout Int) throws -> String {
        guard cursor < scalars.count, scalars[cursor] == "\"" else {
            throw ParseError(description: "expected a double-quoted scalar at offset \(cursor)")
        }
        cursor += 1

        var decoded = String.UnicodeScalarView()

        while cursor < scalars.count {
            let scalar = scalars[cursor]
            cursor += 1

            if scalar == "\"" {
                return String(decoded)
            }
            guard scalar == "\\" else {
                decoded.append(scalar)
                continue
            }
            guard cursor < scalars.count else {
                throw ParseError(description: "dangling escape at end of scalar")
            }

            let escape = scalars[cursor]
            cursor += 1

            switch escape {
            case "0": decoded.append("\u{00}")
            case "a": decoded.append("\u{07}")
            case "b": decoded.append("\u{08}")
            case "t": decoded.append("\u{09}")
            case "n": decoded.append("\u{0A}")
            case "v": decoded.append("\u{0B}")
            case "f": decoded.append("\u{0C}")
            case "r": decoded.append("\u{0D}")
            case "e": decoded.append("\u{1B}")
            case " ": decoded.append(" ")
            case "\"": decoded.append("\"")
            case "/": decoded.append("/")
            case "\\": decoded.append("\\")
            case "N": decoded.append("\u{85}")
            case "_": decoded.append("\u{A0}")
            case "L": decoded.append("\u{2028}")
            case "P": decoded.append("\u{2029}")
            case "x": decoded.append(try readHexEscape(scalars, &cursor, digits: 2))
            case "u": decoded.append(try readHexEscape(scalars, &cursor, digits: 4))
            case "U": decoded.append(try readHexEscape(scalars, &cursor, digits: 8))
            default:
                throw ParseError(description: "unsupported escape '\\\(escape)'")
            }
        }

        throw ParseError(description: "unterminated double-quoted scalar")
    }

    private static func readHexEscape(_ scalars: [Unicode.Scalar], _ cursor: inout Int, digits: Int) throws -> Unicode.Scalar {
        guard cursor + digits <= scalars.count else {
            throw ParseError(description: "truncated hex escape")
        }
        let text = String(String.UnicodeScalarView(scalars[cursor..<(cursor + digits)]))
        cursor += digits
        guard let code = UInt32(text, radix: 16), let scalar = Unicode.Scalar(code) else {
            throw ParseError(description: "invalid hex escape '\(text)'")
        }
        return scalar
    }
}
