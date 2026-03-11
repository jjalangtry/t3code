import Foundation

enum TransportLifecycleEvent: Sendable, Equatable {
    case connected(isReconnect: Bool)
    case connectionLost(message: String?)
}

actor WebSocketTransport {
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var nextId: Int = 1
    private var pending: [String: PendingRequest] = [:]
    private var pushListeners: [String: [@Sendable (Any) -> Void]] = [:]
    private var reconnectAttempt: Int = 0
    private var reconnectWork: Task<Void, Never>?
    private var receiveWork: Task<Void, Never>?
    private var connectionContinuation: CheckedContinuation<Void, any Error>?
    private var lifecycleHandler: (@Sendable (TransportLifecycleEvent) -> Void)?
    private var manuallyDisconnected = false
    private var hasConnectedSuccessfully = false

    private let url: URL

    private static let requestTimeoutSeconds: TimeInterval = 15
    private static let connectTimeoutSeconds: TimeInterval = 10
    private static let reconnectDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    struct PendingRequest {
        let continuation: CheckedContinuation<Any?, any Error>
        let timeoutTask: Task<Void, Never>
    }

    init(url: URL, session: URLSession = URLSession(configuration: .default)) {
        self.url = url
        self.session = session
    }

    func setLifecycleHandler(_ handler: @escaping @Sendable (TransportLifecycleEvent) -> Void) {
        lifecycleHandler = handler
    }

    func connect() async throws {
        guard !manuallyDisconnected else { throw TransportError.disposed }

        reconnectWork?.cancel()
        reconnectWork = nil
        receiveWork?.cancel()
        receiveWork = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        let isReconnectAttempt = hasConnectedSuccessfully

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(Self.connectTimeoutSeconds))
                await self?.failConnectionWaiter(with: TransportError.connectTimeout)
                throw TransportError.connectTimeout
            }

            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    self.connectionContinuation = continuation
                    self.receiveWork = Task { [weak self] in
                        await self?.receiveLoop(isReconnectAttempt: isReconnectAttempt)
                    }
                }
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func disconnect() {
        manuallyDisconnected = true
        reconnectWork?.cancel()
        reconnectWork = nil
        receiveWork?.cancel()
        receiveWork = nil

        failConnectionWaiter(with: TransportError.disposed)
        failAllPending(with: TransportError.disposed)

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    func request<T: Decodable>(_ method: String, params: [String: Any]? = nil) async throws -> T {
        let result = try await requestRaw(method, params: params)
        let data = try JSONSerialization.data(withJSONObject: result as Any)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func requestRaw(_ method: String, params: [String: Any]? = nil) async throws -> Any? {
        guard let ws = webSocketTask else {
            throw TransportError.notConnected
        }

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
                try? await Task.sleep(for: .seconds(Self.requestTimeoutSeconds))
                guard !Task.isCancelled else { return }
                await self?.handleTimeout(id: id, method: method)
            }

            pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)

            Task { [weak self] in
                do {
                    try await ws.send(.string(jsonString))
                } catch {
                    await self?.failPending(id: id, error: error)
                }
            }
        }
    }

    func requestVoid(_ method: String, params: [String: Any]? = nil) async throws {
        _ = try await requestRaw(method, params: params)
    }

    func subscribe(_ channel: String, listener: @escaping @Sendable (Any) -> Void) {
        pushListeners[channel, default: []].append(listener)
    }

    private func failPending(id: String, error: any Error) {
        guard let req = pending.removeValue(forKey: id) else { return }
        req.timeoutTask.cancel()
        req.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: any Error) {
        guard !pending.isEmpty else { return }
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func failConnectionWaiter(with error: any Error) {
        guard let continuation = connectionContinuation else { return }
        connectionContinuation = nil
        continuation.resume(throwing: error)
    }

    private func receiveLoop(isReconnectAttempt: Bool) async {
        guard let ws = webSocketTask else { return }
        var firstMessage = true

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()

                if firstMessage {
                    firstMessage = false
                    hasConnectedSuccessfully = true
                    reconnectAttempt = 0
                    if let continuation = connectionContinuation {
                        connectionContinuation = nil
                        continuation.resume()
                    }
                    lifecycleHandler?(.connected(isReconnect: isReconnectAttempt))
                }

                let text: String?
                switch message {
                case .string(let string):
                    text = string
                case .data(let data):
                    text = String(data: data, encoding: .utf8)
                @unknown default:
                    text = nil
                }

                if let text {
                    handleMessage(text)
                }
            } catch {
                if connectionContinuation != nil {
                    failConnectionWaiter(with: error)
                    cleanupAfterDisconnect()
                    return
                }

                cleanupAfterDisconnect()

                let message = ConnectionErrorFormatter.message(for: error)
                failAllPending(with: TransportError.connectionLost(message))

                if manuallyDisconnected || !hasConnectedSuccessfully {
                    return
                }

                lifecycleHandler?(.connectionLost(message: message))
                scheduleReconnect()
                return
            }
        }
    }

    private func cleanupAfterDisconnect() {
        receiveWork?.cancel()
        receiveWork = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

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

    private func handleTimeout(id: String, method: String) {
        guard let req = pending.removeValue(forKey: id) else { return }
        req.timeoutTask.cancel()
        req.continuation.resume(throwing: TransportError.timeout(method))
    }

    private func scheduleReconnect() {
        guard !manuallyDisconnected else { return }
        guard reconnectWork == nil else { return }

        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1

        reconnectWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        reconnectWork = nil
        guard !manuallyDisconnected else { return }

        do {
            try await connect()
        } catch {
            guard !manuallyDisconnected else { return }
            scheduleReconnect()
        }
    }
}

enum TransportError: LocalizedError, Equatable {
    case encodingFailed
    case timeout(String)
    case serverError(String)
    case disposed
    case notConnected
    case connectTimeout
    case connectionLost(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "Failed to encode request."
        case .timeout(let method):
            "Request timed out: \(method)"
        case .serverError(let message):
            message
        case .disposed:
            "Transport disposed."
        case .notConnected:
            "Not connected to server."
        case .connectTimeout:
            "Connection timed out. Check the server host or port and try again."
        case .connectionLost(let message):
            return message.isEmpty ? "Connection lost." : message
        }
    }
}
