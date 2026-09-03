import Foundation
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class MonitorPresentationTests: XCTestCase {
    func testMonitorProvidersDoNotRequireInstalledCLI() {
        let providers: Set<QuotaProvider> = [
            .codex, .claude, .factoryDroid, .devin, .grok, .openRouter, .amp,
        ]

        let filtered = StatusBarMenuSnapshotMapper.filterProviders(
            providers,
            isMonitorMode: true,
            installedAgents: []
        )

        XCTAssertEqual(Set(filtered), providers)
    }

    func testAccountSourcesPreserveLocalizationKeys() {
        XCTAssertEqual(
            Set(AccountSource.allCases.map(\.localizationKey)),
            Set([
                "monitor.source.quotio",
                "monitor.source.localLogin",
                "monitor.source.cliProxyFile",
                "monitor.source.localIDE",
                "monitor.source.apiKey",
            ])
        )
    }

    func testGLMEditorPreservesExistingProviderConfiguration() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let firstKeyID = UUID()
        let secondKey = CustomAPIKeyEntry(
            apiKey: "second-key",
            proxyURL: "https://second.proxy"
        )
        let existing = CustomProvider(
            name: "Existing Z.ai",
            type: .glmCompatibility,
            baseURL: GLMEndpoint.bigmodel.baseURL,
            prefix: "existing-prefix",
            apiKeys: [
                CustomAPIKeyEntry(
                    id: firstKeyID,
                    apiKey: "first-key",
                    proxyURL: "https://first.proxy"
                ),
                secondKey,
            ],
            limitToSelectedModels: false,
            isEnabled: false,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let updated = GLMProviderEditor.updatedProvider(
            existing,
            apiKey: "rotated-key",
            endpoint: .zai,
            now: updatedAt
        )

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.name, "Existing Z.ai")
        XCTAssertEqual(updated.baseURL, GLMEndpoint.zai.baseURL)
        XCTAssertEqual(updated.prefix, "existing-prefix")
        XCTAssertEqual(updated.apiKeys.count, 2)
        XCTAssertEqual(updated.apiKeys[0].id, firstKeyID)
        XCTAssertEqual(updated.apiKeys[0].apiKey, "rotated-key")
        XCTAssertEqual(updated.apiKeys[0].proxyURL, "https://first.proxy")
        XCTAssertEqual(updated.apiKeys[1], secondKey)
        XCTAssertFalse(updated.limitToSelectedModels)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)
    }

    func testAutoDetectedRowsAllowDeleteOnlyForIDEProviders() {
        for provider in [QuotaProvider.cursor, .trae] {
            let row = AccountRowData.from(provider: provider, accountKey: "user@example.com")
            XCTAssertTrue(row.canDelete)
            XCTAssertEqual(row.source, .autoDetected)
        }
        for provider in [QuotaProvider.devin, .grok] {
            let row = AccountRowData.from(provider: provider, accountKey: "user@example.com")
            XCTAssertFalse(row.canDelete)
        }
    }
}
