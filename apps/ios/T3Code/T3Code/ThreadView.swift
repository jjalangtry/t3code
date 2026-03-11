import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let imageOnlyBootstrapPrompt =
    "[User attached one or more images without additional text. Respond using the conversation context and the attached image(s).]"

struct ThreadView: View {
    @Environment(SessionStore.self) private var store
    let threadId: ThreadId

    @State private var composerText = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showComposerMenu = false
    @State private var presentedSheet: ThreadSheet?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedAttachments: [PendingComposerAttachment] = []
    @State private var showFileImporter = false

    private var thread: OrchestrationThread? {
        store.threads.first { $0.id == threadId }
    }

    private var isRunning: Bool {
        thread?.session?.status == .running
    }

    private var canSend: Bool {
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !selectedAttachments.isEmpty) && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let thread {
                            ForEach(thread.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

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
                .onChange(of: thread?.messages.count ?? 0) { _, _ in
                    if let lastId = thread?.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

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
        .navigationTitle(thread?.title ?? "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedSheet = .threadActions
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -2)
                    }
                }
                .accessibilityLabel("Thread actions")
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
                case .threadActions:
                    ThreadActionSheetView(
                        thread: thread,
                        presentedSheet: $presentedSheet,
                        onRuntimeModeChange: applyRuntimeMode,
                        onInteractionModeChange: applyInteractionMode,
                        onStopSession: stopSession
                    )
                case .terminal:
                    TerminalSheetView(threadId: threadId)
                case .git:
                    GitSheetView(threadId: threadId)
                }
            }
            .presentationDetents(sheet == .threadActions ? [.medium, .large] : [.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var composerBar: some View {
        VStack(spacing: 10) {
            if !selectedAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedAttachments) { attachment in
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
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                plusButton

                TextField(
                    thread?.interactionMode == .plan ? "Ask for a plan…" : "Message",
                    text: $composerText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.thinMaterial, in: Capsule())

                if isRunning {
                    Button(action: interruptTurn) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.red, in: Circle())
                    }
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(canSend ? Color.accentColor : Color.gray.opacity(0.4), in: Circle())
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.bar)
        }
    }

    private var plusButton: some View {
        Button {
            showComposerMenu.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
        }
        .popover(isPresented: $showComposerMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 8,
                    matching: .images
                ) {
                    ComposerActionRow(
                        systemImage: "photo.on.rectangle",
                        title: "Upload Image",
                        subtitle: "Pick from your photo library"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showComposerMenu = false
                    showFileImporter = true
                } label: {
                    ComposerActionRow(
                        systemImage: "paperclip",
                        title: "Upload File",
                        subtitle: "Browse files for images"
                    )
                }
                .buttonStyle(.plain)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Mode")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        modeChip(
                            title: "Chat",
                            selected: thread?.interactionMode != .plan
                        ) {
                            applyInteractionMode(.default)
                        }
                        modeChip(
                            title: "Plan",
                            selected: thread?.interactionMode == .plan
                        ) {
                            applyInteractionMode(.plan)
                        }
                    }

                    HStack(spacing: 8) {
                        modeChip(
                            title: "Supervised",
                            selected: thread?.runtimeMode == .approvalRequired
                        ) {
                            applyRuntimeMode(.approvalRequired)
                        }
                        modeChip(
                            title: "Full Access",
                            selected: thread?.runtimeMode == .fullAccess
                        ) {
                            applyRuntimeMode(.fullAccess)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 300)
            .background(.ultraThinMaterial)
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
                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
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
        for item in items {
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
        let base64 = data.base64EncodedString()
        let dataURL = "data:\(mimeType);base64,\(base64)"
        return PendingComposerAttachment(
            id: UUID().uuidString,
            name: suggestedName,
            mimeType: mimeType,
            sizeBytes: data.count,
            dataURL: dataURL
        )
    }

    private func mimeType(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }
}

private enum ThreadSheet: String, Identifiable {
    case threadActions
    case terminal
    case git

    var id: String { rawValue }
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

private struct ThreadActionSheetView: View {
    let thread: OrchestrationThread?
    @Binding var presentedSheet: ThreadSheet?
    let onRuntimeModeChange: (RuntimeMode) -> Void
    let onInteractionModeChange: (InteractionMode) -> Void
    let onStopSession: () -> Void

    var body: some View {
        Form {
            Section("Workspace") {
                Button {
                    presentedSheet = .terminal
                } label: {
                    actionLabel("Terminal", systemImage: "terminal", detail: "Bottom sheet terminal")
                }

                Button {
                    presentedSheet = .git
                } label: {
                    actionLabel("Git", systemImage: "point.topleft.down.curvedto.point.bottomright.up", detail: "Status, branches, pull, commit")
                }
            }

            Section("Conversation") {
                Button {
                    onInteractionModeChange(.default)
                } label: {
                    actionLabel("Chat Mode", systemImage: "text.bubble", detail: thread?.interactionMode == .plan ? nil : "Current")
                }

                Button {
                    onInteractionModeChange(.plan)
                } label: {
                    actionLabel("Plan Mode", systemImage: "list.bullet.clipboard", detail: thread?.interactionMode == .plan ? "Current" : nil)
                }
            }

            Section("Execution") {
                Button {
                    onRuntimeModeChange(.approvalRequired)
                } label: {
                    actionLabel("Supervised", systemImage: "lock", detail: thread?.runtimeMode == .approvalRequired ? "Current" : nil)
                }

                Button {
                    onRuntimeModeChange(.fullAccess)
                } label: {
                    actionLabel("Full Access", systemImage: "lock.open", detail: thread?.runtimeMode == .fullAccess ? "Current" : nil)
                }
            }

            if thread?.session != nil {
                Section {
                    Button(role: .destructive, action: onStopSession) {
                        Label("Stop Session", systemImage: "stop.circle")
                    }
                }
            }
        }
        .navigationTitle("Thread Actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    presentedSheet = nil
                }
            }
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String, detail: String?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

            HStack(spacing: 10) {
                TextField("Enter a command", text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.thinMaterial, in: Capsule())

                Button("Send") {
                    sendCommand()
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
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

                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text.isEmpty && message.streaming ? "Thinking..." : message.text)
                        .font(.body)

                    if let attachments = message.attachments, !attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(attachments) { attachment in
                                Label(attachment.name, systemImage: "photo")
                                    .font(.caption)
                            }
                        }
                    }
                }
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func iconName(for activity: ThreadActivity) -> String {
        switch activity.tone {
        case .info: "info.circle"
        case .tool: "wrench.and.screwdriver"
        case .approval: "checkmark.shield"
        case .error: "exclamationmark.triangle"
        }
    }

    private func iconColor(for activity: ThreadActivity) -> Color {
        switch activity.tone {
        case .info: .blue
        case .tool: .orange
        case .approval: .green
        case .error: .red
        }
    }

    private func extractDetail(from activity: ThreadActivity) -> String? {
        activity.payload?["detail"]?.stringValue
            ?? activity.payload?["text"]?.stringValue
            ?? activity.payload?["status"]?.stringValue
    }
}
