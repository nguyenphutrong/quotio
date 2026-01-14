//
//  DaemonIPCClient.swift
//  Quotio
//

import Foundation

actor DaemonIPCClient {
    private var fileDescriptor: Int32 = -1
    private var requestIdCounter = 0
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var buffer = Data()
    private var readTask: Task<Void, Never>?
    private let timeout: TimeInterval
    
    static let shared = DaemonIPCClient()
    
    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }
    
    var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Must match quotio-cli daemon socket path: ~/.config/quotio/quotio.sock
        // Using XDG-compliant path for consistency with cross-platform CLI
        return "\(home)/.config/quotio/quotio.sock"
    }
    
    var isConnected: Bool {
        fileDescriptor >= 0
    }
    
    func connect() async throws {
        if fileDescriptor >= 0 { return }
        
        let path = socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw IPCClientError.daemonNotRunning
        }
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCClientError.connectionFailed("Failed to create socket")
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        withUnsafeMutableBytes(of: &addr.sun_path) { pathBuffer in
            path.withCString { cString in
                _ = memcpy(pathBuffer.baseAddress!, cString, min(pathBuffer.count - 1, strlen(cString) + 1))
            }
        }
        
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard connectResult == 0 else {
            close(fd)
            throw IPCClientError.connectionFailed("Failed to connect: errno \(errno)")
        }
        
        fileDescriptor = fd
        startReading()
    }
    
    func disconnect() {
        readTask?.cancel()
        readTask = nil
        
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        
        buffer = Data()
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: IPCClientError.disconnected)
        }
        pendingRequests.removeAll()
    }
    
    func call<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ method: IPCMethod,
        params: P
    ) async throws -> R {
        try await connect()
        
        requestIdCounter += 1
        let id = requestIdCounter
        
        let request = IPCRequest(id: id, method: method.rawValue, params: params)
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(0x0A)
        
        guard fileDescriptor >= 0 else {
            throw IPCClientError.notConnected
        }
        
        let written = data.withUnsafeBytes { ptr in
            write(fileDescriptor, ptr.baseAddress, ptr.count)
        }
        
        guard written == data.count else {
            throw IPCClientError.connectionFailed("Failed to write data")
        }
        
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = pendingRequests.removeValue(forKey: id) {
                    pending.resume(throwing: IPCClientError.timeout)
                }
            }
        }
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(IPCResponse<R>.self, from: responseData)
        
        if let error = response.error {
            throw error
        }
        
        guard let result = response.result else {
            throw IPCClientError.noResult
        }
        
        return result
    }
    
    func call<R: Decodable & Sendable>(_ method: IPCMethod) async throws -> R {
        try await call(method, params: IPCEmptyParams())
    }
    
    private func startReading() {
        let fd = fileDescriptor
        guard fd >= 0 else { return }
        
        readTask = Task.detached { [weak self] in
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            
            while !Task.isCancelled {
                let bytesRead = read(fd, &readBuffer, readBuffer.count)
                
                if bytesRead <= 0 {
                    await self?.disconnect()
                    break
                }
                
                let data = Data(readBuffer[0..<bytesRead])
                await self?.handleData(data)
            }
        }
    }
    
    private func handleData(_ data: Data) {
        buffer.append(data)
        
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let messageData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])
            processMessage(Data(messageData))
        }
    }
    
    private func processMessage(_ data: Data) {
        struct IdExtractor: Decodable {
            let id: Int?
        }
        
        guard let idInfo = try? JSONDecoder().decode(IdExtractor.self, from: data),
              let id = idInfo.id,
              let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }
        
        continuation.resume(returning: data)
    }
}

extension DaemonIPCClient {
    func ping() async throws -> IPCDaemonPingResult {
        try await call(.daemonPing)
    }
    
    func status() async throws -> IPCDaemonStatusResult {
        try await call(.daemonStatus)
    }
    
    func shutdown(graceful: Bool = true) async throws {
        let _: IPCConfigSetResult = try await call(.daemonShutdown, params: IPCDaemonShutdownParams(graceful: graceful))
    }
    
    func fetchQuotas(provider: String? = nil, forceRefresh: Bool = false) async throws -> IPCQuotaFetchResult {
        try await call(.quotaFetch, params: IPCQuotaFetchParams(provider: provider, forceRefresh: forceRefresh))
    }
    
    func listQuotas() async throws -> IPCQuotaListResult {
        try await call(.quotaList)
    }
    
    func detectAgents(forceRefresh: Bool = false) async throws -> IPCAgentDetectResult {
        try await call(.agentDetect, params: IPCAgentDetectParams(forceRefresh: forceRefresh))
    }
    
    func configureAgent(agent: String, mode: String) async throws -> IPCAgentConfigureResult {
        try await call(.agentConfigure, params: IPCAgentConfigureParams(agent: agent, mode: mode))
    }
    
    func startProxy(port: Int? = nil) async throws -> IPCProxyStartResult {
        try await call(.proxyStart, params: IPCProxyStartParams(port: port))
    }
    
    func stopProxy() async throws -> IPCProxyStopResult {
        try await call(.proxyStop)
    }
    
    func proxyStatus() async throws -> IPCProxyStatusResult {
        try await call(.proxyStatus)
    }
    
    func proxyHealth() async throws -> IPCProxyHealthResult {
        try await call(.proxyHealth)
    }
    
    func listAuth(provider: String? = nil) async throws -> IPCAuthListResult {
        try await call(.authList, params: IPCAuthListParams(provider: provider))
    }
}

enum IPCClientError: LocalizedError {
    case daemonNotRunning
    case connectionFailed(String)
    case notConnected
    case disconnected
    case timeout
    case noResult
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .notConnected:
            return "Not connected to daemon"
        case .disconnected:
            return "Disconnected from daemon"
        case .timeout:
            return "Request timed out"
        case .noResult:
            return "No result in response"
        }
    }
}
