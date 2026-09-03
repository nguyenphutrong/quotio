import Foundation
import XCTest
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class AgentModelCatalogHTTPAdapterTests: XCTestCase {
    override func tearDown() {
        ModelCatalogURLProtocol.reset()
        super.tearDown()
    }

    func testFetchCatalogSendsExpectedRequestAndPreservesExactCatalog() async throws {
        let adapter = makeAdapter(body: #"{"data":[{"id":"z","owned_by":"team"},{"id":"z"},{"id":"a","owned_by":""}]}"#)

        let catalog = try await adapter.fetchCatalog(configuration: configuration())

        XCTAssertEqual(catalog, [
            ModelCatalogEntry(id: "z", owner: "team"),
            ModelCatalogEntry(id: "z", owner: nil),
            ModelCatalogEntry(id: "a", owner: ""),
        ])
        let request = try XCTUnwrap(ModelCatalogURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://proxy.example/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testFetchCatalogRejectsNon200Response() async {
        let adapter = makeAdapter(body: "{}", statusCode: 503)
        do {
            _ = try await adapter.fetchCatalog(configuration: configuration())
            XCTFail("Expected bad server response")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testFetchCatalogRejectsMalformedResponse() async {
        let adapter = makeAdapter(body: #"{"data":"wrong"}"#)
        do {
            _ = try await adapter.fetchCatalog(configuration: configuration())
            XCTFail("Expected decoding failure")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testFetchCatalogPreservesSuccessfulEmptyCatalog() async throws {
        let catalog = try await makeAdapter(body: #"{"data":[]}"#)
            .fetchCatalog(configuration: configuration())
        XCTAssertEqual(catalog, [])
    }

    func testAvailableModelsDefaultsMissingOwnerAndDoesNotFilterCopilotWhenSetIsEmpty() async throws {
        let adapter = makeAdapter(body: #"{"data":[{"id":"default"},{"id":"copilot","owned_by":"github-copilot"}]}"#)
        let models = try await adapter.fetchAvailableModels(configuration: configuration())
        XCTAssertEqual(models.map(\.provider), ["openai", "github-copilot"])
        XCTAssertEqual(models.map(\.id), ["default", "copilot"])
    }

    func testAvailableModelsFiltersOnlyUnavailableCopilotModelsWhenSetIsNonempty() async throws {
        let adapter = makeAdapter(
            body: #"{"data":[{"id":"keep","owned_by":"github-copilot"},{"id":"drop","owned_by":"github-copilot"},{"id":"other","owned_by":"openai"}]}"#,
            copilotIDs: ["keep"]
        )
        let models = try await adapter.fetchAvailableModels(configuration: configuration())
        XCTAssertEqual(models.map(\.id), ["keep", "other"])
    }

    func testConnectionSuccessReportsLatencyAndFirstModel() async {
        let clock = TestNow([Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 1.125)])
        let adapter = makeAdapter(body: #"{"data":[{"id":"first"},{"id":"second"}]}"#, now: clock.call)
        let result = await adapter.testConnection(agent: .codexCLI, configuration: configuration())
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, .connected)
        XCTAssertEqual(result.latencyMs, 125)
        XCTAssertEqual(result.modelResponded, "first")
    }

    func testConnectionFailureUsesOpenAIErrorDetail() async {
        let adapter = makeAdapter(body: #"{"error":{"message":"API key rejected"}}"#, statusCode: 401)
        let result = await adapter.testConnection(agent: .claudeCode, configuration: configuration())
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, .server(details: "API key rejected"))
        XCTAssertNotNil(result.latencyMs)
        XCTAssertNil(result.modelResponded)
    }

    func testConnectionTransportFailureReturnsLocalizedErrorWithoutLatency() async {
        let expected = URLError(.notConnectedToInternet)
        let adapter = makeAdapter(error: expected)
        let result = await adapter.testConnection(agent: .ampCLI, configuration: configuration())
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, .transport(details: expected.localizedDescription))
        XCTAssertNil(result.latencyMs)
        XCTAssertNil(result.modelResponded)
    }

    private func configuration() -> AgentConfiguration {
        AgentConfiguration(agent: .codexCLI, proxyURL: "https://proxy.example/v1", apiKey: "secret")
    }

    private func makeAdapter(
        body: String,
        statusCode: Int = 200,
        copilotIDs: Set<String> = [],
        now: @escaping AgentModelCatalogHTTPAdapter.Now = Date.init
    ) -> AgentModelCatalogHTTPAdapter {
        ModelCatalogURLProtocol.setResponse(body: body, statusCode: statusCode)
        return AgentModelCatalogHTTPAdapter(
            session: stubSession(),
            availableCopilotModelIDs: { copilotIDs },
            now: now
        )
    }

    private func makeAdapter(error: Error) -> AgentModelCatalogHTTPAdapter {
        ModelCatalogURLProtocol.setError(error)
        return AgentModelCatalogHTTPAdapter(session: stubSession())
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelCatalogURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ModelCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responseError: Error?
    nonisolated(unsafe) private static var recordedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data, Int, Error?) in
            Self.recordedRequest = request
            return (Self.responseBody, Self.responseStatus, Self.responseError)
        }
        if let error = state.2 {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: state.1, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.0)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func setResponse(body: String, statusCode: Int) {
        lock.withLock {
            responseBody = Data(body.utf8)
            responseStatus = statusCode
            responseError = nil
            recordedRequest = nil
        }
    }

    static func setError(_ error: Error) {
        lock.withLock {
            responseError = error
            recordedRequest = nil
        }
    }

    static func lastRequest() -> URLRequest? { lock.withLock { recordedRequest } }
    static func reset() { lock.withLock { recordedRequest = nil; responseError = nil } }
}

private final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    init(_ values: [Date]) { self.values = values }
    func call() -> Date { lock.withLock { values.removeFirst() } }
}
