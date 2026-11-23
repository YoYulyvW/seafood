import SwiftUI

@main
struct SeafoodApp: App {
    init() {
        SQLiteStore.shared.seedIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(SyncEngine.shared)
                .environmentObject(UpdateChecker.shared)
                .tint(Theme.ink)
                .preferredColorScheme(.light)
        }
    }
}
