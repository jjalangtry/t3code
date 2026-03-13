import PhotosUI
import SwiftUI

// MARK: - Composer Text Field

struct ComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    let canSend: Bool
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var isDictating = false
    @FocusState private var isTextFieldFocused: Bool

    private var showSendButton: Bool {
        canSend || isRunning
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isTextFieldFocused)
                .padding(.vertical, 12)

            if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.scale.combined(with: .opacity))
            } else if canSend {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    isDictating.toggle()
                    if isDictating {
                        isTextFieldFocused = true
                    }
                } label: {
                    Image(systemName: isDictating ? "mic.circle.fill" : "mic.fill")
                        .font(.system(size: isDictating ? 28 : 18, weight: .medium))
                        .foregroundStyle(isDictating ? Color.accentColor : Color.secondary)
                        .frame(width: 32, height: 32)
                        .symbolEffect(.pulse, isActive: isDictating)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .modifier(ComposerFieldModifier())
        .animation(.snappy(duration: 0.2), value: showSendButton)
        .animation(.snappy(duration: 0.2), value: isDictating)
    }
}

// MARK: - Composer Field Modifier

struct ComposerFieldModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Color.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        }
    }
}

// MARK: - Composer Menu Popover

struct ComposerMenuPopoverView: View {
    let thread: OrchestrationThread?
    @Binding var selectedPhotoItems: [PhotosPickerItem]
    let onFileImport: () -> Void
    let onInteractionModeChange: (InteractionMode) -> Void
    let onRuntimeModeChange: (RuntimeMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            actionSection("Attachments") {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 8,
                    matching: .images
                ) {
                    actionRow("Photos", systemImage: "photo.on.rectangle", detail: nil)
                }
                .buttonStyle(.plain)

                Button(action: onFileImport) {
                    actionRow("Files", systemImage: "paperclip", detail: nil)
                }
                .buttonStyle(.plain)
            }

            Divider()

            actionSection("Conversation") {
                Button { onInteractionModeChange(.default) } label: {
                    actionRow("Chat Mode", systemImage: "message", detail: thread?.interactionMode != .plan ? "Current" : nil)
                }
                .buttonStyle(.plain)

                Button { onInteractionModeChange(.plan) } label: {
                    actionRow("Plan Mode", systemImage: "list.bullet.clipboard", detail: thread?.interactionMode == .plan ? "Current" : nil)
                }
                .buttonStyle(.plain)
            }

            Divider()

            actionSection("Execution") {
                Button { onRuntimeModeChange(.approvalRequired) } label: {
                    actionRow("Supervised", systemImage: "lock", detail: thread?.runtimeMode == .approvalRequired ? "Current" : nil)
                }
                .buttonStyle(.plain)

                Button { onRuntimeModeChange(.fullAccess) } label: {
                    actionRow("Full Access", systemImage: "lock.open", detail: thread?.runtimeMode == .fullAccess ? "Current" : nil)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 290)
        .modifier(MorphingGlassModifier(cornerRadius: 20))
    }

    @ViewBuilder
    private func actionSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func actionRow(_ title: String, systemImage: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.primary)
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Morphing Glass Modifier

struct MorphingGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Color.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Inline Error Banner

struct InlineErrorBanner: View {
    let systemImage: String
    let message: String
    let dismissAction: (() -> Void)?

    init(systemImage: String, message: String, dismissAction: (() -> Void)?) {
        self.systemImage = systemImage
        self.message = message
        self.dismissAction = dismissAction
    }

    var body: some View {
        HStack {
            Image(systemName: systemImage)
            Text(message)
                .font(.caption)
            Spacer()
            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
            }
        }
        .foregroundStyle(.red)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Previews

#Preview("Composer Text Field - Empty") {
    VStack {
        ComposerTextField(
            placeholder: "Message",
            text: .constant(""),
            canSend: false,
            isRunning: false,
            onSend: {},
            onStop: {}
        )
    }
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Composer Text Field - With Text") {
    VStack {
        ComposerTextField(
            placeholder: "Message",
            text: .constant("Hello, how can I help?"),
            canSend: true,
            isRunning: false,
            onSend: {},
            onStop: {}
        )
    }
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Composer Text Field - Running") {
    VStack {
        ComposerTextField(
            placeholder: "Message",
            text: .constant(""),
            canSend: false,
            isRunning: true,
            onSend: {},
            onStop: {}
        )
    }
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Composer Menu Popover") {
    ComposerMenuPopoverView(
        thread: nil,
        selectedPhotoItems: .constant([]),
        onFileImport: {},
        onInteractionModeChange: { _ in },
        onRuntimeModeChange: { _ in }
    )
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Inline Error Banner") {
    VStack(spacing: 20) {
        InlineErrorBanner(
            systemImage: "exclamationmark.triangle",
            message: "Something went wrong",
            dismissAction: {}
        )
        
        InlineErrorBanner(
            systemImage: "exclamationmark.octagon",
            message: "Critical error occurred",
            dismissAction: nil
        )
    }
    .background(Color(.systemBackground))
}
