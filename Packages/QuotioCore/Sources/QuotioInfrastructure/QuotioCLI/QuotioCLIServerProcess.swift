import QuotioHostClient
import Foundation
import QuotioDomain
import QuotioApplication
import Security

public enum QuotioCLIServerError: LocalizedError, Equatable {
    case helperUnavailable
    case randomTokenUnavailable
    case startupFailed
    case startupTimedOut
    case incompatibleBootstrap

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "The bundled Quotio CLI helper is missing or not executable."
        case .randomTokenUnavailable:
            "Could not create a private Quotio CLI session."
        case .startupFailed:
            "The Quotio CLI helper stopped before startup completed."
        case .startupTimedOut:
            "The Quotio CLI helper did not start in time."
        case .incompatibleBootstrap:
            "The bundled Quotio CLI helper uses an incompatible local API."
        }
    }
}

@MainActor
public final class QuotioCLIServerProcess {
    private struct Bootstrap: Decodable {
        let bootstrapVersion: Int
        let apiVersion: Int
        let pid: Int32
        let host: String
        let port: Int
    }

    private struct Diagnostic: Decodable {
        enum Event: String, Decodable {
            case read = "vault_keychain_read_failed"
            case write = "vault_keychain_write_failed"
            case authorize = "vault_keychain_authorize_failed"
        }
        let diagnosticVersion: Int
        let event: Event
        let osStatus: Int32
    }

    private let executableURL: URL
    private let configurationURL: URL?
    private let accountDataDirectory: URL?
    private let proxyAuthDirectory: URL?
    private let proxyConfigurationURL: URL?
    private let initialPreferences: @MainActor () -> (ProviderTrackingPreferences, RefreshPreferences, Set<String>)?
    private let storage: QuotioCLIAccountStorage
    private let proxyURL: @MainActor () -> String?
    private let logger: (any ApplicationLogging)?
    private var isStarting = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var diagnostics: Pipe?
    private var diagnosticTask: Task<Void, Never>?

    public var onUnexpectedTermination: (@MainActor @Sendable () -> Void)?

    public init(
        executableURL: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/quotio-cli"),
        storage: QuotioCLIAccountStorage,
        configurationURL: URL? = nil,
        accountDataDirectory: URL? = nil,
        proxyAuthDirectory: URL? = nil,
        proxyConfigurationURL: URL? = nil,
        initialPreferences: @escaping @MainActor () -> (ProviderTrackingPreferences, RefreshPreferences, Set<String>)? = { nil },
        proxyURL: @escaping @MainActor () -> String? = {
            UserDefaults.standard.string(forKey: "proxyURL")
        },
        logger: (any ApplicationLogging)? = nil
    ) {
        self.executableURL = executableURL
        self.storage = storage
        self.configurationURL = configurationURL
        self.accountDataDirectory = accountDataDirectory
        self.proxyAuthDirectory = proxyAuthDirectory
        self.proxyConfigurationURL = proxyConfigurationURL
        self.initialPreferences = initialPreferences
        self.proxyURL = proxyURL
        self.logger = logger
    }

    public func start() async throws -> QuotioHostConnection {
        await stop()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw QuotioCLIServerError.helperUnavailable
        }

