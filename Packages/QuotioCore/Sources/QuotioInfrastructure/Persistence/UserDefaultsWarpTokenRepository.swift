import Foundation
import QuotioApplication
import QuotioDomain

public final class UserDefaultsWarpTokenRepository: WarpTokenRepository, @unchecked Sendable {
    public static let storageKey = "warpTokens"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() async throws -> [WarpToken] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return try JSONDecoder().decode([WarpToken].self, from: data)
    }

    public func save(_ tokens: [WarpToken]) async throws {
        defaults.set(try JSONEncoder().encode(tokens), forKey: Self.storageKey)
    }
}
