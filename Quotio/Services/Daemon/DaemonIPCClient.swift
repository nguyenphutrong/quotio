//
//  DaemonIPCClient.swift
//  Quotio
//

import Foundation

// MARK: - Connection State

enum IPCConnectionState: Sendable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    case failed(String)
    
    var description: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed(let reason): return "failed(\(reason))"
        }
    }
}

// MARK: - Pending Request

private struct PendingRequest: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Error>
    let timeoutTask: Task<Void, Never>
    let method: String
    let createdAt: Date
}

// MARK: - DaemonIPCClient

actor DaemonIPCClient {
    
    private var fileDescriptor: Int32 = -1
    private var requestIdCounter = 0
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var buffer = Data()
    private let timeout: TimeInterval
    private var connectTask: Task<Void, Error>?
    private var readerThread: Thread?
    private var shouldStopReader = false
    
    private(set) var state: IPCConnectionState = .disconnected
    
    static let shared = DaemonIPCClient()
    
    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }
    
    nonisolated var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        return "\(home)/Library/Caches/quotio-cli/quotio.sock"
        #else
        return "\(home)/.cache/quotio-cli/quotio.sock"
        #endif
    }
    
    var isConnected: Bool {
        if case .connected = state, fileDescriptor >= 0 {
            return true
        }
        return false
    }
    
    func connect() async throws {
        if case .connected = state, fileDescriptor >= 0 {
            log("connect: already connected")
            return
        }
        
        if let existingTask = connectTask {
            log("connect: waiting for existing connection attempt")
            try await existingTask.value
            return
        }
        
        let task = Task<Void, Error> {
            try await performConnect()
        }
        connectTask = task
        
        do {
            try await task.value
            connectTask = nil
        } catch {
            connectTask = nil
            throw error
        }
    }
    
    private func performConnect() async throws {
        state = .connecting
        
        let path = socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            log("performConnect: socket not found at \(path)")
            state = .failed("Daemon not running")
            throw IPCClientError.daemonNotRunning
        }
        
        log("performConnect: connecting to \(path)")
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let err = errno
            log("performConnect: socket() failed, errno=\(err)")
            state = .failed("Failed to create socket")
            throw IPCClientError.connectionFailed("Failed to create socket: errno \(err)")
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
        
        if connectResult != 0 {
            let err = errno
            Darwin.close(fd)
            log("performConnect: connect() failed, errno=\(err)")
            state = .failed("Connection refused")
            throw IPCClientError.connectionFailed("Failed to connect: errno \(err)")
        }
        
        fileDescriptor = fd
        shouldStopReader = false
        state = .connected
        log("performConnect: connected successfully, fd=\(fd)")
        
        startReaderThread()
    }
    
    private func startReaderThread() {
        let fd = fileDescriptor
        guard fd >= 0 else { return }
        
        let thread = Thread { [weak self] in
            self?.readerLoop(fd: fd)
        }
        thread.name = "quotio.ipc.reader"
        thread.qualityOfService = .userInitiated
        readerThread = thread
        thread.start()
    }
    
    nonisolated private func readerLoop(fd: Int32) {
        var readBuffer = [UInt8](repeating: 0, count: 8192)
        var localBuffer = Data()
        
        while true {
            let bytesRead = read(fd, &readBuffer, readBuffer.count)
            
            if bytesRead > 0 {
                localBuffer.append(contentsOf: readBuffer[0..<bytesRead])
                
                while let newlineIndex = localBuffer.firstIndex(of: 0x0A) {
                    let messageData = Data(localBuffer[localBuffer.startIndex..<newlineIndex])
                    localBuffer = Data(localBuffer[localBuffer.index(after: newlineIndex)...])
                    
                    Task { [weak self] in
                        await self?.handleMessage(messageData)
                    }
                }
            } else if bytesRead == 0 {
                NSLog("[DaemonIPCClient] readerLoop: EOF received")
                Task { [weak self] in
                    await self?.handleDisconnect(error: nil)
                }
                break
            } else {
                let err = errno
                if err == EINTR {
                    continue
                }
                NSLog("[DaemonIPCClient] readerLoop: read error errno=%d", err)
                Task { [weak self] in
                    await self?.handleDisconnect(error: IPCClientError.connectionFailed("Read error: \(err)"))
                }
                break
            }
        }
    }
    
    func disconnect() {
        guard fileDescriptor >= 0 else { return }
        
        log("disconnect: closing connection")
        
        shouldStopReader = true
        
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (id, request) in pending {
            log("disconnect: failing pending request id=\(id) method=\(request.method)")
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: IPCClientError.disconnected)
        }
        
        buffer = Data()
        state = .disconnected
        log("disconnect: completed")
    }
    
    private func handleMessage(_ data: Data) {
        struct IdExtractor: Decodable {
            let id: Int?
        }
        
        do {
            let idInfo = try JSONDecoder().decode(IdExtractor.self, from: data)
            guard let id = idInfo.id else {
                log("handleMessage: no id field, len=\(data.count)")
                return
            }
            
            guard let pending = pendingRequests.removeValue(forKey: id) else {
                log("handleMessage: stale response for id=\(id), pending=\(pendingRequests.count)")
                return
            }
            
            let elapsed = Date().timeIntervalSince(pending.createdAt)
            log("handleMessage: matched response for id=\(id) method=\(pending.method) elapsed=\(String(format: "%.2f", elapsed))s")
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            log("handleMessage: decode error=\(error), len=\(data.count), preview=\(preview)")
        }
    }
    
    private func handleDisconnect(error: Error?) {
        if case .connected = state {
            log("handleDisconnect: connection lost, error=\(error?.localizedDescription ?? "none")")
            disconnect()
        }
    }
    
    func call<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ method: IPCMethod,
        params: P
    ) async throws -> R {
        try await connect()
        
        let fd = fileDescriptor
        guard fd >= 0 else {
            throw IPCClientError.notConnected
        }
        
        requestIdCounter += 1
        let id = requestIdCounter
        
        let request = IPCRequest(id: id, method: method.rawValue, params: params)
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(0x0A)
        
        log("call: id=\(id) method=\(method.rawValue)")
        
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            let timeoutNanos = UInt64(timeout) * 1_000_000_000
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    await self?.handleTimeout(id: id)
                } catch {}
            }
            
            let pending = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask,
                method: method.rawValue,
                createdAt: Date()
            )
            pendingRequests[id] = pending
            
            let written = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress, ptr.count)
            }
            
            if written != data.count {
                if pendingRequests.removeValue(forKey: id) != nil {
                    timeoutTask.cancel()
                    log("call: write failed for id=\(id), written=\(written) expected=\(data.count)")
                    continuation.resume(throwing: IPCClientError.connectionFailed("Write failed"))
                }
            }
        }
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(IPCResponse<R>.self, from: responseData)
        
        if let error = response.error {
            log("call: id=\(id) returned error: \(error.message)")
            throw error
        }
        
        guard let result = response.result else {
            throw IPCClientError.noResult
        }
        
        log("call: id=\(id) completed successfully")
        return result
    }
    
    private func handleTimeout(id: Int) {
        if let pending = pendingRequests.removeValue(forKey: id) {
            let elapsed = Date().timeIntervalSince(pending.createdAt)
            log("handleTimeout: id=\(id) method=\(pending.method) elapsed=\(String(format: "%.2f", elapsed))s")
            pending.continuation.resume(throwing: IPCClientError.timeout)
        }
    }
    
    func call<R: Decodable & Sendable>(_ method: IPCMethod) async throws -> R {
        try await call(method, params: IPCEmptyParams())
    }
    
    private nonisolated func log(_ message: String) {
        NSLog("[DaemonIPCClient] %@", message)
    }
}

