//
//  CustomProviderHTTPClient.swift
//  Quotio - Custom provider setup HTTP transport
//

import Foundation
import Network

/// A lightweight HTTP response used by custom provider setup and connection testing.
struct CustomProviderHTTPResponse: Sendable {
    /// The numeric HTTP status code returned by the provider.
    let statusCode: Int

    /// The response body after any supported transfer decoding has been applied.
    let data: Data
}

/// Errors raised by the custom provider setup transport.
enum CustomProviderHTTPClientError: LocalizedError {
    /// The request URL is missing, malformed, or unsuitable for the selected transport.
    case invalidHTTPURL

    /// The request uses a URL scheme other than HTTP or HTTPS.
    case unsupportedScheme(String)

    /// The plain HTTP request could not be serialized into bytes.
    case requestEncodingFailed

    /// The provider did not complete the request before the configured timeout.
    case timedOut

    /// The provider returned bytes that could not be parsed as an HTTP response.
    case invalidResponse

    /// The provider returned malformed chunked transfer encoding.
    case malformedChunkedResponse

    /// The provider URL uses HTTP but the user has not opted into insecure HTTP.
    case insecureHTTPNotAllowed

    /// A user-facing description suitable for validation and connection-test failures.
    var errorDescription: String? {
        switch self {
        case .invalidHTTPURL:
            return "Invalid HTTP URL"
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme)"
        case .requestEncodingFailed:
            return "Failed to encode HTTP request"
        case .timedOut:
            return "HTTP request timed out"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .malformedChunkedResponse:
            return "Invalid chunked HTTP response"
        case .insecureHTTPNotAllowed:
            return "Insecure HTTP is blocked. Enable Allow Insecure HTTP for this custom provider to use an http:// endpoint."
        }
    }
}

/// Transport for custom provider setup requests.
///
/// HTTPS uses URLSession so system TLS policy remains the default. Plain HTTP uses a scoped
/// Network.framework transport only when the provider explicitly opts into insecure HTTP.
nonisolated enum CustomProviderHTTPClient {
    /// Executes a custom provider request using the transport required by the request URL scheme.
    /// - Parameters:
    ///   - request: The fully prepared provider request.
    ///   - allowInsecureHTTP: Whether `http://` URLs are allowed for this provider.
    ///   - verifySSL: Whether HTTPS requests should verify certificates normally.
    /// - Returns: The provider response status code and body data.
    static func data(for request: URLRequest, allowInsecureHTTP: Bool, verifySSL: Bool) async throws -> CustomProviderHTTPResponse {
        guard let url = request.url, let scheme = url.scheme?.lowercased() else {
            throw CustomProviderHTTPClientError.invalidHTTPURL
        }

        switch scheme {
        case "https":
            let session = makeCustomProviderURLSession(verifySSL: verifySSL)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CustomProviderHTTPClientError.invalidResponse
            }

            return CustomProviderHTTPResponse(statusCode: httpResponse.statusCode, data: data)

        case "http":
            guard allowInsecureHTTP else {
                throw CustomProviderHTTPClientError.insecureHTTPNotAllowed
            }

            return try await dataForPlainHTTPRequest(request)

        default:
            throw CustomProviderHTTPClientError.unsupportedScheme(scheme)
        }
    }

    /// Sends a plain HTTP request over TCP without using URLSession, which ATS would block.
    private static func dataForPlainHTTPRequest(_ request: URLRequest) async throws -> CustomProviderHTTPResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let host = url.host else {
            throw CustomProviderHTTPClientError.invalidHTTPURL
        }

        let port = UInt16(url.port ?? 80)
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let requestData = makePlainHTTPRequestData(from: request, host: host, port: port) else {
            throw CustomProviderHTTPClientError.requestEncodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let state = PlainHTTPRequestState(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error = error {
                            state.finish(.failure(error))
                            return
                        }

                        state.receiveNext()
                    })
                case .failed(let error):
                    state.finish(.failure(error))
                default:
                    break
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64((request.timeoutInterval > 0 ? request.timeoutInterval : 15) * 1_000_000_000))
                state.finish(.failure(CustomProviderHTTPClientError.timedOut))
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Serializes a URLRequest into an HTTP/1.1 request suitable for a direct TCP connection.
    private static func makePlainHTTPRequestData(from request: URLRequest, host: String, port: UInt16) -> Data? {
        guard let url = request.url else { return nil }

        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
        let target = url.query.map { "\(path)?\($0)" } ?? path
        let hostHeader = port == 80 ? host : "\(host):\(port)"

        var lines = [
            "\(method) \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            "Connection: close"
        ]

        let headers = request.allHTTPHeaderFields ?? [:]
        for (key, value) in headers where key.caseInsensitiveCompare("Host") != .orderedSame && key.caseInsensitiveCompare("Connection") != .orderedSame {
            lines.append("\(key): \(value)")
        }

        let body = request.httpBody ?? Data()
        if !body.isEmpty && headers.keys.first(where: { $0.caseInsensitiveCompare("Content-Length") == .orderedSame }) == nil {
            lines.append("Content-Length: \(body.count)")
        }

        lines.append("")
        lines.append("")

        guard var data = lines.joined(separator: "\r\n").data(using: .utf8) else {
            return nil
        }

        data.append(body)
        return data
    }

    /// Parses an HTTP/1.1 response returned by the plain HTTP transport.
    fileprivate static func parseHTTPResponse(_ response: Data) throws -> CustomProviderHTTPResponse {
        let headerSeparator = Data("\r\n\r\n".utf8)
        guard let headerRange = response.range(of: headerSeparator),
              let headerText = String(data: response.subdata(in: response.startIndex..<headerRange.lowerBound), encoding: .utf8) else {
            throw CustomProviderHTTPClientError.invalidResponse
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw CustomProviderHTTPClientError.invalidResponse
        }

        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw CustomProviderHTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let body = response.subdata(in: bodyStart..<response.endIndex)
        let decodedBody = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
            ? try decodeChunkedBody(body)
            : body

        return CustomProviderHTTPResponse(statusCode: statusCode, data: decodedBody)
    }

    /// Decodes a body using HTTP chunked transfer encoding.
    private static func decodeChunkedBody(_ body: Data) throws -> Data {
        var offset = body.startIndex
        var decoded = Data()
        let lineSeparator = Data("\r\n".utf8)

        while offset < body.endIndex {
            guard let lineRange = body[offset..<body.endIndex].range(of: lineSeparator),
                  let line = String(data: body.subdata(in: offset..<lineRange.lowerBound), encoding: .utf8) else {
                throw CustomProviderHTTPClientError.malformedChunkedResponse
            }

            offset = lineRange.upperBound

            let chunkSizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let chunkSize = Int(chunkSizeText, radix: 16) else {
                throw CustomProviderHTTPClientError.malformedChunkedResponse
            }

            if chunkSize == 0 {
                return decoded
            }

            guard offset + chunkSize <= body.endIndex else {
                throw CustomProviderHTTPClientError.malformedChunkedResponse
            }

            decoded.append(body.subdata(in: offset..<(offset + chunkSize)))
            offset += chunkSize

            if offset + lineSeparator.count <= body.endIndex {
                offset += lineSeparator.count
            }
        }

        return decoded
    }
}

