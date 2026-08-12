import XCTest
@testable import Quotio

final class CodexUsageMapperTests: XCTestCase {
    private func map(_ json: String) throws -> ProviderQuotaData {
        try CodexUsageMapper.map(data: Data(json.utf8))
    }

    /// Exact payload from issue #356: a Codex free account exposing only a
    /// weekly window in `primary_window` must produce a single Weekly bucket,
    /// not a Session bucket, and no fabricated second bucket.
    func testFreeAccountWeeklyOnlyPrimaryWindowMapsToSingleWeeklyBucket() throws {
        let quota = try map("""
        {
          "plan_type": "free",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 85,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 301573,
              "reset_at": 1773507681
            },
            "secondary_window": null
          }
        }
        """)

        XCTAssertEqual(quota.models.map(\.name), ["codex-weekly"])
        let weekly = try XCTUnwrap(quota.models.first)
        XCTAssertEqual(weekly.usedPercentage, 85)
        XCTAssertEqual(weekly.percentage, 15)
        XCTAssertEqual(weekly.displayName, "Weekly")
        XCTAssertFalse(quota.models.contains { $0.name == "codex-session" })
        XCTAssertEqual(quota.planType, "free")
        XCTAssertFalse(quota.isForbidden)
    }

    /// Paid accounts keep the existing labels: 5h primary window is Session,
    /// 7-day secondary window is Weekly.
    func testPaidAccountSessionPrimaryAndWeeklySecondaryKeepLabels() throws {
        let quota = try map("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 40,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600,
              "reset_at": 1773507681
            },
            "secondary_window": {
              "used_percent": 12,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 301573,
              "reset_at": 1773807681
            }
          }
        }
        """)

        XCTAssertEqual(quota.models.map(\.name), ["codex-session", "codex-weekly"])
        XCTAssertEqual(quota.models[0].usedPercentage, 40)
        XCTAssertEqual(quota.models[1].usedPercentage, 12)
        XCTAssertEqual(quota.models[0].displayName, "Session")
        XCTAssertEqual(quota.models[1].displayName, "Weekly")
    }

    /// A null secondary window with a genuine 5h primary window yields only a
    /// Session bucket.
    func testSessionOnlyPrimaryWindowWithNullSecondaryYieldsSingleSessionBucket() throws {
        let quota = try map("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 25,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600,
              "reset_at": 1773507681
            },
            "secondary_window": null
          }
        }
        """)

        XCTAssertEqual(quota.models.map(\.name), ["codex-session"])
        XCTAssertEqual(quota.models[0].usedPercentage, 25)
    }

    /// When `limit_window_seconds` is missing, a multi-day `reset_after_seconds`
    /// still identifies a weekly window: a 5h session window can never reset
    /// days in the future.
    func testMissingWindowSecondsClassifiesByResetHorizon() throws {
        let quota = try map("""
        {
          "plan_type": "free",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 85,
              "reset_after_seconds": 301573,
              "reset_at": 1773507681
            },
            "secondary_window": null
          }
        }
        """)

        XCTAssertEqual(quota.models.map(\.name), ["codex-weekly"])
    }

    /// Without any duration signal the mapper keeps the positional fallback so
    /// existing paid-account responses are unaffected.
    func testMissingDurationSignalsFallBackToPositionalLabels() throws {
        let quota = try map("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 40,
              "reset_after_seconds": 3600,
              "reset_at": 1773507681
            },
            "secondary_window": {
              "used_percent": 12,
              "reset_at": 1773807681
            }
          }
        }
        """)

        XCTAssertEqual(quota.models.map(\.name), ["codex-session", "codex-weekly"])
    }

    /// A ~30-day window is labeled Monthly instead of being folded into Weekly.
    func testMonthlyWindowIsClassifiedAsMonthly() throws {
        let quota = try map("""
        {
          "plan_type": "free",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 60,
              "limit_window_seconds": 2592000,
              "reset_at": 1773507681
            },
            "secondary_window": null
          }
        }
        """)

        XCTAssertEqual(quota.models.map(\.name), ["codex-monthly"])
        XCTAssertEqual(quota.models[0].displayName, "Monthly")
    }

    /// Two windows resolving to the same kind are deduplicated instead of
    /// rendering a duplicate bucket.
    func testDuplicateWindowKindsAreDeduplicated() throws {
        let quota = try map("""
        {
          "plan_type": "free",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 85,
              "limit_window_seconds": 604800,
              "reset_at": 1773507681
            },
            "secondary_window": {
              "used_percent": 20,
              "limit_window_seconds": 604800,
              "reset_at": 1773807681
            }
          }
        }
        """)

        XCTAssertEqual(quota.models.map(\.name), ["codex-weekly"])
        XCTAssertEqual(quota.models[0].usedPercentage, 85)
    }
}
