//
//  ProxyBridge.swift
//  Quotio - TCP Proxy Bridge for Connection Management
//
//  This proxy sits between CLI tools and CLIProxyAPI to solve the stale
//  connection issue. By forcing "Connection: close" on every request,
//  we prevent HTTP keep-alive connections from becoming stale after idle periods.
//
//  Architecture:
//    CLI Tools → ProxyBridge (user port) → CLIProxyAPI (internal port)
//

import Foundation
import Network

/// A lightweight TCP proxy that forwards requests to CLIProxyAPI while
/// ensuring fresh connections by forcing "Connection: close" on all requests.
@MainActor
@Observable
final class ProxyBridge {
    
    // MARK: - Properties
    
    private var listener: NWListener?
    private let stateQueue = DispatchQueue(label: "io.quotio.proxy-bridge-state")
    
    /// The port this proxy listens on (user-facing port)
    private(set) var listenPort: UInt16 = 8080
    
    /// The port CLIProxyAPI runs on (internal port)
    private(set) var targetPort: UInt16 = 18080
    
    /// Target host (always localhost)
    private let targetHost = "127.0.0.1"
    
    /// Whether the proxy bridge is currently running
    private(set) var isRunning = false
    
    /// Last error message
    private(set) var lastError: String?
    
    /// Statistics: total requests forwarded
    private(set) var totalRequests: Int = 0
    
    /// Statistics: active connections count
    private(set) var activeConnections: Int = 0
    
    /// Maximum concurrent connections to prevent resource exhaustion
    private let maxActiveConnections = 100
    
    /// Connection timeout in seconds (for target connection setup)
    private let connectionTimeoutSeconds: UInt64 = 10
    
    /// Callback for request metadata extraction (for RequestTracker)
    var onRequestCompleted: ((RequestMetadata) -> Void)?
    
    // MARK: - Request Metadata
    
    /// Metadata extracted from proxied requests
    struct RequestMetadata: Sendable {
        let timestamp: Date
        let method: String
        let path: String
        let provider: String?
        let model: String?
        let statusCode: Int?
        let durationMs: Int
        let requestSize: Int
        let responseSize: Int
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Configuration
    
    /// Configure the proxy ports
    /// - Parameters:
    ///   - listenPort: The port to listen on (user-facing)
    ///   - targetPort: The port CLIProxyAPI runs on
    func configure(listenPort: UInt16, targetPort: UInt16) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }
    
    /// Calculate internal port from user port (offset by 10000)
    /// This is nonisolated so it can be called from static contexts
    nonisolated static func internalPort(from userPort: UInt16) -> UInt16 {
        // Use offset of 10000, but cap at valid port range
        // For high ports (55536+), use a smaller offset to stay within valid range
        let preferredPort = UInt32(userPort) + 10000
        if preferredPort <= 65535 {
            return UInt16(preferredPort)
        }
        // Fallback: use modular offset within high port range (49152-65535)
        let highPortBase: UInt16 = 49152
        let offset = userPort % 1000
        return highPortBase + offset
    }
    
    // MARK: - Lifecycle
    
    /// Starts the proxy bridge
    func start() {
        guard !isRunning else {
            NSLog("[ProxyBridge] Already running on port \(listenPort)")
            return
        }
        
        lastError = nil
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            guard let port = NWEndpoint.Port(rawValue: listenPort) else {
                lastError = "Invalid port: \(listenPort)"
                NSLog("[ProxyBridge] Invalid port: %d", listenPort)
                return
            }
            
            listener = try NWListener(using: parameters, on: port)
            
            listener?.stateUpdateHandler = { [weak self] state in
                guard let weakSelf = self else { return }
                Task { @MainActor in
                    weakSelf.handleListenerState(state)
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                guard let weakSelf = self else { return }
                Task { @MainActor in
                    weakSelf.handleNewConnection(connection)
                }
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
            
        } catch {
            lastError = error.localizedDescription
            NSLog("[ProxyBridge] Failed to start: \(error)")
        }
    }
    
    /// Stops the proxy bridge
    func stop() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
        }
        
