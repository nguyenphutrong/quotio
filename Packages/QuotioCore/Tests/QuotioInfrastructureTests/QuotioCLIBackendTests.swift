import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class QuotioCLIBackendTests: XCTestCase {
    override func tearDown() {
        QuotioCLIURLProtocol.reset()
        super.tearDown()
    }

    func testUsageReportMapsCanonicalProviderAndRemainingPercentage() throws {
        let data = Data(#"""
        {
          "schema_version": 1,
          "generated_at": "2026-09-16T12:00:00Z",
          "providers": [{
            "provider": "factory",
            "account_ref": {"origin":"owned","id":"account-1","label":"Work"},
            "account": {"id":"user-1","label":"Work","plan":"pro"},
            "windows": [{
              "label":"Weekly","metric_id":"weekly","quota":{"state":"available","used_percent":25,"remaining_percent":75},
              "resets_at":null,"provenance":{"source":"test","confidence":"exact"},
              "fetched_at":"2026-09-16T12:00:00Z"
            }]
          }],
          "failures": []
        }
        """#.utf8)

        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)
        let snapshot = QuotioCLIUsageMapper.snapshot(report)

        XCTAssertEqual(snapshot.quotas[.factoryDroid]?["Work"]?.models.first?.percentage, 75)
        XCTAssertEqual(snapshot.accountAliases[.factoryDroid]?["account-1"], "Work")
        XCTAssertEqual(snapshot.accountIDs[.factoryDroid]?["Work"], "account-1")
    }

    func testUsageReportUsesReferenceLabelsAndKeepsCollidingProviderLabelsDistinct() throws {
        let data = Data(#"""
        {
          "schema_version":1,"generated_at":"2026-09-16T12:00:00Z","failures":[],
          "providers":[
            {"provider":"openrouter","account_ref":{"origin":"owned","id":"account-1","label":"Work"},"account":{"id":"api-key","label":"API Key","plan":null},"windows":[]},
            {"provider":"openrouter","account_ref":{"origin":"owned","id":"account-2","label":"Personal"},"account":{"id":"api-key","label":"API Key","plan":null},"windows":[]}
          ]
        }
        """#.utf8)

        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)
        let snapshot = QuotioCLIUsageMapper.snapshot(report)

        XCTAssertEqual(Set(snapshot.quotas[.openRouter]?.keys.map(\.self) ?? []), ["Work", "Personal"])
        XCTAssertEqual(snapshot.quotas[.openRouter]?["Work"]?.accountDisplayName, "Work")
        XCTAssertEqual(snapshot.quotas[.openRouter]?["Personal"]?.accountDisplayName, "Personal")
        XCTAssertEqual(snapshot.accountIDs[.openRouter]?["Work"], "account-1")
        XCTAssertEqual(snapshot.accountIDs[.openRouter]?["Personal"], "account-2")
    }

    func testUsageReportMapsCodexAnalyticsAndResetCredits() throws {
        let data = Data(#"""
        {
          "schema_version":1,"generated_at":"2026-09-16T12:00:00Z","failures":[],
          "providers":[{
            "provider":"codex","account":{"id":"user-1","label":"Codex User","plan":"plus"},"windows":[],
            "codex_profile":{
              "daily_usage":[{"date":"2026-09-15","tokens":1200}],
              "latest_30_buckets_tokens":1200,"lifetime_tokens":8000,"peak_daily_tokens":1200,
              "longest_running_turn_seconds":3661,"current_streak_days":1,"longest_streak_days":3,
              "fetched_at":"2026-09-16T11:00:00Z"
            },
            "codex_reset_credits":{
              "available_count":2,
              "credits":[{"id":"hashed-credit","expires_at":"2026-09-18T12:00:00Z"}],
              "fetched_at":"2026-09-16T11:30:00Z"
            }
          }]
        }
        """#.utf8)

        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)
        let quota = try XCTUnwrap(QuotioCLIUsageMapper.snapshot(report).quotas[.codex]?["Codex User"])

        XCTAssertEqual(quota.lastUpdated, ISO8601DateFormatter().date(from: "2026-09-16T11:00:00Z"))
        XCTAssertEqual(quota.analytics?.rows.first { $0.id == "codex-lifetime-tokens" }?.value, "8K tokens")
        XCTAssertEqual(quota.analytics?.rows.first { $0.id == "codex-rate-limit-resets" }?.value, "2 available")
        XCTAssertNotNil(quota.analytics?.rows.first { $0.id == "codex-rate-limit-reset-hashed-credit" })
    }

    func testAccountCreateUsesBearerAndIdempotencyHeaders() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        try await backend.saveAPIKey(
            providerID: AccountProviderID(rawValue: QuotaProvider.openRouter.rawValue),
            label: "Primary",
            apiKey: "secret",
            existingAccountID: nil
        )

        let request = try XCTUnwrap(QuotioCLIURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/accounts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testScopedRefreshUsesBorrowedAccountIDFromUsageSnapshot() async throws {
        let report = #"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"borrowed-1","label":"CLI User"},"account":{"id":"user-1","label":"CLI User","plan":null},"windows":[]}],"failures":[]}"#
        for accountKey in ["CLI User", "borrowed-1"] {
            QuotioCLIURLProtocol.reset()
            QuotioCLIURLProtocol.enqueue(report)
            QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
            QuotioCLIURLProtocol.enqueue(report)
            let backend = QuotioCLIBackend(session: stubSession())
            await backend.connect(QuotioCLIConnection(
                baseURL: URL(string: "http://127.0.0.1:43210")!,
                token: "private-token"
            ))

            _ = await backend.bootstrap(mode: .monitor)
            _ = await backend.refresh(QuotaFetchRequest(
                provider: .claude,
                scope: .account(accountKey),
                mode: .monitor,
                force: true
            ))

            let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/refresh"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["account_id"] as? String, "borrowed-1")
            XCTAssertEqual(json["include_owned"] as? Bool, true)
            XCTAssertFalse(QuotioCLIURLProtocol.requests().contains { $0.url?.path == "/v1/accounts" })
        }
    }

    func testLocalProxyModeExcludesOwnedUsageAndPreservesBorrowedAccountSource() async throws {
        let report = #"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned-1","label":"Managed"},"account":{"id":"managed","label":"Managed","plan":null},"windows":[]},{"provider":"claude","account_ref":{"origin":"borrowed_proxy","id":"borrowed-1","label":"CLI User"},"account":{"id":"user-1","label":"CLI User","plan":null},"windows":[]}],"failures":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned-1","label":"Managed"},"code":"authentication"}]}"#
        QuotioCLIURLProtocol.enqueue(report)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"owned-1","provider":"claude","label":"Managed","origin":"owned","enabled":true,"source_kind":null}]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        let snapshot = await backend.bootstrap(mode: .localProxy)
        let accounts = await backend.accounts()

        XCTAssertNil(snapshot.quotas[.claude]?["Managed"])
        XCTAssertTrue(snapshot.accountIssues.isEmpty)
        XCTAssertNotNil(snapshot.quotas[.claude]?["CLI User"])
        XCTAssertEqual(accounts.map(\.source), [.legacyCLIProxy])
    }

    func testLocalProxyModeKeepsOwnedWarpUsage() throws {
        let data = Data(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"warp","account_ref":{"origin":"owned","id":"warp-1","label":"__quotio_local_warp__:Work"},"account":{"id":"warp","label":"Work","plan":null},"windows":[]}],"failures":[]}"#.utf8)
        let report = try makeQuotioCLIDecoder().decode(QuotioCLIUsageReport.self, from: data)

        let snapshot = QuotioCLIUsageMapper.snapshot(report, mode: .localProxy)

        XCTAssertNotNil(snapshot.quotas[.warp]?["Work"])
    }

    func testSynchronizeWarpTokensOnlyUpdatesAndRemovesMirroredAccounts() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"accounts":[{"id":"monitor","provider":"warp","label":"Monitor","origin":"owned","enabled":true,"source_kind":null},{"id":"warp-1","provider":"warp","label":"__quotio_local_warp__:Work","origin":"owned","enabled":true,"source_kind":null},{"id":"warp-2","provider":"warp","label":"__quotio_local_warp__:Old","origin":"owned","enabled":true,"source_kind":null}]}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-2","status":"completed","error":null}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        try await backend.synchronizeWarpTokens([WarpToken(name: "Work", token: "new-token")])

        let requests = QuotioCLIURLProtocol.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PATCH", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/accounts", "/v1/accounts/warp-1", "/v1/accounts/warp-2"])
    }

    func testExpiredDeviceCodeUsesProviderDeadline() async throws {
        let expired = Int64(Date().timeIntervalSince1970) - 1
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"waiting","account_id":null,"error_code":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"waiting","account_id":null,"error_code":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"provider":"copilot","workflow":"device_code","user_code":"CODE","id":"session-1","url":"https://github.com/login/device","expires_at":\#(expired),"status":"failed","account_id":null,"error_code":"unexpected_poll"}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))
        let authorizer = QuotioCLIOAuthAuthorizer(
            backend: backend,
            urlOpener: QuotioCLIURLOpenerStub(),
            callbackTransport: QuotioCLICallbackTransportStub()
        )

        do {
            _ = try await authorizer.begin(
                request: OAuthAuthorizationRequest(
                    providerID: AccountProviderID(rawValue: QuotaProvider.copilot.rawValue)
                ),
                attemptID: OAuthAttemptID(),
                progress: { _ in }
            )
            XCTFail("Expected the provider deadline to expire the session")
        } catch {
            XCTAssertEqual(error as? OAuthFlowFailure, .expired)
        }
        XCTAssertEqual(QuotioCLIURLProtocol.requests().count, 2)
    }

    func testLocalProxyRefreshExcludesOwnedSources() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"id":"operation-1","status":"completed","error":null}"#)
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[],"failures":[]}"#)
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        _ = await backend.refreshAll(mode: .localProxy, providers: [.claude], force: true)

        let body = try XCTUnwrap(QuotioCLIURLProtocol.body(forPath: "/v1/refresh"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["include_owned"] as? Bool, false)
    }

    func testModeSwitchClearsPreviousSnapshotWhenReloadFails() async throws {
        QuotioCLIURLProtocol.enqueue(#"{"schema_version":1,"generated_at":"2026-09-16T12:00:00Z","providers":[{"provider":"claude","account_ref":{"origin":"owned","id":"owned-1","label":"Managed"},"account":{"id":"managed","label":"Managed","plan":null},"windows":[]}],"failures":[]}"#)
        QuotioCLIURLProtocol.enqueue("{}")
        let backend = QuotioCLIBackend(session: stubSession())
        await backend.connect(QuotioCLIConnection(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            token: "private-token"
        ))

        let monitorSnapshot = await backend.bootstrap(mode: .monitor)
        let localSnapshot = await backend.bootstrap(mode: .localProxy)

        XCTAssertNotNil(monitorSnapshot.quotas[.claude]?["Managed"])
        XCTAssertTrue(localSnapshot.quotas.isEmpty)
        XCTAssertNotNil(localSnapshot.issues[.claude])
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotioCLIURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private struct QuotioCLIURLOpenerStub: URLOpening {
    func open(_ url: URL) -> Bool { true }
}

private actor QuotioCLICallbackTransportStub: OAuthCallbackTransport {
    func start(preferredPort: UInt16?) async throws -> UInt16 { preferredPort ?? 0 }
    func waitForCallback(timeout: Duration) async throws -> URL {
        throw OAuthFlowFailure.expired
    }
    func stop() async {}
}

private final class QuotioCLIURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var recordedBodies: [Data?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestBody = Self.readBody(from: request)
        let body = Self.lock.withLock { () -> Data in
            Self.recordedRequests.append(request)
            Self.recordedBodies.append(requestBody)
            return Self.bodies.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(_ body: String) {
        lock.withLock { bodies.append(Data(body.utf8)) }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func body(forPath path: String) -> Data? {
        lock.withLock {
            zip(recordedRequests, recordedBodies).first { $0.0.url?.path == path }?.1
        }
    }

    static func reset() {
        lock.withLock {
            bodies = []
            recordedRequests = []
            recordedBodies = []
        }
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(buffer, count: count)
        }
    }
}
