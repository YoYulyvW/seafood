import SwiftUI

struct RootView: View {
    /// "local" / "remote"；空串表示还没选过使用方式。
    @AppStorage("app_mode") private var appMode = ""
    @EnvironmentObject private var updater: UpdateChecker
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .stock
    @State private var showUpdateAlert = false

    enum Tab: Hashable {
        case stock, inbound, outbound, flow, settings
    }

    var body: some View {
        ZStack {
            if appMode.isEmpty {
                ModeSetupView()
                    .transition(.opacity)
            } else {
                tabs
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: appMode)
        .onAppear {
            autoSyncIfNeeded()
            checkUpdateOnForeground()
            checkLowStock()
        }
        .onChange(of: appMode) { _ in autoSyncIfNeeded() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                checkUpdateOnForeground()
                checkLowStock()
            }
        }
        .alert("发现新版本", isPresented: $showUpdateAlert) {
            Button("去更新") { tab = .settings }
            Button("稍后", role: .cancel) {}
        } message: {
            Text(updateAlertMessage)
        }
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

    /// 回到前台检查一次低库存；同一品类每天只推一次。
    private func checkLowStock() {
        guard !appMode.isEmpty else { return }
        guard (UserDefaults.standard.object(forKey: "lowstock_notify") as? Bool ?? true) else { return }
        Task { await LowStockNotifier.shared.check() }
    }

    private var updateAlertMessage: String {
        guard let latest = updater.latest else { return "有新版本可用。" }
        return latest.version + " (" + String(latest.build) + ") 可用，下载后交给 TrollStore 安装。"
    }

    /// 回到前台时静默检查一次更新；有新版才提示，失败不打扰。
    private func checkUpdateOnForeground() {
        guard !appMode.isEmpty else { return }
        guard !updater.checking, !updater.downloading else { return }
        Task { @MainActor in
            await updater.check()
            if updater.hasUpdate { showUpdateAlert = true }
        }
    }

    /// 远程版启动/切回时联网同步一次。syncOnLaunch 内部自己判 remote + 已配置，失败不抛。
    private func autoSyncIfNeeded() {
        guard appMode == "remote" else { return }
        Task { @MainActor in
            await SyncEngine.shared.syncOnLaunch()
        }
    }
}
