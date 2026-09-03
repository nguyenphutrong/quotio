import Foundation
import QuotioApplication

public actor URLSessionOAuthHTTPTransport: OAuthHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthFlowFailure.invalidResponse
        }
        return OAuthHTTPResponse(statusCode: httpResponse.statusCode, body: data)
    }
}
