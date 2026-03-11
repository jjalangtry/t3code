import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SessionStore {
    var serverHostInput: String = ""
    var advancedPortOverride: String = ""
    var connectionMode: ConnectionMode = .appAuth
    var authUsername: String = ""
    var authPassword: String = ""
    var authToken: String = ""
    var connectionError: String?
    var phase: ConnectionPhase = .disconnected
    var authSessionState: AppAuthSessionState?

    var welcome: WsWelcomePayload?

    var projects: [OrchestrationProject] = []
    var threads: [OrchestrationThread] = []
    var providers: [ServerProviderStatus] = []
    var snapshotSequence: Int = 0

    var selectedThreadId: ThreadId?

    var streamingMessageId: MessageId?
    var streamingText: String = ""

    private var transport: WebSocketTransport?
    private var api: T3CodeAPI?
    private var connectTask: Task<Void, Never>?
    private var snapshotThrottleTask: Task<Void, Never>?
    private var snapshotSyncInFlight = false
    private var snapshotSyncPending = false
    private var latestSequence = 0
    private var didLoadSavedConnection = false
    private var connectionAttemptID = 0

    private let authClient = AppAuthClient()

    private static let hostKey = "t3code_server_host_input"
    private static let modeKey = "t3code_connection_mode"
    private static let portKey = "t3code_advanced_port_override"
    private static let usernameKey = "t3code_auth_username"
    private static let secureStoreService = "jjalangtry.T3Code"
    private static let authTokenAccount = "authToken"
    private static let appAuthSessionTokenAccount = "appAuthSessionToken"

    init() {
        loadSavedConnection()
        applyDebugOverridesIfNeeded()
    }

    var isConnected: Bool {
        phase == .connected
    }

    var isBusy: Bool {
        phase == .checkingAuth || phase == .connecting
    }

    var canSubmitConnection: Bool {
        let hasHost = !serverHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasHost, !isBusy else { return false }

        if connectionMode == .token {
            return !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if shouldShowLoginFields {
            return !authUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !authPassword.isEmpty
        }

        return true
    }

    var shouldShowLoginFields: Bool {
        connectionMode == .appAuth && phase == .awaitingLogin
    }

    var shouldShowTokenField: Bool {
        connectionMode == .token
    }

    var connectButtonLabel: String {
        switch phase {
        case .checkingAuth:
            "Checking Server..."
        case .connecting:
            "Connecting..."
        case .awaitingLogin:
            "Sign In & Connect"
        case .connected, .disconnected, .failed:
            "Connect"
        }
    }

    var selectedThread: OrchestrationThread? {
        threads.first { $0.id == selectedThreadId }
    }

    var activeProjects: [OrchestrationProject] {
        projects.filter { $0.deletedAt == nil }
    }

    func loadSavedConnection() {
        guard !didLoadSavedConnection else { return }
        didLoadSavedConnection = true

        serverHostInput = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        advancedPortOverride = UserDefaults.standard.string(forKey: Self.portKey) ?? ""
        authUsername = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""

        if let rawMode = UserDefaults.standard.string(forKey: Self.modeKey),
           let decodedMode = ConnectionMode(rawValue: rawMode) {
            connectionMode = decodedMode
        } else {
            connectionMode = .appAuth
        }

        authToken =
            SecureStore.readString(
                service: Self.secureStoreService,
                account: Self.authTokenAccount
            ) ?? ""
    }

    func submitConnection() {
        if shouldShowLoginFields {
            signInAndConnect()
            return
        }
        connect()
    }

    func connect() {
        guard !isBusy else { return }

        let endpoint: ServerEndpoint
        do {
            endpoint = try EndpointResolver.resolve(
                hostInput: serverHostInput,
                portOverride: advancedPortOverride
            )
        } catch {
            phase = .failed
            connectionError = ConnectionErrorFormatter.message(for: error)
            return
        }

        saveConnectionPreferences()
        resetConnectionAttempt()
        connectionError = nil
        authSessionState = nil
        phase = connectionMode == .appAuth ? .checkingAuth : .connecting

        let attemptID = nextConnectionAttemptID()
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let authContext = try await self.prepareAuthContext(endpoint: endpoint, attemptID: attemptID)
                guard self.isCurrentAttempt(attemptID) else { return }
                guard let authContext else {
                    self.connectTask = nil
                    return
                }
                try await self.establishConnection(
                    endpoint: endpoint,
                    authContext: authContext,
                    attemptID: attemptID
                )
            } catch {
                self.handleConnectionFailure(error, attemptID: attemptID)
            }
        }
    }

    func disconnect() {
        connectionAttemptID += 1
        connectTask?.cancel()
        connectTask = nil
        snapshotThrottleTask?.cancel()
        snapshotThrottleTask = nil
        snapshotSyncInFlight = false
        snapshotSyncPending = false

        let oldTransport = transport
        transport = nil
        api = nil
        Task {
            await oldTransport?.disconnect()
        }

        connectionError = nil
        authPassword = ""
        authSessionState = nil
        phase = .disconnected
        clearLiveData()
    }

    func sendMessage(threadId: ThreadId, text: String) async throws {
        guard let api else { throw TransportError.notConnected }
        let messageId = UUID().uuidString
        try await api.sendMessage(threadId: threadId, messageId: messageId, text: text)
    }

    func interruptTurn(threadId: ThreadId) async throws {
        guard let api else { throw TransportError.notConnected }
        try await api.interruptTurn(threadId: threadId)
    }

    func createThread(projectId: ProjectId, title: String, model: String) async throws -> ThreadId {
        guard let api else { throw TransportError.notConnected }
        return try await api.createThread(projectId: projectId, title: title, model: model)
    }

    func deleteThread(threadId: ThreadId) async throws {
        guard let api else { throw TransportError.notConnected }
        try await api.deleteThread(threadId: threadId)
    }

    func respondToApproval(threadId: ThreadId, requestId: ApprovalRequestId, decision: String) async throws {
        guard let api else { throw TransportError.notConnected }
        try await api.respondToApproval(threadId: threadId, requestId: requestId, decision: decision)
    }

    func stopSession(threadId: ThreadId) async throws {
        guard let api else { throw TransportError.notConnected }
        try await api.stopSession(threadId: threadId)
    }

    func project(for thread: OrchestrationThread) -> OrchestrationProject? {
        projects.first { $0.id == thread.projectId }
    }

    func threads(for projectId: ProjectId) -> [OrchestrationThread] {
        threads
            .filter { $0.projectId == projectId && $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func forceAwaitingLoginForDebug(serverHost: String = "code.jjalangtry.com") {
        serverHostInput = serverHost
        connectionMode = .appAuth
        authSessionState = AppAuthSessionState(authRequired: true, authenticated: false, username: nil)
        phase = .awaitingLogin
        connectionError = nil
    }

    private func saveConnectionPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(serverHostInput, forKey: Self.hostKey)
        defaults.set(connectionMode.rawValue, forKey: Self.modeKey)
        defaults.set(advancedPortOverride, forKey: Self.portKey)
        defaults.set(authUsername, forKey: Self.usernameKey)

        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            SecureStore.deleteString(
                service: Self.secureStoreService,
                account: Self.authTokenAccount
            )
        } else {
            SecureStore.writeString(
                trimmedToken,
                service: Self.secureStoreService,
                account: Self.authTokenAccount
            )
        }
    }

    private func signInAndConnect() {
        guard !isBusy else { return }

        let username = authUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !authPassword.isEmpty else {
            connectionError = "Enter your username and password."
            return
        }

        let endpoint: ServerEndpoint
        do {
            endpoint = try EndpointResolver.resolve(
                hostInput: serverHostInput,
                portOverride: advancedPortOverride
            )
        } catch {
            phase = .failed
            connectionError = ConnectionErrorFormatter.message(for: error)
            return
        }

        saveConnectionPreferences()
        resetConnectionAttempt()
        connectionError = nil
        authSessionState = AppAuthSessionState(authRequired: true, authenticated: false, username: nil)
        phase = .connecting

        let attemptID = nextConnectionAttemptID()
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let loginResponse = try await self.authClient.login(
                    origin: endpoint.httpOrigin,
                    username: username,
                    password: self.authPassword
                )
                guard self.isCurrentAttempt(attemptID) else { return }

                SecureStore.writeString(
                    loginResponse.sessionToken,
                    service: Self.secureStoreService,
                    account: Self.appAuthSessionTokenAccount
                )
                self.authSessionState = loginResponse.session
                self.authPassword = ""

                try await self.establishConnection(
                    endpoint: endpoint,
                    authContext: .appSession(loginResponse.sessionToken),
                    attemptID: attemptID
                )
            } catch {
                self.handleConnectionFailure(error, attemptID: attemptID)
            }
        }
    }

    private func prepareAuthContext(
        endpoint: ServerEndpoint,
        attemptID: Int
    ) async throws -> ConnectionAuthContext? {
        guard isCurrentAttempt(attemptID) else { return nil }

        switch connectionMode {
        case .token:
            let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ConnectionIssue.missingToken
            }
            return .token(token)

        case .appAuth:
            let storedSessionToken = SecureStore.readString(
                service: Self.secureStoreService,
                account: Self.appAuthSessionTokenAccount
            )
            let sessionState = try await authClient.fetchSession(
                origin: endpoint.httpOrigin,
                sessionToken: storedSessionToken
            )
            guard isCurrentAttempt(attemptID) else { return nil }

            authSessionState = sessionState
            if sessionState.authRequired {
                if sessionState.authenticated,
                   let storedSessionToken,
                   !storedSessionToken.isEmpty {
                    return .appSession(storedSessionToken)
                }

                SecureStore.deleteString(
                    service: Self.secureStoreService,
                    account: Self.appAuthSessionTokenAccount
                )
                phase = .awaitingLogin
                connectionError = nil
                return nil
            }

            return .none
        }
    }

    private func establishConnection(
        endpoint: ServerEndpoint,
        authContext: ConnectionAuthContext,
        attemptID: Int
    ) async throws {
        guard isCurrentAttempt(attemptID) else { return }

        phase = .connecting
        clearLiveData()

        let wsURL = try endpoint.webSocketURL(auth: authContext)
        let transport = WebSocketTransport(url: wsURL)
        await transport.setLifecycleHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleTransportLifecycleEvent(event)
            }
        }

        let api = T3CodeAPI(transport: transport)
        self.transport = transport
        self.api = api
        await setupListeners(api: api)

        do {
            try await transport.connect()
            guard isCurrentAttempt(attemptID), self.api === api else { return }

            let snapshot: OrchestrationReadModel = try await api.getSnapshot()
            guard isCurrentAttempt(attemptID), self.api === api else { return }

            applySnapshot(snapshot)
            latestSequence = max(latestSequence, snapshot.snapshotSequence)
            authPassword = ""
            connectionError = nil
            phase = .connected
            connectTask = nil
        } catch {
            if self.api === api {
                let oldTransport = self.transport
                self.transport = nil
                self.api = nil
                Task {
                    await oldTransport?.disconnect()
                }
            }
            throw error
        }
    }

    private func setupListeners(api: T3CodeAPI) async {
        await api.onWelcome { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.welcome = payload
                self?.reconcileSelectedThread()
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

    private func handleTransportLifecycleEvent(_ event: TransportLifecycleEvent) {
        switch event {
        case .connected(let isReconnect):
            if isReconnect, isConnected {
                connectionError = nil
                scheduleSnapshotSync(delayNanoseconds: 0)
            }
        case .connectionLost:
            break
        }
    }

    private func scheduleSnapshotSync(delayNanoseconds: UInt64 = 100_000_000) {
        guard api != nil else { return }
        guard snapshotThrottleTask == nil else { return }

        snapshotThrottleTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled else { return }
            self.snapshotThrottleTask = nil
            await self.syncSnapshot()
        }
    }

    private func syncSnapshot() async {
        guard let api else { return }

        if snapshotSyncInFlight {
            snapshotSyncPending = true
            return
        }

        snapshotSyncInFlight = true
        defer {
            snapshotSyncInFlight = false
        }

        do {
            let snapshot: OrchestrationReadModel = try await api.getSnapshot()
            guard self.api === api else { return }

            applySnapshot(snapshot)
            latestSequence = max(latestSequence, snapshot.snapshotSequence)
            clearCompletedStreamingState(using: snapshot)
        } catch {
            // Keep the last good state and let the next event trigger another sync.
        }

        if snapshotSyncPending {
            snapshotSyncPending = false
            await syncSnapshot()
        }
    }

    private func applySnapshot(_ snapshot: OrchestrationReadModel) {
        projects = snapshot.projects
        threads = snapshot.threads
        snapshotSequence = snapshot.snapshotSequence
        reconcileSelectedThread()
        clearCompletedStreamingState(using: snapshot)
    }

    private func clearCompletedStreamingState(using snapshot: OrchestrationReadModel) {
        guard let streamingMessageId else { return }

        let isStillStreaming = snapshot.threads
            .flatMap(\.messages)
            .first { $0.id == streamingMessageId }?
            .streaming ?? false

        if !isStillStreaming {
            self.streamingMessageId = nil
            self.streamingText = ""
        }
    }

    private func handleDomainEvent(_ event: OrchestrationEvent) {
        guard event.sequence > latestSequence else { return }
        latestSequence = event.sequence

        switch event.type {
        case "thread.message-sent":
            if let streaming = event.payload["streaming"]?.boolValue, streaming,
               let messageId = event.payload["messageId"]?.stringValue {
                streamingMessageId = messageId
                streamingText = event.payload["text"]?.stringValue ?? ""
            }
        default:
            break
        }

        scheduleSnapshotSync()
    }

    private func reconcileSelectedThread() {
        let visibleThreads = threads.filter { $0.deletedAt == nil }
        guard !visibleThreads.isEmpty else {
            selectedThreadId = nil
            return
        }

        if let selectedThreadId,
           visibleThreads.contains(where: { $0.id == selectedThreadId }) {
            return
        }

        if let bootstrapThreadId = welcome?.bootstrapThreadId,
           visibleThreads.contains(where: { $0.id == bootstrapThreadId }) {
            selectedThreadId = bootstrapThreadId
            return
        }

        selectedThreadId = visibleThreads
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .id
    }

    private func clearLiveData() {
        welcome = nil
        projects = []
        threads = []
        providers = []
        snapshotSequence = 0
        latestSequence = 0
        selectedThreadId = nil
        streamingMessageId = nil
        streamingText = ""
    }

    private func resetConnectionAttempt() {
        connectionAttemptID += 1
        connectTask?.cancel()
        connectTask = nil
        snapshotThrottleTask?.cancel()
        snapshotThrottleTask = nil
        snapshotSyncInFlight = false
        snapshotSyncPending = false

        let oldTransport = transport
        transport = nil
        api = nil
        Task {
            await oldTransport?.disconnect()
        }
    }

    private func nextConnectionAttemptID() -> Int {
        connectionAttemptID += 1
        return connectionAttemptID
    }

    private func isCurrentAttempt(_ attemptID: Int) -> Bool {
        attemptID == connectionAttemptID
    }

    private func handleConnectionFailure(_ error: any Error, attemptID: Int) {
        guard isCurrentAttempt(attemptID) else { return }
        connectTask = nil

        if connectionMode == .appAuth,
           let transportError = error as? TransportError,
           case .serverError(let message) = transportError,
           message.localizedCaseInsensitiveContains("unauthorized") {
            SecureStore.deleteString(
                service: Self.secureStoreService,
                account: Self.appAuthSessionTokenAccount
            )
            authSessionState = AppAuthSessionState(authRequired: true, authenticated: false, username: nil)
            phase = .awaitingLogin
        } else if let appAuthError = error as? AppAuthClientError,
                  case .invalidCredentials = appAuthError {
            phase = .awaitingLogin
        } else if connectionMode == .appAuth, authSessionState?.authRequired == true {
            phase = .awaitingLogin
        } else {
            phase = .failed
        }

        connectionError = ConnectionErrorFormatter.message(for: error)
    }

    private func applyDebugOverridesIfNeeded() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-T3CODE_DEBUG_FORCE_AWAITING_LOGIN") {
            forceAwaitingLoginForDebug()
        }
        #endif
    }
}
