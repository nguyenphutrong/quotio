import Foundation

public protocol QuotaHTTPSession: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: QuotaHTTPSession {}

public actor ReloadableQuotaHTTPSession: QuotaHTTPSession {
  private let makeSession: @Sendable () -> any QuotaHTTPSession
  private var session: any QuotaHTTPSession

  public init(makeSession: @escaping @Sendable () -> any QuotaHTTPSession) {
    self.makeSession = makeSession
    self.session = makeSession()
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let session = session
    return try await session.data(for: request)
  }

  public func reload() {
    session = makeSession()
  }
}

public enum InfrastructureQuotaFetchError: Error, Equatable {
  case invalidURL
  case invalidResponse
  case forbidden
  case httpError(Int)
  case apiError(String)
}
