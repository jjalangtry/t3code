import Foundation
import Testing
@testable import T3Code

struct ConnectionAndTimelineTests {
    @Test
    func appAuthClientTreatsUnauthorizedSessionAsExpired() async throws {
        let session = makeURLSession { request in
            #expect(request.url?.absoluteString == "https://code.jjalangtry.com/api/auth/session")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"expired"}"#.utf8)
            )
        }

        let client = AppAuthClient(session: session)

        await #expect(throws: AppAuthClientError.expiredSession) {
            _ = try await client.fetchSession(
                origin: URL(string: "https://code.jjalangtry.com")!,
                sessionToken: "stale-session"
            )
        }
    }

    @Test
    func threadTimelineInterleavesMessagesAndActivitiesInline() {
        let thread = OrchestrationThread(
            id: "thread-1",
            projectId: "project-1",
            title: "Thread",
            model: "o4-mini",
            runtimeMode: .fullAccess,
            interactionMode: .default,
            branch: nil,
            worktreePath: nil,
            latestTurn: nil,
            createdAt: "2026-03-11T10:00:00.000Z",
            updatedAt: "2026-03-11T10:00:03.000Z",
            deletedAt: nil,
            messages: [
                OrchestrationMessage(
                    id: "user-1",
                    role: .user,
                    text: "Run lint",
                    attachments: nil,
                    turnId: "turn-1",
                    streaming: false,
                    createdAt: "2026-03-11T10:00:00.000Z",
                    updatedAt: "2026-03-11T10:00:00.000Z"
                ),
                OrchestrationMessage(
                    id: "assistant-1",
                    role: .assistant,
                    text: "Done",
                    attachments: nil,
                    turnId: "turn-1",
                    streaming: false,
                    createdAt: "2026-03-11T10:00:02.000Z",
                    updatedAt: "2026-03-11T10:00:02.000Z"
                ),
            ],
            proposedPlans: nil,
            activities: [
                ThreadActivity(
                    id: "activity-1",
                    tone: .tool,
                    kind: "tool.completed",
                    summary: "Ran bun run lint",
                    payload: .object([
                        "data": .object([
                            "command": .array([.string("bun"), .string("run"), .string("lint")]),
                            "files": .array([
                                .object(["path": .string("apps/ios/T3Code/T3Code/SessionStore.swift")]),
                            ]),
                        ]),
                    ]),
                    turnId: "turn-1",
                    sequence: 2,
                    createdAt: "2026-03-11T10:00:01.000Z"
                ),
            ],
            checkpoints: [],
            session: nil
        )

        let items = ThreadTimelineItem.build(from: thread)

        #expect(items.map(\.id) == ["message:user-1", "activity:activity-1", "message:assistant-1"])

        guard case .activity(let activity) = items[1] else {
            Issue.record("Expected middle timeline row to be an activity.")
            return
        }

        #expect(activity.command == "bun run lint")
        #expect(activity.changedFiles == ["apps/ios/T3Code/T3Code/SessionStore.swift"])
    }

    @Test
    func unauthorizedErrorsAreModeSpecific() {
        #expect(
            ConnectionErrorFormatter.message(
                for: TransportError.serverError("Unauthorized WebSocket connection"),
                connectionMode: .token
            ) == "That auth token was rejected."
        )
        #expect(
            ConnectionErrorFormatter.message(
                for: TransportError.serverError("Unauthorized WebSocket connection"),
                connectionMode: .appAuth
            ) == "Your sign-in session expired. Sign in again."
        )
    }
}

private func makeURLSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    MockURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
