import SwiftUI

struct SidebarView: View {
    @Environment(SessionStore.self) private var store

    @State private var sidebarSheet: SidebarSheet?
    @State private var selectedProjectId: ProjectId?
    @State private var newProjectTitle = ""
    @State private var newProjectPath = ""
    @State private var isSubmitting = false
    @State private var sidebarError: String?

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedThreadId) {
            if store.activeProjects.isEmpty {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder.badge.plus",
                    description: Text("Add a project workspace to create your first thread.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(store.activeProjects) { project in
                Section {
                    let projectThreads = store.threads(for: project.id)
                    if projectThreads.isEmpty {
                        Text("No threads yet")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(projectThreads) { thread in
                            NavigationLink(value: thread.id) {
                                ThreadRowView(thread: thread)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task {
                                        try? await store.deleteThread(threadId: thread.id)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        Label(project.title, systemImage: "folder")
                        Spacer()
                        Button {
                            beginNewThread(projectId: project.id)
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(store.welcome?.projectName ?? "T3 Code")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    beginNewProject()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }

                Button {
                    beginNewThread(projectId: selectedProjectId ?? store.activeProjects.first?.id)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(store.activeProjects.isEmpty)

                Button {
                    store.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                }
            }
        }
        .sheet(item: $sidebarSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .newProject:
                    newProjectSheet
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Unable to Continue",
            isPresented: Binding(
                get: { sidebarError != nil },
                set: { isPresented in
                    if !isPresented {
                        sidebarError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sidebarError ?? "")
        }
        .onAppear {
            if selectedProjectId == nil {
                selectedProjectId = store.selectedThread.map { $0.projectId }
                    ?? store.activeProjects.first?.id
            }
        }
        .onChange(of: store.selectedThreadId) { _, threadId in
            if let threadId,
               let thread = store.threads.first(where: { $0.id == threadId }) {
                selectedProjectId = thread.projectId
            }
        }
    }

    private var newProjectSheet: some View {
        Form {
            Section("Workspace") {
                TextField("/path/to/project", text: $newProjectPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Project name (optional)", text: $newProjectTitle)

                if let cwd = store.welcome?.cwd, !cwd.isEmpty {
                    Text("Server cwd: \(cwd)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Matches the web app flow: add a workspace root, then open a new thread inside it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("New Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismissSidebarSheet()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    submitNewProject()
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
                .disabled(isSubmitting || newProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func beginNewProject() {
        newProjectTitle = ""
        newProjectPath = store.welcome?.cwd ?? ""
        isSubmitting = false
        sidebarSheet = .newProject
    }

    private func beginNewThread(projectId: ProjectId?) {
        guard let projectId else { return }
        let project = store.activeProjects.first { $0.id == projectId }
        selectedProjectId = projectId
        let defaultModel = project?.defaultModel ?? store.preferredDefaultModel

        Task {
            do {
                let threadId = try await store.createThread(
                    projectId: projectId,
                    title: "New thread",
                    model: defaultModel,
                    runtimeMode: .fullAccess,
                    interactionMode: .default
                )
                store.selectedThreadId = threadId
            } catch {
                sidebarError = error.localizedDescription
            }
        }
    }

    private func dismissSidebarSheet() {
        isSubmitting = false
        sidebarSheet = nil
    }

    private func submitNewProject() {
        let path = newProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        isSubmitting = true
        Task {
            do {
                let projectId = try await store.createProject(
                    workspaceRoot: path,
                    title: newProjectTitle
                )
                selectedProjectId = projectId
                dismissSidebarSheet()
            } catch {
                isSubmitting = false
                sidebarError = error.localizedDescription
            }
        }
    }
}

private enum SidebarSheet: String, Identifiable {
    case newProject

    var id: String { rawValue }
}

struct ThreadRowView: View {
    @Environment(SessionStore.self) private var store
    let thread: OrchestrationThread

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(thread.title)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 6) {
                if let session = thread.session {
                    StatusBadge(status: session.status)
                }
                if store.terminalActivity[thread.id] == true {
                    Label("Terminal", systemImage: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(thread.interactionMode == .plan ? "Plan" : "Chat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(thread.runtimeMode == .fullAccess ? "Full Access" : "Supervised")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .ready, .interrupted: .blue
        case .starting: .orange
        case .error: .red
        case .idle, .stopped: .gray
        }
    }

    private var label: String {
        switch status {
        case .running: "Running"
        case .ready: "Ready"
        case .starting: "Starting"
        case .error: "Error"
        case .interrupted: "Interrupted"
        case .idle: "Idle"
        case .stopped: "Stopped"
        }
    }
}

#Preview {
    NavigationSplitView {
        SidebarView()
    } detail: {
        Text("Detail")
    }
    .environment(SessionStore())
}
