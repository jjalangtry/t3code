import Foundation

// MARK: - Branded IDs

typealias ThreadId = String
typealias ProjectId = String
typealias MessageId = String
typealias TurnId = String
typealias EventId = String
typealias CommandId = String
typealias ApprovalRequestId = String
typealias CheckpointRef = String

// MARK: - Provider types

nonisolated enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claudeCode
    case cursor
}

nonisolated enum RuntimeMode: String, Codable, Sendable {
    case approvalRequired = "approval-required"
    case fullAccess = "full-access"
}

nonisolated enum InteractionMode: String, Codable, Sendable {
    case `default`
    case plan
}

nonisolated enum GitStackedAction: String, Codable, Sendable, CaseIterable {
    case commit
    case commitPush = "commit_push"
    case commitPushPR = "commit_push_pr"
}

// MARK: - Session

nonisolated enum SessionStatus: String, Codable, Sendable {
    case idle, starting, running, ready, interrupted, stopped, error
}

nonisolated struct OrchestrationSession: Codable, Sendable {
    let threadId: ThreadId
    let status: SessionStatus
    let providerName: String?
    let runtimeMode: RuntimeMode
    let activeTurnId: TurnId?
    let lastError: String?
    let updatedAt: String
}

// MARK: - Messages

nonisolated enum MessageRole: String, Codable, Sendable {
    case user, assistant, system
}

nonisolated struct ChatAttachment: Codable, Sendable, Identifiable {
    let type: String
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
}

nonisolated struct OrchestrationMessage: Codable, Sendable, Identifiable {
    let id: MessageId
    let role: MessageRole
    let text: String
    let attachments: [ChatAttachment]?
    let turnId: TurnId?
    let streaming: Bool
    let createdAt: String
    let updatedAt: String
}

// MARK: - Turn

nonisolated enum LatestTurnState: String, Codable, Sendable {
    case running, interrupted, completed, error
}

nonisolated struct LatestTurn: Codable, Sendable {
    let turnId: TurnId
    let state: LatestTurnState
    let requestedAt: String
    let startedAt: String?
    let completedAt: String?
    let assistantMessageId: MessageId?
}

// MARK: - Activities

nonisolated enum ActivityTone: String, Codable, Sendable {
    case info, tool, approval, error
}

nonisolated struct ThreadActivity: Codable, Sendable, Identifiable {
    let id: EventId
    let tone: ActivityTone
    let kind: String
    let summary: String
    let payload: JSONValue?
    let turnId: TurnId?
    let sequence: Int?
    let createdAt: String
}

// MARK: - Checkpoints

nonisolated struct CheckpointFile: Codable, Sendable {
    let path: String
    let kind: String
    let additions: Int
    let deletions: Int
}

nonisolated struct CheckpointSummary: Codable, Sendable {
    let turnId: TurnId
    let checkpointTurnCount: Int
    let checkpointRef: CheckpointRef
    let status: String
    let files: [CheckpointFile]
    let assistantMessageId: MessageId?
    let completedAt: String
}

// MARK: - Proposed Plan

nonisolated struct ProposedPlan: Codable, Sendable, Identifiable {
    let id: String
    let turnId: TurnId?
    let planMarkdown: String
    let createdAt: String
    let updatedAt: String
}

// MARK: - Thread

nonisolated struct OrchestrationThread: Codable, Sendable, Identifiable {
    let id: ThreadId
    let projectId: ProjectId
    let title: String
    let model: String
    let runtimeMode: RuntimeMode
    let interactionMode: InteractionMode?
    let branch: String?
    let worktreePath: String?
    let latestTurn: LatestTurn?
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?
    let messages: [OrchestrationMessage]
    let proposedPlans: [ProposedPlan]?
    let activities: [ThreadActivity]
    let checkpoints: [CheckpointSummary]
    let session: OrchestrationSession?
}

// MARK: - Project

nonisolated struct ProjectScript: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let command: String
    let icon: String
    let runOnWorktreeCreate: Bool
}

nonisolated struct OrchestrationProject: Codable, Sendable, Identifiable {
    let id: ProjectId
    let title: String
    let workspaceRoot: String
    let defaultModel: String?
    let scripts: [ProjectScript]
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?
}

// MARK: - Read Model (snapshot)

nonisolated struct OrchestrationReadModel: Codable, Sendable {
    let snapshotSequence: Int
    let projects: [OrchestrationProject]
    let threads: [OrchestrationThread]
    let updatedAt: String
}

// MARK: - Welcome payload

nonisolated struct WsWelcomePayload: Codable, Sendable {
    let cwd: String
    let projectName: String
    let bootstrapProjectId: ProjectId?
    let bootstrapThreadId: ThreadId?
}

// MARK: - Server config

