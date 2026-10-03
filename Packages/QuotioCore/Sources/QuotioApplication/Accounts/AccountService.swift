import QuotioDomain

public enum AccountServiceFailure: Error, Equatable, Sendable {
    case invalidCredential
    case duplicateAccount
    case accountNotFound
    case deletionNotAllowed
}

public struct NativeSourcePermission: Codable, Hashable, Identifiable, Sendable {
    public let provider: QuotaProvider
    public let kind: String
    public let location: String?

    public init(provider: QuotaProvider, kind: String, location: String?) {
        self.provider = provider
        self.kind = kind
        self.location = location
    }

    public var id: String { provider.rawValue + ":" + kind + ":" + (location ?? "") }
}

public protocol AccountManaging: Sendable {
    func registerDetectedNativeAccounts() async
    func nativeSourcesRequiringPermission() async -> [NativeSourcePermission]
    func authorizeNativeSource(_ source: NativeSourcePermission) async throws
    func accounts() async -> [Account]
    func setDisabled(_ disabled: Bool, accountID: String) async
    func delete(accountID: String) async throws
    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) async throws
}
