import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class CustomProviderServiceTests: XCTestCase {
    func testSavePreservesCreatedDateAndUsesCaseInsensitiveNameUniqueness() throws {
        let created = Date(timeIntervalSince1970: 10)
        let existing = CustomProvider(name: "GLM Team", type: .glmCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "key")], createdAt: created, updatedAt: created)
        let repository = MemoryCustomProviderRepository([existing])
        let service = CustomProviderService(repository: repository, discovery: StubRemote(), connectionTester: StubRemote())
        var edited = existing; edited.name = "GLM Renamed"
        try service.save(edited, now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(try repository.load().first?.createdAt, created)

        let duplicate = CustomProvider(name: "glm renamed", type: .glmCompatibility, apiKeys: [CustomAPIKeyEntry(apiKey: "key")])
        XCTAssertThrowsError(try service.save(duplicate)) { XCTAssertEqual($0 as? CustomProviderServiceError, .duplicateName) }
    }

    func testEndpointPolicyNormalizesOpenAIAndCodexBaseURLs() {
        XCTAssertEqual(
            CustomProviderEndpointPolicy.normalizedBaseURL(
                " https://llm.example/api ",
                for: .openaiCompatibility
            ),
            "https://llm.example/api/v1"
        )
        XCTAssertEqual(
            CustomProviderEndpointPolicy.normalizedBaseURL(
                "https://llm.example/v2beta",
                for: .codexCompatibility
            ),
            "https://llm.example/v2beta"
        )
        XCTAssertEqual(
            CustomProviderEndpointPolicy.normalizedBaseURL(
                " https://api.anthropic.com ",
                for: .claudeCompatibility
            ),
            "https://api.anthropic.com"
        )
    }
}

private final class MemoryCustomProviderRepository: CustomProviderRepository, @unchecked Sendable {
    private var values: [CustomProvider]
    init(_ values: [CustomProvider]) { self.values = values }
    func load() throws -> [CustomProvider] { values }
    func save(_ providers: [CustomProvider]) throws { values = providers }
}
private struct StubRemote: CustomProviderModelDiscovering, CustomProviderConnectionTesting {
    func discoverModels(for provider: CustomProvider) async throws -> [DiscoveredModel] { [] }
    func testConnection(to provider: CustomProvider) async throws {}
}
