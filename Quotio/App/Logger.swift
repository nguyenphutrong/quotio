import Foundation
import os.log

nonisolated enum Log {
    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "Lifecycle"
    )

    static func warning(_ message: String, file: String = #file) {
        let filename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        logger.warning("[\(filename)] \(message, privacy: .public)")
    }
}
