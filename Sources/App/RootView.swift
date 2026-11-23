import SwiftUI

struct RootView: View {
    /// "local" / "remote"；空串表示还没选过使用方式。
    @AppStorage("app_mode") private var appMode = ""
    @State private var tab: Tab = .stock

    enum Tab: Hashable {
        case stock, inbound, outbound, flow, settings
    }

    var body: some View {
        ZStack {
            if appMode.isEmpty {
                ModeSetupView(appMode: $appMode)
                    .transition(.opacity)
            } else {
                tabs
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: appMode)
        .onAppear { autoSyncIfNeeded() }
        .onChange(of: appMode) { _ in autoSyncIfNeeded() }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            StockView()
                .tabItem { Label("库存", systemImage: "shippingbox") }
                .tag(Tab.stock)
            InboundView()
                .tabItem { Label("入库", systemImage: "tray.and.arrow.down") }
                .tag(Tab.inbound)
            OutboundView()
                .tabItem { Label("出库", systemImage: "tray.and.arrow.up") }
                .tag(Tab.outbound)
            FlowView()
                .tabItem { Label("流水", systemImage: "list.bullet.rectangle") }
                .tag(Tab.flow)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .background(PaperBackground())
    }

    /// 远程版启动/切回时联网同步一次。失败只体现为 SyncEngine.state = .failed，不弹窗。
    private func autoSyncIfNeeded() {
        guard appMode == "remote" else { return }
        Task { @MainActor in
            guard SyncEngine.shared.isConfigured else { return }
            _ = try? await SyncEngine.shared.syncNow()
        }
    }
}
