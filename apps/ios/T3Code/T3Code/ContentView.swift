import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        if store.isConnected {
            NavigationSplitView {
                SidebarView()
            } detail: {
                if let threadId = store.selectedThreadId {
                    ThreadView(threadId: threadId)
                } else {
                    ContentUnavailableView(
                        "Select a Thread",
                        systemImage: "message",
                        description: Text("Choose a thread from the sidebar to start chatting")
                    )
                }
            }
        } else {
            ConnectView()
        }
    }
}

#Preview {
    ContentView()
        .environment(SessionStore())
}
