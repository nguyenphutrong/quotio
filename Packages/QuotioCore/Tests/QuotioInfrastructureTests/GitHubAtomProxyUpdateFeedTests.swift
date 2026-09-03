import Foundation
import XCTest
@testable import QuotioInfrastructure

final class GitHubAtomProxyUpdateFeedTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "GitHubAtomProxyUpdateFeedTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        AtomFeedURLProtocol.reset()
    }

    override func tearDown() {
        AtomFeedURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSuccessfulFeedRequestCachesETagAndReturnsNewerVersion() async throws {
        AtomFeedURLProtocol.enqueue(
            statusCode: 200,
            headers: ["ETag": "etag-1"],
            body: feed(version: "v6.7.13")
        )
        let updateFeed = makeFeed()

        let version = await updateFeed.latestVersion(comparedTo: "6.7.12")

        XCTAssertEqual(version, "v6.7.13")
        let request = try XCTUnwrap(AtomFeedURLProtocol.requests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/atom+xml")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Quotio/1.0")
        let data = try XCTUnwrap(defaults.data(forKey: "atomFeedCache_cliproxy"))
        let cached = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(cached["etag"] as? String, "etag-1")
        XCTAssertEqual(cached["latestVersion"] as? String, "v6.7.13")
    }

    func testNotModifiedRequestUsesConditionalHeadersAndCachedVersion() async {
        AtomFeedURLProtocol.enqueue(
            statusCode: 200,
            headers: ["ETag": "etag-1"],
            body: feed(version: "v6.7.13")
        )
        AtomFeedURLProtocol.enqueue(statusCode: 304)
        let updateFeed = makeFeed()

        _ = await updateFeed.latestVersion(comparedTo: "6.7.12")
        let cachedVersion = await updateFeed.latestVersion(comparedTo: "6.7.12")

        XCTAssertEqual(cachedVersion, "v6.7.13")
        let requests = AtomFeedURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "etag-1")
    }

    func testEqualOrOlderFeedVersionDoesNotReportAnUpdate() async {
        AtomFeedURLProtocol.enqueue(statusCode: 200, body: feed(version: "v6.7.13"))
        AtomFeedURLProtocol.enqueue(statusCode: 200, body: feed(version: "v6.7.13"))
        let updateFeed = makeFeed()

        let equal = await updateFeed.latestVersion(comparedTo: "6.7.13")
        let older = await updateFeed.latestVersion(comparedTo: "6.8.0")

        XCTAssertNil(equal)
        XCTAssertNil(older)
    }

    func testNotificationRecordUsesExistingPersistedKey() {
        let record = UserDefaultsProxyUpdateNotificationRecord(defaults: defaults)

        record.saveLastNotifiedVersion("v6.7.13")

        XCTAssertEqual(record.lastNotifiedVersion(), "v6.7.13")
        XCTAssertEqual(defaults.string(forKey: "notifiedCLIProxyVersion"), "v6.7.13")
    }

    private func makeFeed() -> GitHubAtomProxyUpdateFeed {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AtomFeedURLProtocol.self]
        let feedDefaults = UserDefaults(suiteName: suiteName)!
        return GitHubAtomProxyUpdateFeed(
            feedURL: URL(string: "https://example.com/releases.atom")!,
            session: URLSession(configuration: configuration),
            defaults: feedDefaults,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func feed(version: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <id>tag:github.com,2008:Repository/1/\(version)</id>
            <title>\(version)</title>
          </entry>
        </feed>
        """
    }
}

private final class AtomFeedURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [Response] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.lock.withLock { () -> Response in
            Self.recordedRequests.append(request)
            return Self.responses.removeFirst()
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            client?.urlProtocol(self, didLoad: response.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(
        statusCode: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) {
        lock.withLock {
            responses.append(Response(
                statusCode: statusCode,
                headers: headers,
                body: Data(body.utf8)
            ))
        }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func reset() {
        lock.withLock {
            responses = []
            recordedRequests = []
        }
    }
}
