import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class CustomProviderAdaptersTests: XCTestCase {
    func testUserDefaultsUsesExistingKeyAndISO8601Schema() throws {
        let suite = "CustomProviderAdaptersTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = CustomProvider(name: "GLM", type: .glmCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "plain-api-key")], createdAt: date, updatedAt: date)
        let repository = UserDefaultsCustomProviderRepository(defaults: defaults)
        try repository.save([provider])

        let data = try XCTUnwrap(defaults.data(forKey: "customProviders"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"api-key\" : \"plain-api-key\""))
        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"))
        XCTAssertEqual(try repository.load(), [provider])
    }

    func testConfigSynchronizerReplacesManagedSectionsWithoutChangingFollowingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.yaml")
        try """
        port: 8317

        # Custom Providers (managed by Quotio)
        openai-compatibility:
          - name: "Old"
            base-url: "https://old.example/v1"

        routing:
          strategy: round-robin
        """.write(to: url, atomically: true, encoding: .utf8)
        let provider = CustomProvider(
            name: "New",
            type: .openaiCompatibility,
            baseURL: "https://new.example/v1",
            apiKeys: [CustomAPIKeyEntry(apiKey: "secret")]
        )

        try FileCustomProviderConfigurationSynchronizer().synchronize([provider], at: url.path)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("name: \"Old\""))
        XCTAssertTrue(content.contains("name: \"New\""))
        XCTAssertTrue(content.contains("routing:\n  strategy: round-robin"))
        XCTAssertEqual(content.components(separatedBy: "openai-compatibility:").count, 2)
    }

    func testOpenAIRequestNormalizesURLAuthAndSafeCustomHeaders() async throws {
        let session = RecordingSession(body: #"{"data":[{"id":"z","name":"Zulu","owned_by":"team"},{"id":"a"}]}"#)
        let transport = URLSessionCustomProviderTransport(session: session)
        let provider = CustomProvider(name: "Private", type: .openaiCompatibility, baseURL: " https://llm.example/api ",
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "secret")], headers: [
                                        CustomHeader(key: " X-Tenant ", value: " team-a "),
                                        CustomHeader(key: "Bad Name", value: "drop")
                                      ])
        let models = try await transport.discoverModels(for: provider)
        let request = try await session.request()
        XCTAssertEqual(request.url?.absoluteString, "https://llm.example/api/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tenant"), "team-a")
        XCTAssertNil(request.value(forHTTPHeaderField: "Bad Name"))
        XCTAssertEqual(models.map(\.id), ["z", "a"])
    }

    func testGeminiUsesQueryAuthenticationAndConnectionMapsUnauthorized() async throws {
        let session = RecordingSession(body: "denied", statusCode: 403)
        let transport = URLSessionCustomProviderTransport(session: session)
        let provider = CustomProvider(name: "Gemini", type: .geminiCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "secret")])
        do { try await transport.testConnection(to: provider); XCTFail("Expected unauthorized") }
        catch { XCTAssertEqual(error as? CustomProviderRemoteError, .unauthorized) }
        let request = try await session.request()
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testClinePassSerializesInOpenAISection() {
        let provider = CustomProvider(
            name: "ClinePass Team",
            type: .clinePass,
            apiKeys: [CustomAPIKeyEntry(apiKey: "key-one")],
            models: [ModelMapping(name: "model", alias: "model")]
        )

        let yaml = CustomProviderYAMLSerializer.sections(for: [provider])

        XCTAssertTrue(yaml.contains("openai-compatibility:"))
        XCTAssertFalse(yaml.contains("\nclinepass:"))
        XCTAssertTrue(yaml.contains("name: \"ClinePass Team\""))
    }

    func testProviderTypesSerializeHeadersAtExpectedLevel() {
        let openAI = CustomProviderYAMLSerializer.block(for: makeProvider(
            type: .openaiCompatibility,
            headers: sampleHeaders
        ))
        XCTAssertTrue(openAI.contains(
            "    headers:\n      \"X-API-Key\": \"secret-token\"\n"
        ))
        XCTAssertTrue(openAI.contains("    api-key-entries:\n      - api-key: \"key-one\"\n"))

        let claude = CustomProviderYAMLSerializer.block(for: makeProvider(
            type: .claudeCompatibility,
            baseURL: "https://claude.internal",
            apiKeys: [
                CustomAPIKeyEntry(apiKey: "key-a"),
                CustomAPIKeyEntry(apiKey: "key-b"),
            ],
            headers: sampleHeaders
        ))
        XCTAssertEqual(claude.components(separatedBy: "    headers:\n").count - 1, 2)

        let codex = CustomProviderYAMLSerializer.block(for: makeProvider(
            type: .codexCompatibility,
            headers: sampleHeaders
        ))
        XCTAssertTrue(codex.contains("    base-url: \"https://llm.internal/v1\"\n"))
        XCTAssertTrue(codex.contains("    headers:\n"))

        let gemini = CustomProviderYAMLSerializer.block(for: makeProvider(
            type: .geminiCompatibility,
            baseURL: "https://gemini.internal",
            headers: sampleHeaders
        ))
        XCTAssertTrue(gemini.contains("    base-url: \"https://gemini.internal\"\n"))
        XCTAssertTrue(gemini.contains("    headers:\n"))
    }

    func testSerializerOmitsUnsupportedInvalidAndEmptyHeaders() {
        let glm = makeProvider(type: .glmCompatibility, baseURL: "", headers: sampleHeaders)
        XCTAssertFalse(CustomProviderYAMLSerializer.block(for: glm).contains("headers:"))

        let invalid = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "", value: "ignored"),
                CustomHeader(key: "   ", value: "ignored"),
                CustomHeader(key: "Bad Name", value: "ignored"),
                CustomHeader(key: "X-Valid", value: "kept"),
            ]
        )
        let invalidYAML = CustomProviderYAMLSerializer.block(for: invalid)
        XCTAssertTrue(invalidYAML.contains("      \"X-Valid\": \"kept\"\n"))
        XCTAssertFalse(invalidYAML.contains("ignored"))
        XCTAssertFalse(invalidYAML.contains("Bad Name"))

        let empty = makeProvider(type: .openaiCompatibility, headers: [])
        XCTAssertFalse(CustomProviderYAMLSerializer.block(for: empty).contains("headers:"))
    }

    func testGeneratedYAMLRoundTripsCanonicalHeaders() throws {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "  X-Tenant-ID\t", value: "  team-a  "),
                CustomHeader(key: "X-Quoted", value: "say \"hi\" \\ bye"),
                CustomHeader(key: "X-Tabbed", value: "col-a\tcol-b"),
                CustomHeader(key: "X-Colonized", value: "a: b # not-a-comment"),
            ]
        )

        let parsed = try YAMLHeaderBlockReader.blocks(
            in: CustomProviderYAMLSerializer.block(for: provider)
        )

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(
            parsed.first.map { $0.map { [$0.name, $0.value] } },
            provider.effectiveHeaders.map { [$0.key, $0.value] }
        )
    }

    func testYAMLEscapingRoundTripsControlAndWhitespaceCharacters() throws {
        let originals = [
            "line1\nline2",
            "carriage\r\nreturn",
            "null\u{00}byte",
            "delete\u{7F}char",
            "escape\u{1B}[0m",
            "next\u{85}line",
            "nbsp\u{A0}space",
            "sep\u{2028}line",
            "tab\tand \"quotes\" and \\slash",
        ]

        for original in originals {
            let quoted = "\"" + CustomProviderYAMLSerializer.escapedString(original) + "\""
            XCTAssertFalse(quoted.contains("\n"))
            XCTAssertFalse(quoted.contains("\r"))
            XCTAssertEqual(try YAMLHeaderBlockReader.decodeDoubleQuotedScalar(quoted), original)
        }
    }

    func testRequestHeadersMatchGeneratedYAMLHeaders() async throws {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: " X-API-Key ", value: "\tsecret-token "),
                CustomHeader(key: "X-Model-Version", value: "2024-12"),
            ]
        )
        let transport = URLSessionCustomProviderTransport()

        let fetchRequest = try await transport.makeRequest(
            provider: provider,
            connectionTest: false
        )
        let testRequest = try await transport.makeRequest(
            provider: provider,
            connectionTest: true
        )
        let emitted = try XCTUnwrap(YAMLHeaderBlockReader.blocks(
            in: CustomProviderYAMLSerializer.block(for: provider)
        ).first)

        for entry in emitted {
            XCTAssertEqual(fetchRequest.value(forHTTPHeaderField: entry.name), entry.value)
            XCTAssertEqual(testRequest.value(forHTTPHeaderField: entry.name), entry.value)
        }
    }

    func testConnectionRequestSendsOnlyCanonicalSafeHeaders() async throws {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: " X-Tenant-ID ", value: " team-a "),
                CustomHeader(key: "X-Bad-Value", value: "a\r\nX-Injected: 1"),
            ]
        )

        let request = try await URLSessionCustomProviderTransport().makeRequest(
            provider: provider,
            connectionTest: true
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tenant-ID"), "team-a")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Injected"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Bad-Value"))
        for name in request.allHTTPHeaderFields?.keys.map({ $0 }) ?? [] {
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertTrue(CustomHeader.isValidName(name))
        }
    }

    func testManagedSectionRemovalIsIdempotent() {
        let baseConfig = """
        port: 8317
        auth-dir: "~/.cli-proxy-api"
        remote-management:
          allow-remote: false
        """
        let sections = CustomProviderYAMLSerializer.sections(for: [
            makeProvider(type: .openaiCompatibility, headers: sampleHeaders),
            makeProvider(
                type: .geminiCompatibility,
                baseURL: "https://gemini.internal",
                headers: sampleHeaders
            ),
        ])
        let withSections = baseConfig
            + "\n\n# Custom Providers (managed by Quotio)\n"
            + sections

        let strippedOnce = FileCustomProviderConfigurationSynchronizer
            .removingManagedSections(from: withSections)
        let reappended = strippedOnce
            + "\n\n# Custom Providers (managed by Quotio)\n"
            + sections
        let strippedTwice = FileCustomProviderConfigurationSynchronizer
            .removingManagedSections(from: reappended)

        XCTAssertEqual(strippedOnce, baseConfig)
        XCTAssertEqual(strippedTwice, strippedOnce)
    }

    private var sampleHeaders: [CustomHeader] {
        [
            CustomHeader(key: "X-API-Key", value: "secret-token"),
            CustomHeader(key: "X-Tenant-ID", value: "team-a"),
        ]
    }

    private func makeProvider(
        type: CustomProviderType,
        baseURL: String = "https://llm.internal/v1",
        apiKeys: [CustomAPIKeyEntry] = [CustomAPIKeyEntry(apiKey: "key-one")],
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
}

