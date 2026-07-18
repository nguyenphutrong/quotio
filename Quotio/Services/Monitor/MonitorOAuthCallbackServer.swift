import Foundation
import Network

nonisolated final class MonitorOAuthCallbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: URL?
    private var timeoutWorkItem: DispatchWorkItem?

    func start(preferredPort: UInt16? = nil) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters, on: .any)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port?.rawValue else {
                        continuation.resume(throwing: MonitorOAuthError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "dev.quotio.monitor-oauth"))
        }
    }

    func waitForCallback(timeout: Duration = .seconds(180)) async throws -> URL {
        let components = timeout.components
        let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let pendingCallback {
                    self.pendingCallback = nil
                    lock.unlock()
                    listener?.cancel()
                    listener = nil
                    continuation.resume(returning: pendingCallback)
                    return
                }
                callbackContinuation = continuation
                let workItem = DispatchWorkItem { [weak self] in
                    self?.completeCallback(error: MonitorOAuthError.expired)
                }
                timeoutWorkItem = workItem
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: workItem)
            }
        } onCancel: {
            completeCallback(error: CancellationError())
        }
    }

    func stop() {
        completeCallback(error: CancellationError())
    }

    private func completeCallback(url: URL? = nil, error: Error? = nil) {
        lock.lock()
        let continuation = callbackContinuation
        callbackContinuation = nil
        let timeoutWorkItem = timeoutWorkItem
        self.timeoutWorkItem = nil
        if continuation == nil, let url {
            pendingCallback = url
        }
        let listener = listener
        self.listener = nil
        lock.unlock()
        timeoutWorkItem?.cancel()
        listener?.cancel()
        if let url, let continuation {
            continuation.resume(returning: url)
        } else if let error, let continuation {
            continuation.resume(throwing: error)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "dev.quotio.monitor-oauth.connection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2,
                  let url = URL(string: "http://localhost\(parts[1])") else {
                connection.cancel()
                return
            }
            let body = "<html><body><h2>Authentication complete</h2><p>You can return to Quotio.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            completeCallback(url: url)
        }
    }
}
