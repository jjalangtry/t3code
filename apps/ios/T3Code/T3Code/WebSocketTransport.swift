import Foundation

// MARK: - WebSocket Transport

/// Low-level WebSocket transport matching the T3 Code server protocol.
/// Handles connection, reconnection, request/response correlation, and push event dispatch.
/// Not actor-isolated — all mutable state is accessed only from MainActor call sites.
final class WebSocketTransport: @unchecked Sendable {

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var nextId: Int = 1
    private var pending: [String: PendingRequest] = [:]
    private var pushListeners: [String: [@Sendable (Any) -> Void]] = [:]
    private var reconnectAttempt: Int = 0
    private var reconnectWork: Task<Void, Never>?
    private var disposed = false
    private var receiveWork: Task<Void, Never>?

    private let url: URL

    private static let requestTimeoutSeconds: TimeInterval = 60
    private static let reconnectDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    struct PendingRequest {
        let continuation: CheckedContinuation<Any?, any Error>
        let timeoutTask: Task<Void, Never>
    }

    init(url: URL) {
        self.url = url
    }

    // MARK: - Lifecycle

    @MainActor
    func connect() {
        guard !disposed else { return }

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        reconnectAttempt = 0

        receiveWork?.cancel()
        receiveWork = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    @MainActor
    func disconnect() {
        disposed = true
        reconnectWork?.cancel()
        reconnectWork = nil
        receiveWork?.cancel()
        receiveWork = nil

        for (id, req) in pending {
            req.timeoutTask.cancel()
            req.continuation.resume(throwing: TransportError.disposed)
            pending.removeValue(forKey: id)
        }

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Request / Response

    @MainActor
    func request<T: Decodable>(_ method: String, params: [String: Any]? = nil) async throws -> T {
        let result = try await requestRaw(method, params: params)
        let data = try JSONSerialization.data(withJSONObject: result as Any)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @MainActor
    func requestRaw(_ method: String, params: [String: Any]? = nil) async throws -> Any? {
        let id = String(nextId)
        nextId += 1

        var body: [String: Any] = ["_tag": method]
        if let params {
            for (key, value) in params {
                body[key] = value
            }
        }
        let envelope: [String: Any] = ["id": id, "body": body]

        let jsonData = try JSONSerialization.data(withJSONObject: envelope)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw TransportError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, any Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.handleTimeout(id: id, method: method) }
            }

            pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)

            let ws = webSocketTask
            Task {
                try? await ws?.send(.string(jsonString))
            }
        }
    }

    @MainActor
    func requestVoid(_ method: String, params: [String: Any]? = nil) async throws {
        _ = try await requestRaw(method, params: params)
    }

    // MARK: - Push subscriptions

    @MainActor
    func subscribe(_ channel: String, listener: @escaping @Sendable (Any) -> Void) {
        pushListeners[channel, default: []].append(listener)
    }

    // MARK: - Internals

    private func receiveLoop() async {
        guard let ws = webSocketTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                let text: String?
                switch message {
                case .string(let s):
                    text = s
                case .data(let d):
                    text = String(data: d, encoding: .utf8)
                @unknown default:
                    text = nil
                }
                if let text {
                    await MainActor.run { self.handleMessage(text) }
                }
            } catch {
                await MainActor.run {
                    if !self.disposed {
                        self.scheduleReconnect()
                    }
                }
                return
            }
        }
    }

    @MainActor
    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Push event
        if let type = json["type"] as? String, type == "push",
           let channel = json["channel"] as? String {
            let payload = json["data"] as Any
            if let listeners = pushListeners[channel] {
                for listener in listeners {
                    listener(payload)
                }
            }
            return
        }

        // Response to a request
        guard let id = json["id"] as? String,
              let req = pending.removeValue(forKey: id) else {
            return
        }
        req.timeoutTask.cancel()

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            req.continuation.resume(throwing: TransportError.serverError(message))
        } else {
            req.continuation.resume(returning: json["result"])
        }
    }

    @MainActor
    private func handleTimeout(id: String, method: String) {
        guard let req = pending.removeValue(forKey: id) else { return }
        req.continuation.resume(throwing: TransportError.timeout(method))
    }

    @MainActor
    private func scheduleReconnect() {
        guard !disposed else { return }
        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1

        reconnectWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.connect() }
        }
    }
}

// MARK: - Errors

enum TransportError: LocalizedError {
    case encodingFailed
    case timeout(String)
    case serverError(String)
    case disposed

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode request"
        case .timeout(let method): return "Request timed out: \(method)"
        case .serverError(let message): return message
        case .disposed: return "Transport disposed"
        }
    }
}