        isStarting = true
        defer { isStarting = false }
        let token = try makeToken()
        let storageArguments = try makeStorageArguments()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "serve",
            "--manage",
            "--parent-pipe",
            "--listen", "127.0.0.1:0",
        ] + storageArguments
        if let proxyAuthDirectory {
            process.arguments?.append(contentsOf: ["--cli-proxy-auth-dir", proxyAuthDirectory.path])
        }
        if let proxyConfigurationURL {
            process.arguments?.append(contentsOf: ["--cli-proxy-config", proxyConfigurationURL.path])
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "QUOTIO_SERVER_TOKEN")
        if let value = proxyURL(),
           let url = URL(string: value),
           url.host?.isEmpty == false {
            switch url.scheme?.lowercased() {
            case "http":
                environment["HTTP_PROXY"] = value
                environment["http_proxy"] = value
                environment["HTTPS_PROXY"] = value
                environment["https_proxy"] = value
            case "https":
                environment["HTTPS_PROXY"] = value
                environment["https_proxy"] = value
            case "socks5":
                environment["ALL_PROXY"] = value
                environment["all_proxy"] = value
            default:
                break
            }
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        let stream = outputStream(from: output)
        let diagnosticStream = outputStream(from: diagnostics)
        diagnosticTask = Task { [logger] in
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var line = Data()
            var oversized = false
            for await chunk in diagnosticStream {
                guard !Task.isCancelled else { break }
                for byte in chunk {
                    if byte == 10 {
                        if !oversized,
                           let diagnostic = try? decoder.decode(Diagnostic.self, from: line),
                           diagnostic.diagnosticVersion == 1 {
                            await logger?.write(.warning, message: "Quotio helper \(diagnostic.event.rawValue) os_status=\(diagnostic.osStatus)")
                        }
                        line.removeAll(keepingCapacity: true)
                        oversized = false
                    } else if !oversized {
                        if line.count < 1_024 {
                            line.append(byte)
                        } else {
                            line.removeAll(keepingCapacity: true)
                            oversized = true
                        }
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] terminated in
            let pid = terminated.processIdentifier
            Task { @MainActor [weak self] in
                guard self?.process?.processIdentifier == pid else { return }
                self?.process = nil
                self?.input = nil
                self?.output = nil
                self?.diagnostics?.fileHandleForReading.readabilityHandler = nil
                self?.diagnostics = nil
                self?.diagnosticTask?.cancel()
                self?.diagnosticTask = nil
                if self?.isStarting == false { self?.onUnexpectedTermination?() }
            }
        }
        self.process = process
        self.input = input
        self.output = output
        self.diagnostics = diagnostics

        do {
            try process.run()
            var handshake: [String: Any] = ["token": token]
            if let (tracking, refresh, disabledFiles) = initialPreferences() {
                handshake["preferences"] = [
                    "disabled_providers": tracking.disabledProviders.map(\.rawValue).sorted(),
                    "disabled_proxy_auth_files": disabledFiles.sorted(),
                    "automatically_discover_logins": tracking.automaticallyDiscoverLogins,
                    "refresh_interval": Int(refresh.cadence.intervalSeconds ?? 0),
                    "quota_history_enabled": true,
                ]
            }
            var payload = try JSONSerialization.data(withJSONObject: handshake)
            payload.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: payload)
            let bootstrap = try await bootstrap(from: stream)
            guard bootstrap.bootstrapVersion == 2,
                  bootstrap.apiVersion == 2,
                  bootstrap.pid == process.processIdentifier,
                  bootstrap.host == "127.0.0.1",
                  (1...65_535).contains(bootstrap.port),
                  let baseURL = URL(string: "http://127.0.0.1:\(bootstrap.port)") else {
                throw QuotioCLIServerError.incompatibleBootstrap
            }
            guard process.isRunning else { throw QuotioCLIServerError.startupFailed }
            return QuotioHostConnection(baseURL: baseURL, token: token)
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        let ownedProcess = process
        process = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        diagnostics?.fileHandleForReading.readabilityHandler = nil
        diagnostics = nil
        diagnosticTask?.cancel()
        diagnosticTask = nil
        guard let ownedProcess, ownedProcess.isRunning else { return }
        for _ in 0..<20 where ownedProcess.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if ownedProcess.isRunning {
            ownedProcess.terminate()
        }
    }

    private func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw QuotioCLIServerError.randomTokenUnavailable
        }
        return Data(bytes).base64EncodedString()
    }

    private func makeStorageArguments() throws -> [String] {
        switch storage {
        case .isolated(let store):
            let locations = try makeLocations(for: store)
            return [
                "--config", locations.configuration.path,
                "--account-vault-namespace", store.namespace,
                "--account-data-dir", locations.accounts.path,
            ]
        case .shared(adopting: let store):
            let locations = try locations(of: store)
            var arguments = [
                "--adopt-vault-namespace", store.namespace,
                "--adopt-data-dir", locations.accounts.path,
            ]
            if FileManager.default.fileExists(atPath: locations.configuration.path) {
                arguments += ["--adopt-config", locations.configuration.path]
            }
            return arguments
        }
    }

    private func locations(
        of store: QuotioCLIAccountStorage.IsolatedStore
    ) throws -> (configuration: URL, accounts: URL) {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(store.applicationSupportDirectoryName, isDirectory: true)
        return (
            configurationURL ?? support.appendingPathComponent("quotio-cli.toml"),
            accountDataDirectory ?? support.appendingPathComponent("QuotioCLI", isDirectory: true)
        )
    }

    private func makeLocations(
        for store: QuotioCLIAccountStorage.IsolatedStore
    ) throws -> (configuration: URL, accounts: URL) {
        let (configuration, accounts) = try locations(of: store)
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: configuration.path),
           !FileManager.default.createFile(
               atPath: configuration.path,
               contents: Data(),
               attributes: [.posixPermissions: 0o600]
           ) {
            throw QuotioCLIServerError.startupFailed
        }
        return (configuration, accounts)
    }

    private func outputStream(from pipe: Pipe) -> AsyncStream<Data> {
        AsyncStream { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
            }
        }
    }

    private func bootstrap(from stream: AsyncStream<Data>) async throws -> Bootstrap {
        try await withThrowingTaskGroup(of: Bootstrap.self) { group in
            group.addTask {
                var data = Data()
                for await chunk in stream {
                    data.append(chunk)
                    guard data.count <= 8_192 else {
                        throw QuotioCLIServerError.incompatibleBootstrap
                    }
                    if let newline = data.firstIndex(of: 10) {
                        let decoder = JSONDecoder()
                        decoder.keyDecodingStrategy = .convertFromSnakeCase
                        return try decoder.decode(Bootstrap.self, from: data[..<newline])
                    }
                }
                throw QuotioCLIServerError.startupFailed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw QuotioCLIServerError.startupTimedOut
            }
            defer { group.cancelAll() }
            guard let bootstrap = try await group.next() else {
                throw QuotioCLIServerError.startupFailed
            }
            return bootstrap
        }
    }
}
