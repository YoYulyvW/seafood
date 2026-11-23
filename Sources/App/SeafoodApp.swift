import SwiftUI

@main
struct SeafoodApp: App {
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
