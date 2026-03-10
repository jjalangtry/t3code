import SwiftUI

struct SidebarView: View {
    @Environment(SessionStore.self) private var store
    @State private var showNewThread = false
    @State private var newThreadTitle = ""
    @State private var selectedProjectId: ProjectId?

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedThreadId) {
            ForEach(store.activeProjects) { project in
                Section {
                    let projectThreads = store.threads(for: project.id)
                    if projectThreads.isEmpty {
                        Text("No threads")
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
                    HStack {
                        Image(systemName: "folder")
                        Text(project.title)
                        Spacer()
                        Button {
                            selectedProjectId = project.id
                            newThreadTitle = ""
                            showNewThread = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(store.welcome?.projectName ?? "T3 Code")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                }
            }
        }
        .alert("New Thread", isPresented: $showNewThread) {
            TextField("Thread title", text: $newThreadTitle)
            Button("Create") {
                guard let projectId = selectedProjectId,
                      !newThreadTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let project = store.projects.first { $0.id == projectId }
                let model = project?.defaultModel ?? "o4-mini"
                Task {
                    if let threadId = try? await store.createThread(
                        projectId: projectId,
                        title: newThreadTitle,
                        model: model
                    ) {
                        store.selectedThreadId = threadId
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ThreadRowView: View {
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
                Text(thread.model)
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
