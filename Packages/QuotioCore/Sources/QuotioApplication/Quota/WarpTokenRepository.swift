import QuotioDomain

public protocol WarpTokenRepository: Sendable {
    func load() async throws -> [WarpToken]
    func save(_ tokens: [WarpToken]) async throws
}
