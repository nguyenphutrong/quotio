import XCTest
@testable import Quotio

/// Covers the fetcher-declared bucket kinds and the total-usage math that reads them.
///
/// Every fixture below is a provider payload run through the real mapper, so the
/// classification under test is the one the app actually produces at runtime.
/// Nothing here mutates `MenuBarSettingsManager.shared`: the calculation is a pure
/// function that takes the two display modes as arguments.
final class QuotaBucketKindTests: XCTestCase {

    // MARK: - Codex: additional_rate_limits carry no billing signal

    /// `CodexUsageMapper.extraModels` names `additional_rate_limits` entries
    /// `codex-<metered_feature/limit_name slug>`. That slug is provider text, so it
    /// cannot decide billing: the same collection holds model-specific *subscription*
    /// limits. This payload contains one whose slug ends in `on-demand`, which a
    /// suffix rule would misread as paid overage and drop from session totals.
    func testCodexAdditionalRateLimitsAreNeverClassifiedAsPaidOverage() throws {
        let data = Self.codexUsagePayload()
        let quota = try CodexUsageMapper.map(data: data)

        let names = quota.models.map(\.name)
        XCTAssertEqual(
            names,
            ["codex-session", "codex-weekly", "codex-spark", "codex-spark-weekly", "codex-code-review-on-demand"]
        )

        for model in quota.models {
            XCTAssertNotEqual(
                model.billing,
                .paidOverage,
                "\(model.name) is a rate limit, not paid overage"
            )
        }

        let dynamicLimit = try XCTUnwrap(quota.models.first { $0.name == "codex-code-review-on-demand" })
        XCTAssertNil(dynamicLimit.billing, "an additional rate limit states no billing kind")
    }

    /// The subscription bucket above must keep counting toward `.sessionOnly` totals.
    func testSessionOnlyTotalKeepsCodexAdditionalRateLimits() throws {
        let quota = try CodexUsageMapper.map(data: Self.codexUsagePayload())

        let total = QuotaUsageCalculator.totalUsagePercent(
            models: quota.models,
            totalMode: .sessionOnly,
            aggregation: .lowest
        )

        // codex-code-review-on-demand is the lowest bucket at 5% remaining.
        XCTAssertEqual(total, 5, accuracy: 0.001)
    }

    /// Codex maps the Spark five-hour window to `codex-spark`, whose name contains
    /// none of `session`, `five-hour` or `5h`. The window must come from the payload's
    /// `limit_window_seconds`, not from the name.
    func testCodexDeclaresWindowsFromThePayloadNotTheName() throws {
        let quota = try CodexUsageMapper.map(data: Self.codexUsagePayload())
        let windows = Dictionary(uniqueKeysWithValues: quota.models.map { ($0.name, $0.window) })

        XCTAssertEqual(windows["codex-session"], .session)
        XCTAssertEqual(windows["codex-weekly"], .weekly)
        XCTAssertEqual(windows["codex-spark"], .session)
        XCTAssertEqual(windows["codex-spark-weekly"], .weekly)
        XCTAssertEqual(windows["codex-code-review-on-demand"], .session)
    }

    /// Codex paid credits are an analytics row (`CodexUsageMapper.analytics`), not a
    /// `ModelQuota`, so no Codex bucket may be treated as paid overage.
    func testCodexPaidCreditsRemainAnAnalyticsRow() throws {
        let quota = try CodexUsageMapper.map(data: Self.codexUsagePayload())

        XCTAssertTrue(quota.models.allSatisfy { $0.billing != .paidOverage })
        XCTAssertEqual(
            quota.analytics?.rows.first(where: { $0.id == "codex-extra-usage" })?.title,
            "Extra Usage"
        )
    }

    // MARK: - Providers that really do emit a paid bucket

    func testFactoryDeclaresPoolWindowsAndPaidBalance() throws {
        let response = try JSONDecoder().decode(
            FactoryDroidQuotaResponse.self,
            from: Self.factoryQuotaPayload()
        )
        let quota = FactoryDroidQuotaMapper.map(response, now: Date(timeIntervalSince1970: 0))
        let byName = Dictionary(uniqueKeysWithValues: quota.models.map { ($0.name, $0) })

        XCTAssertEqual(byName["factory-standard-five-hour"]?.window, .session)
        XCTAssertEqual(byName["factory-standard-weekly"]?.window, .weekly)
        XCTAssertEqual(byName["factory-core-monthly"]?.window, .monthly)
        XCTAssertEqual(byName["factory-standard-five-hour"]?.billing, .subscription)

        let balance = try XCTUnwrap(byName["factory-extra-balance"])
        XCTAssertEqual(balance.billing, .paidOverage)
        XCTAssertNil(balance.window, "a prepaid balance refills on no schedule")
    }

    func testGrokDeclaresWeeklyWindowAndOnDemandCap() throws {
        let quota = try XCTUnwrap(GrokQuotaMapper.mapBilling(Self.grokBillingPayload(), plan: "SuperGrok"))
        let byName = Dictionary(uniqueKeysWithValues: quota.models.map { ($0.name, $0) })

        // Guarded on config.currentPeriod.type == USAGE_PERIOD_TYPE_WEEKLY.
        XCTAssertEqual(byName["grok-weekly"]?.window, .weekly)
        XCTAssertEqual(byName["grok-weekly"]?.billing, .subscription)
        XCTAssertEqual(byName["grok-extra-usage"]?.billing, .paidOverage)
    }

    // MARK: - Total usage math