private actor RecordingSession: CustomProviderHTTPSession {
    private let body: Data
    private let statusCode: Int
    private var recorded: URLRequest?
    init(body: String, statusCode: Int = 200) { self.body = Data(body.utf8); self.statusCode = statusCode }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorded = request
        return (body, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
    }
    func request() throws -> URLRequest { try XCTUnwrap(recorded) }
}

private enum YAMLHeaderBlockReader {
    struct ParseError: Error {
        let description: String
    }

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
                guard !entryLine.trimmingCharacters(in: .whitespaces).isEmpty,
                      entryIndent > blockIndent else {
                    break
                }
                entries.append(try parseEntry(entryLine))
                index += 1
            }
            result.append(entries)
        }
        return result
    }

    static func decodeDoubleQuotedScalar(_ scalar: String) throws -> String {
        let scalars = Array(scalar.unicodeScalars)
        var cursor = 0
        let decoded = try readDoubleQuotedScalar(scalars, &cursor)
        guard cursor == scalars.count else {
            throw ParseError(description: "trailing content after scalar")
        }
        return decoded
    }

    private static func parseEntry(_ line: String) throws -> (name: String, value: String) {
        let scalars = Array(line.unicodeScalars)
        var cursor = 0
        skipSpaces(in: scalars, cursor: &cursor)
        let name = try readDoubleQuotedScalar(scalars, &cursor)
        skipSpaces(in: scalars, cursor: &cursor)
        guard cursor < scalars.count, scalars[cursor] == ":" else {
            throw ParseError(description: "missing mapping separator")
        }
        cursor += 1
        skipSpaces(in: scalars, cursor: &cursor)
        let value = try readDoubleQuotedScalar(scalars, &cursor)
        skipSpaces(in: scalars, cursor: &cursor)
        guard cursor == scalars.count else {
            throw ParseError(description: "trailing mapping content")
        }
        return (name, value)
    }

    private static func skipSpaces(in scalars: [Unicode.Scalar], cursor: inout Int) {
        while cursor < scalars.count, scalars[cursor] == " " {
            cursor += 1
        }
    }

    private static func readDoubleQuotedScalar(
        _ scalars: [Unicode.Scalar],
        _ cursor: inout Int
    ) throws -> String {
        guard cursor < scalars.count, scalars[cursor] == "\"" else {
            throw ParseError(description: "expected double-quoted scalar")
        }
        cursor += 1
        var decoded = String.UnicodeScalarView()

        while cursor < scalars.count {
            let scalar = scalars[cursor]
            cursor += 1
            if scalar == "\"" { return String(decoded) }
            guard scalar == "\\" else {
                decoded.append(scalar)
                continue
            }
            guard cursor < scalars.count else {
                throw ParseError(description: "dangling escape")
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
            default: throw ParseError(description: "unsupported escape")
            }
        }
        throw ParseError(description: "unterminated scalar")
    }

    private static func readHexEscape(
        _ scalars: [Unicode.Scalar],
        _ cursor: inout Int,
        digits: Int
    ) throws -> Unicode.Scalar {
        guard cursor + digits <= scalars.count else {
            throw ParseError(description: "truncated hex escape")
        }
        let text = String(String.UnicodeScalarView(scalars[cursor..<(cursor + digits)]))
        cursor += digits
        guard let code = UInt32(text, radix: 16), let scalar = Unicode.Scalar(code) else {
            throw ParseError(description: "invalid hex escape")
        }
        return scalar
    }
}
