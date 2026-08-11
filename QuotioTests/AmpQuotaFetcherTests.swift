import XCTest
@testable import Quotio

final class AmpQuotaFetcherTests: XCTestCase {
    func testRequestContainsOnlyExplicitBearerJSONAndNoCookies() throws {
        let request = AmpQuotaFetcher.request(apiKey: "synthetic-token")
        XCTAssertEqual(request.url?.absoluteString, "https://ampcode.com/api/internal?userDisplayBalanceInfo")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["method"] as? String, "userDisplayBalanceInfo")
        XCTAssertEqual((body["params"] as? [String: Any])?.count, 0)

        let configuration = AmpQuotaFetcher.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testRedirectDelegateRejectsEveryRedirect() throws {
        let delegate = AmpNoRedirectDelegate()
        let source = try XCTUnwrap(URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo"))
        let destination = try XCTUnwrap(URL(string: "https://example.com/login"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": destination.absoluteString]
        ))
        var redirectedRequest: URLRequest? = URLRequest(url: destination)

        delegate.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: source),
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination)
        ) { redirectedRequest = $0 }

        XCTAssertNil(redirectedRequest)
    }

    func testNativeReaderAcceptsSlashVariantsOnly() throws {
        for key in ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try JSONSerialization.data(withJSONObject: [key: " test-key ", "other": "ignored"])
            try data.write(to: url)
            let credential = try XCTUnwrap(AmpNativeCredentialReader.load(path: url.path))
            XCTAssertEqual(credential.apiKey, "test-key")
            XCTAssertEqual(credential.sourcePath, url.path)
        }
    }

    func testParserMapsPercentagesBalancesIdentityAndStableWorkspaceIDs() throws {
        let text = """
        Signed in as person@example.com (Pro)
        Amp Free: 75% remaining today (resets daily)
        Subscription Megawatt: 40% agent usage and 60% orb usage remaining
        Individual credits: $12.50 remaining
        Workspace Acme: $8.25 remaining
        """
        let quota = try XCTUnwrap(AmpQuotaParser.parse(displayText: text))
        XCTAssertEqual(quota.accountDisplayName, "person@example.com")
        XCTAssertEqual(quota.planType, "Megawatt")
        XCTAssertEqual(quota.models.first(where: { $0.name == "amp-free" })?.percentage, 75)
        XCTAssertFalse(try XCTUnwrap(quota.models.first(where: { $0.name == "amp-free" })?.resetTime).isEmpty)
        XCTAssertEqual(quota.models.first(where: { $0.name == "amp-agent-usage" })?.percentage, 40)
        XCTAssertEqual(quota.models.first(where: { $0.name == "amp-orb-usage" })?.percentage, 60)
        let workspace = try XCTUnwrap(quota.models.first(where: { $0.name.hasPrefix("amp-workspace-") }))
        XCTAssertEqual(workspace.name, AmpQuotaParser.parse(displayText: "Workspace Acme: $1 remaining")?.models.first?.name)
        XCTAssertEqual(workspace.presentation, .amount(value: 8.25, unit: .usd, semantics: .balance))
    }

    func testParserMapsSubscriptionOtherUsageAndRenewalSuffix() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-11T12:00:00Z"))
        let quota = try XCTUnwrap(AmpQuotaParser.parse(
            displayText: "Subscription Megawatt: 64% other usage and 98% orb usage remaining - resets upon renewal in 22 days",
            now: now
        ))
        let agent = try XCTUnwrap(quota.models.first(where: { $0.name == "amp-agent-usage" }))
        let orb = try XCTUnwrap(quota.models.first(where: { $0.name == "amp-orb-usage" }))

        XCTAssertEqual(quota.planType, "Megawatt")
        XCTAssertEqual(agent.percentage, 64)
        XCTAssertEqual(agent.usedPercentage, 36)
        XCTAssertEqual(agent.displayName, "Agent Usage")
        XCTAssertEqual(agent.resetTime, "2026-09-02T12:00:00Z")
        XCTAssertEqual(orb.percentage, 98)
        XCTAssertEqual(orb.usedPercentage, 2)
        XCTAssertEqual(orb.displayName, "Orb Usage")
        XCTAssertEqual(orb.resetTime, "2026-09-02T12:00:00Z")
    }

    func testParserUsesIdentityPlanWhenSubscriptionIsMissing() throws {
        let quota = try XCTUnwrap(AmpQuotaParser.parse(displayText: """
        Signed in as person@example.com (Pro)
        Amp Free: 75% remaining today (resets daily)
        """))

        XCTAssertEqual(quota.accountDisplayName, "person@example.com")
        XCTAssertEqual(quota.planType, "Pro")
    }

    func testAPIMapperHandlesDollarFreeQuotaAndAuthenticationFailures() throws {
        let body = Data(#"{"ok":true,"result":{"displayText":"Amp Free: $5/$20 remaining (replenishes +$1/hour)"}}"#.utf8)
        let quota = try XCTUnwrap(AmpQuotaParser.map(data: body, statusCode: 200))
        XCTAssertEqual(quota.models.first?.percentage, 25)
        XCTAssertEqual(quota.models.first?.presentation, .progress(used: 15, limit: 20, unit: .usd))

        XCTAssertTrue(try XCTUnwrap(AmpQuotaParser.map(data: Data(), statusCode: 401)).isForbidden)
        let authRequired = Data(#"{"ok":false,"error":{"code":"auth-required","message":"Sign in"}}"#.utf8)
        XCTAssertTrue(try XCTUnwrap(AmpQuotaParser.map(data: authRequired, statusCode: 200)).isForbidden)
    }
}
