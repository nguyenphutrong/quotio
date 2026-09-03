import Foundation

public struct QuotaTokenRefresh: Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  public let expiresAt: Date?

  public init(
    accessToken: String,
    refreshToken: String?,
    idToken: String? = nil,
    expiresAt: Date?
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.expiresAt = expiresAt
  }
}