/// Thread-safe state shared by Network.framework callbacks for one plain HTTP request.
nonisolated private final class PlainHTTPRequestState: @unchecked Sendable {
    /// The active TCP connection to the provider.
    private let connection: NWConnection

    /// The continuation that completes the async request.
    private let continuation: CheckedContinuation<CustomProviderHTTPResponse, Error>

    /// Guards response accumulation and one-shot continuation completion.
    private let lock = NSLock()

    /// Tracks whether the continuation has already been resumed.
    private var didResume = false

    /// Accumulates response bytes until the provider closes the connection.
    private var responseData = Data()

    /// Creates state for one plain HTTP request.
    init(connection: NWConnection, continuation: CheckedContinuation<CustomProviderHTTPResponse, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    /// Completes the request exactly once and closes the underlying connection.
    func finish(_ result: Result<CustomProviderHTTPResponse, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        connection.cancel()
        continuation.resume(with: result)
    }

    /// Starts or continues receiving response bytes from the provider.
    func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let error = error {
                finish(.failure(error))
                return
            }

            if let data = data, !data.isEmpty {
                append(data)
            }

            if isComplete {
                do {
                    finish(.success(try CustomProviderHTTPClient.parseHTTPResponse(snapshot())))
                } catch {
                    finish(.failure(error))
                }
                return
            }

            receiveNext()
        }
    }

    /// Appends bytes to the accumulated response buffer.
    private func append(_ data: Data) {
        lock.lock()
        responseData.append(data)
        lock.unlock()
    }

    /// Returns a stable copy of the accumulated response data.
    private func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return responseData
    }
}

// MARK: - Custom Provider URLSession

/// Builds the URLSession used for HTTPS custom provider setup requests.
nonisolated private func makeCustomProviderURLSession(verifySSL: Bool) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30

    guard !verifySSL else {
        return URLSession(configuration: configuration)
    }

    return URLSession(
        configuration: configuration,
        delegate: CustomProviderURLSessionDelegate(),
        delegateQueue: nil
    )
}

/// URLSession delegate that can opt out of HTTPS trust validation for a custom provider request.
nonisolated private final class CustomProviderURLSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    /// Handles HTTPS server-trust challenges when SSL verification has been disabled by the user.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
