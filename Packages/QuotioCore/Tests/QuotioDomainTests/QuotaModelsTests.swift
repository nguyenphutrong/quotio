import Foundation
import XCTest
@testable import QuotioDomain

final class QuotaModelsTests: XCTestCase {
    func testLegacyQuotaMetricDecodesWithoutTypedPresentation() throws {
        let data = Data(
            #"{"name":"legacy","percentage":42,"resetTime":"","used":3,"limit":10}"#.utf8
        )

        let metric = try JSONDecoder().decode(QuotaMetric.self, from: data)

        XCTAssertNil(metric.presentation)
        XCTAssertEqual(metric.percentage, 42)
        XCTAssertEqual(metric.used, 3)
        XCTAssertEqual(metric.limit, 10)
    }

    func testMetricPresentationsRoundTripThroughCodableSchema() throws {
        let values: [QuotaMetricPresentation] = [
            .progress(used: 1.25, limit: 10.5, unit: .usd),
            .amount(value: 4.75, unit: .credits, semantics: .balance),
            .status(text: "Enabled"),
        ]

        for value in values {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(QuotaMetricPresentation.self, from: encoded), value)
        }
    }

    func testImportedIDEPolicyUpdatesOnlyExistingAccounts() {
        let old = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 10, resetTime: "")])
        let fresh = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 80, resetTime: "")])

        let result = QuotaPolicy.mergeImportedIDEQuotas(
            fetched: ["kept": fresh, "deleted": fresh],
            into: ["kept": old]
        )

        XCTAssertEqual(result, ["kept": fresh])
    }

    func testImportedIDEPolicyDoesNotImportWithoutConsent() {
        let fresh = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 80, resetTime: "")])

        XCTAssertTrue(QuotaPolicy.mergeImportedIDEQuotas(fetched: ["new": fresh], into: [:]).isEmpty)
    }

    func testImportedIDEPolicyKeepsAccountMissingFromFetch() {
        let existing = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 10, resetTime: "")])

        let result = QuotaPolicy.mergeImportedIDEQuotas(
            fetched: [:],
            into: ["kept": existing]
        )

        XCTAssertEqual(result, ["kept": existing])
    }

    func testCanonicalizedAccountsPromotesNewestAliasValue() {
        let stale = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 2_000))

        let result = QuotaPolicy.canonicalizedAccounts(
            ["github-copilot-user.json": fresh, "user": stale],
            aliases: ["github-copilot-user.json": "user"]
        )

        XCTAssertEqual(result, ["user": fresh])
    }

    func testLastUpdatedDoesNotBorrowSiblingTimestamp() {
        let sibling = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))
        let account = QuotaAccountID(provider: .claude, accountKey: "failed@example.com")

        let updated = QuotaPolicy.lastUpdated(
            for: account,
            in: [.claude: ["successful@example.com": sibling]]
        )

        XCTAssertNil(updated)
    }

    func testLowestAvailablePercentageIgnoresUnknownMetrics() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "unknown", percentage: -1, resetTime: ""),
            QuotaMetric(name: "monthly", percentage: 70, resetTime: ""),
            QuotaMetric(name: "weekly", percentage: 40, resetTime: ""),
        ])

        XCTAssertEqual(QuotaPolicy.lowestAvailablePercentage(in: quota), 40)
    }

    func testProviderTraitsKeepIDEImportAndRoutingRulesSeparate() {
        XCTAssertTrue(QuotaProvider.cursor.isImportedFromLocalIDE)
        XCTAssertTrue(QuotaProvider.trae.isImportedFromLocalIDE)
        XCTAssertFalse(QuotaProvider.cursor.supportsManualAuth)
        XCTAssertTrue(QuotaProvider.warp.isQuotaTrackingOnly)
        XCTAssertFalse(QuotaProvider.warp.supportsLocalProxySetup)
        XCTAssertTrue(QuotaProvider.codex.supportsLocalProxySetup)
        XCTAssertEqual(
            Set(QuotaProvider.allCases.filter(\.isImportedFromLocalIDE)),
            [.cursor, .trae]
        )
    }
}
