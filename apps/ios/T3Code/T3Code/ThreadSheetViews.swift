import SwiftUI

// MARK: - Thread Sheet Types

enum ThreadSheet: String, Identifiable {
    case terminal
    case git
    case plans

    var id: String { rawValue }
}

// MARK: - Terminal Sheet View

struct TerminalSheetView: View {
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
                GlassSurfaceContainer {
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

// MARK: - Git Sheet View

struct GitSheetView: View {
    @Environment(SessionStore.self) private var store
    let threadId: ThreadId

    @State private var status: GitStatusResult?
    @State private var branches: [GitBranch] = []
    @State private var commitMessage = ""
    @State private var localError: String?
    @State private var isLoading = false
    @State private var isRunningAction = false
    @State private var diffPreviewFilePath: String?
    @State private var diffPreviewText = ""
    @State private var diffLoading = false

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
                        Button {
                            openDiff(file.path)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path)
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("+\(file.insertions)  -\(file.deletions)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
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
        .sheet(
            isPresented: Binding(
                get: { diffPreviewFilePath != nil },
                set: { if !$0 { diffPreviewFilePath = nil } }
            )
        ) {
            NavigationStack {
                ScrollView {
                    if diffLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if diffPreviewText.isEmpty {
                        ContentUnavailableView(
                            "Diff Unavailable",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("No inline diff could be loaded for this file yet.")
                        )
                    } else {
                        Text(diffPreviewText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .navigationTitle(diffPreviewFilePath ?? "Diff")
                .navigationBarTitleDisplayMode(.inline)
            }
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

    private func openDiff(_ filePath: String) {
        diffPreviewFilePath = filePath
        diffPreviewText = ""
        diffLoading = true
        Task {
            defer { diffLoading = false }
            do {
                diffPreviewText = try await store.fetchInlineDiff(threadId: threadId, filePath: filePath)
            } catch {
                diffPreviewText = ""
                localError = error.localizedDescription
            }
        }
    }
}

// MARK: - Thread Action Popover

struct ThreadActionPopoverView: View {
    let thread: OrchestrationThread?
    let onOpenTerminal: () -> Void
    let onOpenGit: () -> Void
    let onOpenPlans: () -> Void
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
                actionButton("Plans", systemImage: "doc.text.magnifyingglass", detail: nil, action: onOpenPlans)
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

// MARK: - Plans Sheet View

struct PlansSheetView: View {
    @Environment(SessionStore.self) private var store
    let threadId: ThreadId

    private var thread: OrchestrationThread? {
        store.threads.first { $0.id == threadId }
    }

    private var plans: [ProposedPlan] {
        (thread?.proposedPlans ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            if plans.isEmpty {
                ContentUnavailableView(
                    "No Plans",
                    systemImage: "doc.text",
                    description: Text("Plans will appear here when the assistant proposes one.")
                )
                .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(plans) { plan in
                        GlassPanel(cornerRadius: 22) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Plan")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                MarkdownTextBlock(markdown: plan.planMarkdown)

                                HStack {
                                    Text(DateFormatting.formatTime(plan.updatedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = plan.planMarkdown
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(14)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Previews

#Preview("Terminal Sheet") {
    NavigationStack {
        TerminalSheetView(threadId: "preview-thread")
    }
    .environment(SessionStore())
}

#Preview("Git Sheet") {
    NavigationStack {
        GitSheetView(threadId: "preview-thread")
    }
    .environment(SessionStore())
}

#Preview("Thread Action Popover") {
    ThreadActionPopoverView(
        thread: nil,
        onOpenTerminal: {},
        onOpenGit: {},
        onOpenPlans: {},
        onRuntimeModeChange: { _ in },
        onInteractionModeChange: { _ in },
        onStopSession: {}
    )
    .padding()
    .background(Color.cyan.opacity(0.2))
}
