import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class ProxyManagementAPITests: XCTestCase {
    override func tearDown() {
        ManagementURLProtocol.reset()
        super.tearDown()
    }

    func testAuthFilesRequestAndResponsePreserveLegacySchema() async throws {
        ManagementURLProtocol.enqueue(body: #"{"files":[{"id":"1","name":"codex-a.json","provider":"codex","label":null,"status":"ready","status_message":"ok","disabled":false,"unavailable":false,"runtime_only":true,"auth_index":"7"}]}"#)

        let files = try await makeClient().fetchAuthFiles()

        XCTAssertEqual(files.first?.authIndex, "7")
        XCTAssertEqual(files.first?.runtimeOnly, true)
        let request = try XCTUnwrap(ManagementURLProtocol.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8317/auth-files")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connection"), "close")
    }

    func testNamedAuthFileAndAPICallUseCompatibleEncoding() async throws {
        ManagementURLProtocol.enqueue(body: #"{"models":[{"id":"model","owned_by":"google","type":"antigravity"}]}"#)
        ManagementURLProtocol.enqueue(body: "credentials")
        ManagementURLProtocol.enqueue(body: #"{"status_code":204,"header":{"x":["y"]},"body":null}"#)
        let client = makeClient()

        _ = try await client.fetchAuthFileModels(name: "a b&c.json")
        _ = try await client.downloadAuthFile(name: "claude-user+tag@example.com&team=one.json")
        _ = try await client.apiCall(ProxyAPICall(
            authIndex: "4", method: "POST", url: "https://example.test", header: ["x": "y"], data: "{}"
        ))

        let requests = ManagementURLProtocol.requests()
        XCTAssertEqual(requests[0].url?.absoluteString, "http://127.0.0.1:8317/auth-files/models?name=a%20b%26c.json")
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "http://127.0.0.1:8317/auth-files/download?name=claude-user%2Btag%40example.com%26team%3Done.json"
        )
        XCTAssertEqual(requests[2].url?.path, "/api-call")
        XCTAssertEqual(requests[2].httpMethod, "POST")
        XCTAssertEqual(try json(requests[2])["auth_index"] as? String, "4")
        XCTAssertNil(try json(requests[2])["authIndex"])
    }

    func testSettingsEndpointsPreserveMethodsAndValuePayloads() async throws {
        ManagementURLProtocol.enqueue(body: "{}")
        ManagementURLProtocol.enqueue(body: "{}")
        let client = makeClient()

        try await client.setRequestRetry(6)
        try await client.setQuotaExceededSwitchProject(false)

        let requests = ManagementURLProtocol.requests()
        XCTAssertEqual(requests[0].url?.path, "/request-retry")
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(try json(requests[0])["value"] as? Int, 6)
        XCTAssertEqual(requests[1].url?.path, "/quota-exceeded/switch-project")
        XCTAssertEqual(requests[1].httpMethod, "PATCH")
        XCTAssertEqual(try json(requests[1])["value"] as? Bool, false)
    }

    func testRoutingFallsBackToLegacyEndpointAndSchemaOn404() async throws {
        ManagementURLProtocol.enqueue(body: "{}", status: 404)
        ManagementURLProtocol.enqueue(body: "{}")

        try await makeClient().setRoutingStrategy("fill-first")

        let requests = ManagementURLProtocol.requests()
        XCTAssertEqual(requests.map(\.url!.path), ["/routing/strategy", "/routing"])
        XCTAssertEqual(try json(requests[0])["value"] as? String, "fill-first")
        XCTAssertEqual(try json(requests[1])["strategy"] as? String, "fill-first")
    }

    func testRetryableConnectionFailureRetriesFourTimesWithoutDelay() async {
        for _ in 0..<5 { ManagementURLProtocol.enqueue(error: URLError(.cannotConnectToHost)) }
        let client = makeClient()

        do {
            _ = try await client.fetchAPIKeys()
            XCTFail("Expected connection error")
        } catch {
            guard case .connectionError(_) = error as? ProxyManagementFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(ManagementURLProtocol.requests().count, 5)
    }

    private func makeClient() -> URLSessionProxyManagementAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagementURLProtocol.self]
        return URLSessionProxyManagementAPI(
            connection: ProxyManagementConnection(baseURL: "http://127.0.0.1:8317", authKey: "secret"),
            session: URLSession(configuration: configuration),
            sleep: { _ in }
        )
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            data = body
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private final class ManagementURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub { let data: Data; let status: Int; let error: Error? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.lock.withLock { () -> Stub in
            Self.recorded.append(request)
            return Self.stubs.removeFirst()
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(body: String = "", status: Int = 200) {
        lock.withLock { stubs.append(Stub(data: Data(body.utf8), status: status, error: nil)) }
    }

    static func enqueue(error: Error) {
        lock.withLock { stubs.append(Stub(data: Data(), status: 0, error: error)) }
    }

    static func requests() -> [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { stubs = []; recorded = [] } }
}
