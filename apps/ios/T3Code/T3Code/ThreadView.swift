import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let imageOnlyBootstrapPrompt =
    "[User attached one or more images without additional text. Respond using the conversation context and the attached image(s).]"

// MARK: - Shared Date Formatters (avoid allocations per render)

private enum DateFormatting {
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

struct ThreadView: View {
    @Environment(SessionStore.self) private var store
    let threadId: ThreadId
    private let bottomAnchorId = "thread-bottom-anchor"

    @State private var composerText = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showComposerMenu = false
    @State private var showThreadActionsPopover = false
    @State private var presentedSheet: ThreadSheet?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedAttachments: [PendingComposerAttachment] = []
    @State private var showFileImporter = false
    @State private var pendingRevertTarget: PendingRevertTarget?

    private var thread: OrchestrationThread? {
        store.threads.first { $0.id == threadId }
    }

    private var isRunning: Bool {
        thread?.session?.status == .running
    }

    private var timelineItems: [ThreadTimelineItem] {
        guard let thread else { return [] }
        return ThreadTimelineItem.build(from: thread)
    }

    private var canSend: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !selectedAttachments.isEmpty) && !isSending
    }

    var body: some View {
        ZStack {
            chatBackground

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(timelineItems) { item in
                                switch item {
                                case .message(let message):
                                    MessageBubble(
                                        message: message,
                                        overrideText: store.streamingMessageId == message.id ? store.streamingText : nil
                                    )
                                    .contextMenu {
                                        Button {
                                            copyMessage(message)
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }

                                        Menu("Thread") {
                                            Button {
                                                copyThread()
                                            } label: {
                                                Label("Copy Thread", systemImage: "text.justify")
                                            }

                                            if let turnCount = revertTurnCount(for: message) {
                                                Button(role: .destructive) {
                                                    requestRevert(for: message, turnCount: turnCount)
                                                } label: {
                                                    Label("Revert to Here", systemImage: "arrow.uturn.backward")
                                                }
                                            }
                                        }
                                    } preview: {
                                        MessageBubble(
                                            message: message,
                                            overrideText: store.streamingMessageId == message.id ? store.streamingText : nil
                                        )
                                        .padding()
                                        .background(chatBackground)
                                    }
                                    .id(item.id)
                                case .activity(let activity):
                                    ActivityTimelineRow(activity: activity)
                                        .id(item.id)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorId)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: timelineItems.last?.id) { _, _ in
                        scrollToBottom(proxy, animated: true)
                    }
                    .onChange(of: store.streamingText) { _, _ in
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: threadId) { _, _ in
                        scrollToBottom(proxy, animated: false)
                    }
                }

                if let errorMessage {
                    InlineErrorBanner(
                        systemImage: "exclamationmark.triangle",
                        message: errorMessage
                    ) {
                        self.errorMessage = nil
                    }
                }

                if let sessionError = thread?.session?.lastError {
                    InlineErrorBanner(
                        systemImage: "exclamationmark.octagon",
                        message: sessionError,
                        dismissAction: nil
                    )
                }

                composerBar
            }
        }
        .navigationTitle(thread?.title ?? "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showThreadActionsPopover.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .modifier(GlassCircleModifier(tint: nil))
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .offset(x: 8, y: -4)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thread actions")
                .popover(isPresented: $showThreadActionsPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    ThreadActionPopoverView(
                        thread: thread,
                        onOpenTerminal: {
                            showThreadActionsPopover = false
                            presentedSheet = .terminal
                        },
                        onOpenGit: {
                            showThreadActionsPopover = false
                            presentedSheet = .git
                        },
                        onRuntimeModeChange: applyRuntimeMode,
                        onInteractionModeChange: applyInteractionMode,
                        onStopSession: stopSession
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await loadPhotoAttachments(newItems)
                selectedPhotoItems = []
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            Task {
                await importFileAttachments(result)
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .terminal:
                    TerminalSheetView(threadId: threadId)
                case .git:
                    GitSheetView(threadId: threadId)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Revert Thread?",
            isPresented: Binding(
                get: { pendingRevertTarget != nil },
                set: { if !$0 { pendingRevertTarget = nil } }
            ),
            presenting: pendingRevertTarget
        ) { target in
            Button("Cancel", role: .cancel) {
                pendingRevertTarget = nil
            }
            Button("Revert", role: .destructive) {
                confirmRevert(target)
            }
        } message: { target in
            Text("Revert this thread to the checkpoint near \"\(target.label)\"? Newer messages and changes in this thread will be discarded.")
        }
    }

    private var composerBar: some View {
        VStack(spacing: 10) {
            if !selectedAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedAttachments) { attachment in
                            GlassCapsuleSurface(horizontalPadding: 10, verticalPadding: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "photo")
                                        .font(.caption)
                                    Text(attachment.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Button {
                                        selectedAttachments.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Button {
                    showComposerMenu.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .modifier(GlassCircleModifier(tint: nil))
                .popover(isPresented: $showComposerMenu) {
                    VStack(alignment: .leading, spacing: 12) {
                        PhotosPicker(
                            selection: $selectedPhotoItems,
                            maxSelectionCount: 8,
                            matching: .images
                        ) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showComposerMenu = false
                            showFileImporter = true
                        } label: {
                            Label("Files", systemImage: "paperclip")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Divider()

                        HStack(spacing: 0) {
                            Button {
                                applyInteractionMode(.default)
                            } label: {
                                Text("Chat")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(thread?.interactionMode != .plan ? Color.primary : Color.secondary)
                                    .background(thread?.interactionMode != .plan ? Color.primary.opacity(0.12) : Color.clear)
                            }
                            .buttonStyle(.plain)

                            Button {
                                applyInteractionMode(.plan)
                            } label: {
                                Text("Plan")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(thread?.interactionMode == .plan ? Color.primary : Color.secondary)
                                    .background(thread?.interactionMode == .plan ? Color.primary.opacity(0.12) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .clipShape(Capsule())

                        HStack(spacing: 0) {
                            Button {
                                applyRuntimeMode(.approvalRequired)
                            } label: {
                                Text("Supervised")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(thread?.runtimeMode == .approvalRequired ? Color.primary : Color.secondary)
                                    .background(thread?.runtimeMode == .approvalRequired ? Color.primary.opacity(0.12) : Color.clear)
                            }
                            .buttonStyle(.plain)

                            Button {
                                applyRuntimeMode(.fullAccess)
                            } label: {
                                Text("Full Auto")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(thread?.runtimeMode == .fullAccess ? Color.primary : Color.secondary)
                                    .background(thread?.runtimeMode == .fullAccess ? Color.primary.opacity(0.12) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .clipShape(Capsule())
                    }
                    .padding(16)
                    .frame(width: 220)
                    .presentationCompactAdaptation(.popover)
                }

                ComposerTextField(
                    placeholder: thread?.interactionMode == .plan ? "Ask for a plan..." : "Message",
                    text: $composerText,
                    canSend: canSend,
                    isRunning: isRunning,
                    onSend: sendMessage,
                    onStop: interruptTurn
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private var statusColor: Color {
        switch thread?.session?.status {
        case .running: .green
        case .starting: .orange
        case .error: .red
        case .ready, .interrupted: .blue
        case .idle, .stopped, .none: .gray
        }
    }

    @ViewBuilder
    private func modeChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
        .overlay {
            Capsule()
                .stroke(selected ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.18), lineWidth: 0.8)
        }
    }

    private var chatBackground: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color(.secondarySystemBackground).opacity(0.96),
                Color.cyan.opacity(0.08),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 220, height: 220)
                .blur(radius: 30)
                .offset(x: 80, y: -40)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 180, height: 180)
                .blur(radius: 26)
                .offset(x: -50, y: 60)
        }
        .ignoresSafeArea()
    }

    private func copyMessage(_ message: OrchestrationMessage) {
        UIPasteboard.general.string = message.text
    }

    private func copyThread() {
        guard let thread else { return }
        let transcript = thread.messages
            .map { message in
                let speaker: String
                switch message.role {
                case .user:
                    speaker = "You"
                case .assistant:
                    speaker = "Assistant"
                case .system:
                    speaker = "System"
                }
                return "\(speaker): \(message.text)"
            }
            .joined(separator: "\n\n")
        UIPasteboard.general.string = transcript
    }

    private func revertTurnCount(for message: OrchestrationMessage) -> Int? {
        guard message.role == .assistant else { return nil }
        return thread?.checkpoints.first(where: {
            $0.assistantMessageId == message.id && $0.status == "ready"
        })?.checkpointTurnCount
    }

    private func requestRevert(for message: OrchestrationMessage, turnCount: Int) {
        let label = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingRevertTarget = PendingRevertTarget(
            turnCount: turnCount,
            label: label.isEmpty ? "this message" : String(label.prefix(60))
        )
    }

    private func confirmRevert(_ target: PendingRevertTarget) {
        pendingRevertTarget = nil
        Task {
            do {
                try await store.revertThread(threadId: threadId, turnCount: target.turnCount)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendMessage() {
        guard canSend else { return }

        let trimmedText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textToSend = trimmedText.isEmpty ? imageOnlyBootstrapPrompt : trimmedText
        let attachmentsToSend = selectedAttachments

        isSending = true
        composerText = ""
        selectedAttachments = []

        Task {
            do {
                try await store.sendMessage(
                    threadId: threadId,
                    text: textToSend,
                    attachments: attachmentsToSend
                )
            } catch {
                errorMessage = error.localizedDescription
                composerText = trimmedText
                selectedAttachments = attachmentsToSend
            }
            isSending = false
        }
    }

    private func interruptTurn() {
        Task {
            try? await store.interruptTurn(threadId: threadId)
        }
    }

    private func stopSession() {
        Task {
            do {
                try await store.stopSession(threadId: threadId)
                presentedSheet = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyRuntimeMode(_ runtimeMode: RuntimeMode) {
        guard thread?.runtimeMode != runtimeMode else { return }
        Task {
            do {
                try await store.setThreadRuntimeMode(threadId: threadId, runtimeMode: runtimeMode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyInteractionMode(_ interactionMode: InteractionMode) {
        guard thread?.interactionMode != interactionMode else { return }
        Task {
            do {
                try await store.setThreadInteractionMode(threadId: threadId, interactionMode: interactionMode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadPhotoAttachments(_ items: [PhotosPickerItem]) async {
        let maxAttachments = 4
        for item in items {
            // Check attachment limit
            let currentCount = await MainActor.run { selectedAttachments.count }
            guard currentCount < maxAttachments else {
                await MainActor.run {
                    errorMessage = "Maximum \(maxAttachments) attachments allowed."
                }
                break
            }
            
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let attachment = try makeAttachment(
                    data: data,
                    suggestedName: item.itemIdentifier ?? "Image",
                    mimeType: "image/jpeg"
                )
                await MainActor.run {
                    selectedAttachments.append(attachment)
                    showComposerMenu = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Unable to load that image."
                }
            }
        }
    }

    private func importFileAttachments(_ result: Result<[URL], any Error>) async {
        do {
            let urls = try result.get()
            for url in urls {
                let isScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let data = try Data(contentsOf: url)
                guard let mimeType = mimeType(for: url), mimeType.hasPrefix("image/") else {
                    await MainActor.run {
                        errorMessage = "Only image uploads are supported right now."
                    }
                    continue
                }

                let attachment = try makeAttachment(
                    data: data,
                    suggestedName: url.lastPathComponent,
                    mimeType: mimeType
                )
                await MainActor.run {
                    selectedAttachments.append(attachment)
                }
            }
            await MainActor.run {
                showComposerMenu = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Unable to import that file."
            }
        }
    }

    private func makeAttachment(data: Data, suggestedName: String, mimeType: String) throws -> PendingComposerAttachment {
        // Downscale large images to reduce memory usage
        let processedData: Data
        let finalMimeType: String
        
        if mimeType.hasPrefix("image/"),
           let image = UIImage(data: data) {
            let maxDimension: CGFloat = 1600
            let scale = min(maxDimension / max(image.size.width, image.size.height), 1.0)
            
            if scale < 1.0 {
                let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                let resized = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
                processedData = resized.jpegData(compressionQuality: 0.85) ?? data
                finalMimeType = "image/jpeg"
            } else {
                // Compress even if not resizing
                processedData = image.jpegData(compressionQuality: 0.85) ?? data
                finalMimeType = "image/jpeg"
            }
        } else {
            processedData = data
            finalMimeType = mimeType
        }
        
        let base64 = processedData.base64EncodedString()
        let dataURL = "data:\(finalMimeType);base64,\(base64)"
        return PendingComposerAttachment(
            id: UUID().uuidString,
            name: suggestedName,
            mimeType: finalMimeType,
            sizeBytes: processedData.count,
            dataURL: dataURL
        )
    }

    private func mimeType(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
    }
}

private enum ThreadSheet: String, Identifiable {
    case terminal
    case git

    var id: String { rawValue }
}

private struct PendingRevertTarget: Identifiable {
    let turnCount: Int
    let label: String

    var id: Int { turnCount }
}

private struct InlineErrorBanner: View {
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

private struct ComposerActionRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct MorphingGlassModifier: ViewModifier {
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

private struct ThreadActionPopoverView: View {
    let thread: OrchestrationThread?
    let onOpenTerminal: () -> Void
    let onOpenGit: () -> Void
    let onRuntimeModeChange: (RuntimeMode) -> Void
    let onInteractionModeChange: (InteractionMode) -> Void
    let onStopSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            actionSection("Workspace") {
                actionButton("Terminal", systemImage: "terminal", detail: "Worktree shell", action: onOpenTerminal)
                actionButton("Git", systemImage: "point.topleft.down.curvedto.point.bottomright.up", detail: "Status and branch actions", action: onOpenGit)
            }

            Divider()

            actionSection("Conversation") {
                actionButton("Chat Mode", systemImage: "message", detail: thread?.interactionMode == .plan ? nil : "Current") {
                    onInteractionModeChange(.default)
                }
                actionButton("Plan Mode", systemImage: "list.bullet.clipboard", detail: thread?.interactionMode == .plan ? "Current" : nil) {
                    onInteractionModeChange(.plan)
                }
            }

            Divider()

            actionSection("Execution") {
                actionButton("Supervised", systemImage: "lock", detail: thread?.runtimeMode == .approvalRequired ? "Current" : nil) {
                    onRuntimeModeChange(.approvalRequired)
                }
                actionButton("Full Access", systemImage: "lock.open", detail: thread?.runtimeMode == .fullAccess ? "Current" : nil) {
                    onRuntimeModeChange(.fullAccess)
                }
            }

            if thread?.session != nil {
                Divider()
                Button(role: .destructive, action: onStopSession) {
                    Label("Stop Session", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func actionButton(_ title: String, systemImage: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
    }
}

private struct TerminalSheetView: View {
    @Environment(SessionStore.self) private var store
    let threadId: ThreadId

    @State private var command = ""
    @State private var localError: String?

    private var snapshot: TerminalSessionSnapshot? {
        store.terminalSessions[threadId]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let localError {
                InlineErrorBanner(systemImage: "exclamationmark.triangle", message: localError, dismissAction: {
                    self.localError = nil
                })
            }

            ScrollView {
                Text(snapshot?.history.isEmpty == false ? snapshot?.history ?? "" : "Open the terminal to inspect the current worktree.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(.footnote, design: .monospaced))
                    .padding()
            }
            .background(Color(.secondarySystemBackground))

            Divider()

            GlassPanel(cornerRadius: 30) {
                HStack(spacing: 10) {
                    GlassCapsuleSurface(horizontalPadding: 14, verticalPadding: 10) {
                        TextField("Enter a command", text: $command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    let canSend = !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    GlassCircleButton(size: 38, tint: canSend ? .accentColor : .gray, isEnabled: canSend, action: sendCommand) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .padding(10)
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    Task {
                        try? await store.closeTerminal(threadId: threadId)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        do {
                            try await store.clearTerminal(threadId: threadId)
                        } catch {
                            localError = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task {
            if snapshot == nil {
                do {
                    try await store.openTerminal(threadId: threadId)
                } catch {
                    localError = error.localizedDescription
                }
            }
        }
        .onChange(of: store.terminalErrors[threadId]) { _, newValue in
            if let newValue {
                localError = newValue
            }
        }
    }

    private func sendCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let payload = trimmed.hasSuffix("\n") ? trimmed : "\(trimmed)\n"
        command = ""

        Task {
            do {
                try await store.writeTerminal(threadId: threadId, data: payload)
            } catch {
                localError = error.localizedDescription
            }
        }
    }
}

private struct GitSheetView: View {
    @Environment(SessionStore.self) private var store
    let threadId: ThreadId

    @State private var status: GitStatusResult?
    @State private var branches: [GitBranch] = []
    @State private var commitMessage = ""
    @State private var localError: String?
    @State private var isLoading = false
    @State private var isRunningAction = false

    var body: some View {
        Form {
            if let localError {
                Section {
                    Text(localError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Status") {
                if let status {
                    LabeledContent("Branch", value: status.branch ?? "Detached")
                    LabeledContent("Changes", value: status.hasWorkingTreeChanges ? "Uncommitted" : "Clean")
                    LabeledContent("Ahead", value: "\(status.aheadCount)")
                    LabeledContent("Behind", value: "\(status.behindCount)")
                } else if isLoading {
                    ProgressView()
                } else {
                    Text("No git status available yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if let status, !status.workingTree.files.isEmpty {
                Section("Files") {
                    ForEach(status.workingTree.files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path)
                                .font(.subheadline)
                            Text("+\(file.insertions)  -\(file.deletions)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !branches.isEmpty {
                Section("Branches") {
                    ForEach(branches) { branch in
                        Button {
                            checkout(branch.name)
                        } label: {
                            HStack {
                                Text(branch.name)
                                Spacer()
                                if branch.current {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Section("Actions") {
                Button("Pull Latest") {
                    pullLatest()
                }
                .disabled(isRunningAction)

                TextField("Commit message", text: $commitMessage)

                Button("Commit") {
                    runGitAction(.commit)
                }
                .disabled(isRunningAction || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Commit & Push") {
                    runGitAction(.commitPush)
                }
                .disabled(isRunningAction || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Commit, Push & PR") {
                    runGitAction(.commitPushPR)
                }
                .disabled(isRunningAction || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Git")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let gitStatus = store.gitStatus(threadId: threadId)
            async let gitBranches = store.gitListBranches(threadId: threadId)
            let resolvedStatus = try await gitStatus
            let resolvedBranches = try await gitBranches
            status = resolvedStatus
            branches = resolvedBranches.branches
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func pullLatest() {
        isRunningAction = true
        Task {
            defer { isRunningAction = false }
            do {
                _ = try await store.gitPull(threadId: threadId)
                await refresh()
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func checkout(_ branch: String) {
        isRunningAction = true
        Task {
            defer { isRunningAction = false }
            do {
                try await store.gitCheckout(threadId: threadId, branch: branch)
                await refresh()
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func runGitAction(_ action: GitStackedAction) {
        isRunningAction = true
        Task {
            defer { isRunningAction = false }
            do {
                _ = try await store.gitRunStackedAction(
                    threadId: threadId,
                    action: action,
                    commitMessage: commitMessage,
                    featureBranch: false
                )
                await refresh()
            } catch {
                localError = error.localizedDescription
            }
        }
    }
}

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
                    Text(displayedText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

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

private struct MessageBubbleSurface: ViewModifier {
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
                    .background(Color.blue.opacity(0.92))
                    .glassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                    .background(Color.clear)
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

private struct ComposerTextField: View {
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

private struct ComposerFieldModifier: ViewModifier {
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

#Preview {
    ThreadView(threadId: "preview-thread")
        .environment(SessionStore())
}
