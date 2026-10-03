import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioInfrastructure

final class ManagementAPIClientTests: XCTestCase {
    override func tearDown() {
        LogURLProtocol.reset()
        super.tearDown()
    }

    func testDisabledFileLoggingMapsToSemanticError() async throws {
        LogURLProtocol.respond(status: 400, body: #"{"error":"logging to file disabled"}"#)

        do {
            _ = try await makeClient().fetchLogs(after: nil)
            XCTFail("Expected file logging to be disabled")
        } catch {
            XCTAssertEqual(error as? ProxyLogFailure, .loggingDisabled)
        }

        let request = try XCTUnwrap(LogURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.path, "/v0/management/logs")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testOtherBadRequestRemainsHTTPError() async {
        LogURLProtocol.respond(status: 400, body: #"{"error":"invalid after timestamp"}"#)

        do {
            _ = try await makeClient().fetchLogs(after: nil)
            XCTFail("Expected a bad request")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Management API returned HTTP 400")
        }
    }

    private func makeClient() -> ManagementAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogURLProtocol.self]
        return ManagementAPIClient(
            connectionProvider: {
                ManagementAPIClient.Connection(
                    baseURL: "http://127.0.0.1:8317/v0/management",
                    authKey: "test-key"
                )
            },
            session: URLSession(configuration: configuration)
        )
    }
}

private final class LogURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) private static var recordedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.recordedRequest = request
            return Self.stub
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func respond(status: Int, body: String) {
        lock.withLock { stub = (status, Data(body.utf8)) }
    }

    static func lastRequest() -> URLRequest? {
        lock.withLock { recordedRequest }
    }

    static func reset() {
        lock.withLock {
            stub = (200, Data())
            recordedRequest = nil
        }
    }
}
