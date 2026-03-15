import SwiftUI

// MARK: - Shared Date Formatters (avoid allocations per render)

enum DateFormatting {
    static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let isoFormatterBasic: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    static func formatTime(_ iso: String) -> String {
        guard let date = isoFormatterWithFractional.date(from: iso)
            ?? isoFormatterBasic.date(from: iso) else {
            return ""
        }
        return timeFormatter.string(from: date)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: OrchestrationMessage
    let overrideText: String?

    init(message: OrchestrationMessage, overrideText: String? = nil) {
        self.message = message
        self.overrideText = overrideText
    }

    private var displayedText: String {
        let liveText = overrideText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !liveText.isEmpty {
            return liveText
        }
        if message.text.isEmpty && message.streaming {
            return "Thinking..."
        }
        return message.text
    }

    private var showsBubbleChrome: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 54) }

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownTextBlock(markdown: displayedText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let attachments = message.attachments, !attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(attachments) { attachment in
                                Label(attachment.name, systemImage: "photo")
                                    .font(.caption)
                            }
                        }
                    }

                    if message.streaming {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Working…")
                                .font(.caption)
                        }
                        .foregroundStyle(message.role == .user ? AnyShapeStyle(.white.opacity(0.92)) : AnyShapeStyle(.secondary))
                    }
                }
                .padding(.horizontal, showsBubbleChrome ? 14 : 0)
                .padding(.vertical, showsBubbleChrome ? 11 : 0)
                .modifier(MessageBubbleSurface(role: message.role, isEnabled: showsBubbleChrome))
                .foregroundStyle(foregroundColor)

                Text(DateFormatting.formatTime(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: message.role == .user ? 320 : .infinity, alignment: .leading)

            if message.role != .user { Spacer(minLength: 54) }
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }
}

struct MarkdownTextBlock: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.body)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Activity Timeline Row

struct ActivityTimelineRow: View {
    let activity: ThreadTimelineActivity

    var body: some View {
        HStack {
            GlassPanel(cornerRadius: 24) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: iconName(for: activity))
                        .font(.caption)
                        .foregroundStyle(iconColor(for: activity))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(activity.summary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        if let command = activity.command {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if let detail = activity.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        if !activity.changedFiles.isEmpty {
                            Text(activity.changedFiles.joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(4)
                        }

                        Text(DateFormatting.formatTime(activity.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }
            Spacer(minLength: 60)
        }
    }

    private func iconName(for activity: ThreadTimelineActivity) -> String {
        switch activity.tone {
        case .info: "info.circle"
        case .tool: "wrench.and.screwdriver"
        case .approval: "checkmark.shield"
        case .error: "exclamationmark.triangle"
        }
    }

    private func iconColor(for activity: ThreadTimelineActivity) -> Color {
        switch activity.tone {
        case .info: .blue
        case .tool: .orange
        case .approval: .green
        case .error: .red
        }
    }
}

// MARK: - Message Bubble Surface Modifier

struct MessageBubbleSurface: ViewModifier {
    let role: MessageRole
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else {
            switch role {
            case .user:
                if #available(iOS 26.0, *) {
                    content
                        .background(.clear)
                        .glassEffect(.regular.tint(.blue), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    content
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.88)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                        }
                        .shadow(color: .blue.opacity(0.22), radius: 18, y: 8)
                }
            case .assistant, .system:
                if #available(iOS 26.0, *) {
                    content
                        .background(.clear)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    content
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
                        }
                        .shadow(color: .black.opacity(0.06), radius: 20, y: 8)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Message Bubble - User") {
    MessageBubblePreviewContainer(role: .user, text: "Hello! Can you help me with a Swift question?")
}

#Preview("Message Bubble - Assistant") {
    MessageBubblePreviewContainer(role: .assistant, text: "Of course! I'd be happy to help you with Swift. What would you like to know?")
}

#Preview("Message Bubble - Streaming") {
    MessageBubblePreviewContainer(role: .assistant, text: "Let me think about that...", streaming: true)
}

// Preview helper that doesn't require full model initialization
private struct MessageBubblePreviewContainer: View {
    let role: MessageRole
    let text: String
    var streaming: Bool = false
    
    var body: some View {
        VStack(alignment: role == .user ? .trailing : .leading, spacing: 6) {
            HStack {
                if role == .user { Spacer(minLength: 54) }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if streaming {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Working…")
                                .font(.caption)
                        }
                        .foregroundStyle(role == .user ? AnyShapeStyle(.white.opacity(0.92)) : AnyShapeStyle(.secondary))
                    }
                }
                .padding(.horizontal, role == .user ? 14 : 0)
                .padding(.vertical, role == .user ? 11 : 0)
                .modifier(MessageBubbleSurface(role: role, isEnabled: role == .user))
                .foregroundStyle(role == .user ? .white : .primary)
                .frame(maxWidth: role == .user ? 320 : .infinity, alignment: .leading)
                
                if role != .user { Spacer(minLength: 54) }
            }
            
            Text("12:34 PM")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color.cyan.opacity(0.1))
    }
}

#Preview("Activity Timeline Row") {
    ActivityTimelinePreviewContainer()
}

private struct ActivityTimelinePreviewContainer: View {
    var body: some View {
        HStack {
            GlassPanel(cornerRadius: 24) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Executed bash command")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        
                        Text("ls -la ~/Documents")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        
                        Text("file1.swift\nfile2.swift")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(4)
                        
                        Text("12:34 PM")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }
            Spacer(minLength: 60)
        }
        .padding()
        .background(Color.cyan.opacity(0.1))
    }
}