// MARK: - Convenience Methods

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
    
    func deleteAuth(name: String) async throws -> IPCAuthDeleteResult {
        try await call(.authDelete, params: IPCAuthDeleteParams(name: name))
    }
    
    func startOAuth(provider: String, projectId: String? = nil, isWebUI: Bool = true) async throws -> IPCAuthOAuthResult {
        try await call(.authOAuth, params: IPCAuthOAuthParams(provider: provider, projectId: projectId, isWebUI: isWebUI))
    }
    
    func pollOAuthStatus(state: String) async throws -> IPCAuthPollResult {
        try await call(.authPoll, params: IPCAuthPollParams(state: state))
    }
    
    func fetchLogs(after: Int? = nil) async throws -> IPCLogsFetchResult {
        try await call(.logsFetch, params: IPCLogsFetchParams(after: after))
    }
    
    func clearLogs() async throws -> IPCLogsClearResult {
        try await call(.logsClear)
    }
    
    func getRoutingStrategy() async throws -> IPCConfigRoutingResult {
        try await call(.configRouting, params: IPCConfigRoutingParams())
    }
    
    func setRoutingStrategy(_ strategy: String) async throws -> IPCConfigRoutingResult {
        try await call(.configRouting, params: IPCConfigRoutingParams(strategy: strategy))
    }
    
    func getDebugMode() async throws -> IPCConfigDebugResult {
        try await call(.configDebug, params: IPCConfigDebugParams())
    }
    
    func setDebugMode(_ enabled: Bool) async throws -> IPCConfigDebugResult {
        try await call(.configDebug, params: IPCConfigDebugParams(enabled: enabled))
    }
    
    func getProxyUrl() async throws -> IPCConfigProxyUrlResult {
        try await call(.configProxyUrl, params: IPCConfigProxyUrlParams())
    }
    
    func setProxyUrl(_ url: String?) async throws -> IPCConfigProxyUrlResult {
        try await call(.configProxyUrl, params: IPCConfigProxyUrlParams(url: url))
    }
    
    func deleteAllAuth() async throws -> IPCAuthDeleteAllResult {
        try await call(.authDeleteAll, params: IPCAuthDeleteAllParams())
    }
    
    func setAuthDisabled(name: String, disabled: Bool) async throws -> IPCAuthSetDisabledResult {
        try await call(.authSetDisabled, params: IPCAuthSetDisabledParams(name: name, disabled: disabled))
    }
    
    func getAuthModels(name: String) async throws -> IPCAuthModelsResult {
        try await call(.authModels, params: IPCAuthModelsParams(name: name))
    }
    
    func getProxyConfigAll() async throws -> IPCProxyConfigGetAllResult {
        try await call(.proxyConfigGetAll)
    }
    
    func getProxyConfig(key: String) async throws -> IPCProxyConfigGetResult {
        try await call(.proxyConfigGet, params: IPCProxyConfigGetParams(key: key))
    }
    
    func setProxyConfig(key: String, value: Any) async throws -> IPCProxyConfigSetResult {
        try await call(.proxyConfigSet, params: IPCProxyConfigSetParams(key: key, value: IPCAnyCodable(value)))
    }
    
    func listApiKeys() async throws -> IPCApiKeysListResult {
        try await call(.apiKeysList)
    }
    
    func addApiKey() async throws -> IPCApiKeysAddResult {
        try await call(.apiKeysAdd)
    }
    
    func deleteApiKey(_ key: String) async throws -> IPCApiKeysDeleteResult {
        try await call(.apiKeysDelete, params: IPCApiKeysDeleteParams(key: key))
    }
    
    func proxyHealthCheck() async throws -> IPCProxyHealthCheckResult {
        try await call(.proxyHealthCheck)
    }
    
    func getProxyLatestVersion() async throws -> IPCProxyLatestVersionResult {
        try await call(.proxyLatestVersion)
    }
    
    func apiCall(
        authIndex: String?,
        method: String,
        url: String,
        header: [String: String]?,
        data: String?
    ) async throws -> IPCApiCallResult {
        try await call(.apiCall, params: IPCApiCallParams(
            authIndex: authIndex,
            method: method,
            url: url,
            header: header,
            data: data
        ))
    }
    
    func remoteSetConfig(
        endpointURL: String,
        displayName: String? = nil,
        managementKey: String? = nil,
        verifySSL: Bool? = nil,
        timeoutSeconds: Int? = nil
    ) async throws -> IPCRemoteSetConfigResult {
        try await call(.remoteSetConfig, params: IPCRemoteSetConfigParams(
            endpointURL: endpointURL,
            displayName: displayName,
            managementKey: managementKey,
            verifySSL: verifySSL,
            timeoutSeconds: timeoutSeconds
        ))
    }
    
    func remoteGetConfig() async throws -> IPCRemoteGetConfigResult {
        try await call(.remoteGetConfig)
    }
    
    func remoteClearConfig() async throws -> IPCRemoteClearConfigResult {
        try await call(.remoteClearConfig)
    }
    
    func remoteTestConnection(
        endpointURL: String,
        managementKey: String? = nil,
        timeoutSeconds: Int? = nil
    ) async throws -> IPCRemoteTestConnectionResult {
        try await call(.remoteTestConnection, params: IPCRemoteTestConnectionParams(
            endpointURL: endpointURL,
            managementKey: managementKey,
            timeoutSeconds: timeoutSeconds
        ))
    }
    
    func setLocalManagementKey(_ key: String) async throws -> IPCConfigSetResult {
        try await call(.configSetLocalManagementKey, params: IPCConfigSetLocalManagementKeyParams(key: key))
    }
    
    func getLocalManagementKey() async throws -> IPCConfigGetLocalManagementKeyResult {
        try await call(.configGetLocalManagementKey)
    }
    
    func refreshQuotaTokens(provider: String? = nil) async throws -> IPCQuotaRefreshTokensResult {
        try await call(.quotaRefreshTokens, params: IPCQuotaRefreshTokensParams(provider: provider))
    }
    
    func fetchCopilotAvailableModels() async throws -> IPCCopilotAvailableModelsResult {
        try await call(.copilotAvailableModels)
    }
    
    // MARK: - Copilot Device Code
    
    func copilotStartDeviceCode() async throws -> IPCCopilotStartDeviceCodeResult {
        try await call(.authCopilotStartDeviceCode)
    }
    
    func copilotPollDeviceCode(deviceCode: String) async throws -> IPCCopilotPollDeviceCodeResult {
        try await call(.authCopilotPollDeviceCode, params: IPCCopilotPollDeviceCodeParams(deviceCode: deviceCode))
    }
    
    func copilotCancel() async throws -> IPCConfigSetResult {
        try await call(.authCopilotCancel)
    }
    
    // MARK: - Kiro Authentication
    
    func kiroStartGoogle() async throws -> IPCKiroGoogleAuthResult {
        try await call(.authKiroGoogle)
    }
    
    func kiroPollGoogle() async throws -> IPCKiroGooglePollResult {
        try await call(.authKiroPollGoogle)
    }
    
    func kiroCancelGoogle() async throws -> IPCConfigSetResult {
        try await call(.authKiroCancelGoogle)
    }
    
    func kiroStartAws() async throws -> IPCKiroAwsAuthResult {
        try await call(.authKiroAws)
    }
    
    func kiroPollAws() async throws -> IPCKiroAwsPollResult {
        try await call(.authKiroPollAws)
    }
    
    func kiroCancelAws() async throws -> IPCConfigSetResult {
        try await call(.authKiroCancelAws)
    }
    
    func kiroImport() async throws -> IPCKiroImportResult {
        try await call(.authKiroImport)
    }
    
    func fetchStats() async throws -> IPCStatsGetResult {
        try await call(.statsGet)
    }
    
    func listRequestStats(provider: String? = nil, minutes: Int? = nil) async throws -> IPCStatsListResult {
        try await call(.statsList, params: IPCStatsListParams(provider: provider, minutes: minutes))
    }
    
    func clearRequestStats() async throws -> IPCStatsClearResult {
        try await call(.statsClear)
    }
}

// MARK: - Error Types

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
