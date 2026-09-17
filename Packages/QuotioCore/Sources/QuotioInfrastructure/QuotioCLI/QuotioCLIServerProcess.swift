import Foundation
import Security

public struct QuotioCLIConnection: Sendable, Equatable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

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

    private let executableURL: URL
    private let configurationURL: URL?
    private let accountDataDirectory: URL?
    private let proxyAuthDirectory: URL?
    private let providers: [String]
    private let executableDirectories: [URL]
    private let proxyURL: @MainActor () -> String?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?

    public var onUnexpectedTermination: (@MainActor @Sendable () -> Void)?

    public init(
        executableURL: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/quotio-cli"),
        configurationURL: URL? = nil,
        accountDataDirectory: URL? = nil,
        proxyAuthDirectory: URL? = nil,
        providers: [String] = [],
        executableDirectories: [URL] = [],
        proxyURL: @escaping @MainActor () -> String? = {
            UserDefaults.standard.string(forKey: "proxyURL")
        }
    ) {
        self.executableURL = executableURL
        self.configurationURL = configurationURL
        self.accountDataDirectory = accountDataDirectory
        self.proxyAuthDirectory = proxyAuthDirectory
        self.providers = providers
        self.executableDirectories = executableDirectories
        self.proxyURL = proxyURL
    }

    public func start() async throws -> QuotioCLIConnection {
        await stop()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw QuotioCLIServerError.helperUnavailable
        }

        let token = try makeToken()
        let locations = try makeLocations()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "serve",
            "--manage",
            "--parent-pipe",
            "--listen", "127.0.0.1:0",
            "--refresh-interval", "0",
            "--config", locations.configuration.path,
            "--account-vault-namespace", "quotio-macos",
            "--account-data-dir", locations.accounts.path,
        ]
        if let proxyAuthDirectory {
            process.arguments?.append(contentsOf: ["--cli-proxy-auth-dir", proxyAuthDirectory.path])
        }
        for provider in providers {
            process.arguments?.append(contentsOf: ["--provider", provider])
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "QUOTIO_SERVER_TOKEN")
        let searchPath = executableDirectories.map(\.path) + [environment["PATH"] ?? ""]
        environment["PATH"] = searchPath.filter { !$0.isEmpty }.joined(separator: ":")
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
        process.standardError = FileHandle.nullDevice
        let stream = outputStream(from: output)
        process.terminationHandler = { [weak self] terminated in
            let pid = terminated.processIdentifier
            Task { @MainActor [weak self] in
                guard self?.process?.processIdentifier == pid else { return }
                self?.process = nil
                self?.input = nil
                self?.output = nil
                self?.onUnexpectedTermination?()
            }
        }
        self.process = process
        self.input = input
        self.output = output

        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8))
            let bootstrap = try await bootstrap(from: stream)
            guard bootstrap.bootstrapVersion == 1,
                  bootstrap.apiVersion == 1,
                  bootstrap.pid == process.processIdentifier,
                  bootstrap.host == "127.0.0.1",
                  (1...65_535).contains(bootstrap.port),
                  let baseURL = URL(string: "http://127.0.0.1:\(bootstrap.port)") else {
                throw QuotioCLIServerError.incompatibleBootstrap
            }
            return QuotioCLIConnection(baseURL: baseURL, token: token)
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

    private func makeLocations() throws -> (configuration: URL, accounts: URL) {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("app.bytrong.quotio", isDirectory: true)
        let accounts = accountDataDirectory
            ?? support.appendingPathComponent("QuotioCLI", isDirectory: true)
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        let configuration = configurationURL ?? support.appendingPathComponent("quotio-cli.toml")
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
