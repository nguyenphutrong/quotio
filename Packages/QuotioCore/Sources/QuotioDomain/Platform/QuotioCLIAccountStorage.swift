import Foundation

public enum QuotioCLIAccountStorage: Equatable, Sendable {
    public struct IsolatedStore: Equatable, Sendable {
        public let namespace: String
        public let applicationSupportDirectoryName: String

        public init(namespace: String, applicationSupportDirectoryName: String) {
            self.namespace = namespace
            self.applicationSupportDirectoryName = applicationSupportDirectoryName
        }
    }

    case isolated(IsolatedStore)
    case shared(adopting: IsolatedStore)
}
