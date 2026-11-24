import SwiftUI
import UIKit

@main
struct SeafoodApp: App {
    init() {
        // 用自绘标签栏，系统 bar 只保留 TabView 的页面管理能力
        UITabBar.appearance().isHidden = true
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(SyncEngine.shared)
                .environmentObject(UpdateChecker.shared)
                .tint(Theme.signal)
        }
    }
}
