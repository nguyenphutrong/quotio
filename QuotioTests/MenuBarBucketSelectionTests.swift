import XCTest
@testable import Quotio

/// Covers the per-menu-bar-item quota bucket selector (issue #393) and the
/// provider shapes whose windows a name-substring matcher gets wrong.
final class MenuBarBucketSelectionTests: XCTestCase {

    // MARK: - Codex Spark regression

    /// Codex maps the Spark five-hour window to `codex-spark`. Its name contains
    /// none of `session`, `five-hour` or `5h`, so a name matcher would report the
    /// 80% plan session bucket and hide the 10% Spark bucket. The window is taken
    /// from the payload's `limit_window_seconds` instead.
    func testCodexSessionWindowIncludesSparkFiveHourBucket() throws {
        let quota = try CodexUsageMapper.map(data: Self.codexSparkPayload())
        let byName = Dictionary(uniqueKeysWithValues: quota.models.map { ($0.name, $0) })

        XCTAssertEqual(byName["codex-session"]?.percentage, 80)
        XCTAssertEqual(byName["codex-spark"]?.percentage, 10)
        XCTAssertEqual(byName["codex-spark"]?.window, .session)

        let value = MenuBarBucketResolver.percent(
            models: quota.models,
            selection: .window(.session),
            aggregation: .lowest
        )
        XCTAssertEqual(try XCTUnwrap(value), 10, accuracy: 0.001)
    }

    /// The same account can also pin one exact Codex bucket.
    func testCodexIndividualBucketsAreSelectable() throws {
        let quota = try CodexUsageMapper.map(data: Self.codexSparkPayload())

        XCTAssertEqual(
            MenuBarBucketResolver.percent(
                models: quota.models,
                selection: .bucket("codex-spark"),
                aggregation: .lowest
            ),
            10
        )
        XCTAssertEqual(
            MenuBarBucketResolver.percent(
                models: quota.models,
                selection: .bucket("codex-session"),
                aggregation: .lowest
            ),
            80
        )
    }

    // MARK: - Copilot monthly regression

    /// Copilot's monthly quotas are named `copilot-chat` / `copilot-completions`,
    /// which contain no monthly marker. The window comes from the entitlement
    /// payload (`monthly_quotas`, `quota_reset_date`).
    func testCopilotQuotasAreSelectableAsMonthly() throws {
        for payload in [Self.copilotSnapshotPayload(), Self.copilotLimitedUserPayload()] {
            let entitlement = try JSONDecoder().decode(CopilotEntitlement.self, from: payload)
            let quota = CopilotQuotaFetcher.convertToQuotaData(entitlement: entitlement)

            XCTAssertFalse(quota.models.isEmpty)
            XCTAssertTrue(quota.models.allSatisfy { $0.window == .monthly }, "\(quota.models.map(\.name))")

            let value = MenuBarBucketResolver.percent(
                models: quota.models,
                selection: .window(.monthly),
                aggregation: .lowest
            )
            XCTAssertNotNil(value)
        }
    }

    func testCopilotMonthlyWindowAggregatesWithSelectedMode() throws {
        let entitlement = try JSONDecoder().decode(CopilotEntitlement.self, from: Self.copilotSnapshotPayload())
        let quota = CopilotQuotaFetcher.convertToQuotaData(entitlement: entitlement)

        // chat 40% remaining, completions 90%, premium 60%.
        XCTAssertEqual(
            try XCTUnwrap(MenuBarBucketResolver.percent(models: quota.models, selection: .window(.monthly), aggregation: .lowest)),
            40,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(MenuBarBucketResolver.percent(models: quota.models, selection: .window(.monthly), aggregation: .average)),
            (40 + 90 + 60) / 3,
            accuracy: 0.001
        )
    }

    // MARK: - Specific buckets asked for by #393

