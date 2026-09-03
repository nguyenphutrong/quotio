import Foundation
import QuotioApplication

public enum SecureAtomicFileWriter {
    public static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw AuthFileRepositoryError.symbolicLinkRefused
        }

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary, options: .withoutOverwriting)
        do {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}
