import Foundation
import QuotioApplication

public actor FileAntigravityAuthWorkaround: AntigravityAuthFileWorkaroundApplying {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func apply(in authDirectory: String) {
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDirectory) else { return }
        for file in files where file.hasSuffix(".json") && file.hasPrefix("antigravity-") {
            let path = (authDirectory as NSString).appendingPathComponent(file)
            let backupPath = path + ".bak"
            if !fileManager.fileExists(atPath: backupPath) {
                try? fileManager.copyItem(atPath: path, toPath: backupPath)
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            var metadata = json["metadata"] as? [String: Any] ?? [:]
            metadata["base_url"] = "https://daily-cloudcode-pa.googleapis.com"
            json["metadata"] = metadata
            if let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    public func remove(in authDirectory: String) {
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDirectory) else { return }
        var restoredCount = 0
        for file in files where file.hasSuffix(".json.bak") {
            let backupPath = (authDirectory as NSString).appendingPathComponent(file)
            let originalPath = String(backupPath.dropLast(4))
            do {
                if fileManager.fileExists(atPath: originalPath) {
                    try fileManager.removeItem(atPath: originalPath)
                }
                try fileManager.moveItem(atPath: backupPath, toPath: originalPath)
                restoredCount += 1
            } catch {
                continue
            }
        }
        guard restoredCount == 0 else { return }
        for file in files where file.hasSuffix(".json") && file.hasPrefix("antigravity-") {
            let path = (authDirectory as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var metadata = json["metadata"] as? [String: Any] else {
                continue
            }
            metadata.removeValue(forKey: "base_url")
            json["metadata"] = metadata
            if let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
