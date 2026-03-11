import Foundation

enum ThreadTimelineItem: Identifiable {
    case message(OrchestrationMessage)
    case activity(ThreadTimelineActivity)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id)"
        case .activity(let activity):
            return "activity:\(activity.id)"
        }
    }

    var createdAt: String {
        switch self {
        case .message(let message):
            return message.createdAt
        case .activity(let activity):
            return activity.createdAt
        }
    }

    private var sortPriority: Int {
        switch self {
        case .message(let message):
            switch message.role {
            case .user:
                return 0
            case .assistant, .system:
                return 2
            }
        case .activity:
            return 1
        }
    }

    static func build(from thread: OrchestrationThread) -> [ThreadTimelineItem] {
        let items =
            thread.messages.map(ThreadTimelineItem.message)
            + thread.activities
                .filter { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { ThreadTimelineItem.activity(ThreadTimelineActivity(activity: $0)) }

        return items.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }
            if left.sortPriority != right.sortPriority {
                return left.sortPriority < right.sortPriority
            }
            return left.id < right.id
        }
    }
}

struct ThreadTimelineActivity: Identifiable, Equatable {
    let id: EventId
    let tone: ActivityTone
    let summary: String
    let detail: String?
    let command: String?
    let changedFiles: [String]
    let createdAt: String

    init(activity: ThreadActivity) {
        self.id = activity.id
        self.tone = activity.tone
        self.summary = activity.summary
        self.detail = Self.extractDetail(from: activity.payload)
        self.command = Self.extractCommand(from: activity.payload)
        self.changedFiles = Self.extractChangedFiles(from: activity.payload)
        self.createdAt = activity.createdAt
    }

    private static func extractDetail(from payload: JSONValue?) -> String? {
        payload?["detail"]?.stringValue
            ?? payload?["text"]?.stringValue
            ?? payload?["status"]?.stringValue
    }

    private static func extractCommand(from payload: JSONValue?) -> String? {
        let data = payload?["data"]
        let item = data?["item"]
        let itemInput = item?["input"]
        let itemResult = item?["result"]
        return normalizeCommand(data?["command"])
            ?? normalizeCommand(item?["command"])
            ?? normalizeCommand(itemInput?["command"])
            ?? normalizeCommand(itemResult?["command"])
    }

    private static func normalizeCommand(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let command):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .array(let parts):
            let command = parts.compactMap { part -> String? in
                guard case .string(let stringPart) = part else { return nil }
                let trimmed = stringPart.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }.joined(separator: " ")
            return command.isEmpty ? nil : command
        default:
            return nil
        }
    }

    private static func extractChangedFiles(from payload: JSONValue?) -> [String] {
        var changedFiles: [String] = []
        var seen = Set<String>()
        collectChangedFiles(from: payload?["data"], into: &changedFiles, seen: &seen, depth: 0)
        return changedFiles
    }

    private static func collectChangedFiles(
        from value: JSONValue?,
        into changedFiles: inout [String],
        seen: inout Set<String>,
        depth: Int
    ) {
        guard depth <= 4, changedFiles.count < 8 else { return }
        guard let value else { return }

        switch value {
        case .array(let items):
            for item in items {
                collectChangedFiles(from: item, into: &changedFiles, seen: &seen, depth: depth + 1)
                if changedFiles.count >= 8 {
                    return
                }
            }
        case .object(let object):
            for key in ["path", "filePath", "relativePath", "filename", "newPath", "oldPath"] {
                guard let candidate = object[key]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !candidate.isEmpty,
                    !seen.contains(candidate) else {
                    continue
                }
                seen.insert(candidate)
                changedFiles.append(candidate)
            }

            for key in ["item", "result", "input", "data", "changes", "files", "edits", "patch", "patches", "operations"] {
                collectChangedFiles(from: object[key], into: &changedFiles, seen: &seen, depth: depth + 1)
                if changedFiles.count >= 8 {
                    return
                }
            }
        default:
            break
        }
    }
}
