import SwiftUI

struct RootView: View {
    /// "local" / "remote"；空串表示还没选过使用方式。
    @AppStorage("app_mode") private var appMode = ""
    @EnvironmentObject private var updater: UpdateChecker
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .stock
    @State private var showUpdateAlert = false
    @AppStorage("alert_style") private var alertStyle = "bubble"
    @State private var bubbleExpanded = false
    @State private var showOperatorPrompt = false
    @State private var mountedTabs: Set<Tab> = [.stock]
    @State private var downloadedIPA: URL?
    @AppStorage("update_skipped_build") private var skippedBuild = 0

    enum Tab: Hashable, CaseIterable {
        case stock, inbound, outbound, flow, settings

        var title: String {
            switch self {
            case .stock: return "库存"
            case .inbound: return "入库"
            case .outbound: return "出库"
            case .flow: return "流水"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .stock: return "shippingbox"
            case .inbound: return "tray.and.arrow.down"
            case .outbound: return "tray.and.arrow.up"
            case .flow: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        ZStack {
            if appMode.isEmpty {
                ModeSetupView()
                    .transition(.opacity)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    VStack(spacing: 0) {
                        if alertStyle == "bar" {
                            StockAlertBanner()
                        }
                        tabs
                    }
                    InkTabBar(index: Binding(
                        get: { Tab.allCases.firstIndex(of: tab) ?? 0 },
                        set: { tab = Tab.allCases[$0] }
                    ), titles: Tab.allCases.map { $0.title }, icons: Tab.allCases.map { $0.icon })
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 1)

                    if alertStyle == "bubble" {
                        StockAlertBubble(expanded: $bubbleExpanded)
                            .padding(.trailing, Theme.s4)
                            .padding(.bottom, 96)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: appMode)
        .onAppear {
            autoSyncIfNeeded()
            checkUpdateOnForeground()
            checkLowStock()
            StockAlertCenter.shared.refresh()
            promptOperatorIfNeeded()
        }
        .onChange(of: appMode) { _ in
            autoSyncIfNeeded()
            promptOperatorIfNeeded()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onChanged { _ in
                if bubbleExpanded { bubbleExpanded = false }
            }
        )
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                bubbleExpanded = false
            }
            if phase == .active {
                checkUpdateOnForeground()
                checkLowStock()
                StockAlertCenter.shared.refresh()
            }
        }
        .sheet(isPresented: $showOperatorPrompt) {
            OperatorPromptSheet { _ in }
        }
        .alert("新版本已下载", isPresented: $showUpdateAlert) {
            Button("立即安装") { installDownloadedUpdate() }
            Button("稍后", role: .cancel) {
                if let latest = updater.latest { skippedBuild = latest.build }
            }
        } message: {
            Text(updateAlertMessage)
        }
    }

    /// 不用系统 TabView：它会在底部留一层容器背景（也就是你看到多出来的那条）。
    /// 页面首次进入才挂载，之后常驻，切 tab 不丢输入状态。
    private var tabs: some View {
        ZStack {
            if mountedTabs.contains(.stock) { page(StockView(), .stock) }
            if mountedTabs.contains(.inbound) { page(InboundView(), .inbound) }
            if mountedTabs.contains(.outbound) { page(OutboundView(), .outbound) }
            if mountedTabs.contains(.flow) { page(FlowView(), .flow) }
            if mountedTabs.contains(.settings) { page(SettingsView(), .settings) }
        }
        .background(PaperBackground())
        .onChange(of: tab) { value in
            mountedTabs.insert(value)
            bubbleExpanded = false
        }
    }

    @ViewBuilder
    private func page<V: View>(_ content: V, _ tag: Tab) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 只挤安全区，不画任何东西：页面背景照旧通铺到屏幕底部
                Color.clear.frame(height: 76)
            }
            .opacity(tab == tag ? 1 : 0)
            .allowsHitTesting(tab == tag)
            .accessibilityHidden(tab != tag)
    }

    /// 首次安装或老数据没操作员时，提示补一个（可随机）。
    private func promptOperatorIfNeeded() {
        guard !appMode.isEmpty else { return }
        if SQLiteStore.shared.setting("operator").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showOperatorPrompt = true
        }
    }

    /// 回到前台检查一次低库存；同一品类每天只推一次。
    private func checkLowStock() {
        guard !appMode.isEmpty else { return }
        guard (UserDefaults.standard.object(forKey: "lowstock_notify") as? Bool ?? true) else { return }
        Task { await LowStockNotifier.shared.check() }
    }

    private var updateAlertMessage: String {
        guard let latest = updater.latest else { return "有新版本可用。" }
        return latest.version + " (" + String(latest.build) + ") 已下载完成，点「立即安装」会跳到 TrollStore 覆盖安装。"
    }

    /// 回到前台静默检查；有新版直接下好，再弹窗，点「立即安装」直接进 TrollStore。
    private func checkUpdateOnForeground() {
        guard !appMode.isEmpty else { return }
        guard !updater.checking, !updater.downloading else { return }
        Task { @MainActor in
            await updater.check()
            guard updater.hasUpdate, let info = updater.latest else { return }
            guard info.build != skippedBuild else { return }
            do {
                let file = try await updater.download(info)
                downloadedIPA = file
                showUpdateAlert = true
            } catch {
                ToastCenter.shared.show("更新下载失败：" + error.localizedDescription, kind: .error)
            }
        }
    }

    private func installDownloadedUpdate() {
        guard let info = updater.latest else { return }
        Task { @MainActor in
            do {
                try await updater.installWithTrollStore(info, localFile: downloadedIPA)
            } catch {
                ToastCenter.shared.show("打开 TrollStore 失败：" + error.localizedDescription, kind: .error)
            }
        }
    }

    /// 远程版启动/切回时联网同步一次。syncOnLaunch 内部自己判 remote + 已配置，失败不抛。
    private func autoSyncIfNeeded() {
        Task { @MainActor in
            await SyncEngine.shared.syncOnLaunch()
        }
    }
}
