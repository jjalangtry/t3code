import Foundation

enum ThreadProjectionReducer {
    static func apply(event: OrchestrationEvent, to threads: [OrchestrationThread]) -> [OrchestrationThread] {
        guard let threadId = event.payload["threadId"]?.stringValue,
              let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else {
            return threads
        }

        var nextThreads = threads
        let current = threads[threadIndex]

        switch event.type {
        case "thread.session-set":
            guard let sessionPayload = event.payload["session"],
                  let session = decodeJSONValue(OrchestrationSession.self, from: sessionPayload) else {
                return threads
            }
            nextThreads[threadIndex] = OrchestrationThread(
                id: current.id,
                projectId: current.projectId,
                title: current.title,
                model: current.model,
                runtimeMode: current.runtimeMode,
                interactionMode: current.interactionMode,
                branch: current.branch,
                worktreePath: current.worktreePath,
                latestTurn: current.latestTurn,
                createdAt: current.createdAt,
                updatedAt: event.occurredAt,
                deletedAt: current.deletedAt,
                messages: current.messages,
                proposedPlans: current.proposedPlans,
                activities: current.activities,
                checkpoints: current.checkpoints,
                session: session
            )
            return nextThreads
        case "thread.activity-appended":
            guard let activityPayload = event.payload["activity"],
                  let activity = decodeJSONValue(ThreadActivity.self, from: activityPayload) else {
                return threads
            }
            nextThreads[threadIndex] = OrchestrationThread(
                id: current.id,
                projectId: current.projectId,
                title: current.title,
                model: current.model,
                runtimeMode: current.runtimeMode,
                interactionMode: current.interactionMode,
                branch: current.branch,
                worktreePath: current.worktreePath,
                latestTurn: current.latestTurn,
                createdAt: current.createdAt,
                updatedAt: event.occurredAt,
                deletedAt: current.deletedAt,
                messages: current.messages,
                proposedPlans: current.proposedPlans,
                activities: current.activities + [activity],
                checkpoints: current.checkpoints,
                session: current.session
            )
            return nextThreads
        default:
            return threads
        }
    }

    private static func decodeJSONValue<T: Decodable>(_ type: T.Type, from value: JSONValue) -> T? {
        guard let data = value.toData() else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
