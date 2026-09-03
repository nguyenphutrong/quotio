import Foundation
import Network
import QuotioApplication

public final class LoopbackOAuthCallbackTransport: OAuthCallbackTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: URL?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    public func start(preferredPort: UInt16? = nil) async throws -> UInt16 {
        await stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters, on: .any)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.listener = listener
                    startContinuation = continuation
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else {
                            fail(OAuthFlowFailure.invalidResponse)
                            return
                        }
                        completeStart(port)
                    case .failed(let error):
                        fail(error)
                    case .cancelled:
                        fail(CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: DispatchQueue(label: "dev.quotio.oauth.callback"))
            }
        } onCancel: {
            fail(CancellationError())
        }
    }

    public func waitForCallback(timeout: Duration = .seconds(180)) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending: URL? = lock.withLock {
                    if let pendingCallback {
                        self.pendingCallback = nil
                        return pendingCallback
                    }
                    callbackContinuation = continuation
                    timeoutTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                            self?.fail(OAuthFlowFailure.expired)
                        } catch {
                            return
                        }
                    }
                    return nil
                }
                if let pending {
                    stopListener()
                    continuation.resume(returning: pending)
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }

    public func stop() async {
        fail(CancellationError())
    }

    private func completeStart(_ port: UInt16) {
        let continuation = lock.withLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume(returning: port)
    }

    private func completeCallback(_ url: URL) {
        let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
            let continuation = callbackContinuation
            callbackContinuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            if continuation == nil {
                pendingCallback = url
            }
            return continuation
        }
        stopListener()
        continuation?.resume(returning: url)
    }

    private func fail(_ error: any Error) {
        let state = lock.withLock { () -> (
            CheckedContinuation<UInt16, Error>?,
            CheckedContinuation<URL, Error>?,
            NWListener?,
            Task<Void, Never>?
        ) in
            let state = (startContinuation, callbackContinuation, listener, timeoutTask)
            startContinuation = nil
            callbackContinuation = nil
            listener = nil
            timeoutTask = nil
            pendingCallback = nil
            return state
        }
        state.3?.cancel()
        state.2?.stateUpdateHandler = nil
        state.2?.cancel()
        state.0?.resume(throwing: error)
        state.1?.resume(throwing: error)
    }

    private func stopListener() {
        let listener = lock.withLock {
            let listener = self.listener
            self.listener = nil
            return listener
        }
        listener?.stateUpdateHandler = nil
        listener?.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "dev.quotio.oauth.callback.connection"))
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
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            completeCallback(url)
        }
    }
}
