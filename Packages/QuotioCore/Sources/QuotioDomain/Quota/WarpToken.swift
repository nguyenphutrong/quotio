import Foundation

public struct WarpToken: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var token: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        token: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.token = token
        self.isEnabled = isEnabled
    }
}
