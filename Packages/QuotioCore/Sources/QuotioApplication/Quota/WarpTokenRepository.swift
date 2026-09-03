import QuotioDomain

public protocol WarpTokenRepository: Sendable {
    func load() throws -> [WarpToken]
    func save(_ tokens: [WarpToken]) throws
}
