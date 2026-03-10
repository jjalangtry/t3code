import Foundation
import Observation
import SwiftUI

// MARK: - App-level view model

/// Central observable state for the iOS client using @Observable (iOS 17+).
@MainActor
@Observable
final class SessionStore {
    // Connection
    var serverURL: String = ""
    var authToken: String = ""
    var isConnected = false
    var connectionError: String?

    // Welcome
    var welcome: WsWelcomePayload?

    // Data
    var projects: [OrchestrationProject] = []
    var threads: [OrchestrationThread] = []
    var providers: [ServerProviderStatus] = []
    var snapshotSequence: Int = 0

    // Navigation
    var selectedThreadId: ThreadId?

    // Streaming state
    var streamingMessageId: MessageId?
    var streamingText: String = ""

    private var transport: WebSocketTransport?
    private var api: T3CodeAPI?

    // MARK: - Persistence

    private static let urlKey = "t3code_server_url"
    private static let tokenKey = "t3code_auth_token"

    func loadSavedConnection() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        authToken = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
    }

    func saveConnection() {
        UserDefaults.standard.set(serverURL, forKey: Self.urlKey)
        UserDefaults.standard.set(authToken, forKey: Self.tokenKey)
    }

    // MARK: - Connection

    func connect() {
        disconnect()
        connectionError = nil

        guard let baseURL = URL(string: serverURL) else {
            connectionError = "Invalid URL"
            return
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)

        if components?.scheme == "https" {
            components?.scheme = "wss"
        } else if components?.scheme == "http" {
            components?.scheme = "ws"
        } else if components?.scheme != "ws" && components?.scheme != "wss" {
            components?.scheme = "wss"
        }

        if !authToken.isEmpty {
            var queryItems = components?.queryItems ?? []
            queryItems.append(URLQueryItem(name: "token", value: authToken))
            components?.queryItems = queryItems
        }

        guard let wsURL = components?.url else {
            connectionError = "Could not build WebSocket URL"
            return
        }

        saveConnection()

        let newTransport = WebSocketTransport(url: wsURL)
        let newApi = T3CodeAPI(transport: newTransport)
        transport = newTransport
        api = newApi

        isConnected = true

        Task {
            await setupListeners(api: newApi)
            await newTransport.connect()

            do {
                let snapshot: OrchestrationReadModel = try await newApi.getSnapshot()
                self.applySnapshot(snapshot)
            } catch {
                self.connectionError = error.localizedDescription
            }
        }
    }

    func disconnect() {
        Task {
            await transport?.disconnect()
        }
        transport = nil
        api = nil
        isConnected = false
        welcome = nil
        projects = []
        threads = []
        providers = []
        snapshotSequence = 0
        streamingMessageId = nil
        streamingText = ""
    }

    // MARK: - Actions

    func sendMessage(threadId: ThreadId, text: String) async throws {
        guard let api else { throw TransportError.disposed }
        let messageId = UUID().uuidString
        try await api.sendMessage(threadId: threadId, messageId: messageId, text: text)
    }

    func interruptTurn(threadId: ThreadId) async throws {
        guard let api else { throw TransportError.disposed }
        try await api.interruptTurn(threadId: threadId)
    }

    func createThread(projectId: ProjectId, title: String, model: String) async throws -> ThreadId {
        guard let api else { throw TransportError.disposed }
        return try await api.createThread(projectId: projectId, title: title, model: model)
    }

    func deleteThread(threadId: ThreadId) async throws {
        guard let api else { throw TransportError.disposed }
        try await api.deleteThread(threadId: threadId)
    }

    func respondToApproval(threadId: ThreadId, requestId: ApprovalRequestId, decision: String) async throws {
        guard let api else { throw TransportError.disposed }
        try await api.respondToApproval(threadId: threadId, requestId: requestId, decision: decision)
    }

    func stopSession(threadId: ThreadId) async throws {
        guard let api else { throw TransportError.disposed }
        try await api.stopSession(threadId: threadId)
    }

    // MARK: - Computed

    var selectedThread: OrchestrationThread? {
        threads.first { $0.id == selectedThreadId }
    }

    func project(for thread: OrchestrationThread) -> OrchestrationProject? {
        projects.first { $0.id == thread.projectId }
    }

    func threads(for projectId: ProjectId) -> [OrchestrationThread] {
        threads
            .filter { $0.projectId == projectId && $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeProjects: [OrchestrationProject] {
        projects.filter { $0.deletedAt == nil }
    }

    // MARK: - Internal

    private func setupListeners(api: T3CodeAPI) async {
        await api.onWelcome { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.welcome = payload
            }
        }

        await api.onServerConfigUpdated { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.providers = payload.providers
            }
        }

        await api.onDomainEvent { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDomainEvent(event)
            }
        }
    }

    private func applySnapshot(_ snapshot: OrchestrationReadModel) {
        projects = snapshot.projects
        threads = snapshot.threads
        snapshotSequence = snapshot.snapshotSequence
    }

    private func handleDomainEvent(_ event: OrchestrationEvent) {
        Task {
            guard let api = self.api else { return }

            switch event.type {
            case "thread.message-sent":
                if let streaming = event.payload["streaming"]?.boolValue, streaming,
                   let messageId = event.payload["messageId"]?.stringValue {
                    self.streamingMessageId = messageId
                    self.streamingText = event.payload["text"]?.stringValue ?? ""
                }
            default:
                break
            }

            do {
                let snapshot: OrchestrationReadModel = try await api.getSnapshot()
                self.applySnapshot(snapshot)

                if let sid = self.streamingMessageId {
                    let stillStreaming = snapshot.threads
                        .flatMap(\.messages)
                        .first { $0.id == sid }?.streaming ?? false
                    if !stillStreaming {
                        self.streamingMessageId = nil
                        self.streamingText = ""
                    }
                }
            } catch {
                // Best effort
            }
        }
    }
}
