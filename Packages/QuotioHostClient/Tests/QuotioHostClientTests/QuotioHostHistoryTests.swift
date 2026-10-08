import Foundation
import XCTest
@testable import QuotioHostClient

final class QuotioHostHistoryTests: XCTestCase {
    private func observation(_ state: String = "available", remaining: Double? = 80) -> [String: Any] {
        var quota: [String: Any] = ["state": state]
        if let remaining { quota["remaining_percent"] = remaining; quota["used_percent"] = 100 - remaining }
        return ["series_id": "series", "basis_id": "basis", "fetched_at": "2026-10-05T00:01:00Z",
                "quota": quota, "provenance": ["source": "provider", "confidence": "estimated"]]
    }
    private func chart() -> [String: Any] {
        ["schema_version": 2, "host_id": "host", "account_id": "account", "metric_id": "session", "history_revision": 1,
         "range": "24h", "start_at": "2026-10-05T00:00:00Z", "end_at": "2026-10-06T00:00:00Z", "bin_seconds": 240,
         "recording_enabled": true, "bins": [["id": 0, "start_at": "2026-10-05T00:00:00Z", "end_at": "2026-10-05T00:04:00Z",
             "first_observed_at": "2026-10-05T00:01:00Z", "last_observed_at": "2026-10-05T00:01:00Z", "sample_count": 1,
             "latest": observation(), "min_remaining_percent": 80, "max_remaining_percent": 80, "states": ["available"]]],
         "events": [], "latest": observation(), "lowest_remaining_percent": 80]
    }
    private func decode(_ json: [String: Any]) throws -> QuotioHostHistoryChart {
        let value = try makeQuotioHostDecoder().decode(QuotioHostHistoryChart.self, from: JSONSerialization.data(withJSONObject: json))
        try value.validate()
        return value
    }
    func testKnownZeroAndHundredAreObservationsNotEmptyBins() throws {
        for percent in [0.0, 100.0] {
            var json = chart()
            var bins = json["bins"] as! [[String: Any]]
            bins[0]["latest"] = observation(percent == 0 ? "exhausted" : "available", remaining: percent)
            bins[0]["min_remaining_percent"] = percent; bins[0]["max_remaining_percent"] = percent
            bins[0]["states"] = [percent == 0 ? "exhausted" : "available"]
            json["bins"] = bins; json["latest"] = bins[0]["latest"]; json["lowest_remaining_percent"] = percent
            let value = try decode(json)
            XCTAssertEqual(value.bins.count, 1)
            XCTAssertEqual(value.bins[0].latest.quota.remainingPercent, percent)
        }
    }
    func testNonnumericStatesRetainNilPercentAndEmptyBinsRemainEmpty() throws {
        for state in ["unknown", "unlimited", "disabled", "limit"] {
            var json = chart()
            var value = observation(state, remaining: nil)
            if state == "limit" { value["quota"] = ["state": "limit", "amount": 10, "unit": "credits"] }
            json["bins"] = []; json["latest"] = value; json.removeValue(forKey: "lowest_remaining_percent")
            let decoded = try decode(json)
            XCTAssertTrue(decoded.bins.isEmpty)
            XCTAssertNil(decoded.latest?.quota.remainingPercent)
            XCTAssertEqual(decoded.latest?.provenance.confidence, "estimated")
        }
    }
    func testMalformedPercentQuotaAndBinRelationshipsAreRejected() throws {
        for remaining in [-1.0, 101.0] {
            var json = chart(); json["latest"] = observation(remaining: remaining)
            XCTAssertThrowsError(try decode(json))
        }
        var missing = chart(); missing["latest"] = observation(remaining: nil)
        XCTAssertThrowsError(try decode(missing))
        var bins = chart()["bins"] as! [[String: Any]]
        bins[0]["last_observed_at"] = "2026-10-05T00:05:00Z"
        var outside = chart(); outside["bins"] = bins
        XCTAssertThrowsError(try decode(outside))
        var duplicate = chart(); duplicate["bins"] = [chart()["bins"] as! [[String: Any]]].flatMap { $0 + $0 }
        XCTAssertThrowsError(try decode(duplicate))
        var mixed = chart(); mixed["latest"] = observation("unknown", remaining: 0)
        XCTAssertThrowsError(try decode(mixed))
    }
    func testInvalidIdentifierAndUnsupportedRangeRejectBeforeRequest() async {
        let client = QuotioHostHTTPClient(connection: .init(baseURL: URL(string: "http://127.0.0.1:1")!, token: "synthetic"))
        do { _ = try await client.historyCatalog(accountID: "../other"); XCTFail("unsafe identifier") }
        catch { XCTAssertEqual(error as? QuotioHostClientError, .incompatible) }
        var json = chart(); json["range"] = "90d"
        XCTAssertThrowsError(try decode(json))
    }
    func testAllEventsRetainDistinctIdentityAndBoundaryKind() throws {
        var json = chart()
        json["events"] = ["reset_inferred", "quota_increased", "basis_changed", "clock_changed"].enumerated().map { index, kind in
            ["id": "event_\(index)", "kind": kind, "from_at": "2026-10-05T00:01:00Z", "to_at": "2026-10-05T00:02:00Z"]
        }
        XCTAssertEqual(try decode(json).events.count, 4)
        var duplicate = json["events"] as! [[String: Any]]; duplicate.append(duplicate[0]); json["events"] = duplicate
        XCTAssertThrowsError(try decode(json))
    }
}
