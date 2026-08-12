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
