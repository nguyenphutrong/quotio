import Foundation

public protocol QuotaHTTPSession: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: QuotaHTTPSession {}

public enum InfrastructureQuotaFetchError: Error, Equatable {
  case invalidURL
  case invalidResponse
  case forbidden
  case httpError(Int)
  case apiError(String)
}
