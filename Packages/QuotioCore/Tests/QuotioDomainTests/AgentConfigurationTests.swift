import XCTest
@testable import QuotioDomain

final class AgentConfigurationTests: XCTestCase {
    func testProxyConfigurationRequiresAbsoluteHTTPURLAndAPIKey() throws {
        var configuration = AgentConfiguration(
            agent: .ampCLI,
            proxyURL: "relative/path",
            apiKey: "key"
        )
        XCTAssertThrowsError(try configuration.validate()) {
            XCTAssertEqual($0 as? AgentConfigurationValidationError, .invalidProxyURL)
        }

        configuration.proxyURL = "http://127.0.0.1:8317/v1"
        configuration.apiKey = "  "
        XCTAssertThrowsError(try configuration.validate()) {
            XCTAssertEqual($0 as? AgentConfigurationValidationError, .missingAPIKey)
        }
    }

    func testRequiredModelSlotsDependOnAgentContract() throws {
        var claude = AgentConfiguration(
            agent: .claudeCode,
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "key"
        )
        claude.modelSlots[.opus] = ""
        XCTAssertThrowsError(try claude.validate()) {
            XCTAssertEqual($0 as? AgentConfigurationValidationError, .missingModel)
        }

        var codex = AgentConfiguration(
            agent: .codexCLI,
            proxyURL: "http://127.0.0.1:8317/v1",
            apiKey: "key"
        )
        codex.modelSlots[.opus] = ""
        XCTAssertNoThrow(try codex.validate())
        codex.modelSlots[.sonnet] = ""
        XCTAssertThrowsError(try codex.validate())
    }

    func testDefaultSetupDoesNotRequireProxyCredentials() {
        let configuration = AgentConfiguration(
            agent: .factoryDroid,
            proxyURL: "",
            apiKey: "",
            setupMode: .defaultSetup
        )
        XCTAssertNoThrow(try configuration.validate())
    }

}
