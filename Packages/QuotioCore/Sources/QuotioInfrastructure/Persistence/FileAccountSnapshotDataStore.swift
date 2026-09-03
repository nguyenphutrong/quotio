import Foundation
import QuotioApplication

public actor FileAccountSnapshotDataStore: AccountSnapshotDataStore {
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Quotio/Monitor/snapshots-v1.json")
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data) throws {
        try SecureAtomicFileWriter.write(data, to: url)
    }
}
