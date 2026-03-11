import Foundation

// MARK: - High-level API wrapping WebSocket transport

/// Mirrors the NativeApi from the web client, providing typed methods
/// for orchestration, git, and server operations.
nonisolated final class T3CodeAPI: Sendable {
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
        attachments: [PendingComposerAttachment] = [],
        runtimeMode: RuntimeMode = .fullAccess,
        interactionMode: InteractionMode = .default
    ) async throws {
        let encodedAttachments = attachments.map { attachment in
            [
                "type": "image",
                "name": attachment.name,
                "mimeType": attachment.mimeType,
                "sizeBytes": attachment.sizeBytes,
                "dataUrl": attachment.dataURL,
            ] as [String: Any]
        }

        let command: [String: Any] = [
            "type": "thread.turn.start",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "message": [
                "messageId": messageId,
                "role": "user",
                "text": text,
                "attachments": encodedAttachments,
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

    func createProject(workspaceRoot: String, title: String, defaultModel: String) async throws -> ProjectId {
        let projectId = UUID().uuidString
        let command: [String: Any] = [
            "type": "project.create",
            "commandId": UUID().uuidString,
            "projectId": projectId,
            "title": title,
            "workspaceRoot": workspaceRoot,
            "defaultModel": defaultModel,
            "createdAt": isoNow(),
        ]
        try await dispatchCommand(command)
        return projectId
    }

    func setThreadRuntimeMode(threadId: ThreadId, runtimeMode: RuntimeMode) async throws {
        let command: [String: Any] = [
            "type": "thread.runtime-mode.set",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "runtimeMode": runtimeMode.rawValue,
            "createdAt": isoNow(),
        ]
        try await dispatchCommand(command)
    }

    func setThreadInteractionMode(threadId: ThreadId, interactionMode: InteractionMode) async throws {
        let command: [String: Any] = [
            "type": "thread.interaction-mode.set",
            "commandId": UUID().uuidString,
            "threadId": threadId,
            "interactionMode": interactionMode.rawValue,
            "createdAt": isoNow(),
        ]
        try await dispatchCommand(command)
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

    // MARK: - Git

    func gitStatus(cwd: String) async throws -> GitStatusResult {
        try await transport.request("git.status", params: ["cwd": cwd])
    }

    func gitPull(cwd: String) async throws -> GitPullResult {
        try await transport.request("git.pull", params: ["cwd": cwd])
    }

    func gitListBranches(cwd: String) async throws -> GitListBranchesResult {
        try await transport.request("git.listBranches", params: ["cwd": cwd])
    }

    func gitCheckout(cwd: String, branch: String) async throws {
        try await transport.requestVoid("git.checkout", params: [
            "cwd": cwd,
            "branch": branch,
        ])
    }

    func gitRunStackedAction(
        cwd: String,
        action: GitStackedAction,
        commitMessage: String?,
        featureBranch: Bool? = nil
    ) async throws -> GitRunStackedActionResult {
        var params: [String: Any] = [
            "cwd": cwd,
            "action": action.rawValue,
        ]
        if let commitMessage, !commitMessage.isEmpty {
            params["commitMessage"] = commitMessage
        }
        if let featureBranch {
            params["featureBranch"] = featureBranch
        }
        return try await transport.request("git.runStackedAction", params: params)
    }

    // MARK: - Terminal

    func openTerminal(threadId: ThreadId, cwd: String, terminalId: String = "default") async throws {
        try await transport.requestVoid("terminal.open", params: [
            "threadId": threadId,
            "terminalId": terminalId,
            "cwd": cwd,
            "cols": 100,
            "rows": 32,
        ])
    }

    func writeTerminal(threadId: ThreadId, data: String, terminalId: String = "default") async throws {
        try await transport.requestVoid("terminal.write", params: [
            "threadId": threadId,
            "terminalId": terminalId,
            "data": data,
        ])
    }

    func clearTerminal(threadId: ThreadId, terminalId: String = "default") async throws {
        try await transport.requestVoid("terminal.clear", params: [
            "threadId": threadId,
            "terminalId": terminalId,
        ])
    }

    func closeTerminal(threadId: ThreadId, terminalId: String? = "default") async throws {
        var params: [String: Any] = [
            "threadId": threadId,
            "deleteHistory": true,
        ]
        if let terminalId {
            params["terminalId"] = terminalId
        }
        try await transport.requestVoid("terminal.close", params: params)
    }

    // MARK: - Push event subscriptions

    func onDomainEvent(_ handler: @escaping @Sendable (OrchestrationEvent) -> Void) async {
        await transport.subscribe("orchestration.domainEvent") { data in
            guard let dict = data as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let event = try? JSONDecoder().decode(OrchestrationEvent.self, from: jsonData) else { return }
            handler(event)
        }
    }

    func onWelcome(_ handler: @escaping @Sendable (WsWelcomePayload) -> Void) async {
        await transport.subscribe("server.welcome") { data in
            guard let dict = data as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let payload = try? JSONDecoder().decode(WsWelcomePayload.self, from: jsonData) else { return }
            handler(payload)
        }
    }

    func onServerConfigUpdated(_ handler: @escaping @Sendable (ServerConfigUpdatedPayload) -> Void) async {
        await transport.subscribe("server.configUpdated") { data in
            guard let dict = data as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let payload = try? JSONDecoder().decode(ServerConfigUpdatedPayload.self, from: jsonData) else { return }
            handler(payload)
        }
    }

    func onTerminalEvent(_ handler: @escaping @Sendable (TerminalEvent) -> Void) async {
        await transport.subscribe("terminal.event") { data in
            guard let dict = data as? [String: Any],
                  let type = dict["type"] as? String,
                  let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }

            switch type {
            case "started":
                guard let payload = try? JSONDecoder().decode(TerminalStartedEventPayload.self, from: jsonData) else {
                    return
                }
                handler(.started(payload))
            case "output":
                guard let payload = try? JSONDecoder().decode(TerminalOutputEventPayload.self, from: jsonData) else {
                    return
                }
                handler(.output(payload))
            case "exited":
                guard let payload = try? JSONDecoder().decode(TerminalExitedEventPayload.self, from: jsonData) else {
                    return
                }
                handler(.exited(payload))
            case "error":
                guard let payload = try? JSONDecoder().decode(TerminalErrorEventPayload.self, from: jsonData) else {
                    return
                }
                handler(.error(payload))
            case "cleared":
                guard let payload = try? JSONDecoder().decode(TerminalClearedEventPayload.self, from: jsonData) else {
                    return
                }
                handler(.cleared(payload))
            case "restarted":
                guard let payload = try? JSONDecoder().decode(TerminalRestartedEventPayload.self, from: jsonData) else {
                    return
                }
                handler(.restarted(payload))
            case "activity":
                guard let payload = try? JSONDecoder().decode(TerminalActivityEventPayload.self, from: jsonData) else {
                    return
                }
                handler(.activity(payload))
            default:
                break
            }
        }
    }
}
