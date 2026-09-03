import Foundation
import XCTest
@testable import QuotioDomain

final class CustomProviderModelsTests: XCTestCase {
    func testRawValuesDefaultsAndLegacyPayloadRemainCompatible() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let payload = """
        [{"id":"\(id.uuidString)","name":"Legacy GLM","type":"glm-api-key","base-url":"https://api.z.ai"}]
        """.data(using: .utf8)!
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let provider = try XCTUnwrap(try decoder.decode([CustomProvider].self, from: payload).first)

        XCTAssertEqual(provider.type, .glmCompatibility)
        XCTAssertEqual(provider.identity, "Legacy GLM")
        XCTAssertEqual(provider.apiKeys, [])
        XCTAssertEqual(provider.headers, [])
        XCTAssertTrue(provider.limitToSelectedModels)
        XCTAssertTrue(provider.isEnabled)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let roundTrip = try decoder.decode([CustomProvider].self, from: encoder.encode([provider]))
        XCTAssertEqual(roundTrip.first?.id, id)
        XCTAssertEqual(roundTrip.first?.type.rawValue, "glm-api-key")
    }

    func testHeadersAreCanonicalWireSafeAndValidatedCaseInsensitively() {
        let provider = CustomProvider(name: "Private", type: .openaiCompatibility, baseURL: "https://example.com/v1",
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "secret")], headers: [
                                        CustomHeader(key: " X-Tenant ", value: " team "),
                                        CustomHeader(key: "x-tenant", value: "other"),
                                        CustomHeader(key: "X-Injected", value: "one\r\ntwo")
                                      ])
        XCTAssertEqual(provider.effectiveHeaders.map(\.key), ["X-Tenant", "x-tenant"])
        XCTAssertTrue(provider.validationIssues().contains(.duplicateHeaderName))
        XCTAssertTrue(provider.validationIssues().contains(.invalidHeaderValue))
    }

    func testProviderTypesGateCustomHeaders() {
        XCTAssertTrue(CustomProviderType.openaiCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.claudeCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.geminiCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.codexCompatibility.supportsCustomHeaders)
        XCTAssertFalse(CustomProviderType.glmCompatibility.supportsCustomHeaders)
        XCTAssertFalse(CustomProviderType.clinePass.supportsCustomHeaders)
    }

    func testClinePassUsesNameIdentity() {
        let provider = CustomProvider(name: "ClinePass Team", type: .clinePass,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "secret")],
                                      models: [ModelMapping(name: "model", alias: "model")])

        XCTAssertEqual(provider.identity, "ClinePass Team")
    }

    func testEffectiveHeadersAreEmptyForUnsupportedProviderTypes() {
        for type in [CustomProviderType.glmCompatibility, .clinePass] {
            let provider = makeProvider(type: type, baseURL: "", headers: sampleHeaders)
            XCTAssertTrue(provider.effectiveHeaders.isEmpty, "\(type) must not send custom headers")
        }
    }

    func testCanonicalizedHeadersTrimOptionalWhitespaceAndDropUnnamedEntries() {
        let canonical = CustomHeader.canonicalized([
            CustomHeader(key: " X-Tenant-ID\t", value: "\t team-a "),
            CustomHeader(key: "   ", value: "ignored"),
            CustomHeader(key: "", value: "ignored"),
        ])

        XCTAssertEqual(canonical.map { [$0.key, $0.value] }, [["X-Tenant-ID", "team-a"]])
    }

    func testCanonicalizedHeaderDoesNotStripNewlinesFromValues() {
        let canonical = CustomHeader.canonicalized([
            CustomHeader(key: "X-Secret", value: " line1\nline2 "),
        ])

        XCTAssertEqual(canonical.first?.value, "line1\nline2")
        XCTAssertTrue(CustomHeader.validationIssues(in: canonical).contains(.invalidHeaderValue))
    }

    func testWhitespacePaddedHeaderNamesAreValidatedAfterNormalization() {
        let valid = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: " X-Tenant-ID ", value: " team-a ")]
        )
        XCTAssertTrue(valid.validationIssues().isEmpty)
        XCTAssertEqual(valid.effectiveHeaders.map { [$0.key, $0.value] }, [["X-Tenant-ID", "team-a"]])

        let duplicate = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "X-API-Key", value: "a"),
                CustomHeader(key: "  X-API-Key  ", value: "b"),
            ]
        )
        XCTAssertTrue(duplicate.validationIssues().contains(.duplicateHeaderName))
    }

    func testHeaderValueValidationAcceptsWireSafeASCIIAndRejectsInjection() {
        for value in ["", "secret-token", "a: b, c=d; e", "col-a\tcol-b"] {
            XCTAssertTrue(CustomHeader.isValidValue(value))
        }
        for value in [
            "line1\nline2",
            "line1\rline2",
            "a\r\nX-Injected: 1",
            "null\u{00}byte",
            "delete\u{7F}",
            "token\u{A0}",
            "b\u{00ed}-m\u{1ead}t",
        ] {
            XCTAssertFalse(CustomHeader.isValidValue(value))
        }
    }

    func testHeaderNameValidationAcceptsRFC7230TokensAndRejectsInvalidCharacters() {
        for name in ["X-API-Key", "X-Model-Version", "x_custom.header~1"] {
            XCTAssertTrue(CustomHeader.isValidName(name))
        }
        for name in ["", "X API Key", "X-API-Key:", "\u{041a}\u{043b}\u{044e}\u{0447}"] {
            XCTAssertFalse(CustomHeader.isValidName(name))
        }
    }

    func testProviderValidationRejectsInvalidHeaders() {
        let lineBreak = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "X-Secret", value: "line1\nline2")]
        )
        XCTAssertTrue(lineBreak.validationIssues().contains(.invalidHeaderValue))

        let injection = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(
                key: "X-Tenant-ID",
                value: "team-a\r\nAuthorization: Bearer stolen"
            )]
        )
        XCTAssertTrue(injection.validationIssues().contains(.invalidHeaderValue))

        let invalidName = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "Bad Name", value: "v")]
        )
        XCTAssertTrue(invalidName.validationIssues().contains(.invalidHeaderName))
    }

    func testHeadersSurviveCodableRoundTrip() throws {
        let provider = makeProvider(type: .claudeCompatibility, headers: sampleHeaders)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CustomProvider.self, from: encoder.encode(provider))

        XCTAssertEqual(decoded.headers, provider.headers)
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
        apiKeys: [CustomAPIKeyEntry] = [CustomAPIKeyEntry(apiKey: "test-key")],
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
