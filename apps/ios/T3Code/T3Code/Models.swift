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

enum ProviderKind: String, Codable, CaseIterable {
    case codex
    case claudeCode
    case cursor
}

enum RuntimeMode: String, Codable {
    case approvalRequired = "approval-required"
    case fullAccess = "full-access"
}

enum InteractionMode: String, Codable {
    case `default`
    case plan
}

// MARK: - Session

enum SessionStatus: String, Codable {
    case idle, starting, running, ready, interrupted, stopped, error
}

struct OrchestrationSession: Codable {
    let threadId: ThreadId
    let status: SessionStatus
    let providerName: String?
    let runtimeMode: RuntimeMode
    let activeTurnId: TurnId?
    let lastError: String?
    let updatedAt: String
}

// MARK: - Messages

enum MessageRole: String, Codable {
    case user, assistant, system
}

struct ChatAttachment: Codable, Identifiable {
    let type: String
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
}

struct OrchestrationMessage: Codable, Identifiable {
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

enum LatestTurnState: String, Codable {
    case running, interrupted, completed, error
}

struct LatestTurn: Codable {
    let turnId: TurnId
    let state: LatestTurnState
    let requestedAt: String
    let startedAt: String?
    let completedAt: String?
    let assistantMessageId: MessageId?
}

// MARK: - Activities

enum ActivityTone: String, Codable {
    case info, tool, approval, error
}

struct ThreadActivity: Codable, Identifiable {
    let id: EventId
    let tone: ActivityTone
    let kind: String
    let summary: String
    let payload: AnyCodable?
    let turnId: TurnId?
    let sequence: Int?
    let createdAt: String
}

// MARK: - Checkpoints

struct CheckpointFile: Codable {
    let path: String
    let kind: String
    let additions: Int
    let deletions: Int
}

struct CheckpointSummary: Codable {
    let turnId: TurnId
    let checkpointTurnCount: Int
    let checkpointRef: CheckpointRef
    let status: String
    let files: [CheckpointFile]
    let assistantMessageId: MessageId?
    let completedAt: String
}

// MARK: - Proposed Plan

struct ProposedPlan: Codable, Identifiable {
    let id: String
    let turnId: TurnId?
    let planMarkdown: String
    let createdAt: String
    let updatedAt: String
}

// MARK: - Thread

struct OrchestrationThread: Codable, Identifiable {
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

struct ProjectScript: Codable, Identifiable {
    let id: String
    let name: String
    let command: String
    let icon: String
    let runOnWorktreeCreate: Bool
}

struct OrchestrationProject: Codable, Identifiable {
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

struct OrchestrationReadModel: Codable {
    let snapshotSequence: Int
    let projects: [OrchestrationProject]
    let threads: [OrchestrationThread]
    let updatedAt: String
}

// MARK: - Welcome payload

struct WsWelcomePayload: Codable {
    let cwd: String
    let projectName: String
    let bootstrapProjectId: ProjectId?
    let bootstrapThreadId: ThreadId?
}

// MARK: - Server config

struct ServerProviderStatus: Codable, Identifiable {
    var id: String { provider }
    let provider: String
    let status: String
    let available: Bool
    let authStatus: String
    let checkedAt: String
    let message: String?
}

struct ServerConfigUpdatedPayload: Codable {
    let issues: [AnyCodable]
    let providers: [ServerProviderStatus]
}

// MARK: - Orchestration Event

struct OrchestrationEvent: Codable {
    let sequence: Int
    let eventId: EventId
    let type: String
    let aggregateKind: String
    let aggregateId: String
    let occurredAt: String
    let commandId: CommandId?
    let payload: AnyCodable
    let metadata: AnyCodable?
}

// MARK: - AnyCodable (generic JSON wrapper)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    subscript(key: String) -> Any? {
        (value as? [String: Any])?[key]
    }
}
