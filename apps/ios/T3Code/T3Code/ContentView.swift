import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        if store.isConnected {
            NavigationSplitView {
                SidebarView()
            } detail: {
                if let threadId = store.selectedThreadId {
                    ThreadView(threadId: threadId)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "message")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("Select a thread")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ConnectView()
        }
    }
}