    func testSessionOnlyTotalExcludesDeclaredPaidOverage() {
        let models = [
            ModelQuota(name: "five-hour-session", percentage: 55, resetTime: "", window: .session, billing: .subscription),
            ModelQuota(name: "seven-day-weekly", percentage: 70, resetTime: "", window: .weekly, billing: .subscription),
            ModelQuota(name: "extra-usage", percentage: 0, resetTime: "", window: .monthly, billing: .paidOverage)
        ]

        let total = QuotaUsageCalculator.totalUsagePercent(
            models: models,
            totalMode: .sessionOnly,
            aggregation: .lowest
        )
        XCTAssertEqual(total, 55, accuracy: 0.001)
    }

    /// A bucket with no declared billing kind is *not* paid overage, so it must stay
    /// in the subscription group rather than silently vanishing from the total.
    func testSessionOnlyTotalKeepsUnclassifiedBuckets() {
        let models = [
            ModelQuota(name: "codex-session", percentage: 42, resetTime: "", window: .session, billing: .subscription),
            ModelQuota(name: "codex-some-overage", percentage: 12, resetTime: "")
        ]

        let total = QuotaUsageCalculator.totalUsagePercent(
            models: models,
            totalMode: .sessionOnly,
            aggregation: .lowest
        )
        XCTAssertEqual(total, 12, accuracy: 0.001)
    }

    func testCombinedTotalCountsPaidOverage() {
        let models = [
            ModelQuota(name: "plan-usage", percentage: 10, resetTime: "", billing: .subscription),
            ModelQuota(name: "on-demand", percentage: 80, resetTime: "", billing: .paidOverage)
        ]

        let total = QuotaUsageCalculator.totalUsagePercent(
            models: models,
            totalMode: .combined,
            aggregation: .lowest
        )
        XCTAssertEqual(total, 80, accuracy: 0.001)
    }

    func testSessionOnlyFallsBackToPaidOverageWhenNoSubscriptionValueIsKnown() {
        let models = [
            ModelQuota(name: "on-demand", percentage: 25, resetTime: "", billing: .paidOverage)
        ]

        let total = QuotaUsageCalculator.totalUsagePercent(
            models: models,
            totalMode: .sessionOnly,
            aggregation: .lowest
        )
        XCTAssertEqual(total, 25, accuracy: 0.001)
    }

    func testUnknownPercentagesAreIgnoredByAggregation() {
        // Status/balance rows use -1 as the "unknown" sentinel.
        let models = [
            ModelQuota(name: "grok-weekly", percentage: 30, resetTime: "", window: .weekly, billing: .subscription),
            ModelQuota(name: "grok-extra-usage", percentage: -1, resetTime: "", billing: .paidOverage)
        ]

        XCTAssertEqual(
            QuotaUsageCalculator.totalUsagePercent(models: models, totalMode: .combined, aggregation: .lowest),
            30,
            accuracy: 0.001
        )
    }

    // MARK: - Persistence compatibility

    /// `ProviderQuotaData` is cached to disk. Data written before the bucket kinds
    /// existed must still decode, with both kinds left unknown.
    func testQuotaDataCachedBeforeBucketKindsStillDecodes() throws {
        let legacy = Data("""
        {
          "models": [
            { "name": "codex-session", "percentage": 40, "resetTime": "" }
          ],
          "lastUpdated": 0,
          "isForbidden": false
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ProviderQuotaData.self, from: legacy)
        let model = try XCTUnwrap(decoded.models.first)
        XCTAssertNil(model.window)
        XCTAssertNil(model.billing)
    }

    // MARK: - Fixtures

    /// Shaped after `GET /backend-api/wham/usage`: a plan rate limit plus
    /// `additional_rate_limits` holding the Spark windows and one other
    /// model-specific limit.
    private static func codexUsagePayload() -> Data {
        Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "limit_reached": false,
            "primary_window": { "used_percent": 20, "reset_at": 1800000000, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 35, "reset_at": 1800500000, "limit_window_seconds": 604800 }
          },
          "additional_rate_limits": [
            {
              "limit_name": "codex_spark",
              "metered_feature": "spark",
              "rate_limit": {
                "primary_window": { "used_percent": 90, "reset_at": 1800000000, "limit_window_seconds": 18000 },
                "secondary_window": { "used_percent": 50, "reset_at": 1800500000, "limit_window_seconds": 604800 }
              }
            },
            {
              "limit_name": "code_review_on_demand",
              "metered_feature": "code review on-demand",
              "rate_limit": {
                "primary_window": { "used_percent": 95, "reset_at": 1800000000, "limit_window_seconds": 18000 }
              }
            }
          ],
          "credits": { "balance": 12.5 }
        }
        """.utf8)
    }

    private static func factoryQuotaPayload() -> Data {
        Data("""
        {
          "usesTokenRateLimitsBilling": true,
          "limits": {
            "standard": {
              "fiveHour": { "usedPercent": 25, "windowEnd": "2999-01-01T00:00:00Z" },
              "weekly": { "usedPercent": 40, "windowEnd": "2999-01-02T00:00:00Z" }
            },
            "core": {
              "monthly": { "usedPercent": 10, "windowEnd": "2999-02-01T00:00:00Z" }
            }
          },
          "extraUsageBalanceCents": 750
        }
        """.utf8)
    }

    private static func grokBillingPayload() -> Data {
        Data("""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "end": "2999-01-08T00:00:00Z"
            },
            "creditUsagePercent": 60,
            "onDemandCap": { "val": 2500 }
          }
        }
        """.utf8)
    }
}
