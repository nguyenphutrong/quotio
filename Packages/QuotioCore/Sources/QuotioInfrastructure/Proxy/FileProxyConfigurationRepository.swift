import Foundation
import QuotioApplication
import QuotioDomain

public actor FileProxyConfigurationRepository: ProxyConfigurationRepository {
    private let fileManager: FileManager
    private let resolvedPaths: ProxyPaths

    public init(
        paths: ProxyPaths = FileProxyConfigurationRepository.defaultPaths(),
        fileManager: FileManager = .default
    ) {
        self.resolvedPaths = paths
        self.fileManager = fileManager
    }

    public static func defaultPaths(fileManager: FileManager = .default) -> ProxyPaths {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let quotioDirectory = appSupport.appendingPathComponent("Quotio")
        let proxyDirectory = quotioDirectory.appendingPathComponent("proxy/upstream/current")
        return ProxyPaths(
            legacyBinaryPath: quotioDirectory.appendingPathComponent("CLIProxyAPI").path,
            configPath: quotioDirectory.appendingPathComponent("config.yaml").path,
            authDirectoryPath: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cli-proxy-api").path,
            expectedBinaryPath: proxyDirectory.appendingPathComponent("CLIProxyAPI").path
        )
    }

    public func paths() -> ProxyPaths {
        resolvedPaths
    }

    public func ensureExists(
        port: UInt16,
        managementKey: String,
        allowNetworkAccess: Bool
    ) {
        let configURL = URL(fileURLWithPath: resolvedPaths.configPath)
        try? fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            atPath: resolvedPaths.authDirectoryPath,
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: resolvedPaths.configPath) else { return }

        let configuration = """
        host: "\(allowNetworkAccess ? "0.0.0.0" : "127.0.0.1")"
        port: \(port)
        auth-dir: "\(resolvedPaths.authDirectoryPath)"
        proxy-url: ""

        api-keys:
          - "quotio-local-\(UUID().uuidString)"

        remote-management:
          allow-remote: false
          secret-key: "\(managementKey)"

        debug: false
        logging-to-file: false
        usage-statistics-enabled: true

        routing:
          strategy: "round-robin"

        quota-exceeded:
          switch-project: true
          switch-preview-model: true

        request-retry: 3
        max-retry-interval: 30
        """
        try? configuration.write(
            toFile: resolvedPaths.configPath,
            atomically: true,
            encoding: .utf8
        )
    }

    public func setPort(_ port: UInt16) {
        updateValue(pattern: #"port:\s*\d+"#, replacement: "port: \(port)")
    }

    public func setHost(_ host: String) {
        updateValue(pattern: #"host:\s*"[^"]*""#, replacement: "host: \"\(host)\"")
    }

    public func ensureAPIKey() {
        guard let content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8) else {
            return
        }
        var lines = content.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "api-keys:"
        }) {
            var scanIndex = index + 1
            while scanIndex < lines.count {
                let line = lines[scanIndex]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }
                if trimmed.hasPrefix("-") {
                    if !trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return
                    }
                    scanIndex += 1
                    continue
                }
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
                scanIndex += 1
            }
            lines.insert("  - \"quotio-local-\(UUID().uuidString)\"", at: index + 1)
        } else {
            lines.append(contentsOf: [
                "",
                "api-keys:",
                "  - \"quotio-local-\(UUID().uuidString)\"",
                "",
            ])
        }
        write(lines.joined(separator: "\n"))
    }

    public func setAllowRemote(_ enabled: Bool) {
        updateValue(
            pattern: #"allow-remote:\s*(true|false)"#,
            replacement: "allow-remote: \(enabled)"
        )
    }

    public func setLogging(_ enabled: Bool) {
        updateValue(
            pattern: #"logging-to-file:\s*(true|false)"#,
            replacement: "logging-to-file: \(enabled)"
        )
    }

    public func setRoutingStrategy(_ strategy: String) {
        updateValue(
            pattern: #"strategy:\s*"[^"]*""#,
            replacement: "strategy: \"\(strategy)\""
        )
    }

    public func setProxyURL(_ url: String?) {
        guard var content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8) else {
            return
        }
        let value = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let range = content.range(of: #"proxy-url:\s*\"[^\"]*\""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "proxy-url: \"\(value)\"")
        } else if let range = content.range(of: #"proxy-url:\s*[^\n]*"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "proxy-url: \"\(value)\"")
        } else if let range = content.range(of: #"port:\s*\d+\n"#, options: .regularExpression) {
            content.insert(contentsOf: "proxy-url: \"\(value)\"\n", at: range.upperBound)
        } else {
            return
        }
        write(content)
    }

    public func setManagementKey(_ key: String) {
        guard var content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8) else {
            return
        }
        if let range = content.range(of: #"secret-key:\s*\".*\""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(key)\"")
        } else if let range = content.range(of: #"secret-key:\s*[^\n]+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(key)\"")
        } else {
            return
        }
        write(content)
    }

    public func makeTestConfiguration(port: UInt16, managementKey: String) throws -> String {
        let path = fileManager.temporaryDirectory
            .appendingPathComponent("quotio-test-config-\(port).yaml").path
        let configuration = """
        host: "127.0.0.1"
        port: \(port)
        auth-dir: "\(resolvedPaths.authDirectoryPath)"

        api-keys:
          - "quotio-test-\(UUID().uuidString.prefix(8))"

        remote-management:
          allow-remote: false
          secret-key: "\(managementKey)"

        debug: false
        logging-to-file: false
        usage-statistics-enabled: false

        routing:
          strategy: "round-robin"
        """
        try configuration.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    public func removeTestConfiguration(at path: String) {
        try? fileManager.removeItem(atPath: path)
    }

    private func updateValue(pattern: String, replacement: String) {
        guard var content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8),
              let range = content.range(of: pattern, options: .regularExpression) else {
            return
        }
        content.replaceSubrange(range, with: replacement)
        write(content)
    }

    private func write(_ content: String) {
        try? content.write(
            toFile: resolvedPaths.configPath,
            atomically: true,
            encoding: .utf8
        )
    }
}