    /// "users cannot choose Factory Standard vs Core five-hour quota".
    func testFactoryStandardAndCoreFiveHourPoolsAreSeparatelySelectable() throws {
        let response = try JSONDecoder().decode(FactoryDroidQuotaResponse.self, from: Self.factoryPayload())
        let quota = FactoryDroidQuotaMapper.map(response, now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(
            MenuBarBucketResolver.percent(
                models: quota.models,
                selection: .bucket("factory-standard-five-hour"),
                aggregation: .lowest
            ),
            75
        )
        XCTAssertEqual(
            MenuBarBucketResolver.percent(
                models: quota.models,
                selection: .bucket("factory-core-five-hour"),
                aggregation: .lowest
            ),
            30
        )
        // The session window still aggregates both pools.
        XCTAssertEqual(
            MenuBarBucketResolver.percent(
                models: quota.models,
                selection: .window(.session),
                aggregation: .lowest
            ),
            30
        )
    }

    /// "Antigravity Gemini vs Claude/GPT session quota".
    func testAntigravityGroupSessionPoolsAreSeparatelySelectable() {
        let models = [
            ModelQuota(name: "antigravity-gemini-session", percentage: 60, resetTime: "", window: .session, billing: .subscription),
            ModelQuota(name: "antigravity-claude-gpt-session", percentage: 20, resetTime: "", window: .session, billing: .subscription),
            ModelQuota(name: "antigravity-gemini-weekly", percentage: 70, resetTime: "", window: .weekly, billing: .subscription)
        ]

        XCTAssertEqual(
            MenuBarBucketResolver.percent(models: models, selection: .bucket("antigravity-gemini-session"), aggregation: .lowest),
            60
        )
        XCTAssertEqual(
            MenuBarBucketResolver.percent(models: models, selection: .bucket("antigravity-claude-gpt-session"), aggregation: .lowest),
            20
        )
    }

    /// "or an extra/on-demand quota".
    func testPaidOverageBucketIsSelectable() {
        let models = [
            ModelQuota(name: "plan-usage", percentage: 15, resetTime: "", billing: .subscription),
            ModelQuota(name: "on-demand", percentage: 90, resetTime: "", billing: .paidOverage)
        ]

        XCTAssertEqual(
            MenuBarBucketResolver.percent(models: models, selection: .bucket("on-demand"), aggregation: .lowest),
            90
        )
    }

    // MARK: - Option list

    func testOptionsOfferAutoDeclaredWindowsAndEveryPercentageBucket() throws {
        let quota = try CodexUsageMapper.map(data: Self.codexSparkPayload())

        XCTAssertEqual(
            MenuBarBucketResolver.options(for: quota.models),
            [
                .auto,
                .window(.session),
                .window(.weekly),
                .bucket("codex-session"),
                .bucket("codex-weekly"),
                .bucket("codex-spark"),
                .bucket("codex-spark-weekly")
            ]
        )
    }

    /// Status and balance rows carry the `-1` unknown sentinel and cannot be
    /// rendered as a menu bar percentage, so they are not offered.
    func testOptionsOmitBucketsWithoutAPercentage() throws {
        let quota = try XCTUnwrap(GrokQuotaMapper.mapBilling(Self.grokPayload(), plan: nil))

        XCTAssertEqual(
            MenuBarBucketResolver.options(for: quota.models),
            [.auto, .window(.weekly), .bucket("grok-weekly")]
        )
    }

    // MARK: - Fallback behaviour

    func testSelectionUnavailableForAnAccountFallsBackToTheAggregate() {
        // Claude Code exposes no monthly subscription window.
        let models = [
            ModelQuota(name: "five-hour-session", percentage: 80, resetTime: "", window: .session, billing: .subscription),
            ModelQuota(name: "seven-day-weekly", percentage: 40, resetTime: "", window: .weekly, billing: .subscription)
        ]

        XCTAssertNil(MenuBarBucketResolver.percent(models: models, selection: .window(.monthly), aggregation: .lowest))
        XCTAssertNil(MenuBarBucketResolver.percent(models: models, selection: .bucket("codex-session"), aggregation: .lowest))
        XCTAssertNil(MenuBarBucketResolver.percent(models: models, selection: .auto, aggregation: .lowest))
    }

    func testSelectionWithOnlyUnknownValuesFallsBack() {
        let models = [
            ModelQuota(name: "five-hour-session", percentage: -1, resetTime: "", window: .session, billing: .subscription),
            ModelQuota(name: "seven-day-weekly", percentage: 40, resetTime: "", window: .weekly, billing: .subscription)
        ]

        XCTAssertNil(MenuBarBucketResolver.percent(models: models, selection: .window(.session), aggregation: .lowest))
        XCTAssertNil(MenuBarBucketResolver.percent(models: models, selection: .bucket("five-hour-session"), aggregation: .lowest))
    }

    func testAvailabilityCheckMatchesTheResolver() {
        let models = [
            ModelQuota(name: "codex-spark", percentage: 10, resetTime: "", window: .session, billing: .subscription)
        ]

        XCTAssertTrue(MenuBarBucketResolver.isAvailable(.auto, in: models))
        XCTAssertTrue(MenuBarBucketResolver.isAvailable(.window(.session), in: models))
        XCTAssertTrue(MenuBarBucketResolver.isAvailable(.bucket("codex-spark"), in: models))
        XCTAssertFalse(MenuBarBucketResolver.isAvailable(.window(.monthly), in: models))
        XCTAssertFalse(MenuBarBucketResolver.isAvailable(.bucket("codex-session"), in: models))
    }

    // MARK: - Persistence

    @MainActor
    func testSelectionRoundTripsThroughTheStoredMenuBarItem() throws {
        let items = [
            MenuBarQuotaItem(provider: "codex", accountKey: "a@example.com", bucketSelection: .bucket("codex-spark")),
            MenuBarQuotaItem(provider: "claude", accountKey: "b@example.com", bucketSelection: .window(.weekly)),
            MenuBarQuotaItem(provider: "cursor", accountKey: "c@example.com")
        ]

        let decoded = try JSONDecoder().decode(
            [MenuBarQuotaItem].self,
            from: try JSONEncoder().encode(items)
        )

        XCTAssertEqual(decoded, items)
        XCTAssertEqual(decoded[0].resolvedBucketSelection, .bucket("codex-spark"))
        XCTAssertEqual(decoded[1].resolvedBucketSelection, .window(.weekly))
        XCTAssertEqual(decoded[2].resolvedBucketSelection, .auto)
    }

    /// Selections persisted before this feature existed must still decode.
    @MainActor
    func testMenuBarItemsStoredBeforeTheSelectorStillDecode() throws {
        let legacy = Data("""
        [{ "provider": "codex", "accountKey": "a@example.com" }]
        """.utf8)

        let decoded = try JSONDecoder().decode([MenuBarQuotaItem].self, from: legacy)
        XCTAssertEqual(decoded.first?.resolvedBucketSelection, .auto)
    }

    /// The bucket choice is an attribute of an item, not part of its identity, so
    /// adding the same account twice is still rejected.
    @MainActor
    func testIdentityIgnoresTheBucketSelection() {
        let plain = MenuBarQuotaItem(provider: "codex", accountKey: "a@example.com")
        let chosen = MenuBarQuotaItem(provider: "codex", accountKey: "a@example.com", bucketSelection: .window(.weekly))

        XCTAssertEqual(plain.id, chosen.id)
        XCTAssertNotEqual(plain, chosen, "the stored value must still differ so changes persist")
    }

    // MARK: - Fixtures

    private static func codexSparkPayload() -> Data {
        // Plan session 80% remaining, Spark five-hour 10% remaining.
        Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 20, "reset_at": 1800000000, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 45, "reset_at": 1800500000, "limit_window_seconds": 604800 }
          },
          "additional_rate_limits": [
            {
              "limit_name": "codex_spark",
              "metered_feature": "spark",
              "rate_limit": {
                "primary_window": { "used_percent": 90, "reset_at": 1800000000, "limit_window_seconds": 18000 },
                "secondary_window": { "used_percent": 30, "reset_at": 1800500000, "limit_window_seconds": 604800 }
              }
            }
          ]
        }
        """.utf8)
    }

    private static func copilotSnapshotPayload() -> Data {
        Data("""
        {
          "quota_reset_date": "2999-01-01",
          "quota_snapshots": {
            "chat": { "entitlement": 50, "remaining": 20, "unlimited": false },
            "completions": { "entitlement": 2000, "remaining": 1800, "unlimited": false },
            "premium_interactions": { "entitlement": 50, "remaining": 30, "unlimited": false }
          }
        }
        """.utf8)
    }

    private static func copilotLimitedUserPayload() -> Data {
        Data("""
        {
          "quota_reset_date": "2999-01-01",
          "limited_user_quotas": { "chat": 25, "completions": 1000 },
          "monthly_quotas": { "chat": 50, "completions": 2000 }
        }
        """.utf8)
    }

    private static func factoryPayload() -> Data {
        Data("""
        {
          "usesTokenRateLimitsBilling": true,
          "limits": {
            "standard": { "fiveHour": { "usedPercent": 25, "windowEnd": "2999-01-01T00:00:00Z" } },
            "core": { "fiveHour": { "usedPercent": 70, "windowEnd": "2999-01-01T00:00:00Z" } }
          }
        }
        """.utf8)
    }

    private static func grokPayload() -> Data {
        Data("""
        {
          "config": {
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2999-01-08T00:00:00Z" },
            "creditUsagePercent": 55,
            "onDemandCap": { "val": 0 }
          }
        }
        """.utf8)
    }
}
