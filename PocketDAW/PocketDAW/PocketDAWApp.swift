import SwiftUI

@main
struct PocketDAWApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(Theme.accent)
                .onAppear { store.host.start() }
                .onChange(of: phase) { _, p in
                    if p == .background { if store.playing { store.stopAll() }; store.save() }
                    if p == .active { store.host.start() }
                }
        }
    }
}
