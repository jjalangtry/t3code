import Foundation

// MARK: - High-level API wrapping WebSocket transport

/// Mirrors the NativeApi from the web client, providing typed methods
/// for orchestration, git, and server operations.
@MainActor
final class T3CodeAPI {
    let transport: WebSocketTransport

    init(transport: WebSocketTransport) {
        self.transport = transport
    }

    // MARK: - Orchestration

    func getSnapshot() async throws -> OrchestrationReadModel {
        try await transport.request("orchestration.getSnapshot")
    }

    func dispatchCommand(_ command: [String: Any]) async throws {
        try await transport.requestVoid("orchestration.dispatchCommand", params: ["command": command])
    }

    func replayEvents(fromSequence: Int) async throws -> [OrchestrationEvent] {
        try await transport.request("orchestration.replayEvents", params: [
            "fromSequenceExclusive": fromSequence,
        ])
    }

    // MARK: - Orchestration commands (convenience)

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    func sendMessage(
        threadId: ThreadId,
        messageId: MessageId,
        text: String,
        runtimeMode: RuntimeMode = .fullAccess,
        interactionMode: InteractionMode = .default
    ) async throws {
        let command: [String: Any] = [
            "type": "thread.turn.start",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "message": [
                "messageId": messageId,
                "role": "user",
                "text": text,
                "attachments": [[String: Any]](),
            ] as [String: Any],
            "runtimeMode": runtimeMode.rawValue,
            "interactionMode": interactionMode.rawValue,
            "createdAt": isoNow(),
        ]
        try await dispatchCommand(command)
    }

    func interruptTurn(threadId: ThreadId, turnId: TurnId? = nil) async throws {
        var command: [String: Any] = [
            "type": "thread.turn.interrupt",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "createdAt": isoNow(),
        ]
        if let turnId {
            command["turnId"] = turnId
        }
        try await dispatchCommand(command)
    }

    func createThread(
        projectId: ProjectId,
        title: String,
        model: String,
        runtimeMode: RuntimeMode = .fullAccess,
        interactionMode: InteractionMode = .default
    ) async throws -> ThreadId {
        let threadId = UUID().uuidString
        var command: [String: Any] = [
            "type": "thread.create",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "projectId": projectId,
            "title": title,
            "model": model,
            "runtimeMode": runtimeMode.rawValue,
            "interactionMode": interactionMode.rawValue,
            "createdAt": isoNow(),
        ]
        command["branch"] = nil as String?
        command["worktreePath"] = nil as String?
        try await dispatchCommand(command)
        return threadId
    }

    func deleteThread(threadId: ThreadId) async throws {
        let command: [String: Any] = [
            "type": "thread.delete",
            "commandId": UUID().uuidString,
            "threadId": threadId,
        ]
        try await dispatchCommand(command)
    }

    func respondToApproval(
        threadId: ThreadId,
        requestId: ApprovalRequestId,
        decision: String
    ) async throws {
        let command: [String: Any] = [
            "type": "thread.approval.respond",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "requestId": requestId,
            "decision": decision,
            "createdAt": isoNow(),
        ]
        try await dispatchCommand(command)
    }

    func stopSession(threadId: ThreadId) async throws {
        let command: [String: Any] = [
            "type": "thread.session.stop",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "createdAt": isoNow(),
        ]
        try await dispatchCommand(command)
    }

    // MARK: - Server

    func getServerConfig() async throws -> Any? {
        try await transport.requestRaw("server.getConfig")
    }

    // MARK: - Push event subscriptions

    func onDomainEvent(_ handler: @escaping @MainActor (OrchestrationEvent) -> Void) {
        transport.subscribe("orchestration.domainEvent") { data in
            guard let dict = data as? [String: Any] else { return }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let event = try? JSONDecoder().decode(OrchestrationEvent.self, from: jsonData) else { return }
            Task { @MainActor in handler(event) }
        }
    }

    func onWelcome(_ handler: @escaping @MainActor (WsWelcomePayload) -> Void) {
        transport.subscribe("server.welcome") { data in
            guard let dict = data as? [String: Any] else { return }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let payload = try? JSONDecoder().decode(WsWelcomePayload.self, from: jsonData) else { return }
            Task { @MainActor in handler(payload) }
        }
    }

    func onServerConfigUpdated(_ handler: @escaping @MainActor (ServerConfigUpdatedPayload) -> Void) {
        transport.subscribe("server.configUpdated") { data in
            guard let dict = data as? [String: Any] else { return }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let payload = try? JSONDecoder().decode(ServerConfigUpdatedPayload.self, from: jsonData) else { return }
            Task { @MainActor in handler(payload) }
        }
    }
}
