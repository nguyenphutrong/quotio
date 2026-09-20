import Foundation
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class ClaudeFableQuotaTests: XCTestCase {
  func testReadsFableWeeklyScopedLimitWithItsOwnPercentageAndReset() throws {
    let json: [String: Any] = [
      "limits": [
        ["kind": "weekly_scoped", "percent": 12.0, "scope": ["model": ["display_name": "Sonnet"]]],
        [
          "kind": "weekly_scoped", "percent": 67.0, "resets_at": "2026-09-14T00:00:00Z",
          "scope": ["model": ["display_name": "Fable"]],
        ],
      ]
    ]
    let metric = try XCTUnwrap(ClaudeQuotaFetcher.parseFableWeekly(from: json))
    XCTAssertEqual(metric.name, "seven-day-fable")
    XCTAssertEqual(metric.percentage, 33)
    XCTAssertEqual(metric.resetTime, "2026-09-14T00:00:00Z")
  }

  func testMissingFableDoesNotBorrowAnotherWeeklyLimit() {
    XCTAssertNil(
      ClaudeQuotaFetcher.parseFableWeekly(from: [
        "seven_day": ["utilization": 90], "seven_day_opus": ["utilization": 60],
        "limits": [
          ["kind": "weekly_scoped", "percent": 20, "scope": ["model": ["display_name": "Sonnet"]]]
        ],
      ]))
  }

  func testFableMetricLandsRightAfterTheWeeklyMetric() throws {
    let body = #"""
      {"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},
       "seven_day":{"utilization":70,"resets_at":null},
       "seven_day_opus":{"utilization":10,"resets_at":null},
       "limits":[{"kind":"weekly_scoped","percent":40,"resets_at":"2030-01-02T00:00:00Z",
                  "scope":{"model":{"display_name":"Fable"}}}]}
      """#
    let quota = try XCTUnwrap(ClaudeQuotaFetcher.mapUsage(Data(body.utf8)))
    XCTAssertEqual(
      quota.models.map(\.name),
      ["five-hour-session", "seven-day-weekly", "seven-day-fable", "seven-day-opus"])
    XCTAssertEqual(quota.models.map(\.percentage), [75, 30, 60, 90])
  }
}
