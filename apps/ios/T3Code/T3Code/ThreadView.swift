import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let imageOnlyBootstrapPrompt =
    "[User attached one or more images without additional text. Respond using the conversation context and the attached image(s).]"

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
                    .padding(.bottom, composerBottomPadding)
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

            // Floating composer bar overlay - messages scroll behind this
            VStack {
                Spacer()
                floatingComposerOverlay
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
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .offset(x: 8, y: -4)
                    }
                }
                .buttonStyle(.plain)
                .modifier(GlassCircleModifier(tint: nil, isInteractive: true))
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
                        onOpenPlans: {
                            showThreadActionsPopover = false
                            presentedSheet = .plans
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
                case .plans:
                    PlansSheetView(threadId: threadId)
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

    // Padding for scroll content to account for floating composer
    private var composerBottomPadding: CGFloat {
        var height: CGFloat = 100 // Base composer height
        if errorMessage != nil { height += 40 }
        if thread?.session?.lastError != nil { height += 40 }
        if !selectedAttachments.isEmpty { height += 50 }
        return height
    }

    @ViewBuilder
    private var floatingComposerOverlay: some View {
        VStack(spacing: 0) {
            // Error banners with glass effect
            if let errorMessage {
                GlassErrorBanner(
                    systemImage: "exclamationmark.triangle",
                    message: errorMessage
                ) {
                    self.errorMessage = nil
                }
            }

            if let sessionError = thread?.session?.lastError {
                GlassErrorBanner(
                    systemImage: "exclamationmark.octagon",
                    message: sessionError,
                    dismissAction: nil
                )
            }

            // Attachments row
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            // Composer bar
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
                .modifier(GlassCircleModifier(tint: nil, isInteractive: true))
                .popover(isPresented: $showComposerMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    ComposerMenuPopoverView(
                        thread: thread,
                        selectedPhotoItems: $selectedPhotoItems,
                        onFileImport: {
                            showComposerMenu = false
                            showFileImporter = true
                        },
                        onInteractionModeChange: applyInteractionMode,
                        onRuntimeModeChange: applyRuntimeMode
                    )
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
            .padding(.bottom, 6)
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
        Color.black
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

private struct PendingRevertTarget: Identifiable {
    let turnCount: Int
    let label: String

    var id: Int { turnCount }
}

// MARK: - Previews

#Preview("Thread View") {
    ThreadView(threadId: "preview-thread")
        .environment(SessionStore())
}