        isRunning = false
        NSLog("[ProxyBridge] Stopped")
    }
    
    // MARK: - State Handling
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            NSLog("[ProxyBridge] Listening on port \(listenPort), forwarding to \(targetPort)")
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
            NSLog("[ProxyBridge] Failed: \(error)")
        case .cancelled:
            isRunning = false
            NSLog("[ProxyBridge] Cancelled")
        default:
            break
        }
    }
    
    // MARK: - Connection Handling
    
    private func handleNewConnection(_ connection: NWConnection) {
        if activeConnections >= maxActiveConnections {
            NSLog("[ProxyBridge] Connection limit reached (\(maxActiveConnections)), rejecting")
            connection.cancel()
            return
        }
        
        activeConnections += 1
        totalRequests += 1
        
        let connectionId = totalRequests
        let startTime = Date()
        
        NSLog("[ProxyBridge] New connection #\(connectionId)")
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let weakSelf = self else { return }
            if case .cancelled = state {
                Task { @MainActor in
                    weakSelf.activeConnections -= 1
                }
            } else if case .failed(let error) = state {
                NSLog("[ProxyBridge] Connection #\(connectionId) failed: \(error)")
                Task { @MainActor in
                    weakSelf.activeConnections -= 1
                }
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
        
        // Start receiving request
        receiveRequest(
            from: connection,
            connectionId: connectionId,
            startTime: startTime,
            accumulatedData: Data()
        )
    }
    
    // MARK: - Request Receiving (Iterative)
    
    /// Receives HTTP request data iteratively to avoid stack overflow
    private nonisolated func receiveRequest(
        from connection: NWConnection,
        connectionId: Int,
        startTime: Date,
        accumulatedData: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ProxyBridge] #\(connectionId) receive error: \(error)")
                connection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            
            var newData = accumulatedData
            newData.append(data)
            
            // Check if we have a complete HTTP request
            if let requestString = String(data: newData, encoding: .utf8),
               let headerEndRange = requestString.range(of: "\r\n\r\n") {
                
                let headerEndIndex = requestString.distance(from: requestString.startIndex, to: headerEndRange.upperBound)
                let headerPart = String(requestString.prefix(headerEndIndex))
                
                // Check Content-Length to determine if we have full body
                if let contentLengthLine = headerPart
                    .components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }) {
                    
                    let headerParts = contentLengthLine.components(separatedBy: ":")
                    guard headerParts.count > 1 else { return }
                    
                    let lengthStr = headerParts[1].trimmingCharacters(in: .whitespaces)
                    if let contentLength = Int(lengthStr) {
                        let currentBodyLength = newData.count - headerEndIndex
                        
                        // Need more data
                        if currentBodyLength < contentLength {
                            // Use async dispatch to break recursion stack
                            DispatchQueue.global(qos: .userInitiated).async {
                                self.receiveRequest(
                                    from: connection,
                                    connectionId: connectionId,
                                    startTime: startTime,
                                    accumulatedData: newData
                                )
                            }
                            return
                        }
                    }
                }
                
                // Complete request - process it
                self.processRequest(
                    data: newData,
                    connection: connection,
                    connectionId: connectionId,
                    startTime: startTime
                )
                
            } else if !isComplete {
                // Haven't found header end yet, continue receiving
                // Use async dispatch to break recursion stack
                DispatchQueue.global(qos: .userInitiated).async {
                    self.receiveRequest(
                        from: connection,
                        connectionId: connectionId,
                        startTime: startTime,
                        accumulatedData: newData
                    )
                }
            } else {
                // Complete but malformed
                self.processRequest(
                    data: newData,
                    connection: connection,
                    connectionId: connectionId,
                    startTime: startTime
                )
            }
        }
    }
    
    // MARK: - Request Processing
    
    private nonisolated func processRequest(
        data: Data,
        connection: NWConnection,
        connectionId: Int,
        startTime: Date
    ) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendError(to: connection, statusCode: 400, message: "Invalid request encoding")
            return
        }
        
        // Parse HTTP request line
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(to: connection, statusCode: 400, message: "Missing request line")
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            sendError(to: connection, statusCode: 400, message: "Invalid request format")
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        let httpVersion = parts[2]
        
        // Collect headers
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        
        // Extract body
        var body = ""
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            body = String(requestString[bodyRange.upperBound...])
        }
        
        // Extract metadata for tracking
        let metadata = extractMetadata(method: method, path: path, body: body)
        
        NSLog("[ProxyBridge] #\(connectionId) \(method) \(path)")
        
        // Forward to CLIProxyAPI - capture all variables explicitly for Sendable closure
        let capturedHeaders = headers
        let capturedBody = body
        let capturedMetadata = metadata
        let capturedDataCount = data.count
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let targetPortValue = self.targetPort
            let targetHostValue = self.targetHost
            self.forwardRequest(
                method: method,
                path: path,
                version: httpVersion,
                headers: capturedHeaders,
                body: capturedBody,
                originalConnection: connection,
                connectionId: connectionId,
                startTime: startTime,
                requestSize: capturedDataCount,
                metadata: capturedMetadata,
                targetPort: targetPortValue,
                targetHost: targetHostValue
            )
        }
    }
    
    // MARK: - Metadata Extraction
    
    private nonisolated func extractMetadata(method: String, path: String, body: String) -> (provider: String?, model: String?, method: String, path: String) {
        // Detect provider from path
        var provider: String?
        if path.contains("/anthropic/") || path.contains("/claude") {
            provider = "claude"
        } else if path.contains("/gemini/") || path.contains("/google/") {
            provider = "gemini"
        } else if path.contains("/openai/") || path.contains("/chat/completions") {
            provider = "openai"
        } else if path.contains("/copilot/") {
            provider = "copilot"
        } else if path.contains("codewhisperer") || path.contains("kiro") {
            provider = "kiro"
        }
        
        // Extract model from JSON body
        var model: String?
        if let bodyData = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let modelValue = json["model"] as? String {
            model = modelValue
            
            // Infer provider from model name if not already detected
            if provider == nil {
                if modelValue.hasPrefix("claude") {
                    provider = "claude"
                } else if modelValue.hasPrefix("gemini") || modelValue.hasPrefix("models/gemini") {
                    provider = "gemini"
                } else if modelValue.hasPrefix("gpt") || modelValue.hasPrefix("o1") || modelValue.hasPrefix("o3") {
                    provider = "openai"
                } else if modelValue.contains("kiro") || modelValue.contains("codewhisperer") {
                    provider = "kiro"
                }
            }
        }
        
        return (provider, model, method, path)
    }
    
    // MARK: - Request Forwarding
    
    private nonisolated func forwardRequest(
        method: String,
        path: String,
        version: String,
        headers: [(String, String)],
        body: String,
        originalConnection: NWConnection,
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        metadata: (provider: String?, model: String?, method: String, path: String),
        targetPort: UInt16,
        targetHost: String
    ) {
        // Create connection to CLIProxyAPI
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            NSLog("[ProxyBridge] Invalid target port: %d", targetPort)
            sendError(to: originalConnection, statusCode: 500, message: "Invalid target port")
            return
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: port)
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        let targetConnection = NWConnection(to: endpoint, using: parameters)
        
        let timeoutSeconds = self.connectionTimeoutSeconds
        
        // Use class-based wrapper for thread-safe cancellation flag
        final class TimeoutState: @unchecked Sendable {
            var cancelled = false
        }
        let timeoutState = TimeoutState()
        
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak targetConnection] in
            guard !timeoutState.cancelled else { return }
            guard let conn = targetConnection, conn.state != .ready else { return }
            NSLog("[ProxyBridge] #\(connectionId) target connection timeout after \(timeoutSeconds)s")
            conn.cancel()
        }
        
        targetConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                timeoutState.cancelled = true
                // Build forwarded request with Connection: close
                var forwardedRequest = "\(method) \(path) \(version)\r\n"
                
                // Forward headers, excluding ones we'll override
                let excludedHeaders: Set<String> = ["connection", "content-length", "host", "transfer-encoding"]
                for (name, value) in headers {
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedRequest += "\(name): \(value)\r\n"
                    }
                }
                
                // Add our headers
                forwardedRequest += "Host: \(targetHost):\(targetPort)\r\n"
                forwardedRequest += "Connection: close\r\n"  // KEY: Force fresh connections
                forwardedRequest += "Content-Length: \(body.utf8.count)\r\n"
                forwardedRequest += "\r\n"
                forwardedRequest += body
                
                guard let requestData = forwardedRequest.data(using: .utf8) else {
                    self.sendError(to: originalConnection, statusCode: 500, message: "Failed to encode request")
                    targetConnection.cancel()
                    return
                }
                
                targetConnection.send(content: requestData, completion: .contentProcessed { error in
                    if let error = error {
                        NSLog("[ProxyBridge] #\(connectionId) send error: \(error)")
                        targetConnection.cancel()
                        originalConnection.cancel()
                    } else {
                        // Start receiving response
                        self.receiveResponse(
                            from: targetConnection,
                            to: originalConnection,
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            metadata: metadata,
                            responseData: Data()
                        )
                    }
                })
                
            case .failed(let error):
                timeoutState.cancelled = true
                NSLog("[ProxyBridge] #\(connectionId) target connection failed: \(error)")
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Cannot connect to proxy")
                targetConnection.cancel()
                
            default:
                break
            }
        }
        
        targetConnection.start(queue: .global(qos: .userInitiated))
    }
    
    // MARK: - Response Streaming (Iterative)
    
    private nonisolated func receiveResponse(
        from targetConnection: NWConnection,
        to originalConnection: NWConnection,
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        metadata: (provider: String?, model: String?, method: String, path: String),
        responseData: Data
    ) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ProxyBridge] #\(connectionId) response error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            
            // Use let to avoid captured var warning - Data is already accumulated via parameter
            let accumulatedResponse: Data
            if let data = data, !data.isEmpty {
                var newAccumulated = responseData
                newAccumulated.append(data)
                accumulatedResponse = newAccumulated
            } else {
                accumulatedResponse = responseData
            }
            
            if let data = data, !data.isEmpty {
                // Forward chunk to client
                originalConnection.send(content: data, completion: .contentProcessed { sendError in
                    if let sendError = sendError {
                        NSLog("[ProxyBridge] #\(connectionId) send response error: \(sendError)")
                    }
                    
                    if isComplete {
                        // Request complete - record metadata
                        self.recordCompletion(
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            responseSize: accumulatedResponse.count,
                            responseData: accumulatedResponse,
                            metadata: metadata
                        )
                        
                        targetConnection.cancel()
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                            originalConnection.cancel()
                        })
                    } else {
                        // Continue streaming - use async dispatch to break recursion stack
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.receiveResponse(
                                from: targetConnection,
                                to: originalConnection,
                                connectionId: connectionId,
                                startTime: startTime,
                                requestSize: requestSize,
                                metadata: metadata,
                                responseData: accumulatedResponse
                            )
                        }
                    }
                })
            } else if isComplete {
                // Record completion
                self.recordCompletion(
                    connectionId: connectionId,
                    startTime: startTime,
                    requestSize: requestSize,
                    responseSize: accumulatedResponse.count,
                    responseData: accumulatedResponse,
                    metadata: metadata
                )
                
                targetConnection.cancel()
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })
            }
        }
    }
    
    // MARK: - Completion Recording
    
    private nonisolated func recordCompletion(
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        responseSize: Int,
        responseData: Data,
        metadata: (provider: String?, model: String?, method: String, path: String)
    ) {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        
        // Extract status code from response
        var statusCode: Int?
        if let responseString = String(data: responseData.prefix(100), encoding: .utf8),
           let statusLine = responseString.components(separatedBy: "\r\n").first {
            // Parse "HTTP/1.1 200 OK"
            let parts = statusLine.components(separatedBy: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        }
        
        NSLog("[ProxyBridge] #\(connectionId) completed: \(statusCode ?? 0) in \(durationMs)ms (\(requestSize)B → \(responseSize)B)")
        
        // Capture variables for Sendable closure
        let capturedStatusCode = statusCode
        let capturedMetadata = metadata
        
        // Notify callback on main thread
        Task { @MainActor [weak self] in
            let requestMetadata = RequestMetadata(
                timestamp: startTime,
                method: capturedMetadata.method,
                path: capturedMetadata.path,
                provider: capturedMetadata.provider,
                model: capturedMetadata.model,
                statusCode: capturedStatusCode,
                durationMs: durationMs,
                requestSize: requestSize,
                responseSize: responseSize
            )
            self?.onRequestCompleted?(requestMetadata)
        }
    }
    
    // MARK: - Error Response
    
    private nonisolated func sendError(to connection: NWConnection, statusCode: Int, message: String) {
        guard let bodyData = message.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        // Map status code to proper HTTP reason phrase
        let reasonPhrase: String
        switch statusCode {
        case 400: reasonPhrase = "Bad Request"
        case 404: reasonPhrase = "Not Found"
        case 500: reasonPhrase = "Internal Server Error"
        case 502: reasonPhrase = "Bad Gateway"
        case 503: reasonPhrase = "Service Unavailable"
        default: reasonPhrase = "Error"
        }
        
        // Build HTTP response with proper CRLF line endings (no leading whitespace)
        let headers = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n" +
            "Content-Type: text/plain\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        
        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        var responseData = Data()
        responseData.append(headerData)
        responseData.append(bodyData)
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