nonisolated struct ServerProviderStatus: Codable, Sendable, Identifiable {
    var id: String { provider }
    let provider: String
    let status: String
    let available: Bool
    let authStatus: String
    let checkedAt: String
    let message: String?
}

nonisolated struct ServerConfigUpdatedPayload: Codable, Sendable {
    let issues: [JSONValue]
    let providers: [ServerProviderStatus]
}

// MARK: - Git

nonisolated struct GitWorkingTreeFile: Codable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let insertions: Int
    let deletions: Int
}

nonisolated struct GitWorkingTreeSummary: Codable, Sendable {
    let files: [GitWorkingTreeFile]
    let insertions: Int
    let deletions: Int
}

nonisolated struct GitStatusPR: Codable, Sendable {
    let number: Int
    let title: String
    let url: String
    let baseBranch: String
    let headBranch: String
    let state: String
}

nonisolated struct GitStatusResult: Codable, Sendable {
    let branch: String?
    let hasWorkingTreeChanges: Bool
    let workingTree: GitWorkingTreeSummary
    let hasUpstream: Bool
    let aheadCount: Int
    let behindCount: Int
    let pr: GitStatusPR?
}

nonisolated struct GitBranch: Codable, Sendable, Identifiable {
    var id: String {
        let remote = isRemote == true ? "remote" : "local"
        return "\(remote):\(name)"
    }

    let name: String
    let isRemote: Bool?
    let remoteName: String?
    let current: Bool
    let isDefault: Bool
    let worktreePath: String?
}

nonisolated struct GitListBranchesResult: Codable, Sendable {
    let branches: [GitBranch]
    let isRepo: Bool
}

nonisolated struct GitPullResult: Codable, Sendable {
    let status: String
    let branch: String
    let upstreamBranch: String?
}

nonisolated struct GitActionBranchResult: Codable, Sendable {
    let status: String
    let name: String?
}

nonisolated struct GitActionCommitResult: Codable, Sendable {
    let status: String
    let commitSha: String?
    let subject: String?
}

nonisolated struct GitActionPushResult: Codable, Sendable {
    let status: String
    let branch: String?
    let upstreamBranch: String?
    let setUpstream: Bool?
}

nonisolated struct GitActionPRResult: Codable, Sendable {
    let status: String
    let url: String?
    let number: Int?
    let baseBranch: String?
    let headBranch: String?
    let title: String?
}

nonisolated struct GitRunStackedActionResult: Codable, Sendable {
    let action: GitStackedAction
    let branch: GitActionBranchResult
    let commit: GitActionCommitResult
    let push: GitActionPushResult
    let pr: GitActionPRResult
}

// MARK: - Terminal

nonisolated enum TerminalSessionStatus: String, Codable, Sendable {
    case starting
    case running
    case exited
    case error
}

nonisolated struct TerminalSessionSnapshot: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let cwd: String
    let status: TerminalSessionStatus
    let pid: Int?
    let history: String
    let exitCode: Int?
    let exitSignal: Int?
    let updatedAt: String
}

nonisolated struct TerminalStartedEventPayload: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let createdAt: String
    let type: String
    let snapshot: TerminalSessionSnapshot
}

nonisolated struct TerminalOutputEventPayload: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let createdAt: String
    let type: String
    let data: String
}

nonisolated struct TerminalExitedEventPayload: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let createdAt: String
    let type: String
    let exitCode: Int?
    let exitSignal: Int?
}

nonisolated struct TerminalErrorEventPayload: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let createdAt: String
    let type: String
    let message: String
}

nonisolated struct TerminalClearedEventPayload: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let createdAt: String
    let type: String
}

nonisolated struct TerminalRestartedEventPayload: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let createdAt: String
    let type: String
    let snapshot: TerminalSessionSnapshot
}

nonisolated struct TerminalActivityEventPayload: Codable, Sendable {
    let threadId: ThreadId
    let terminalId: String
    let createdAt: String
    let type: String
    let hasRunningSubprocess: Bool
}

nonisolated enum TerminalEvent: Sendable {
    case started(TerminalStartedEventPayload)
    case output(TerminalOutputEventPayload)
    case exited(TerminalExitedEventPayload)
    case error(TerminalErrorEventPayload)
    case cleared(TerminalClearedEventPayload)
    case restarted(TerminalRestartedEventPayload)
    case activity(TerminalActivityEventPayload)
}

// MARK: - Composer Attachments

nonisolated struct PendingComposerAttachment: Identifiable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
    let dataURL: String
}

// MARK: - Orchestration Event

nonisolated struct OrchestrationEvent: Codable, Sendable {
    let sequence: Int
    let eventId: EventId
    let type: String
    let aggregateKind: String
    let aggregateId: String
    let occurredAt: String
    let commandId: CommandId?
    let payload: JSONValue
    let metadata: JSONValue?
}

// MARK: - JSONValue (type-safe JSON wrapper)

nonisolated enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
}
