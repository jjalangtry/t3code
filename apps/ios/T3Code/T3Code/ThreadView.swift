import SwiftUI

struct ThreadView: View {
    @EnvironmentObject private var store: SessionStore
    let threadId: ThreadId

    @State private var composerText = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var thread: OrchestrationThread? {
        store.threads.first { $0.id == threadId }
    }

    private var isRunning: Bool {
        thread?.session?.status == .running
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let thread {
                            ForEach(thread.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            // Activity log for current turn
                            if let turnId = thread.session?.activeTurnId ?? thread.latestTurn?.turnId {
                                let turnActivities = thread.activities
                                    .filter { $0.turnId == turnId }
                                    .sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }

                                if !turnActivities.isEmpty {
                                    ActivityLogView(activities: turnActivities)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: thread?.messages.count) {
                    if let lastId = thread?.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Error
            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage)
                        .font(.caption)
                    Spacer()
                    Button { self.errorMessage = nil } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            // Session error
            if let sessionError = thread?.session?.lastError {
                HStack {
                    Image(systemName: "exclamationmark.octagon")
                    Text(sessionError)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                }
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            // Composer
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message...", text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if isRunning {
                    Button {
                        Task {
                            try? await store.interruptTurn(threadId: threadId)
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(thread?.title ?? "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session = thread?.session {
                    StatusBadge(status: session.status)
                }
            }
        }
    }

    private func sendMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        composerText = ""

        Task {
            do {
                try await store.sendMessage(threadId: threadId, text: text)
            } catch {
                errorMessage = error.localizedDescription
                composerText = text
            }
            isSending = false
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: OrchestrationMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant || message.role == .system {
                    HStack(spacing: 4) {
                        Image(systemName: message.role == .assistant ? "sparkles" : "info.circle")
                            .font(.caption2)
                        Text(message.role == .assistant ? "Assistant" : "System")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if message.streaming {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }

                Text(message.text.isEmpty && message.streaming ? "Thinking..." : message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(backgroundColor)
                    .foregroundStyle(foregroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(formatTime(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: .blue
        case .assistant: Color(.secondarySystemBackground)
        case .system: Color(.tertiarySystemBackground)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }

    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return ""
        }
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }
}

// MARK: - Activity Log

struct ActivityLogView: View {
    let activities: [ThreadActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activities) { activity in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: iconName(for: activity))
                        .font(.caption)
                        .foregroundStyle(iconColor(for: activity))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let detail = extractDetail(from: activity) {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func iconName(for activity: ThreadActivity) -> String {
        switch activity.tone {
        case .tool: "wrench"
        case .error: "exclamationmark.triangle"
        case .approval: "checkmark.shield"
        case .info: "info.circle"
        }
    }

    private func iconColor(for activity: ThreadActivity) -> Color {
        switch activity.tone {
        case .tool: .blue
        case .error: .red
        case .approval: .orange
        case .info: .secondary
        }
    }

    private func extractDetail(from activity: ThreadActivity) -> String? {
        guard let payload = activity.payload?.value as? [String: Any],
              let detail = payload["detail"] as? String,
              !detail.isEmpty else {
            return nil
        }
        return detail
    }
}
