import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @State private var selectedTab = 0

    private var preferredColorScheme: ColorScheme? {
        switch store.themePreference {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var body: some View {
        if store.isConnected {
            TabView(selection: $selectedTab) {
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
                .tabItem {
                    Label("Chats", systemImage: "message")
                }
                .tag(0)

                NavigationStack {
                    SettingsView()
                }
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(1)
            }
            .preferredColorScheme(preferredColorScheme)
        } else {
            ConnectView()
                .preferredColorScheme(preferredColorScheme)
        }
    }
}

#Preview {
    ContentView()
        .environment(SessionStore())
}
