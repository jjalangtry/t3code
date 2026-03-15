import SwiftUI

@main
struct T3CodeApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onOpenURL { url in
                    store.handleDeepLink(url)
                }
        }
    }
}
