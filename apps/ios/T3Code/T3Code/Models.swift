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

enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claudeCode
    case cursor
}

enum RuntimeMode: String, Codable, Sendable {
    case approvalRequired = "approval-required"
    case fullAccess = "full-access"
}

enum InteractionMode: String, Codable, Sendable {
    case `default`
    case plan
}

// MARK: - Session

enum SessionStatus: String, Codable, Sendable {
    case idle, starting, running, ready, interrupted, stopped, error
}

struct OrchestrationSession: Codable, Sendable {
    let threadId: ThreadId
    let status: SessionStatus
    let providerName: String?
    let runtimeMode: RuntimeMode
    let activeTurnId: TurnId?
    let lastError: String?
    let updatedAt: String
}

// MARK: - Messages

enum MessageRole: String, Codable, Sendable {
    case user, assistant, system
}

struct ChatAttachment: Codable, Sendable, Identifiable {
    let type: String
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
}

struct OrchestrationMessage: Codable, Sendable, Identifiable {
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

enum LatestTurnState: String, Codable, Sendable {
    case running, interrupted, completed, error
}

struct LatestTurn: Codable, Sendable {
    let turnId: TurnId
    let state: LatestTurnState
    let requestedAt: String
    let startedAt: String?
    let completedAt: String?
    let assistantMessageId: MessageId?
}

// MARK: - Activities

enum ActivityTone: String, Codable, Sendable {
    case info, tool, approval, error
}

struct ThreadActivity: Codable, Sendable, Identifiable {
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

struct CheckpointFile: Codable, Sendable {
    let path: String
    let kind: String
    let additions: Int
    let deletions: Int
}

struct CheckpointSummary: Codable, Sendable {
    let turnId: TurnId
    let checkpointTurnCount: Int
    let checkpointRef: CheckpointRef
    let status: String
    let files: [CheckpointFile]
    let assistantMessageId: MessageId?
    let completedAt: String
}

// MARK: - Proposed Plan

struct ProposedPlan: Codable, Sendable, Identifiable {
    let id: String
    let turnId: TurnId?
    let planMarkdown: String
    let createdAt: String
    let updatedAt: String
}

// MARK: - Thread

struct OrchestrationThread: Codable, Sendable, Identifiable {
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

struct ProjectScript: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let command: String
    let icon: String
    let runOnWorktreeCreate: Bool
}

struct OrchestrationProject: Codable, Sendable, Identifiable {
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

struct OrchestrationReadModel: Codable, Sendable {
    let snapshotSequence: Int
    let projects: [OrchestrationProject]
    let threads: [OrchestrationThread]
    let updatedAt: String
}

// MARK: - Welcome payload

struct WsWelcomePayload: Codable, Sendable {
    let cwd: String
    let projectName: String
    let bootstrapProjectId: ProjectId?
    let bootstrapThreadId: ThreadId?
}

// MARK: - Server config

struct ServerProviderStatus: Codable, Sendable, Identifiable {
    var id: String { provider }
    let provider: String
    let status: String
    let available: Bool
    let authStatus: String
    let checkedAt: String
    let message: String?
}

struct ServerConfigUpdatedPayload: Codable, Sendable {
    let issues: [JSONValue]
    let providers: [ServerProviderStatus]
}

// MARK: - Orchestration Event

struct OrchestrationEvent: Codable, Sendable {
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

enum JSONValue: Codable, Sendable, Hashable {
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
