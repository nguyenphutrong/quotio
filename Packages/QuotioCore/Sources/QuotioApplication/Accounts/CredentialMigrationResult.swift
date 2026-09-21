public struct CredentialMigrationResult: Sendable, Equatable {
    public var migratedCount: Int
    public var pendingCount: Int
    public var metadataUnreadable: Bool

    public init(migratedCount: Int = 0, pendingCount: Int = 0, metadataUnreadable: Bool = false) {
        self.migratedCount = migratedCount
        self.pendingCount = pendingCount
        self.metadataUnreadable = metadataUnreadable
    }
}
